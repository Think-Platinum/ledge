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
    @State private var logTimeWindow: LogTimeWindow = .oneHour
    @State private var isLoadingLogs: Bool = false
    @State private var selfCheckResults: [DisplayManager.SelfCheckResult] = []

    private let bundleID = Bundle.main.bundleIdentifier ?? "com.thinkplatinum.Ledge"

    /// How far back "Load Logs" queries OSLogStore. `OSLogStore` is scoped to
    /// the current process so "since launch" is effectively the upper bound
    /// anyway — this just controls the window width.
    enum LogTimeWindow: String, CaseIterable {
        case fiveMinutes = "5m"
        case thirtyMinutes = "30m"
        case oneHour = "1h"
        case fourHours = "4h"
        case sinceLaunch = "Launch"

        var seconds: TimeInterval {
            switch self {
            case .fiveMinutes:   return 300
            case .thirtyMinutes: return 1800
            case .oneHour:       return 3600
            case .fourHours:     return 14400
            case .sinceLaunch:   return 86400 // clamped by OSLogStore to process start
            }
        }
    }

    var body: some View {
        Form {
            buildSection
            permissionsSection
            touchPipelineSection
            displaySecuritySection
            debugVisualsSection
            appStateSection
            logsSection
        }
        .formStyle(.grouped)
        .navigationTitle("Developer")
    }

    // MARK: - Build Identity

    /// Surfaces the compile-time `BuildInfo` constants so you can verify
    /// "am I actually running what I just shipped?" without `lsof` /
    /// `mdfind`. Stamped by `bin/ship` before each release build; reads
    /// `"dev"` for Cmd+R-from-Xcode builds that skipped the ship script.
    private var buildSection: some View {
        Section("Build") {
            LabeledContent("Commit") {
                HStack(spacing: 6) {
                    Text(BuildInfo.commit)
                        .font(.caption.monospaced())
                    if BuildInfo.workingTree == "DIRTY" {
                        Text("DIRTY")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.orange)
                    } else if BuildInfo.workingTree == "dev" {
                        Text("dev build")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            LabeledContent("Built") {
                Text(BuildInfo.builtAt)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if !BuildInfo.signingIdentity.isEmpty {
                LabeledContent("Signed") {
                    Text(BuildInfo.signingIdentity)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            // Bundle path of the running process — distinct from the
            // commit. If LaunchServices activated a stale install, this
            // is how you spot it: the path won't be /Applications/Ledge.app.
            LabeledContent("Bundle path") {
                Text(Bundle.main.bundlePath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
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

    // MARK: - Display Security

    private var displaySecuritySection: some View {
        let counts = displayManager.securityEventCounts

        return Section("Display Security") {
            LabeledContent("Blanked") {
                HStack {
                    statusDot(!displayManager.isDisplayBlanked)
                    Text(displayManager.isDisplayBlanked ? "Yes" : "No")
                        .font(.caption.monospaced())
                }
            }

            if let reason = displayManager.lastBlankReason {
                LabeledContent("Last Blank") {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(reason)
                            .font(.caption.monospaced())
                        if let ts = displayManager.lastBlankTimestamp {
                            Text(formatTimestamp(ts))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let reason = displayManager.lastUnblankReason {
                LabeledContent("Last Unblank") {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(reason)
                            .font(.caption.monospaced())
                        if let ts = displayManager.lastUnblankTimestamp {
                            Text(formatTimestamp(ts))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            eventCountRow(label: "screensDidSleep", value: counts.screensDidSleep)
            eventCountRow(label: "screensDidWake", value: counts.screensDidWake)
            eventCountRow(label: "willSleep", value: counts.willSleep)
            eventCountRow(label: "didWake", value: counts.didWake)
            eventCountRow(label: "screenIsLocked", value: counts.screenLocked)
            eventCountRow(label: "screenIsUnlocked", value: counts.screenUnlocked)
            eventCountRow(label: "screensaver.didStart", value: counts.screensaverStart)
            eventCountRow(label: "screensaver.didStop", value: counts.screensaverStop)

            Button("Force Unblank") {
                displayManager.forceUnblank()
            }
            .help("Clears the blanking state and shows the panel content. Use if the panel is stuck black after sleep/wake or display reconfiguration.")

            Text("Counts each observed system event since app launch. If the panel sticks black, these reveal which notification sequence is missing — e.g. a wake without a matching screensDidWake or screenIsUnlocked.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func eventCountRow(label: String, value: Int) -> some View {
        LabeledContent(label) {
            Text("\(value)")
                .font(.caption.monospaced())
                .foregroundStyle(value > 0 ? .primary : .secondary)
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
    }

    // MARK: - Debug Visuals

    private var debugVisualsSection: some View {
        Section("Debug Visuals") {
            Toggle("Show Touch Surfaces", isOn: $displayManager.showTouchSurfaces)
            Text("Draws a red border around interactive touch targets on the dashboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                        Text(verbatim: "key=\(panel.isKeyWindow) level=\(Int(panel.level.rawValue))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not created")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Mouse Guard") {
                statusDot(displayManager.isMouseGuardEnabled)
                Text(displayManager.isMouseGuardEnabled ? "Enabled" : "Disabled")
                    .font(.caption.monospaced())
            }

            // Self-check — evaluates the display invariants on demand so
            // divergence can be seen without reading logs.
            Button("Run Self-Check") {
                selfCheckResults = displayManager.runSelfCheck()
            }
            .help("Evaluate whether xeneonScreen / panel / fullscreenHelper agree with each other. Result is also written to os.log.")

            if !selfCheckResults.isEmpty {
                ForEach(selfCheckResults) { result in
                    selfCheckRow(result)
                }

                Text("Results also written to os.log (Logs → DisplayManager → SNAPSHOT[self-check]).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Render one self-check row: coloured dot, invariant name, optional detail.
    private func selfCheckRow(_ result: DisplayManager.SelfCheckResult) -> some View {
        LabeledContent(result.name) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                selfCheckDot(result.status)
                if let detail = result.detail {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(result.status == .fail ? .primary : .secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.trailing)
                } else {
                    Text(selfCheckLabel(result.status))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func selfCheckDot(_ status: DisplayManager.SelfCheckStatus) -> some View {
        let color: Color
        switch status {
        case .pass:    color = .green
        case .fail:    color = .red
        case .skipped: color = .gray
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    private func selfCheckLabel(_ status: DisplayManager.SelfCheckStatus) -> String {
        switch status {
        case .pass:    return "Pass"
        case .fail:    return "Fail"
        case .skipped: return "Skipped"
        }
    }

    // MARK: - Logs

    private var logsSection: some View {
        Section("Logs") {
            Picker("Category", selection: $logCategoryFilter) {
                Text("All").tag("All")
                Section("Display") {
                    ForEach(LogCategory.display, id: \.self) { cat in
                        Text(cat).tag(cat)
                    }
                }
                ForEach(LogCategory.widgetGroups) { group in
                    Section(group.widget) {
                        ForEach(group.categories, id: \.self) { cat in
                            Text(cat).tag(cat)
                        }
                    }
                }
            }
            .pickerStyle(.menu)

            Picker("Window", selection: $logTimeWindow) {
                ForEach(LogTimeWindow.allCases, id: \.self) { window in
                    Text(window.rawValue).tag(window)
                }
            }
            .pickerStyle(.segmented)

            DisclosureGroup("Per-Widget Debug Logging") {
                ForEach(LogCategory.widgetGroups) { group in
                    Text(group.widget)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    ForEach(group.categories, id: \.self) { cat in
                        CategoryDebugToggle(category: cat)
                    }
                }
            }

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
        let windowSeconds = logTimeWindow.seconds

        // Run OSLogStore query on a background thread — it's expensive
        Task.detached(priority: .userInitiated) {
            let results: [String]
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                // OSLogStore is scoped to the current process, so the store
                // cannot return entries from before launch — it clamps to the
                // process start regardless of the window we request.
                let position = store.position(timeIntervalSinceEnd: -windowSeconds)

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
                .suffix(500)
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

/// A `Toggle` bound to `UserDefaults` via `@AppStorage` for a single log
/// category's `.debug` gate. Extracted because `@AppStorage` requires a
/// static key literal — this wrapper parameterises it by category name.
private struct CategoryDebugToggle: View {
    let category: String
    @AppStorage var enabled: Bool

    init(category: String) {
        self.category = category
        self._enabled = AppStorage(wrappedValue: false, DebugLogger.debugEnabledKey(for: category))
    }

    var body: some View {
        Toggle(category, isOn: $enabled)
    }
}
