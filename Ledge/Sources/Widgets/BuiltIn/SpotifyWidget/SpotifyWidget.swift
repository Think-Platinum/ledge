import SwiftUI
import Combine

/// Spotify widget showing current playback with album art and controls.
///
/// Supports two data sources:
/// - **AppleScript** (default) — talks to the local Spotify desktop app. No auth needed.
/// - **Spotify Web API** — uses OAuth PKCE for cross-device playback state and control.
///   Shows which device is playing (phone, speaker, etc.) and can transfer playback.
///   Requires a Spotify Client ID from developer.spotify.com.
struct SpotifyWidget {

    struct Config: Codable, Equatable {
        var showAlbumArt: Bool = true
        var showProgressBar: Bool = true
        var showAlbumColors: Bool = true
        var showSkipButtons: Bool = true
        var useWebAPI: Bool = false
        var spotifyClientID: String = ""
    }

    static let descriptor = WidgetDescriptor(
        typeID: "com.ledge.spotify",
        displayName: "Spotify",
        description: "Now playing with playback controls",
        iconSystemName: "music.note",
        minimumSize: .sixByTwo,
        defaultSize: .eightByFour,
        maximumSize: .twelveBySix,
        defaultConfiguration: try? JSONEncoder().encode(Config()),
        viewFactory: { instanceID, configStore in
            AnyView(SpotifyWidgetView(instanceID: instanceID, configStore: configStore))
        },
        settingsFactory: { instanceID, configStore in
            AnyView(SpotifySettingsView(instanceID: instanceID, configStore: configStore))
        }
    )
}

// MARK: - View

struct SpotifyWidgetView: View {
    @Environment(\.theme) private var theme
    @Environment(\.widgetBackgroundStyle) private var backgroundStyle
    let instanceID: UUID
    let configStore: WidgetConfigStore

    @State private var config = SpotifyWidget.Config()
    private let bridge = SpotifyBridge()
    private let colorExtractor = AlbumColorExtractor()
    @StateObject private var authManager = SpotifyAuthManager()
    @State private var webAPI: SpotifyWebAPI?
    @State private var state = SpotifyBridge.PlaybackState()
    @State private var isSpotifyRunning = false
    @State private var albumColors: AlbumColorExtractor.Colors?
    @State private var lastArtworkURL = ""
    /// Holds the previous artwork URL for crossfade transitions.
    @State private var previousArtworkURL = ""
    /// Controls the crossfade opacity (0 = showing old art, 1 = showing new art).
    @State private var artworkTransitionProgress: CGFloat = 1.0
    @State private var isSeeking = false
    @State private var seekPosition: Double = 0
    /// Guards against overlapping refresh tasks. If a previous Task.detached
    /// AppleScript call hasn't finished when the timer fires again, skip the poll.
    @State private var isRefreshing = false
    /// Name of the Spotify device currently playing (from Web API).
    @State private var deviceName: String = ""
    /// Type of the Spotify device (e.g. "Computer", "Smartphone") for icon.
    @State private var deviceType: String = ""

    /// Whether the Web API data source is active and authenticated.
    private var useWebAPI: Bool {
        config.useWebAPI && authManager.isAuthenticated
    }

    private let pollTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let positionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if !isSpotifyRunning {
                notRunningView
            } else if state.trackName.isEmpty {
                notPlayingView
            } else {
                nowPlayingView
            }
        }
        .onAppear {
            loadConfig()
            configureWebAPI()
            refreshState()
            // Re-extract colours if we have artwork but lost the colours
            // (can happen when the view hierarchy rebuilds due to theme/env changes)
            if albumColors == nil && !lastArtworkURL.isEmpty {
                extractColors(from: lastArtworkURL)
            }
        }
        .onReceive(pollTimer) { _ in refreshState() }
        .onReceive(positionTimer) { _ in
            if state.isPlaying && !isSeeking {
                state.playerPosition += 1
            }
        }
        .onReceive(configStore.configDidChange) { changedID in
            if changedID == instanceID { loadConfig() }
        }
    }

    // MARK: - Now Playing (Size-Adaptive)

    private var nowPlayingView: some View {
        GeometryReader { geometry in
            let h = geometry.size.height

            ZStack {
                // Radial album colour glow — radiates from the album art position
                albumColorGlow(size: geometry.size)

                if h < 150 {
                    ultraCompactLayout(size: geometry.size)
                } else if h < 280 {
                    compactLayout(size: geometry.size)
                } else {
                    fullLayout(size: geometry.size)
                }
            }
        }
        .onChange(of: state.artworkURL) { _, newURL in
            if !newURL.isEmpty && newURL != lastArtworkURL {
                // Store the old URL for crossfade, then start transition
                previousArtworkURL = lastArtworkURL
                lastArtworkURL = newURL

                // Reset transition progress — old art visible
                artworkTransitionProgress = 0.0

                // Animate crossfade in sync with the background colour transition (0.8s)
                withAnimation(.easeInOut(duration: 0.8)) {
                    artworkTransitionProgress = 1.0
                }

                // Extract colours — also animates at 0.8s easeInOut internally
                extractColors(from: newURL)
            }
        }
    }

    // MARK: - Ultra-Compact Layout (1 row)
    //
    // ┌──────────────────────────────────────────────────────────────┐
    // │ ┌────┐  Track Name    Artist           ⏮   ▶   ⏭          │
    // │ └────┘                                                      │
    // └──────────────────────────────────────────────────────────────┘

    @ViewBuilder
    private func ultraCompactLayout(size: CGSize) -> some View {
        let artSize = size.height - 16

        HStack(spacing: 10) {
            // Small album art
            albumArtView(size: artSize, cornerRadius: 6, placeholderIconSize: 16)

            // Track info — minimal
            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(
                    text: state.trackName,
                    font: .system(size: 18, weight: .semibold),
                    color: .white,
                    trigger: state.trackName
                )
                MarqueeText(
                    text: state.artistName,
                    font: .system(size: 14),
                    color: .white.opacity(0.6),
                    trigger: state.artistName
                )
                if !deviceName.isEmpty {
                    deviceLabel(fontSize: 10)
                }
            }
            .frame(minWidth: 80)

            Spacer(minLength: 4)

            // Just basic playback controls — no progress, no volume
            // Sized for touch targets (min 44pt tap area)
            HStack(spacing: 20) {
                Button { doPreviousTrack() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 18))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                Button { doPlayPause() } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                Button { doNextTrack() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 18))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    // MARK: - Compact Layout (2 rows)
    //
    // ┌──────────────────────────────────────────────────────────────┐
    // │ ┌────────┐  Track Name                                      │
    // │ │        │  Artist                                          │
    // │ │  Art   │  Album                                           │
    // │ │        │  ══════════●══════════  0:43 / 5:57              │
    // │ └────────┘  ⏮  ◀10  ▶  10▶  ⏭           🔊━━━  ▫         │
    // └──────────────────────────────────────────────────────────────┘

    @ViewBuilder
    private func compactLayout(size: CGSize) -> some View {
        let artSize = size.height - 20

        HStack(spacing: 12) {
            // Album art
            albumArtView(size: artSize, cornerRadius: 8, placeholderIconSize: 20)

            // Right side: track info → progress → controls (stacked vertically)
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)

                // Track info — larger fonts for touchscreen readability
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(
                        text: state.trackName,
                        font: .system(size: 22, weight: .semibold),
                        color: .white,
                        trigger: state.trackName
                    )
                    MarqueeText(
                        text: state.artistName,
                        font: .system(size: 16),
                        color: .white.opacity(0.65),
                        trigger: state.artistName
                    )
                    MarqueeText(
                        text: state.albumName,
                        font: .system(size: 14),
                        color: .white.opacity(0.4),
                        trigger: state.albumName
                    )
                    if !deviceName.isEmpty {
                        deviceLabel(fontSize: 11)
                    }
                }

                Spacer(minLength: 4)

                // Progress bar (fills available width)
                if config.showProgressBar, state.trackDuration > 0 {
                    progressBar(barHeight: 6, timeFont: .system(size: 11, design: .monospaced))
                }

                // Controls + volume
                compactControls
                    .padding(.top, 4)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private var compactControls: some View {
        HStack(spacing: 0) {
            Spacer()

            // Centered playback controls — sized for touch (min 44pt tap area)
            HStack(spacing: 20) {
                Button { doPreviousTrack() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 18))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                if config.showSkipButtons {
                    Button { doSkipBackward(10) } label: {
                        Image(systemName: "gobackward.10").font(.system(size: 16))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }
                Button { doPlayPause() } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                if config.showSkipButtons {
                    Button { doSkipForward(10) } label: {
                        Image(systemName: "goforward.10").font(.system(size: 16))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }
                Button { doNextTrack() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 18))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)

            Spacer()

            // Volume + Spotify link — right-aligned
            HStack(spacing: 5) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                Slider(
                    value: Binding(
                        get: { Double(state.volume) },
                        set: { state.volume = Int($0); doSetVolume(Int($0)) }
                    ),
                    in: 0...100
                )
                .frame(width: 55)
                .tint(.green)
                .controlSize(.mini)

                Button { bridge.activateSpotify() } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Full Layout (3+ rows)
    //
    // ┌─────────────────────────────────────────────────────────────┐
    // │ ┌──────────┐  Track Name (28pt)                            │
    // │ │          │  Artist (20pt)                                 │
    // │ │  Album   │  Album (16pt)                                 │
    // │ │   Art    │                                                │
    // │ │          │  ══════════●══════════  1:23 / 4:56           │
    // │ │          │  ⏮  ◀10  ▶  10▶  ⏭           🔊━━━  ▫      │
    // │ └──────────┘                                                │
    // └─────────────────────────────────────────────────────────────┘

    @ViewBuilder
    private func fullLayout(size: CGSize) -> some View {
        let artSize = size.height - 24

        HStack(spacing: 0) {
            // Album art — full height with padding
            albumArtView(size: artSize, cornerRadius: 10, placeholderIconSize: 36)
                .padding(.leading, 12)
                .padding(.vertical, 12)

            // Track info + controls
            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                // Track info
                VStack(alignment: .leading, spacing: 3) {
                    MarqueeText(
                        text: state.trackName,
                        font: .system(size: 28, weight: .semibold),
                        color: .white,
                        trigger: state.trackName
                    )
                    MarqueeText(
                        text: state.artistName,
                        font: .system(size: 20),
                        color: .white.opacity(0.75),
                        trigger: state.artistName
                    )
                    MarqueeText(
                        text: state.albumName,
                        font: .system(size: 16),
                        color: .white.opacity(0.5),
                        trigger: state.albumName
                    )
                    if !deviceName.isEmpty {
                        deviceLabel(fontSize: 12)
                    }
                }

                Spacer()

                // Progress bar
                if config.showProgressBar, state.trackDuration > 0 {
                    progressBar(barHeight: 8, timeFont: .system(size: 12, design: .monospaced))
                }

                // Controls
                fullControlsRow
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Shared Progress Bar

    private func progressBar(barHeight: CGFloat, timeFont: Font) -> some View {
        VStack(spacing: barHeight < 6 ? 1 : 3) {
            GeometryReader { barGeo in
                let progress = isSeeking
                    ? min(seekPosition / state.trackDuration, 1.0)
                    : min(state.playerPosition / state.trackDuration, 1.0)
                let barWidth = barGeo.size.width

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: barHeight / 2)
                        .fill(.white.opacity(0.2))
                        .frame(height: barHeight)
                    RoundedRectangle(cornerRadius: barHeight / 2)
                        .fill(Color.green)
                        .frame(width: barWidth * progress, height: barHeight)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isSeeking = true
                            let fraction = max(0, min(value.location.x / barWidth, 1.0))
                            seekPosition = fraction * state.trackDuration
                        }
                        .onEnded { value in
                            let fraction = max(0, min(value.location.x / barWidth, 1.0))
                            let position = fraction * state.trackDuration
                            doSeek(position)
                            state.playerPosition = position
                            isSeeking = false
                        }
                )
            }
            .frame(height: barHeight + 8)

            HStack {
                Text(formatTime(isSeeking ? seekPosition : state.playerPosition))
                Spacer()
                Text(formatTime(state.trackDuration))
            }
            .font(timeFont)
            .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Full Controls

    private var fullControlsRow: some View {
        HStack(spacing: 0) {
            Spacer()

            // Centered playback controls — larger touch targets
            HStack(spacing: 24) {
                Button { doPreviousTrack() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 22))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                if config.showSkipButtons {
                    Button { doSkipBackward(10) } label: {
                        Image(systemName: "gobackward.10").font(.system(size: 20))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }
                Button { doPlayPause() } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 36))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                if config.showSkipButtons {
                    Button { doSkipForward(10) } label: {
                        Image(systemName: "goforward.10").font(.system(size: 20))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }
                Button { doNextTrack() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 22))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 14)
                Slider(
                    value: Binding(
                        get: { Double(state.volume) },
                        set: { state.volume = Int($0); doSetVolume(Int($0)) }
                    ),
                    in: 0...100
                )
                .frame(width: 70)
                .tint(.green)
                .controlSize(.mini)

                Button { bridge.activateSpotify() } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Album Art (Crossfade)

    @ViewBuilder
    private func albumArtView(size: CGFloat, cornerRadius: CGFloat, placeholderIconSize: CGFloat) -> some View {
        if config.showAlbumArt, !state.artworkURL.isEmpty {
            ZStack {
                // Previous artwork (fading out)
                if !previousArtworkURL.isEmpty, artworkTransitionProgress < 1.0,
                   let oldURL = URL(string: previousArtworkURL) {
                    AsyncImage(url: oldURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle()
                            .fill(.white.opacity(0.08))
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: placeholderIconSize))
                                    .foregroundStyle(.white.opacity(0.3))
                            )
                    }
                    .opacity(1.0 - artworkTransitionProgress)
                }

                // Current artwork (fading in)
                if let url = URL(string: state.artworkURL) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                            .opacity(artworkTransitionProgress)
                    } placeholder: {
                        Rectangle()
                            .fill(.white.opacity(0.08))
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: placeholderIconSize))
                                    .foregroundStyle(.white.opacity(0.3))
                            )
                            .opacity(artworkTransitionProgress)
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    // MARK: - Album Colour Glow

    /// Renders a radial glow emanating from the album art position,
    /// using the extracted album colours.
    ///
    /// Behaviour changes with the widget background style:
    /// - **Solid / Blur**: Glow radiates from the album art and fades
    ///   to clear at the edges — the container background (theme colour
    ///   or frosted blur) shows through where the glow ends.
    /// - **Transparent**: No glow at all — the widget is fully see-through
    ///   and only the album art, text, and controls are visible.
    @ViewBuilder
    private func albumColorGlow(size: CGSize) -> some View {
        // In transparent mode, no background glow — widget is fully clear
        if backgroundStyle == .transparent {
            EmptyView()
        } else if config.showAlbumColors, let colors = albumColors {
            let artSize = artSizeForHeight(size.height)

            // Anchor point: centre of the album art (left-aligned with padding)
            let artCenterX = artPaddingForHeight(size.height) + artSize / 2
            let artCenterY = size.height / 2

            // Normalise the anchor to UnitPoint (0-1 range)
            let anchorX = artCenterX / max(size.width, 1)
            let anchorY = artCenterY / max(size.height, 1)

            // The glow extends past the art and fades to clear.
            // Layered radial gradients create depth — primary near
            // the art, secondary wash extending further right.
            ZStack {
                // Primary colour — strong near the art, fades outward
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: colors.primary.opacity(0.9), location: 0.0),
                        .init(color: colors.primary.opacity(0.6), location: 0.25),
                        .init(color: colors.secondary.opacity(0.3), location: 0.55),
                        .init(color: .clear, location: 1.0)
                    ]),
                    center: UnitPoint(x: anchorX, y: anchorY),
                    startRadius: artSize * 0.3,
                    endRadius: max(size.width, size.height) * 0.95
                )

                // Secondary accent — a softer fill that extends further
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: colors.secondary.opacity(0.4), location: 0.0),
                        .init(color: colors.secondary.opacity(0.15), location: 0.5),
                        .init(color: .clear, location: 1.0)
                    ]),
                    center: UnitPoint(x: anchorX * 1.5, y: anchorY),
                    startRadius: artSize * 0.5,
                    endRadius: size.width * 0.8
                )
            }
        }
    }

    /// Returns the album art size for a given widget height
    /// (mirrors the calculation in each layout function).
    private func artSizeForHeight(_ height: CGFloat) -> CGFloat {
        if height < 150 {
            return height - 16     // ultraCompact
        } else if height < 280 {
            return height - 20     // compact
        } else {
            return height - 24     // full
        }
    }

    /// Returns the leading padding before album art for a given widget height.
    private func artPaddingForHeight(_ height: CGFloat) -> CGFloat {
        if height < 150 {
            return 8               // ultraCompact: .padding(.horizontal, 8)
        } else if height < 280 {
            return 10              // compact: .padding(.horizontal, 10)
        } else {
            return 12              // full: .padding(.leading, 12)
        }
    }

    // MARK: - Placeholder States

    private var notRunningView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 32))
                .foregroundColor(theme.tertiaryText)
            Text(useWebAPI ? "No Active Device" : "Spotify Not Running")
                .font(.system(size: 14))
                .foregroundColor(theme.tertiaryText)
            if !useWebAPI {
                Button {
                    bridge.activateSpotify()
                } label: {
                    Text("Open Spotify")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(theme.primaryText.opacity(0.1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notPlayingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 32))
                .foregroundColor(theme.tertiaryText)
            Text("Not Playing")
                .font(.system(size: 14))
                .foregroundColor(theme.tertiaryText)
            Button {
                doPlayPause()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 24))
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var volumeIcon: String {
        if state.volume == 0 { return "speaker.slash.fill" }
        if state.volume < 33 { return "speaker.wave.1.fill" }
        if state.volume < 66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: - Device Label

    /// Shows "Playing on [device]" with an appropriate SF Symbol icon.
    private func deviceLabel(fontSize: CGFloat) -> some View {
        HStack(spacing: 3) {
            Image(systemName: deviceSystemImage)
                .font(.system(size: fontSize - 1))
            Text("Playing on \(deviceName)")
                .font(.system(size: fontSize))
                .lineLimit(1)
        }
        .foregroundStyle(.green.opacity(0.7))
        .padding(.top, 1)
    }

    /// SF Symbol for the current device type.
    private var deviceSystemImage: String {
        switch deviceType.lowercased() {
        case "computer": return "laptopcomputer"
        case "smartphone": return "iphone"
        case "speaker": return "hifispeaker"
        case "tv": return "tv"
        case "tablet": return "ipad"
        case "automobile": return "car"
        case "castaudio", "castdevice": return "airplayaudio"
        default: return "speaker.wave.2"
        }
    }

    // MARK: - Playback Control Wrappers

    /// Play/pause — routes through Web API when active, otherwise AppleScript.
    private func doPlayPause() {
        if useWebAPI, let api = webAPI {
            Task {
                do {
                    if state.isPlaying {
                        try await api.pause()
                    } else {
                        try await api.play()
                    }
                } catch {}
                refreshAfterDelay()
            }
        } else {
            bridge.playPause()
            refreshAfterDelay()
        }
    }

    private func doNextTrack() {
        if useWebAPI, let api = webAPI {
            Task {
                try? await api.nextTrack()
                refreshAfterDelay()
            }
        } else {
            bridge.nextTrack()
            refreshAfterDelay()
        }
    }

    private func doPreviousTrack() {
        if useWebAPI, let api = webAPI {
            Task {
                try? await api.previousTrack()
                refreshAfterDelay()
            }
        } else {
            bridge.previousTrack()
            refreshAfterDelay()
        }
    }

    private func doSkipForward(_ seconds: Double) {
        if useWebAPI, let api = webAPI {
            Task {
                let newPos = min(state.playerPosition + seconds, state.trackDuration)
                try? await api.seek(positionMs: Int(newPos * 1000))
                refreshAfterDelay()
            }
        } else {
            bridge.skipForward(seconds)
            refreshAfterDelay()
        }
    }

    private func doSkipBackward(_ seconds: Double) {
        if useWebAPI, let api = webAPI {
            Task {
                let newPos = max(state.playerPosition - seconds, 0)
                try? await api.seek(positionMs: Int(newPos * 1000))
                refreshAfterDelay()
            }
        } else {
            bridge.skipBackward(seconds)
            refreshAfterDelay()
        }
    }

    private func doSeek(_ seconds: Double) {
        if useWebAPI, let api = webAPI {
            Task { try? await api.seek(positionMs: Int(seconds * 1000)) }
        } else {
            bridge.setPosition(seconds)
        }
    }

    private func doSetVolume(_ volume: Int) {
        if useWebAPI, let api = webAPI {
            Task { try? await api.setVolume(percent: volume) }
        } else {
            bridge.setVolume(volume)
        }
    }

    // MARK: - Helpers

    private func extractColors(from urlString: String) {
        let extractor = colorExtractor
        Task.detached {
            let colors = await extractor.extract(from: urlString)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.8)) {
                    albumColors = colors
                }
            }
        }
    }

    private func refreshAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            refreshState()
        }
    }

    private func refreshState() {
        // Skip if a previous refresh is still in flight
        guard !isRefreshing else { return }
        isRefreshing = true

        if useWebAPI, let api = webAPI {
            // Web API path — async, no AppleScript
            Task {
                defer { isRefreshing = false }
                do {
                    if let playback = try await api.getPlaybackState() {
                        isSpotifyRunning = true
                        state = SpotifyBridge.PlaybackState(
                            isPlaying: playback.isPlaying,
                            trackName: playback.item?.name ?? "",
                            artistName: playback.item?.artistName ?? "",
                            albumName: playback.item?.album.name ?? "",
                            artworkURL: playback.item?.album.imageURL ?? "",
                            trackDuration: Double(playback.item?.durationMs ?? 0) / 1000.0,
                            playerPosition: Double(playback.progressMs ?? 0) / 1000.0,
                            volume: playback.device?.volumePercent ?? state.volume
                        )
                        deviceName = playback.device?.name ?? ""
                        deviceType = playback.device?.type ?? ""
                    } else {
                        // No active playback but API responded (204 No Content)
                        isSpotifyRunning = true
                        state = SpotifyBridge.PlaybackState()
                        deviceName = ""
                        deviceType = ""
                    }
                } catch SpotifyWebAPI.SpotifyAPIError.noActiveDevice {
                    // 404 = no active device — Spotify is running, just nothing playing
                    isSpotifyRunning = true
                    state = SpotifyBridge.PlaybackState()
                    deviceName = ""
                    deviceType = ""
                } catch {
                    // Real API error — fall back to AppleScript to check local Spotify
                    let b = bridge
                    let running = await Task.detached { b.isSpotifyRunning() }.value
                    isSpotifyRunning = running
                    if running {
                        let newState = await Task.detached { b.fetchPlaybackState() }.value
                        state = newState
                    } else {
                        state = SpotifyBridge.PlaybackState()
                    }
                    deviceName = ""
                    deviceType = ""
                }
            }
        } else {
            // AppleScript path — original behaviour
            let b = bridge
            Task.detached {
                let running = b.isSpotifyRunning()
                let newState = running ? b.fetchPlaybackState() : SpotifyBridge.PlaybackState()
                await MainActor.run {
                    isSpotifyRunning = running
                    state = newState
                    deviceName = ""
                    deviceType = ""
                    isRefreshing = false
                }
            }
        }
    }

    /// Configure the Web API client and auth manager with the current client ID.
    private func configureWebAPI() {
        authManager.clientID = config.spotifyClientID
        if webAPI == nil {
            webAPI = SpotifyWebAPI(authManager: authManager)
        }
    }

    private func loadConfig() {
        if let saved: SpotifyWidget.Config = configStore.read(instanceID: instanceID, as: SpotifyWidget.Config.self) {
            config = saved
        }
        // Keep auth manager in sync with config
        authManager.clientID = config.spotifyClientID
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Marquee Text (bouncing scroll for overflowing text + reveal animation)

/// Displays text that bounces back and forth when it's too wide for its container.
/// When the text changes, a left-to-right reveal sweep animates the new text in,
/// giving a character-by-character appearance effect.
///
/// Uses PhaseAnimator (macOS 14+) to cycle between start and end offsets for scrolling.
private struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    let trigger: String

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    /// The text actually displayed — lags behind `text` so the old string
    /// is visible during the fade-out phase before swapping to the new one.
    @State private var displayText: String = ""
    /// Controls the left-to-right reveal sweep (0 = hidden, 1 = fully visible).
    @State private var revealProgress: CGFloat = 1.0
    /// Controls the overall text opacity for fade-out / fade-in transitions.
    @State private var textOpacity: CGFloat = 1.0
    /// True while a transition is in progress (prevents overlapping animations).
    @State private var isTransitioning = false

    /// Only scroll if the text overflows by more than 10pt.
    /// Prevents unnecessary scrolling for tiny measurement differences
    /// during layout transitions.
    private var overflow: CGFloat { max(textWidth - containerWidth - 10, 0) }

    var body: some View {
        // Hidden text establishes the natural single-line layout frame
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .overlay {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { containerWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in containerWidth = w }
                }
            }
            .overlay(alignment: .leading) {
                if overflow > 0 {
                    let scrollDuration = max(Double(overflow) / 30.0, 1.0)

                    PhaseAnimator([false, true], trigger: trigger) { scrolled in
                        innerText
                            .offset(x: scrolled ? -overflow : 0)
                    } animation: { phase in
                        phase
                            ? .linear(duration: scrollDuration).delay(2.0)
                            : .linear(duration: scrollDuration * 0.75).delay(1.5)
                    }
                    .clipped()
                } else {
                    innerText
                }
            }
            .onChange(of: text) { oldValue, newValue in
                // Only animate when the actual content changes
                if oldValue != newValue && !newValue.isEmpty {
                    guard !isTransitioning else { return }
                    isTransitioning = true

                    // Phase 1: Fade out the OLD text (1 second)
                    // displayText still shows the old string here
                    withAnimation(.easeIn(duration: 1.0)) {
                        textOpacity = 0
                    }

                    // Phase 2: After fade-out, swap to new text and fade in (2 seconds)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        displayText = newValue
                        revealProgress = 0
                        withAnimation(.easeOut(duration: 2.0)) {
                            textOpacity = 1.0
                            revealProgress = 1.0
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            isTransitioning = false
                        }
                    }
                }
            }
            .onAppear {
                displayText = text
            }
    }

    private var innerText: some View {
        Text(displayText)
            .font(font)
            .foregroundStyle(color)
            .fixedSize(horizontal: true, vertical: false)
            .opacity(textOpacity)
            .mask(revealMask)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { textWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in textWidth = w }
                }
            )
    }

    /// A gradient mask that sweeps left-to-right to reveal text.
    /// When revealProgress is 1.0, the mask is fully opaque (no effect).
    /// When animating from 0 → 1, it creates a soft "wipe" that gives
    /// the appearance of characters fading in from left to right.
    @ViewBuilder
    private var revealMask: some View {
        if revealProgress >= 1.0 {
            // Fully revealed — no mask needed
            Rectangle()
        } else {
            GeometryReader { geo in
                let sweepWidth = geo.size.width + 40  // extra for soft edge
                let offset = -sweepWidth + (sweepWidth + geo.size.width) * revealProgress

                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.7),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: sweepWidth)
                .offset(x: offset)
            }
        }
    }
}

// MARK: - Settings

struct SpotifySettingsView: View {
    let instanceID: UUID
    let configStore: WidgetConfigStore

    @State private var config = SpotifyWidget.Config()
    @StateObject private var authManager = SpotifyAuthManager()
    @State private var webAPI: SpotifyWebAPI?
    @State private var devices: [SpotifyWebAPI.Device] = []
    @State private var isLoadingDevices = false
    @State private var showingSetupGuide = false

    var body: some View {
        Form {
            // MARK: Display Options
            Section("Display") {
                Toggle("Show album art", isOn: $config.showAlbumArt)
                Toggle("Show progress bar", isOn: $config.showProgressBar)
                Toggle("Album art color background", isOn: $config.showAlbumColors)
                Toggle("Show skip 10s buttons", isOn: $config.showSkipButtons)
            }

            // MARK: Spotify Web API
            Section("Spotify Web API") {
                Toggle("Use Spotify Web API", isOn: $config.useWebAPI)

                if config.useWebAPI {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Client ID")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Paste your Spotify Client ID", text: $config.spotifyClientID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    .padding(.vertical, 2)

                    HStack(spacing: 4) {
                        Text("Redirect URI:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(SpotifyAuthManager.redirectURI)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Button {
                        showingSetupGuide = true
                    } label: {
                        Label("Setup Guide", systemImage: "questionmark.circle")
                            .font(.callout)
                    }

                    // Auth status and actions
                    if authManager.isAuthenticated {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Signed in as \(authManager.userDisplayName ?? "Spotify User")")
                                .font(.callout)
                        }
                        .padding(.vertical, 2)

                        Button("Sign Out") {
                            authManager.logout()
                            devices = []
                        }
                        .foregroundStyle(.red)
                    } else {
                        if authManager.isAuthenticating {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Waiting for Spotify authorization…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Button("Sign in with Spotify") {
                                authManager.clientID = config.spotifyClientID
                                authManager.login()
                            }
                            .disabled(config.spotifyClientID.isEmpty)
                        }

                        if let error = authManager.error {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            // MARK: Devices
            if config.useWebAPI && authManager.isAuthenticated {
                Section("Devices") {
                    if isLoadingDevices {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Loading devices…").font(.callout).foregroundStyle(.secondary)
                        }
                    } else if devices.isEmpty {
                        Text("No devices found. Open Spotify on a device to see it here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(devices) { device in
                            HStack(spacing: 8) {
                                Image(systemName: device.systemImage)
                                    .font(.system(size: 14))
                                    .foregroundStyle(device.isActive ? .green : .secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(device.name)
                                        .font(.callout)
                                        .foregroundStyle(device.isActive ? .primary : .secondary)
                                    if device.isActive {
                                        Text("Currently playing")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    }
                                }
                                Spacer()
                                if let vol = device.volumePercent {
                                    Text("\(vol)%")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if !device.isActive {
                                    Button("Transfer") {
                                        transferPlayback(to: device)
                                    }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }

                    Button {
                        loadDevices()
                    } label: {
                        Label("Refresh Devices", systemImage: "arrow.clockwise")
                            .font(.callout)
                    }
                }
            }
        }
        .onAppear {
            loadConfig()
            authManager.clientID = config.spotifyClientID
            if webAPI == nil {
                webAPI = SpotifyWebAPI(authManager: authManager)
            }
            if config.useWebAPI && authManager.isAuthenticated {
                loadDevices()
            }
        }
        .sheet(isPresented: $showingSetupGuide) {
            SpotifySetupGuide()
        }
        .onChange(of: config) { _, _ in saveConfig() }
        .onChange(of: authManager.isAuthenticated) { _, authenticated in
            if authenticated && config.useWebAPI {
                loadDevices()
            }
        }
    }

    private func loadConfig() {
        if let saved: SpotifyWidget.Config = configStore.read(instanceID: instanceID, as: SpotifyWidget.Config.self) {
            config = saved
        }
    }

    private func saveConfig() {
        configStore.write(instanceID: instanceID, value: config)
    }

    private func loadDevices() {
        guard let api = webAPI else { return }
        isLoadingDevices = true
        Task {
            do {
                devices = try await api.getDevices()
            } catch {
                devices = []
            }
            isLoadingDevices = false
        }
    }

    private func transferPlayback(to device: SpotifyWebAPI.Device) {
        guard let api = webAPI, let id = device.id else { return }
        Task {
            try? await api.transferPlayback(to: id)
            try? await Task.sleep(for: .seconds(1))
            loadDevices()
        }
    }
}
