import SwiftUI

/// Main entry point for the Ledge application.
///
/// Uses SwiftUI App lifecycle but bridges to AppKit via AppDelegate for
/// NSPanel management and display detection.
@main
struct LedgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window — appears on the primary display.
        // When running as a test host, show an empty view to avoid
        // triggering display/permission work that kills the test runner.
        Window("Ledge Settings", id: "settings") {
            if AppEnvironment.isTesting {
                EmptyView()
            } else {
                SettingsView(
                    layoutManager: appDelegate.layoutManager,
                    configStore: appDelegate.configStore
                )
                .environmentObject(appDelegate.displayManager)
                .environment(appDelegate.themeManager)
            }
        }
        .defaultSize(width: 800, height: 650)
    }
}
