import SwiftUI
import Combine

/// Spotify widget showing current playback with album art and controls.
///
/// Supports two data sources:
/// - **AppleScript** (default) — talks to the local Spotify desktop app. No auth needed.
/// - **Spotify Web API** — uses OAuth PKCE for cross-device playback state and control.
///   Shows which device is playing (phone, speaker, etc.) and can transfer playback.
///   Requires a Spotify Client ID from developer.spotify.com.
/// How album art colours/imagery are used as the widget background.
enum AlbumArtStyle: String, Codable, CaseIterable {
    case none         = "None"
    case edgeFade     = "Edge Fade"
    case frostedGlass = "Frosted Glass"
    case vinylAura    = "Vinyl Aura"
    case colorBands   = "Color Bands"

    var displayName: String { rawValue }
}

struct SpotifyWidget {

    struct Config: Codable, Equatable {
        var showAlbumArt: Bool = true
        var showProgressBar: Bool = true
        var albumArtStyle: AlbumArtStyle = .edgeFade
        var showSkipButtons: Bool = false
        var useWebAPI: Bool = false
        var spotifyClientID: String = ""

        private enum CodingKeys: String, CodingKey {
            case showAlbumArt, showProgressBar, albumArtStyle, showSkipButtons, useWebAPI, spotifyClientID
            case legacyShowAlbumColors = "showAlbumColors"
        }

        init() {}

        init(showAlbumArt: Bool = true, showProgressBar: Bool = true, albumArtStyle: AlbumArtStyle = .edgeFade, showSkipButtons: Bool = false, useWebAPI: Bool = false, spotifyClientID: String = "") {
            self.showAlbumArt = showAlbumArt
            self.showProgressBar = showProgressBar
            self.albumArtStyle = albumArtStyle
            self.showSkipButtons = showSkipButtons
            self.useWebAPI = useWebAPI
            self.spotifyClientID = spotifyClientID
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            showAlbumArt = try container.decodeIfPresent(Bool.self, forKey: .showAlbumArt) ?? true
            showProgressBar = try container.decodeIfPresent(Bool.self, forKey: .showProgressBar) ?? true
            showSkipButtons = try container.decodeIfPresent(Bool.self, forKey: .showSkipButtons) ?? false
            useWebAPI = try container.decodeIfPresent(Bool.self, forKey: .useWebAPI) ?? false
            spotifyClientID = try container.decodeIfPresent(String.self, forKey: .spotifyClientID) ?? ""

            if let style = try? container.decode(AlbumArtStyle.self, forKey: .albumArtStyle) {
                albumArtStyle = style
            } else if let legacy = try? container.decode(Bool.self, forKey: .legacyShowAlbumColors) {
                albumArtStyle = legacy ? .edgeFade : .none
            } else {
                albumArtStyle = .edgeFade
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(showAlbumArt, forKey: .showAlbumArt)
            try container.encode(showProgressBar, forKey: .showProgressBar)
            try container.encode(albumArtStyle, forKey: .albumArtStyle)
            try container.encode(showSkipButtons, forKey: .showSkipButtons)
            try container.encode(useWebAPI, forKey: .useWebAPI)
            try container.encode(spotifyClientID, forKey: .spotifyClientID)
        }
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
    /// The artwork URL currently displayed — lags behind `state.artworkURL`
    /// so the old art stays visible during the fade-out phase.
    @State private var displayedArtworkURL = ""
    /// Controls album art opacity for fade-out/fade-in transitions.
    @State private var artworkOpacity: CGFloat = 1.0
    /// Controls background opacity for coordinated fade-out/fade-in with artwork.
    @State private var backgroundOpacity: CGFloat = 1.0
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

    /// Controls visibility of track text for coordinated transitions.
    /// Set to `false` to conceal text, `true` to reveal.
    @State private var textContentVisible = true
    /// Monotonically-increasing ID for track changes. Used to cancel
    /// stale reveal callbacks when rapid skips occur.
    @State private var trackChangeID: Int = 0

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
            let w = geometry.size.width

            ZStack {
                // Radial album colour glow — radiates from the album art position
                albumArtBackground(size: geometry.size)
                    .opacity(backgroundOpacity)

                // Tier routing — mirrors Testing/widget-layout-sandbox/index.html.
                // Overlay fires either by hard width cutoff (w < 300) OR when
                // the compact tier's horizontal controls wouldn't fit (e.g. 3×2
                // on Xeneon Edge, where the album art column eats so much space
                // that even a 3-button cluster can't sit beside the track info).
                let compactCWEstimate = w - 20 - (h - 20) - 12 - 8   // outerPad×2 - artSize - hSpacing - trailingInset
                let overlayByWidth = w < 300
                let overlayByControlsFit = compactCWEstimate < 184   // 3-button cluster minimum

                if overlayByWidth || overlayByControlsFit {
                    overlayLayout(size: geometry.size)
                } else if h < 150 || w < 500 {
                    ultraCompactLayout(size: geometry.size)
                } else if h < 280 || w < 800 {
                    compactLayout(size: geometry.size)
                } else {
                    fullLayout(size: geometry.size)
                }
            }
        }
        .onChange(of: state.artworkURL, initial: true) { _, newURL in
            // `initial: true` ensures this fires when nowPlayingView first appears
            // with an already-set artworkURL (e.g. Spotify was playing at launch).
            // Without it, the view transitions from notPlayingView → nowPlayingView
            // with the URL already populated, and .onChange never fires.
            if !newURL.isEmpty && newURL != lastArtworkURL {
                let isFirstLoad = lastArtworkURL.isEmpty
                lastArtworkURL = newURL

                if isFirstLoad {
                    // First artwork — show immediately, no transition
                    displayedArtworkURL = newURL
                    artworkOpacity = 1.0
                    backgroundOpacity = 1.0
                }

                // Pre-extract colours so they're ready when the reveal fires
                extractColors(from: newURL)
            }
        }
        .onChange(of: state.trackName) { oldValue, newValue in
            if oldValue != newValue && !newValue.isEmpty {
                // Increment change ID — cancels any pending reveal from a
                // previous skip so rapid skips don't reveal stale data.
                trackChangeID += 1
                let thisChange = trackChangeID

                // Conceal: text characters fade/blur out L→R, art + background fade out
                textContentVisible = false
                withAnimation(.easeIn(duration: 0.5)) {
                    artworkOpacity = 0.0
                    backgroundOpacity = 0.0
                }

                // After conceal completes (0.8s for char cascade + small gap),
                // swap art and reveal new text + art + background together.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    guard trackChangeID == thisChange else { return }
                    displayedArtworkURL = state.artworkURL
                    textContentVisible = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.5)) {
                            artworkOpacity = 1.0
                            backgroundOpacity = 1.0
                        }
                    }
                }
            }
        }
    }

    // MARK: - Overlay Layout (tiny widgets — 1×1, 2×2, 3×2, etc.)
    //
    // ┌─────────────────────┐    ┌──────────────────────────┐
    // │   Track Name (txt)  │    │                          │
    // │   Artist (overlay)  │    │                          │
    // │                     │    │         ┌───┐            │
    // │         ┌───┐       │    │         │ ▶ │            │
    // │         │ ▶ │       │    │         └───┘            │
    // │         └───┘       │    │                          │
    // └─────────────────────┘    └──────────────────────────┘
    //   3×2 with text overlay      1×1 — single-button overlay
    //
    // Album art fills the widget (aspect-fill, cropped); controls live in a
    // translucent capsule centred over the art. Track name + artist appear in
    // a top scrim only on widgets that are tall enough AND wide enough.

    @ViewBuilder
    private func overlayLayout(size: CGSize) -> some View {
        let w = size.width
        let h = size.height
        let showThreeButtons = w >= 200
        let showTextOverlay = w >= 300 && h >= 180

        ZStack(alignment: .center) {
            // Album art fills the widget surface (aspect-fill — may crop for
            // non-square widgets). Drawn behind everything else.
            if config.showAlbumArt, !displayedArtworkURL.isEmpty,
               let url = URL(string: displayedArtworkURL) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.white.opacity(0.08))
                }
                .frame(width: w, height: h)
                .clipped()
                .opacity(artworkOpacity)
            }

            // Track name + artist scrim — only on bigger overlay widgets.
            if showTextOverlay {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        MarqueeText(
                            text: state.trackName,
                            font: .system(size: 16, weight: .semibold),
                            color: .white,
                            isContentVisible: textContentVisible
                        )
                        MarqueeText(
                            text: state.artistName,
                            font: .system(size: 13),
                            color: .white.opacity(0.85),
                            isContentVisible: textContentVisible
                        )
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0.75), location: 0.0),
                                .init(color: .black.opacity(0.45), location: 0.6),
                                .init(color: .black.opacity(0.0),  location: 1.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    Spacer(minLength: 0)
                }
            }

            // Controls capsule — centred. Three buttons if the widget can fit
            // them (w ≥ 200), otherwise just play/pause.
            HStack(spacing: 6) {
                if showThreeButtons {
                    Button { doPreviousTrack() } label: {
                        Image(systemName: "backward.fill").font(.system(size: 20))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                            .debugTouchSurface()
                    }
                }
                Button { doPlayPause() } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.12))
                        .clipShape(Circle())
                        .contentShape(Circle())
                        .debugTouchSurface()
                }
                if showThreeButtons {
                    Button { doNextTrack() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 20))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                            .debugTouchSurface()
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55))
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        }
        .clipped()
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
        // Sub-mode dispatch — mirrors widget-layout-sandbox computeLayout:
        //   horizontal       — Art | Track/Artist/Album | prev/play/next cluster
        //   art-overlay-play — Art (play overlaid) | Track/Artist/Album full-width
        //
        // The trigger is pure geometry: when the text column would have less
        // than minTextRoom (100pt) sharing space with the 3-button cluster,
        // drop the cluster and overlay play on the art slot instead. Whether
        // album art is rendered does not affect the layout decision.
        let ucPaddings: CGFloat = 16 + 20   // 8pt × 2 outer + 10pt × 2 HStack gaps
        let cluster3: CGFloat = 184          // 3×48 + 2×20
        let minTextRoom: CGFloat = 100
        let textPlusClusterRoom = size.width - artSize - ucPaddings
        let useArtOverlayPlay = textPlusClusterRoom < cluster3 + minTextRoom

        if useArtOverlayPlay {
            ultraCompactArtOverlay(artSize: artSize)
        } else {
            ultraCompactHorizontal(artSize: artSize)
        }
    }

    /// Three text lines + a small album art on the left + horizontal prev/play/next cluster.
    @ViewBuilder
    private func ultraCompactHorizontal(artSize: CGFloat) -> some View {
        HStack(spacing: 10) {
            albumArtView(size: artSize, cornerRadius: 6, placeholderIconSize: 16)

            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(
                    text: state.trackName,
                    font: .system(size: 18, weight: .semibold),
                    color: .white,
                    isContentVisible: textContentVisible
                )
                MarqueeText(
                    text: state.artistName,
                    font: .system(size: 14),
                    color: .white.opacity(0.65),
                    isContentVisible: textContentVisible
                )
                MarqueeText(
                    text: state.albumName,
                    font: .system(size: 12),
                    color: .white.opacity(0.45),
                    isContentVisible: textContentVisible
                )
                if !deviceName.isEmpty {
                    deviceLabel(fontSize: 10)
                }
            }
            .frame(minWidth: 80)

            Spacer(minLength: 4)

            HStack(spacing: 20) {
                Button { doPreviousTrack() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 18))
                        .frame(minWidth: 48, minHeight: 48)
                        .contentShape(Rectangle())
                        .debugTouchSurface()
                }
                Button { doPlayPause() } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28))
                        .frame(minWidth: 48, minHeight: 48)
                        .contentShape(Rectangle())
                        .debugTouchSurface()
                }
                Button { doNextTrack() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 18))
                        .frame(minWidth: 48, minHeight: 48)
                        .contentShape(Rectangle())
                        .debugTouchSurface()
                }
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    /// Art-overlay-play sub-mode — play button centred on the album art slot,
    /// no separate prev/next cluster, text column gets the full remaining width.
    /// The play position is anchored to the art slot regardless of whether the
    /// art itself is shown, so toggling album art does not reflow the controls.
    @ViewBuilder
    private func ultraCompactArtOverlay(artSize: CGFloat) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if config.showAlbumArt {
                    albumArtView(size: artSize, cornerRadius: 6, placeholderIconSize: 16)
                } else {
                    Color.clear.frame(width: artSize, height: artSize)
                }

                Button { doPlayPause() } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.55))
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                        .contentShape(Circle())
                        .debugTouchSurface()
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(
                    text: state.trackName,
                    font: .system(size: 18, weight: .semibold),
                    color: .white,
                    isContentVisible: textContentVisible
                )
                MarqueeText(
                    text: state.artistName,
                    font: .system(size: 14),
                    color: .white.opacity(0.65),
                    isContentVisible: textContentVisible
                )
                MarqueeText(
                    text: state.albumName,
                    font: .system(size: 12),
                    color: .white.opacity(0.45),
                    isContentVisible: textContentVisible
                )
                if !deviceName.isEmpty {
                    deviceLabel(fontSize: 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        // Mirror the HStack geometry: outer .padding(.horizontal, 10) = 20pt total,
        // art column = artSize, HStack spacing = 12, plus 8pt trailing breathing
        // room reserved for the slider thumb so it never sits flush against the
        // widget's clipped edge. That's the budget the controls row must fit within.
        let controlsTrailingInset: CGFloat = 8
        let controlsWidth = size.width - 20 - artSize - 12 - controlsTrailingInset

        #if DEBUG
        let _ = print(String(format: "[SpotifyWidget][compact] size=%.1fx%.1f artSize=%.1f controlsWidth=%.1f skipON=%@",
                             size.width, size.height, artSize, controlsWidth, config.showSkipButtons ? "true" : "false"))
        #endif

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
                        isContentVisible: textContentVisible
                    )
                    MarqueeText(
                        text: state.artistName,
                        font: .system(size: 16),
                        color: .white.opacity(0.65),
                        isContentVisible: textContentVisible
                    )
                    MarqueeText(
                        text: state.albumName,
                        font: .system(size: 14),
                        color: .white.opacity(0.4),
                        isContentVisible: textContentVisible
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

                // Controls + volume — pass the precomputed width so the tier
                // degradation inside can prevent the row from overflowing.
                compactControls(availableWidth: controlsWidth)
                    .padding(.top, 4)
                    .padding(.trailing, controlsTrailingInset)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    // MARK: - Compact Controls
    //
    // Mirrors fullControlsRow's tier-degradation approach, scaled for compact widgets.
    //
    // Width budgets:
    //   Cluster skip ON:  5×48 + 4×20 = 320pt
    //   Cluster skip OFF: 3×48 + 2×20 = 184pt
    //
    //   Vol group widths (compact — shorter slider than full layout):
    //     cT1: icon(14) + 5 + slider(45) + 5 + launch(48) = 117pt  [full]
    //     cT2: icon(14) + 5 + slider(45)                  =  64pt  [slider, no launch]
    //     cT3: icon-button(48)                             =  48pt  [icon-only, popover]
    //
    //   Min row width = 2 × volGroupWidth + clusterWidth
    //   cT1 threshold ON:  2×117 + 320 = 554pt
    //   cT2 threshold ON:  2×64  + 320 = 448pt
    //   cT3 threshold ON:  2×48  + 320 = 416pt
    //   cT4 (no vol)    :         320pt
    //
    // For the default layout (628×227pt widget, controlsWidth ≈ 389pt, skip ON):
    //   389 < 416 → cT4 fires (no volume shown). The cluster (320pt) fits cleanly
    //   with the two Spacers sharing the remaining ~69pt of breathing room.
    //
    // The ghost-mirror leading spacer keeps the cluster on the true midpoint.

    @State private var showCompactVolumePopover = false

    private func compactControls(availableWidth: CGFloat) -> some View {
        let buttonWidth: CGFloat  = 48
        let spacing: CGFloat      = 20
        let buttonCount: CGFloat  = config.showSkipButtons ? 5 : 3
        let gapCount: CGFloat     = buttonCount - 1

        let clusterWidth = buttonCount * buttonWidth + gapCount * spacing

        let cVolFull:   CGFloat = 117   // icon + slider(45) + launch
        let cVolSlider: CGFloat = 64    // icon + slider(45), no launch
        let cVolIcon:   CGFloat = 48    // icon-only popover

        let cT1 = 2 * cVolFull   + clusterWidth
        let cT2 = 2 * cVolSlider + clusterWidth
        let cT3 = 2 * cVolIcon   + clusterWidth

        let useFullVolume = availableWidth >= cT1
        let useSliderVol  = !useFullVolume  && availableWidth >= cT2
        let useIconVol    = !useSliderVol   && availableWidth >= cT3
        // cT4 / no-volume: everything else (cluster always fits when availableWidth >= clusterWidth)

        #if DEBUG
        let _tier = useFullVolume ? "cT1-full" : useSliderVol ? "cT2-slider" : useIconVol ? "cT3-icon" : "cT4-noVol"
        let _ = print(String(format: "[SpotifyWidget][compactControls] available=%.1f tier=%@ cT1=%.0f cT2=%.0f cT3=%.0f cluster=%.0f",
                             availableWidth, _tier, cT1, cT2, cT3, clusterWidth))
        #endif

        let resolvedVolWidth: CGFloat = {
            if useFullVolume  { return cVolFull   }
            if useSliderVol   { return cVolSlider }
            if useIconVol     { return cVolIcon   }
            return 0
        }()

        return HStack(spacing: 0) {
            // Ghost mirror — invisible leading balance weight
            if resolvedVolWidth > 0 {
                Color.clear.frame(width: resolvedVolWidth)
            }

            Spacer(minLength: 0)

            // Centred playback cluster
            HStack(spacing: spacing) {
                Button { doPreviousTrack() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 18))
                        .frame(minWidth: 48, minHeight: 48)
                        .contentShape(Rectangle())
                        .debugTouchSurface()
                }
                if config.showSkipButtons {
                    Button { doSkipBackward(10) } label: {
                        Image(systemName: "gobackward.10").font(.system(size: 16))
                            .frame(minWidth: 48, minHeight: 48)
                            .contentShape(Rectangle())
                            .debugTouchSurface()
                    }
                }
                Button { doPlayPause() } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                        .frame(minWidth: 48, minHeight: 48)
                        .contentShape(Rectangle())
                        .debugTouchSurface()
                }
                if config.showSkipButtons {
                    Button { doSkipForward(10) } label: {
                        Image(systemName: "goforward.10").font(.system(size: 16))
                            .frame(minWidth: 48, minHeight: 48)
                            .contentShape(Rectangle())
                            .debugTouchSurface()
                    }
                }
                Button { doNextTrack() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 18))
                        .frame(minWidth: 48, minHeight: 48)
                        .contentShape(Rectangle())
                        .debugTouchSurface()
                }
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            // Trailing volume group at the tier-appropriate width.
            // .frame(width: 14) on the icon anchors it to the same 14pt assumed
            // in the cVolFull/cVolSlider constants so the outer .frame(width:) is exact.
            if useFullVolume {
                HStack(spacing: 5) {
                    Image(systemName: volumeIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(width: 14)
                    Slider(
                        value: Binding(
                            get: { Double(state.volume) },
                            set: { state.volume = Int($0); doSetVolume(Int($0)) }
                        ),
                        in: 0...100
                    )
                    .frame(width: 45)
                    .tint(.green)
                    .controlSize(.mini)
                    Button { bridge.activateSpotify() } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.35))
                            .frame(minWidth: 48, minHeight: 48)
                            .contentShape(Rectangle())
                            .debugTouchSurface()
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: cVolFull, alignment: .trailing)

            } else if useSliderVol {
                HStack(spacing: 5) {
                    Image(systemName: volumeIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(width: 14)
                    Slider(
                        value: Binding(
                            get: { Double(state.volume) },
                            set: { state.volume = Int($0); doSetVolume(Int($0)) }
                        ),
                        in: 0...100
                    )
                    .frame(width: 45)
                    .tint(.green)
                    .controlSize(.mini)
                }
                .frame(width: cVolSlider, alignment: .trailing)

            } else if useIconVol {
                Button {
                    showCompactVolumePopover.toggle()
                } label: {
                    Image(systemName: volumeIcon)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(minWidth: 48, minHeight: 48)
                        .contentShape(Rectangle())
                        .debugTouchSurface()
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showCompactVolumePopover, arrowEdge: .bottom) {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { Double(state.volume) },
                                set: { state.volume = Int($0); doSetVolume(Int($0)) }
                            ),
                            in: 0...100
                        )
                        .frame(width: 120)
                        .tint(.green)
                        .controlSize(.mini)
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
                .frame(width: cVolIcon, alignment: .trailing)
            }
            // cT4: no volume group rendered
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
        let isExtraLarge = size.height >= 400

        #if DEBUG
        let _fullCtrlW = size.width - artSize - 12 - 32
        let _ = print(String(format: "[SpotifyWidget][full] size=%.1fx%.1f artSize=%.1f controlsWidth=%.1f skipON=%@",
                             size.width, size.height, artSize, _fullCtrlW, config.showSkipButtons ? "true" : "false"))
        #endif

        // Scale track info fonts for very large widgets
        let trackFontSize: CGFloat = isExtraLarge ? min(size.height * 0.08, 44) : 28
        let artistFontSize: CGFloat = isExtraLarge ? min(size.height * 0.055, 28) : 20
        let albumFontSize: CGFloat = isExtraLarge ? min(size.height * 0.04, 22) : 16
        let deviceFontSize: CGFloat = isExtraLarge ? 14 : 12

        HStack(spacing: 0) {
            // Album art — full height with padding
            albumArtView(size: artSize, cornerRadius: 10, placeholderIconSize: 36)
                .padding(.leading, 12)
                .padding(.vertical, 12)

            // Track info + controls
            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                // Track info — scales with widget size
                VStack(alignment: .leading, spacing: isExtraLarge ? 5 : 3) {
                    MarqueeText(
                        text: state.trackName,
                        font: .system(size: trackFontSize, weight: .semibold),
                        color: .white,
                        isContentVisible: textContentVisible
                    )
                    MarqueeText(
                        text: state.artistName,
                        font: .system(size: artistFontSize),
                        color: .white.opacity(0.75),
                        isContentVisible: textContentVisible
                    )
                    MarqueeText(
                        text: state.albumName,
                        font: .system(size: albumFontSize),
                        color: .white.opacity(0.5),
                        isContentVisible: textContentVisible
                    )
                    if !deviceName.isEmpty {
                        deviceLabel(fontSize: deviceFontSize)
                    }
                }

                Spacer()

                // Progress bar
                if config.showProgressBar, state.trackDuration > 0 {
                    progressBar(barHeight: 8, timeFont: .system(size: 12, design: .monospaced))
                }

                // Compute the available width for the controls row.
                // Subtract: art column (artSize + 12pt leading pad) + this VStack's
                // own horizontal padding (16pt each side = 32pt).
                let controlsWidth = size.width - artSize - 12 - 32

                fullControlsRow(availableWidth: controlsWidth)
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
    //
    // The controls row degrades gracefully when the available width is too narrow
    // to fit the playback cluster plus the volume group. Degradation order:
    //
    //   Tier 1 — Full volume (icon + slider + launch button)
    //   Tier 2 — No launch button (icon + slider only)
    //   Tier 3 — Icon-only volume (tap opens popover slider)
    //   Tier 4 — No volume at all
    //   Tier 5 — No volume + tighter button spacing (24 → 16pt)  [last resort]
    //
    // The ghost-mirror leading spacer always matches the trailing volume group
    // width so the cluster stays on the true midpoint of the row.
    //
    // Width budgets (button touch targets = 48pt min, spacing = 24pt):
    //   Cluster (skip ON):  5×48 + 4×24 = 336pt
    //   Cluster (skip OFF): 3×48 + 2×24 = 192pt
    //
    //   Tier 1 vol group:  icon(14) + 6 + slider(70) + 6 + launch(48) = 144pt
    //   Tier 2 vol group:  icon(14) + 6 + slider(70) = 90pt
    //   Tier 3 vol group:  icon-button(48) = 48pt
    //
    //   Min row width = 2 × volGroupWidth + clusterWidth
    //   Tier 1 threshold ON:  2×144 + 336 = 624pt
    //   Tier 2 threshold ON:  2×90  + 336 = 516pt
    //   Tier 3 threshold ON:  2×48  + 336 = 432pt
    //   Tier 4 threshold ON:  0     + 336 = 336pt  (no ghost needed either)
    //   Tier 5 threshold ON:  5×48  + 4×16 = 304pt (always fits in fullLayout)

    // State for the icon-only volume popover (Tier 3)
    @State private var showVolumePopover = false

    private func fullControlsRow(availableWidth: CGFloat) -> some View {
        // Determine cluster width for threshold math
        let buttonWidth: CGFloat  = 48
        let spacing: CGFloat      = 24
        let tightSpacing: CGFloat = 16
        let buttonCount: CGFloat  = config.showSkipButtons ? 5 : 3
        let gapCount: CGFloat     = buttonCount - 1

        let clusterWidth     = buttonCount * buttonWidth + gapCount * spacing
        let clusterWidthTight = buttonCount * buttonWidth + gapCount * tightSpacing

        // Volume group widths for each tier
        let volFull: CGFloat  = 144   // icon + slider + launch
        let volSlider: CGFloat = 90   // icon + slider (no launch)
        let volIcon: CGFloat  = 48    // icon-only touch target

        // Tier thresholds: 2 × volGroupWidth + clusterWidth must fit in availableWidth
        let t1 = 2 * volFull   + clusterWidth       // full volume with launch
        let t2 = 2 * volSlider + clusterWidth       // slider, no launch
        let t3 = 2 * volIcon   + clusterWidth       // icon-only volume
        let t4 = clusterWidth                        // no volume
        // t5 uses tight spacing — check against clusterWidthTight

        // Pick the tier
        let useFullVolume   = availableWidth >= t1
        let useSliderVol    = !useFullVolume  && availableWidth >= t2
        let useIconVol      = !useSliderVol   && availableWidth >= t3
        let useNoVolume     = !useIconVol     && availableWidth >= t4
        let useTightSpacing = !useNoVolume    && availableWidth >= clusterWidthTight

        // Resolved vol group width for the ghost mirror
        let resolvedVolWidth: CGFloat = {
            if useFullVolume  { return volFull   }
            if useSliderVol   { return volSlider }
            if useIconVol     { return volIcon   }
            return 0
        }()

        let resolvedSpacing: CGFloat = useTightSpacing ? tightSpacing : spacing

        return HStack(spacing: 0) {
            // Ghost mirror — invisible balance weight on the leading side
            if resolvedVolWidth > 0 {
                Color.clear.frame(width: resolvedVolWidth)
            }

            Spacer(minLength: 0)

            // Centred playback cluster
            HStack(spacing: resolvedSpacing) {
                Button { doPreviousTrack() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 22))
                        .frame(minWidth: 48, minHeight: 48)
                        .contentShape(Rectangle())
                        .debugTouchSurface()
                }
                if config.showSkipButtons {
                    Button { doSkipBackward(10) } label: {
                        Image(systemName: "gobackward.10").font(.system(size: 20))
                            .frame(minWidth: 48, minHeight: 48)
                            .contentShape(Rectangle())
                            .debugTouchSurface()
                    }
                }
                Button { doPlayPause() } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 36))
                        .frame(minWidth: 48, minHeight: 48)
                        .contentShape(Rectangle())
                        .debugTouchSurface()
                }
                if config.showSkipButtons {
                    Button { doSkipForward(10) } label: {
                        Image(systemName: "goforward.10").font(.system(size: 20))
                            .frame(minWidth: 48, minHeight: 48)
                            .contentShape(Rectangle())
                            .debugTouchSurface()
                    }
                }
                Button { doNextTrack() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 22))
                        .frame(minWidth: 48, minHeight: 48)
                        .contentShape(Rectangle())
                        .debugTouchSurface()
                }
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            // Trailing volume group — rendered at the tier-appropriate width
            if useFullVolume {
                // Tier 1: icon + slider + launch button
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
                            .frame(minWidth: 48, minHeight: 48)
                            .contentShape(Rectangle())
                            .debugTouchSurface()
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: volFull, alignment: .trailing)

            } else if useSliderVol {
                // Tier 2: icon + slider (launch button dropped)
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
                }
                .frame(width: volSlider, alignment: .trailing)

            } else if useIconVol {
                // Tier 3: icon-only — tap reveals a popover slider
                Button {
                    showVolumePopover.toggle()
                } label: {
                    Image(systemName: volumeIcon)
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(minWidth: 48, minHeight: 48)
                        .contentShape(Rectangle())
                        .debugTouchSurface()
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showVolumePopover, arrowEdge: .bottom) {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { Double(state.volume) },
                                set: { state.volume = Int($0); doSetVolume(Int($0)) }
                            ),
                            in: 0...100
                        )
                        .frame(width: 120)
                        .tint(.green)
                        .controlSize(.mini)
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
                .frame(width: volIcon, alignment: .trailing)

            }
            // Tier 4 / Tier 5: no volume group rendered at all
        }
    }

    // MARK: - Album Art (Fade Out / Fade In)

    @ViewBuilder
    private func albumArtView(size: CGFloat, cornerRadius: CGFloat, placeholderIconSize: CGFloat) -> some View {
        if config.showAlbumArt, !displayedArtworkURL.isEmpty {
            Group {
                if let url = URL(string: displayedArtworkURL) {
                    AsyncImage(url: url) { image in
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
                }
            }
            .opacity(artworkOpacity)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    // MARK: - Album Art Background Styles

    /// Dispatches to the selected album art background style.
    @ViewBuilder
    private func albumArtBackground(size: CGSize) -> some View {
        if backgroundStyle == .transparent {
            EmptyView()
        } else {
            switch config.albumArtStyle {
            case .none:         EmptyView()
            case .edgeFade:     edgeFadeBackground(size: size)
            case .frostedGlass: frostedGlassBackground(size: size)
            case .vinylAura:    vinylAuraBackground(size: size)
            case .colorBands:   colorBandsBackground(size: size)
            }
        }
    }

    /// **Edge Fade** — blurred edge colours bleed from the album art rightward.
    /// At larger widget sizes, the blur radius and spread scale proportionally
    /// so the colour wash fills the trailing space naturally.
    @ViewBuilder
    private func edgeFadeBackground(size: CGSize) -> some View {
        if let colors = albumColors {
            let artSize = artSizeForHeight(size.height)
            let artPad = artPaddingForHeight(size.height)
            let artCenterX = artPad + artSize / 2
            let artCenterY = size.height / 2
            let trailingSpace = size.width - (artPad + artSize)

            // Scale blur with widget size for smooth coverage on large widgets
            let baseBlur = max(18, trailingSpace * 0.12)
            let spreadBlur = max(trailingSpace * 0.35, 40)

            ZStack {
                // Primary gradient from art edges
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [colors.edgeLeading, colors.edgeTrailing],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: artSize + trailingSpace * 0.3, height: artSize)
                    .position(x: artCenterX + trailingSpace * 0.15, y: artCenterY)
                    .blur(radius: baseBlur)

                // Trailing colour wash — extends further on large widgets
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [colors.edgeTrailing, colors.edgeTrailing.opacity(0.3)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: trailingSpace * 0.85, height: artSize * 0.9)
                    .position(x: artPad + artSize + trailingSpace * 0.4, y: artCenterY)
                    .blur(radius: spreadBlur)

                // Top/bottom edge tints for vertical bleed
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [colors.edgeTop.opacity(0.4), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: trailingSpace, height: artSize * 0.5)
                    .position(x: artPad + artSize + trailingSpace / 2, y: artCenterY * 0.4)
                    .blur(radius: baseBlur * 0.8)

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, colors.edgeBottom.opacity(0.4)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: trailingSpace, height: artSize * 0.5)
                    .position(x: artPad + artSize + trailingSpace / 2, y: size.height - artCenterY * 0.4)
                    .blur(radius: baseBlur * 0.8)
            }
            .clipped()
        }
    }

    /// **Frosted Glass** — album art fills the widget, heavily blurred with a dark overlay.
    @ViewBuilder
    private func frostedGlassBackground(size: CGSize) -> some View {
        if !displayedArtworkURL.isEmpty {
            ZStack {
                AsyncImage(url: URL(string: displayedArtworkURL)) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size.width, height: size.height)
                            .clipped()
                            .blur(radius: 30)
                    } else {
                        Color.clear
                    }
                }
                Color.black.opacity(0.35)
            }
        }
    }

    /// **Vinyl Aura** — concentric radial gradient centred on the album art.
    @ViewBuilder
    private func vinylAuraBackground(size: CGSize) -> some View {
        if let colors = albumColors {
            let artSize = artSizeForHeight(size.height)
            let artPad = artPaddingForHeight(size.height)
            let artCenterX = artPad + artSize / 2
            let artCenterY = size.height / 2

            RadialGradient(
                colors: [
                    colors.edgeLeading.opacity(0.8),
                    colors.primary.opacity(0.5),
                    colors.secondary.opacity(0.3),
                    Color.clear
                ],
                center: UnitPoint(
                    x: artCenterX / size.width,
                    y: artCenterY / size.height
                ),
                startRadius: artSize * 0.3,
                endRadius: max(size.width, size.height) * 0.85
            )
        }
    }

    /// **Color Bands** — vertical gradient through extracted edge colours.
    @ViewBuilder
    private func colorBandsBackground(size: CGSize) -> some View {
        if let colors = albumColors {
            LinearGradient(
                colors: [
                    colors.edgeTop,
                    colors.primary,
                    colors.secondary,
                    colors.edgeBottom
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(0.7)
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
                if backgroundOpacity < 0.01 {
                    // Background is transparent mid-transition — apply instantly
                    // so new colours are ready when the fade-in begins.
                    albumColors = colors
                } else {
                    withAnimation(.easeInOut(duration: 0.8)) {
                        albumColors = colors
                    }
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

// MARK: - Marquee Text (character-by-character transitions + bounce scroll)

/// Phase of the character cascade animation.
private enum CharTransitionPhase {
    case idle
    case concealing
    case revealing
}

/// Displays text that gently bounces side-to-side when too wide for its container.
///
/// On track change the parent toggles `isContentVisible` to coordinate a
/// character-by-character cascade transition:
///   1. Old text: each character fades out + blurs, staggered L→R (50% overlap)
///   2. Text swaps (old text is now invisible)
///   3. New text: each character fades in + un-blurs, staggered L→R (50% overlap)
///   4. If the new text overflows, gentle bounce scroll begins
///
/// Uses PhaseAnimator (macOS 14+) to cycle between start and end offsets for scrolling.
private struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    /// Driven by the parent — `false` to conceal, `true` to reveal.
    let isContentVisible: Bool

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    /// The text actually displayed — lags behind `text` so the old string
    /// stays visible during the conceal cascade before swapping to the new one.
    @State private var displayText: String = ""
    /// Drives the character cascade (0→1). Each character computes its
    /// individual opacity/blur from this plus its index.
    @State private var transitionProgress: CGFloat = 0.0
    /// Current phase of the character transition.
    @State private var phase: CharTransitionPhase = .idle
    /// Incremented on each text change to re-trigger the PhaseAnimator scroll.
    @State private var scrollTrigger: Int = 0

    /// Only scroll if the text overflows by more than 10pt.
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
                if overflow > 0 && phase == .idle {
                    let scrollDuration = max(Double(overflow) / 30.0, 1.0)

                    PhaseAnimator([false, true], trigger: scrollTrigger) { scrolled in
                        characterStack
                            .offset(x: scrolled ? -overflow : 0)
                    } animation: { p in
                        p
                            ? .linear(duration: scrollDuration).delay(2.0)
                            : .linear(duration: scrollDuration * 0.75).delay(1.5)
                    }
                    .clipped()
                } else {
                    characterStack
                        .clipped()
                }
            }
            .onChange(of: isContentVisible) { _, nowVisible in
                if !nowVisible {
                    // Conceal: characters fade out + blur, staggered L→R
                    phase = .concealing
                    transitionProgress = 0.0
                    withAnimation(.easeIn(duration: 0.8)) {
                        transitionProgress = 1.0
                    }
                } else {
                    // Swap to new text, then reveal: characters fade in + un-blur
                    displayText = text
                    phase = .revealing
                    transitionProgress = 0.0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 1.0)) {
                            transitionProgress = 1.0
                        }
                    }
                    // After reveal completes, enter idle and start bounce scroll
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                        phase = .idle
                        scrollTrigger += 1
                    }
                }
            }
            .onChange(of: text) { _, newValue in
                // Only update immediately on first load (displayText empty).
                // During track changes the old text stays visible through the
                // conceal cascade — displayText is swapped in the reveal phase.
                if displayText.isEmpty && isContentVisible {
                    displayText = newValue
                    scrollTrigger += 1
                }
            }
            .onAppear {
                displayText = text
            }
    }

    // MARK: - Character Stack

    private var characterStack: some View {
        HStack(spacing: 0) {
            ForEach(Array(displayText.enumerated()), id: \.offset) { index, char in
                Text(String(char))
                    .font(font)
                    .foregroundStyle(color)
                    .opacity(charOpacity(at: index))
                    .blur(radius: charBlur(at: index))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { textWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in textWidth = w }
            }
        )
    }

    // MARK: - Per-Character Animation

    private func charOpacity(at index: Int) -> CGFloat {
        switch phase {
        case .idle:
            return 1.0
        case .concealing:
            return 1.0 - cascadeProgress(at: index, total: displayText.count)
        case .revealing:
            return cascadeProgress(at: index, total: displayText.count)
        }
    }

    private func charBlur(at index: Int) -> CGFloat {
        let maxBlur: CGFloat = 4
        switch phase {
        case .idle:
            return 0
        case .concealing:
            return cascadeProgress(at: index, total: displayText.count) * maxBlur
        case .revealing:
            return (1.0 - cascadeProgress(at: index, total: displayText.count)) * maxBlur
        }
    }

    /// Returns 0→1 for a specific character as overall `transitionProgress` goes 0→1.
    /// Characters are staggered left-to-right with 50% overlap between consecutive
    /// character timings — each character's fade window starts halfway through
    /// the previous character's window.
    private func cascadeProgress(at index: Int, total: Int) -> CGFloat {
        guard total > 1 else { return min(max(transitionProgress, 0), 1) }
        let n = CGFloat(total)
        // With 50% overlap: window = 2/(N+1), start(i) = i/(N+1)
        let start = CGFloat(index) / (n + 1.0)
        let end = CGFloat(index + 2) / (n + 1.0)
        if transitionProgress <= start { return 0 }
        if transitionProgress >= end { return 1 }
        return (transitionProgress - start) / (end - start)
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
                Picker("Background style", selection: $config.albumArtStyle) {
                    ForEach(AlbumArtStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
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
