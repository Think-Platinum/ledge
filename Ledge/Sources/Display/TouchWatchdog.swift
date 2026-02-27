import Foundation
import CoreGraphics
import os.log

/// Monitors CGEventTap health independently of the event callback.
///
/// The CGEventTap callback can only detect disables when events arrive. If the
/// tap is silently disabled and no events fire, the callback never runs and
/// we'd never know the tap is dead. This watchdog timer periodically checks
/// `CGEvent.tapIsEnabled()` and re-enables the tap if needed.
///
/// ENHANCED: Also monitors for "dead tap syndrome" — when the tap is technically
/// enabled but events stop arriving. This can happen if the tap thread crashes
/// or becomes unresponsive.
///
/// Runs on MainActor because it uses a `Timer` on the main run loop and
/// publishes state for the Touch Diagnostics widget to observe.
@MainActor
@Observable
final class TouchWatchdog {

    private let logger = Logger(subsystem: "com.ledge.app", category: "TouchWatchdog")

    // MARK: - Published State

    /// Whether the event tap is currently healthy (enabled).
    private(set) var isTapHealthy: Bool = true

    /// Number of times the tap has been found disabled since watchdog started.
    private(set) var disableCount: Int = 0

    /// Timestamp of the most recent tap disable detected by the watchdog.
    private(set) var lastDisableTime: Date? = nil

    /// Total number of health checks performed.
    private(set) var checksPerformed: Int = 0

    /// Whether the tap appears to be "dead" (enabled but not receiving events).
    /// This can indicate a crashed event tap thread or system filtering events.
    /// Only set when events stop arriving MID-SEQUENCE (finger was down, events stopped).
    /// Idle periods with no touch are perfectly normal and do NOT trigger this.
    private(set) var isDeadTapDetected: Bool = false

    /// Number of consecutive checks with no touch activity (for dead tap detection).
    private(set) var consecutiveQuietChecks: Int = 0

    /// Timestamp of last successful touch event (updated by flight recorder).
    private(set) var lastEventTime: Date? = nil

    /// Whether a touch sequence is currently in progress (finger is down).
    /// Set by the flight recorder / touch remapper. When true, we expect a
    /// continuous stream of events — silence during an active sequence is suspicious.
    private(set) var isTouchSequenceActive: Bool = false

    /// Current health status message (for diagnostic display).
    var healthStatus: String {
        if !isTapHealthy {
            return "⚠️ TAP DISABLED"
        } else if isDeadTapDetected {
            return "⚠️ TAP STALLED (events stopped mid-touch)"
        } else {
            return "✓ Healthy"
        }
    }

    // MARK: - Internal

    /// The CGEventTap mach port to monitor.
    private var tap: CFMachPort?

    /// Timer that fires every `checkInterval` seconds.
    private var timer: Timer?

    /// How often to check tap health (seconds).
    private let checkInterval: TimeInterval = 3.0  // Reduced from 5s for faster detection

    /// Callback to get the last event timestamp from the flight recorder.
    var getLastEventTimestamp: (() -> Date?)?

    /// Callback to get the total event count from the flight recorder.
    var getTotalEventCount: (() -> UInt64)?

    /// Last known total event count (for detecting new activity).
    private var lastKnownEventCount: UInt64 = 0

    // MARK: - Lifecycle

    /// Start monitoring the given event tap.
    ///
    /// - Parameter tap: The `CFMachPort` returned by `CGEvent.tapCreate`.
    func start(tap: CFMachPort) {
        self.tap = tap
        disableCount = 0
        lastDisableTime = nil
        checksPerformed = 0
        consecutiveQuietChecks = 0
        isTapHealthy = true
        isDeadTapDetected = false
        lastKnownEventCount = getTotalEventCount?() ?? 0

        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkTapHealth()
            }
        }
        logger.info("Watchdog started — checking tap health every \(self.checkInterval)s")
    }

    /// Stop monitoring.
    func stop() {
        timer?.invalidate()
        timer = nil
        tap = nil
        consecutiveQuietChecks = 0
        isDeadTapDetected = false
        logger.info("Watchdog stopped")
    }

    /// Notify the watchdog that a touch event was just processed (heartbeat).
    /// Call this from the flight recorder or touch remapper when events arrive.
    func recordEventActivity() {
        lastEventTime = Date()
        consecutiveQuietChecks = 0
        if isDeadTapDetected {
            isDeadTapDetected = false
            logger.info("Watchdog: tap recovered — events flowing again")
        }
    }

    /// Notify the watchdog that a touch sequence started (finger down).
    func touchSequenceStarted() {
        isTouchSequenceActive = true
        consecutiveQuietChecks = 0
    }

    /// Notify the watchdog that a touch sequence ended (finger up).
    func touchSequenceEnded() {
        isTouchSequenceActive = false
        consecutiveQuietChecks = 0
    }

    // MARK: - Health Check

    private func checkTapHealth() {
        guard let tap else { return }
        checksPerformed += 1

        // ─── Check 1: Is the tap enabled? ───
        let enabled = CGEvent.tapIsEnabled(tap: tap)
        if !enabled {
            // Tap was silently disabled — re-enable it
            CGEvent.tapEnable(tap: tap, enable: true)
            disableCount += 1
            lastDisableTime = Date()
            isTapHealthy = false
            consecutiveQuietChecks = 0
            logger.warning("⚠ Watchdog: event tap was DISABLED (detect #\(self.disableCount)) — re-enabled")

            // Verify re-enable worked
            let nowEnabled = CGEvent.tapIsEnabled(tap: tap)
            if nowEnabled {
                isTapHealthy = true
                logger.info("Watchdog: tap successfully re-enabled")
            } else {
                logger.error("Watchdog: tap re-enable FAILED — touch will not work until restart")
            }
            return
        }

        // Tap is enabled — mark as healthy (at least not disabled)
        if !isTapHealthy {
            isTapHealthy = true
            logger.info("Watchdog: tap health restored")
        }

        // ─── Check 2: Is the tap receiving events? ───
        // Get current event count from flight recorder
        let currentEventCount = getTotalEventCount?() ?? 0
        let hasNewEvents = currentEventCount > lastKnownEventCount
        lastKnownEventCount = currentEventCount

        if hasNewEvents {
            // Events are flowing — tap is alive
            consecutiveQuietChecks = 0
            if isDeadTapDetected {
                isDeadTapDetected = false
                logger.info("Watchdog: tap recovered — events detected after quiet period")
            }
        } else {
            // No new events since last check
            consecutiveQuietChecks += 1

            // Only flag as dead if we've seen a significant quiet period
            // AND we've seen events before (if we never received any, maybe user just hasn't touched)
            if consecutiveQuietChecks >= 4 && currentEventCount > 0 {
                if !isDeadTapDetected {
                    isDeadTapDetected = true
                    logger.error("⚠ Watchdog: DEAD TAP detected — tap is enabled but no events received for \(self.consecutiveQuietChecks * Int(self.checkInterval))s")
                    logger.error("   This may indicate: (1) CGEventTap thread crashed, (2) macOS is filtering events, (3) HID device disconnected")
                    logger.error("   Recommendation: Toggle panel OFF and back ON, or restart Ledge")
                }
            }
        }

        // Log periodic status
        if checksPerformed % 20 == 0 {
            logger.info("Watchdog: check #\(self.checksPerformed) — tap=\(enabled ? "enabled" : "disabled"), events=\(currentEventCount), quiet=\(self.consecutiveQuietChecks), status=\(self.healthStatus)")
        }
    }

    /// Force a full recovery attempt (for use by diagnostic widget or manual intervention).
    func forceRecovery() {
        guard let tap else {
            logger.warning("Cannot force recovery: no tap registered")
            return
        }

        logger.notice("Forcing tap recovery attempt...")

        // Disable and re-enable
        CGEvent.tapEnable(tap: tap, enable: false)
        Thread.sleep(forTimeInterval: 0.1)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Reset state
        consecutiveQuietChecks = 0
        isDeadTapDetected = false
        isTapHealthy = CGEvent.tapIsEnabled(tap: tap)

        logger.notice("Recovery attempt complete — tap \(self.isTapHealthy ? "enabled" : "STILL DISABLED")")
    }
}
