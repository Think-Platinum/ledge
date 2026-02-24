import Foundation

/// Utility for detecting the runtime environment.
///
/// When running under XCTest, the app delegate's launch code must skip
/// system-level operations that require permissions (Accessibility,
/// CGEventTap) or physical hardware (Xeneon Edge display). Without this
/// guard, the test runner gets killed by permission dialogs or hangs
/// waiting for hardware that isn't connected.
nonisolated enum AppEnvironment {

    /// `true` when the process is hosted by XCTest (unit tests or UI tests).
    ///
    /// Detection uses multiple signals because the hosted-test launch sequence
    /// varies across Xcode versions:
    ///
    /// 1. `XCTestConfigurationFilePath` — set by Xcode when launching the test host.
    /// 2. `XCTestSessionIdentifier` — another env var injected by the test runner.
    /// 3. `XCTestBundlePath` — set in some Xcode versions.
    /// 4. `NSClassFromString("XCTestCase")` — XCTest framework is loaded into the process.
    /// 5. `-XCTest` in launch arguments — Xcode passes this to the test host executable.
    static let isTesting: Bool = {
        let env = ProcessInfo.processInfo.environment
        let args = ProcessInfo.processInfo.arguments

        // Environment variables Xcode injects into the test host process
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestSessionIdentifier"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }

        // Launch argument Xcode passes to the test host
        if args.contains(where: { $0.contains("XCTest") || $0.contains("xctest") }) { return true }

        // XCTest framework loaded into the process
        if NSClassFromString("XCTestCase") != nil { return true }

        return false
    }()
}
