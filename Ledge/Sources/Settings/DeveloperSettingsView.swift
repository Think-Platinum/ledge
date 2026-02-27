import SwiftUI
import EventKit
import CoreLocation
import OSLog

/// Developer/debug settings panel for inspecting app state, permissions,
/// touch pipeline health, and logs during development.
struct DeveloperSettingsView: View {
    @EnvironmentObject var displayManager: DisplayManager

    @State private var showResetConfirmation = false
    @State private var logEntries: [String] = []
    @State private var logCategoryFilter: String = "All"
    @State private var isLoadingLogs: Bool = false

    private let bundleID = Bundle.main.bundleIdentifier ?? "com.thinkplatinum.Ledge"

    private let logCategories = [
        "All", "TouchRemapper", "HIDTouchReader", "HIDTouchDetector",
        "DisplayManager", "TouchWatchdog", "MouseGuard", "LedgePanel"
    ]

    var body: some View {
        Form {
            permissionsSection
            touchPipelineSection
            appStateSection
            logsSection
        }
        .formStyle(.grouped)
        .navigationTitle("Developer")
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section("Permissions") {
            // Accessibility (managed outside TCC)
            LabeledContent("Accessibility") {
                HStack {
                    statusDot(displayManager.accessibilityPermission == .granted)
                    Text(displayManager.accessibilityPermission.rawValue)
                        .font(.caption.monospaced())
                }
            }

            // Calendar
            LabeledContent("Calendar") {
                let status = EKEventStore.authorizationStatus(for: .event)
                HStack {
                    statusDot(status == .fullAccess)
                    Text(calendarStatusText(status))
                        .font(.caption.monospaced())
                }
            }

            // Location
            LabeledContent("Location") {
                let status = CLLocationManager().authorizationStatus
                HStack {
                    statusDot(status == .authorizedAlways)
                    Text(locationStatusText(status))
                        .font(.caption.monospaced())
                }
            }

            // Actions
            Button("Open Accessibility Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }

            Button("Reset TCC Permissions", role: .destructive) {
                showResetConfirmation = true
            }
            .confirmationDialog(
                "Reset all TCC permissions for Ledge?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset All", role: .destructive) {
                    resetTCCPermissions()
                }
            } message: {
                Text("This will reset Calendar, Camera, Microphone, AppleEvents, and Location permissions. The app will re-prompt on next use. Accessibility must be reset manually in System Settings.")
            }

            Text("Accessibility is managed outside TCC and cannot be reset programmatically. Use the button above to open System Settings and remove/re-add Ledge manually.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Touch Pipeline

    private var touchPipelineSection: some View {
        Section("Touch Pipeline") {
            LabeledContent("Mode") {
                HStack {
                    Image(systemName: displayManager.isHIDTouchReaderActive
                          ? "antenna.radiowaves.left.and.right"
                          : "point.topleft.down.to.point.bottomright.curvepath")
                    Text(displayManager.touchPipelineMode.rawValue)
                        .font(.caption.monospaced())
                }
            }

            LabeledContent("CGEventTap") {
                HStack {
                    statusDot(displayManager.isTouchRemapperActive)
                    Text(displayManager.isTouchRemapperActive ? "Active" : "Inactive")
                        .font(.caption.monospaced())
                    if displayManager.touchRemapper.suppressionOnly {
                        Text("(suppression only)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            LabeledContent("HID Reader") {
                HStack {
                    statusDot(displayManager.isHIDTouchReaderActive)
                    Text(displayManager.isHIDTouchReaderActive ? "Active" : "Inactive")
                        .font(.caption.monospaced())
                }
            }

            LabeledContent("Watchdog") {
                Text(displayManager.touchWatchdog.healthStatus)
                    .font(.caption.monospaced())
            }

            LabeledContent("Calibration") {
                Text(displayManager.calibrationState.rawValue)
                    .font(.caption.monospaced())
            }

            if let deviceID = displayManager.learnedDeviceID {
                LabeledContent("Device ID") {
                    Text("\(deviceID)")
                        .font(.caption.monospaced())
                }
            }

            // Flight recorder stats
            let recorder = displayManager.flightRecorder
            LabeledContent("Events Recorded") {
                Text("\(recorder.totalRecorded)")
                    .font(.caption.monospaced())
            }
            LabeledContent("Events Dropped") {
                Text("\(recorder.totalDropped)")
                    .font(.caption.monospaced())
                    .foregroundStyle(recorder.totalDropped > 0 ? .red : .primary)
            }
            LabeledContent("Events/sec") {
                Text(String(format: "%.1f", recorder.eventsPerSecond))
                    .font(.caption.monospaced())
            }
            if let latency = recorder.averageLatencyMs {
                LabeledContent("Avg Latency") {
                    Text(String(format: "%.1f ms", latency))
                        .font(.caption.monospaced())
                }
            }

            LabeledContent("Watchdog Checks") {
                Text("\(displayManager.touchWatchdog.checksPerformed)")
                    .font(.caption.monospaced())
            }
            LabeledContent("Tap Disables") {
                Text("\(displayManager.touchWatchdog.disableCount)")
                    .font(.caption.monospaced())
                    .foregroundStyle(displayManager.touchWatchdog.disableCount > 0 ? .orange : .primary)
            }
        }
    }

    // MARK: - App State

    private var appStateSection: some View {
        Section("App State") {
            LabeledContent("Display") {
                if let screen = displayManager.xeneonScreen {
                    VStack(alignment: .trailing) {
                        Text(screen.localizedName)
                            .font(.caption.monospaced())
                        Text("\(Int(screen.frame.width))×\(Int(screen.frame.height)) @ (\(Int(screen.frame.origin.x)),\(Int(screen.frame.origin.y)))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not connected")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Panel") {
                if let panel = displayManager.panel {
                    VStack(alignment: .trailing) {
                        Text(panel.isVisible ? "Visible" : "Hidden")
                            .font(.caption.monospaced())
                        Text("key=\(panel.isKeyWindow) level=\(Int(panel.level.rawValue))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not created")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Display Blanked") {
                statusDot(!displayManager.isDisplayBlanked)
                Text(displayManager.isDisplayBlanked ? "Yes" : "No")
                    .font(.caption.monospaced())
            }

            LabeledContent("Mouse Guard") {
                statusDot(displayManager.isMouseGuardEnabled)
                Text(displayManager.isMouseGuardEnabled ? "Enabled" : "Disabled")
                    .font(.caption.monospaced())
            }
        }
    }

    // MARK: - Logs

    private var logsSection: some View {
        Section("Logs") {
            Picker("Category", selection: $logCategoryFilter) {
                ForEach(logCategories, id: \.self) { cat in
                    Text(cat).tag(cat)
                }
            }
            .pickerStyle(.segmented)

            if logEntries.isEmpty && !isLoadingLogs {
                Text("Press \"Load Logs\" to fetch recent entries")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else if isLoadingLogs {
                ProgressView("Loading logs...")
                    .font(.caption)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(logEntries.indices, id: \.self) { index in
                            Text(logEntries[index])
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 300)
                .background(.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            HStack {
                Button("Load Logs") {
                    refreshLogs()
                }
                .disabled(isLoadingLogs)
                Button("Copy to Clipboard") {
                    let text = logEntries.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .disabled(logEntries.isEmpty)
            }
        }
    }

    // MARK: - Helpers

    private func statusDot(_ isGood: Bool) -> some View {
        Circle()
            .fill(isGood ? .green : .orange)
            .frame(width: 8, height: 8)
    }

    private func calendarStatusText(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not Determined"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .fullAccess: return "Full Access"
        case .writeOnly: return "Write Only"
        @unknown default: return "Unknown"
        }
    }

    private func locationStatusText(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not Determined"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorizedAlways: return "Authorized (Always)"
        case .authorized: return "Authorized"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - TCC Reset

    private func resetTCCPermissions() {
        let services = [
            "Calendar", "Camera", "Microphone", "AppleEvents",
            "Location", "AddressBook", "Photos"
        ]

        for service in services {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundleID]
            try? process.run()
            process.waitUntilExit()
        }
    }

    // MARK: - Log Collection

    private func refreshLogs() {
        isLoadingLogs = true
        let category = logCategoryFilter

        // Run OSLogStore query on a background thread — it's expensive
        Task.detached(priority: .userInitiated) {
            let results: [String]
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let position = store.position(timeIntervalSinceEnd: -300)  // Last 5 minutes

                let predicate: NSPredicate
                if category == "All" {
                    predicate = NSPredicate(format: "subsystem == 'com.ledge.app'")
                } else {
                    predicate = NSPredicate(format: "subsystem == 'com.ledge.app' AND category == %@", category)
                }

                let entries = try store.getEntries(at: position, matching: predicate)

                results = entries.compactMap { entry -> String? in
                    guard let logEntry = entry as? OSLogEntryLog else { return nil }
                    let time = logEntry.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
                    return "[\(time)] [\(logEntry.category)] \(logEntry.composedMessage)"
                }
                .suffix(200)
                .reversed()
                .map { $0 }
            } catch {
                results = ["Error reading logs: \(error.localizedDescription)"]
            }

            await MainActor.run {
                logEntries = results
                isLoadingLogs = false
            }
        }
    }
}
