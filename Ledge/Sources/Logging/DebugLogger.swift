import Foundation
import os.log

/// A supplementary logger for `.debug`-level messages gated by a per-category
/// `UserDefaults` flag (`logDebug.<category>`). Used alongside each widget's
/// regular `os.Logger` — the regular logger handles `.info` / `.notice` /
/// `.error` etc. (with their `privacy:` modifiers), and this type handles
/// `.debug` calls that should be silent unless the user has flipped the
/// matching toggle in Developer Settings → Logs.
///
/// Why separate from `os.Logger`: Swift's `Logger.debug(_:)` requires a
/// string interpolation at the call site (compile-time check), so a
/// transparent wrapper that forwards `OSLogMessage` values is not possible.
/// Call sites here use plain `String` interpolation — no `privacy:` modifiers.
///
/// Emission strategy: when the toggle is on, the message is emitted at
/// `.notice` level (prefixed with `[debug]`) rather than `.debug`. macOS does
/// not persist `.debug` to `OSLogStore` by default, so emitting at `.notice`
/// is what makes the toggle visibly work in the in-app log viewer without
/// requiring a one-time `log config --mode level:debug` external setup.
nonisolated struct DebugLogger: Sendable {

    private let logger: Logger
    private let category: String

    nonisolated init(subsystem: String = "com.ledge.app", category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.category = category
    }

    /// UserDefaults key used to gate `.debug` messages for a given category.
    nonisolated static func debugEnabledKey(for category: String) -> String {
        "logDebug.\(category)"
    }

    nonisolated private var debugEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.debugEnabledKey(for: category))
    }

    /// Emit a debug-level message if the category's toggle is on. The message
    /// is elevated to `.notice` level so it persists in `OSLogStore` and
    /// shows up in the Developer Settings log viewer.
    ///
    /// The `@autoclosure` avoids building the interpolated string when the
    /// toggle is off.
    nonisolated func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        let rendered = message()
        logger.notice("[debug] \(rendered, privacy: .public)")
    }
}
