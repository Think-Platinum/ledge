import SwiftUI
import Combine
import os.log

// MARK: - Descriptor

enum TouchDiagnosticsWidget {

    static let descriptor = WidgetDescriptor(
        typeID: "com.ledge.touch-diagnostics",
        displayName: "Touch Diagnostics",
        description: "Real-time touch pipeline health, event log, and delivery statistics",
        iconSystemName: "hand.tap",
        minimumSize: .fourByTwo,
        defaultSize: .sixByThree,
        maximumSize: .tenBySix,
        defaultConfiguration: nil,
        viewFactory: { _, _ in
            AnyView(TouchDiagnosticsWidgetView())
        },
        settingsFactory: nil
    )
}

// MARK: - View

struct TouchDiagnosticsWidgetView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject var displayManager: DisplayManager

    /// Tick counter to drive periodic refresh of flight recorder stats.
    @State private var tick: UInt64 = 0

    private let refreshTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 200
            VStack(alignment: .leading, spacing: compact ? 3 : 6) {
                // Alert banner if touch is unhealthy
                if !displayManager.touchWatchdog.isTapHealthy || displayManager.touchWatchdog.isDeadTapDetected {
                    alertBanner
                }
                
                statusRow
                statsRow
                if !compact {
                    eventLog
                }
            }
            .padding(6)
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundColor(theme.primaryText)
        }
        .onReceive(refreshTimer) { _ in
            tick += 1
        }
    }

    // MARK: - Alert Banner

    private var alertBanner: some View {
        let watchdog = displayManager.touchWatchdog
        
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 14))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(watchdog.healthStatus)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.orange)
                
                if watchdog.isDeadTapDetected {
                    Text("Quiet for \(watchdog.consecutiveQuietChecks * 3)s — tap may have crashed")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                    Text("Toggle panel OFF/ON or tap to retry")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                } else if !watchdog.isTapHealthy {
                    Text("Auto-recovery attempted \(watchdog.disableCount)×")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }
            }
            
            Spacer()
            
            // Manual recovery button
            Button(action: {
                displayManager.touchWatchdog.forceRecovery()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.orange.opacity(0.3))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Status Row

    private var statusRow: some View {
        HStack(spacing: 10) {
            statusDot(
                "AX",
                active: displayManager.accessibilityPermission == .granted,
                warning: displayManager.accessibilityPermission == .waiting
            )
            statusDot(
                "Tap",
                active: displayManager.isTouchRemapperActive,
                warning: false
            )
            statusDot(
                "Cal",
                active: displayManager.calibrationState == .calibrated
                    || displayManager.calibrationState == .autoDetected,
                warning: displayManager.calibrationState == .learning
            )
            statusDot(
                "WD",
                active: displayManager.touchWatchdog.isTapHealthy && !displayManager.touchWatchdog.isDeadTapDetected,
                warning: displayManager.touchWatchdog.isDeadTapDetected
            )

            Spacer()

            if let id = displayManager.learnedDeviceID {
                Text("dev:\(id)")
                    .foregroundColor(theme.secondaryText)
            }
        }
    }

    private func statusDot(_ label: String, active: Bool, warning: Bool) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(active ? Color.green : (warning ? Color.yellow : Color.red))
                .frame(width: 6, height: 6)
            Text(label)
                .foregroundColor(theme.secondaryText)
        }
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        let recorder = displayManager.flightRecorder
        let watchdog = displayManager.touchWatchdog
        let _ = tick  // Force re-evaluation on timer

        return HStack(spacing: 12) {
            statLabel("ev/s", value: String(format: "%.0f", recorder.eventsPerSecond))
            statLabel("drop", value: "\(recorder.totalDropped)")
            if let latency = recorder.averageLatencyMs {
                statLabel("lat", value: String(format: "%.1fms", latency))
            }
            if watchdog.disableCount > 0 {
                statLabel("wd", value: "\(watchdog.disableCount)×")
                    .foregroundColor(.orange)
            }
            
            // Show quiet counter when events stop
            if watchdog.consecutiveQuietChecks > 0 && recorder.totalRecorded > 0 {
                statLabel("quiet", value: "\(watchdog.consecutiveQuietChecks * 3)s")
                    .foregroundColor(watchdog.isDeadTapDetected ? .red : .yellow)
            }

            Spacer()

            if let touch = displayManager.lastTouchInfo {
                Text(String(format: "(%.0f,%.0f)→(%.0f,%.0f)",
                            touch.originalPoint.x, touch.originalPoint.y,
                            touch.remappedPoint?.x ?? 0, touch.remappedPoint?.y ?? 0))
                    .foregroundColor(theme.secondaryText)
            }
        }
    }

    private func statLabel(_ label: String, value: String) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .foregroundColor(theme.secondaryText.opacity(0.6))
            Text(value)
                .foregroundColor(theme.primaryText)
        }
    }

    // MARK: - Event Log

    private var eventLog: some View {
        let entries = displayManager.flightRecorder.recentEntries(count: 15)
        let _ = tick  // Force re-evaluation on timer

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 1) {
                // Header
                HStack(spacing: 0) {
                    Text("T ")
                        .frame(width: 18, alignment: .leading)
                    Text("Seq ")
                        .frame(width: 40, alignment: .leading)
                    Text("Original")
                        .frame(width: 100, alignment: .leading)
                    Text("Remapped")
                        .frame(width: 100, alignment: .leading)
                    Text("S")
                        .frame(width: 14, alignment: .center)
                }
                .foregroundColor(theme.secondaryText.opacity(0.5))
                .font(.system(size: 9, weight: .medium, design: .monospaced))

                ForEach(entries.reversed().indices, id: \.self) { index in
                    let entry = entries.reversed()[index]
                    eventRow(entry, dimmed: index > 3)
                }
            }
        }
    }

    private func eventRow(_ entry: TouchFlightRecorder.Entry, dimmed: Bool) -> some View {
        let statusColor: Color = switch entry.deliveryStatus {
        case .delivered:  .green
        case .dropped:    .orange
        case .suppressed: .gray
        }

        return HStack(spacing: 0) {
            Text(entry.eventType.rawValue)
                .frame(width: 18, alignment: .leading)
                .foregroundColor(statusColor)

            Text("\(entry.sequenceID)")
                .frame(width: 40, alignment: .leading)

            Text(String(format: "%.0f,%.0f", entry.originalPoint.x, entry.originalPoint.y))
                .frame(width: 100, alignment: .leading)

            if let rp = entry.remappedPoint {
                Text(String(format: "%.0f,%.0f", rp.x, rp.y))
                    .frame(width: 100, alignment: .leading)
            } else {
                Text("–")
                    .frame(width: 100, alignment: .leading)
                    .foregroundColor(.red)
            }

            Text(entry.deliveryStatus.rawValue)
                .frame(width: 14, alignment: .center)
                .foregroundColor(statusColor)
        }
        .font(.system(size: 10, weight: .regular, design: .monospaced))
        .foregroundColor(theme.primaryText.opacity(dimmed ? 0.5 : 0.9))
    }
}
