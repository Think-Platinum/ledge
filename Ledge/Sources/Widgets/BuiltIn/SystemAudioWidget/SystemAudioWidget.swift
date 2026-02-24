import SwiftUI
import Combine

// MARK: - Always-Active Slider

/// A custom slider that never dims when the window is inactive.
///
/// The standard SwiftUI `Slider` inherits AppKit's inactive-window dimming,
/// which makes it grey out whenever Ledge isn't the active app (i.e. almost
/// always, since LedgePanel uses `.nonactivatingPanel`). This replacement
/// renders identically but ignores window activation state.
private struct AlwaysActiveSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var tint: Color = .blue

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let trackHeight: CGFloat = 5
            let thumbSize: CGFloat = 18
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let usableWidth = geo.size.width - thumbSize
            let thumbX = thumbSize / 2 + fraction * usableWidth

            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: trackHeight)

                // Filled track
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, thumbX), height: trackHeight)

                // Thumb
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: thumbX - thumbSize / 2)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        let x = drag.location.x - thumbSize / 2
                        let pct = Double(x / usableWidth)
                        value = min(range.upperBound, max(range.lowerBound, range.lowerBound + pct * (range.upperBound - range.lowerBound)))
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 24)
    }
}

/// System audio widget with volume control, sound mute, and microphone mute.
///
/// Size-adaptive: shows all controls in larger sizes, compact layout in small sizes.
struct SystemAudioWidget {

    static let descriptor = WidgetDescriptor(
        typeID: "com.ledge.system-audio",
        displayName: "System Audio",
        description: "Volume, sound mute & mic mute",
        iconSystemName: "speaker.wave.2.fill",
        minimumSize: .twoByTwo,
        defaultSize: .fourByThree,
        maximumSize: .sixByFour,
        defaultConfiguration: nil,
        viewFactory: { instanceID, configStore in
            AnyView(SystemAudioWidgetView(instanceID: instanceID, configStore: configStore))
        },
        settingsFactory: nil,
        requiredPermissions: [.camera]
    )
}

// MARK: - View

struct SystemAudioWidgetView: View {
    @Environment(\.theme) private var theme
    let instanceID: UUID
    let configStore: WidgetConfigStore

    private let bridge = SystemAudioBridge()
    @State private var audioState = SystemAudioBridge.AudioState()

    private let pollTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width > 300
            let isTall = geometry.size.height > 200

            if isWide && isTall {
                fullLayout
            } else if isWide {
                wideLayout
            } else {
                compactLayout
            }
        }
        .onAppear { refreshState() }
        .onReceive(pollTimer) { _ in refreshState() }
    }

    // MARK: - Full Layout (2+ rows, wide)

    private var fullLayout: some View {
        VStack(spacing: 16) {
            // Volume slider
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: outputIcon)
                        .font(.system(size: 20))
                        .foregroundColor(audioState.isOutputMuted ? .red : theme.primaryText)
                        .frame(width: 28)

                    Text("Volume")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    Spacer()

                    Text(String(format: "%.0f%%", audioState.outputVolume * 100))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }

                AlwaysActiveSlider(
                    value: Binding(
                        get: { Double(audioState.outputVolume) },
                        set: { newVal in
                            audioState.outputVolume = Float(newVal)
                            bridge.setOutputVolume(Float(newVal))
                        }
                    ),
                    tint: audioState.isOutputMuted ? .red : theme.accent
                )
            }

            Divider().background(theme.tertiaryText.opacity(0.3))

            Spacer()

            // Mute buttons
            HStack(spacing: 20) {
                // Sound Mute
                muteButton(
                    icon: audioState.isOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    label: audioState.isOutputMuted ? "Unmute" : "Mute",
                    isActive: audioState.isOutputMuted,
                    color: .red
                ) {
                    bridge.toggleOutputMute()
                    refreshState()
                }

                // Mic Mute
                muteButton(
                    icon: audioState.isInputMuted ? "mic.slash.fill" : "mic.fill",
                    label: audioState.isInputMuted ? "Mic Off" : "Mic On",
                    isActive: audioState.isInputMuted,
                    color: .orange
                ) {
                    bridge.toggleInputMute()
                    refreshState()
                }

                // Camera Status
                VStack(spacing: 6) {
                    Image(systemName: audioState.isCameraInUse ? "video.fill" : "video.slash.fill")
                        .font(.system(size: 28))
                        .foregroundColor(audioState.isCameraInUse ? .green : theme.secondaryText)
                        .frame(width: 56, height: 56)
                        .background(audioState.isCameraInUse ? Color.green.opacity(0.15) : theme.primaryText.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    Text(audioState.isCameraInUse ? (audioState.cameraName ?? "In Use") : "Camera")
                        .font(.system(size: 12))
                        .foregroundColor(audioState.isCameraInUse ? .green : theme.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Wide Layout (1 row)

    private var wideLayout: some View {
        HStack(spacing: 16) {
            // Volume slider
            HStack(spacing: 10) {
                Image(systemName: outputIcon)
                    .font(.system(size: 18))
                    .foregroundColor(audioState.isOutputMuted ? .red : theme.primaryText)
                    .frame(width: 24)

                AlwaysActiveSlider(
                    value: Binding(
                        get: { Double(audioState.outputVolume) },
                        set: { newVal in
                            audioState.outputVolume = Float(newVal)
                            bridge.setOutputVolume(Float(newVal))
                        }
                    ),
                    tint: audioState.isOutputMuted ? .red : theme.accent
                )

                Text(String(format: "%.0f%%", audioState.outputVolume * 100))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 40)
            }

            // Mute buttons
            HStack(spacing: 12) {
                Button {
                    bridge.toggleOutputMute()
                    refreshState()
                } label: {
                    Image(systemName: audioState.isOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 20))
                        .foregroundColor(audioState.isOutputMuted ? .red : theme.secondaryText)
                        .frame(width: 36, height: 36)
                        .background(audioState.isOutputMuted ? Color.red.opacity(0.15) : theme.primaryText.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Button {
                    bridge.toggleInputMute()
                    refreshState()
                } label: {
                    Image(systemName: audioState.isInputMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 20))
                        .foregroundColor(audioState.isInputMuted ? .orange : theme.secondaryText)
                        .frame(width: 36, height: 36)
                        .background(audioState.isInputMuted ? Color.orange.opacity(0.15) : theme.primaryText.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                // Camera status
                Image(systemName: audioState.isCameraInUse ? "video.fill" : "video.slash.fill")
                    .font(.system(size: 20))
                    .foregroundColor(audioState.isCameraInUse ? .green : theme.secondaryText)
                    .frame(width: 36, height: 36)
                    .background(audioState.isCameraInUse ? Color.green.opacity(0.15) : theme.primaryText.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Compact Layout (small)

    private var compactLayout: some View {
        VStack(spacing: 10) {
            // Volume as circular indicator
            ZStack {
                Circle()
                    .stroke(theme.primaryText.opacity(0.1), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: Double(audioState.outputVolume))
                    .stroke(
                        audioState.isOutputMuted ? Color.red : theme.accent,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                Image(systemName: outputIcon)
                    .font(.system(size: 20))
                    .foregroundColor(audioState.isOutputMuted ? .red : theme.primaryText)
            }
            .frame(width: 50, height: 50)
            .onTapGesture {
                bridge.toggleOutputMute()
                refreshState()
            }

            // Mic mute button
            Button {
                bridge.toggleInputMute()
                refreshState()
            } label: {
                Image(systemName: audioState.isInputMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 16))
                    .foregroundColor(audioState.isInputMuted ? .orange : theme.secondaryText)
                    .frame(width: 32, height: 32)
                    .background(audioState.isInputMuted ? Color.orange.opacity(0.15) : theme.primaryText.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Components

    private func muteButton(icon: String, label: String, isActive: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundColor(isActive ? color : theme.secondaryText)
                    .frame(width: 56, height: 56)
                    .background(isActive ? color.opacity(0.15) : theme.primaryText.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(isActive ? color : theme.tertiaryText)
            }
        }
        .buttonStyle(.plain)
    }

    private var outputIcon: String {
        if audioState.isOutputMuted { return "speaker.slash.fill" }
        if audioState.outputVolume < 0.01 { return "speaker.fill" }
        if audioState.outputVolume < 0.33 { return "speaker.wave.1.fill" }
        if audioState.outputVolume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: - Helpers

    private func refreshState() {
        let b = bridge
        Task.detached {
            let newState = b.getState()
            await MainActor.run {
                audioState = newState
            }
        }
    }
}
