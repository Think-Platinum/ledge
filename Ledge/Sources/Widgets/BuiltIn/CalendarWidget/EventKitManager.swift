import EventKit
import os.log

/// Manages EventKit access for fetching calendar events.
///
/// Handles permission requests and event fetching. Works with any calendar
/// synced to macOS (iCloud, Google Calendar, Exchange, etc.).
@Observable
class EventKitManager {

    private let logger = Logger(subsystem: "com.ledge.app", category: "EventKitManager")
    private let store = EKEventStore()

    var hasAccess: Bool = false
    var events: [CalendarEvent] = []

    struct CalendarEvent: Identifiable {
        let id: String
        let title: String
        let startDate: Date
        let endDate: Date
        let isAllDay: Bool
        let calendarColor: CGColor?
        let calendarName: String
    }

    /// Request calendar access and begin fetching events.
    func requestAccess() {
        store.requestFullAccessToEvents { granted, error in
            Task { @MainActor [weak self] in
                self?.hasAccess = granted
                if granted {
                    self?.fetchEvents()
                } else if let error {
                    self?.logger.error("Calendar access denied: \(error.localizedDescription)")
                }
            }
        }

        // Listen for calendar changes
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.fetchEvents()
            }
        }
    }

    /// Fetch events for the next N days.
    ///
    /// Filters to the set of calendars the user has left checked in macOS
    /// Calendar.app's sidebar — see `visibleCalendars()` for how that is
    /// derived. The disabled set is re-read on every call so that toggling
    /// a calendar's visibility in Calendar.app propagates on the next tick
    /// without restarting Ledge (#68).
    func fetchEvents(daysAhead: Int = 3) {
        guard hasAccess else { return }

        let now = Date()
        let endDate = Calendar.current.date(byAdding: .day, value: daysAhead, to: now)!

        let calendars = visibleCalendars()
        let predicate = store.predicateForEvents(withStart: now, end: endDate, calendars: calendars)
        let ekEvents = store.events(matching: predicate)

        events = ekEvents.map { event in
            CalendarEvent(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "Untitled",
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                calendarColor: event.calendar?.cgColor,
                calendarName: event.calendar?.title ?? ""
            )
        }
        .sorted { $0.startDate < $1.startDate }
    }

    /// Calendars to query, filtered to exclude those the user has hidden
    /// in macOS Calendar.app's sidebar.
    ///
    /// Returns `nil` to mean "every calendar" — which is what
    /// `predicateForEvents` accepts as the wildcard. We return `nil`
    /// (preserving the pre-#68 behaviour) when:
    /// - The user has not hidden anything (no point filtering).
    /// - Calendar.app's preferences are unreadable (sandboxed build,
    ///   missing prefs file).
    /// - The filter would leave zero calendars (stale or corrupt
    ///   disabled set — fall back to "show all" rather than a blank
    ///   widget; AC7).
    private func visibleCalendars() -> [EKCalendar]? {
        let disabled = readDisabledCalendarIdentifiers()
        guard !disabled.isEmpty else { return nil }

        let all = store.calendars(for: .event)
        let visible = all.filter { !disabled.contains($0.calendarIdentifier) }

        return visible.isEmpty ? nil : visible
    }

    /// Read Calendar.app's hidden-calendar UUIDs from its preference
    /// domain.
    ///
    /// macOS Calendar.app stores its sidebar visibility state in the
    /// `com.apple.iCal` preference domain under `DisabledCalendars` —
    /// a dict keyed by window name. `MainWindow` is the user's primary
    /// Calendar.app window; the value is an array of
    /// `EKCalendar.calendarIdentifier` UUIDs the user has unchecked.
    ///
    /// This is an undocumented preference. The fallback (empty set ⇒
    /// caller sees `nil` ⇒ all calendars) keeps the widget functional
    /// if Apple ever renames or restructures the key.
    ///
    /// Reading another app's preference domain via
    /// `UserDefaults(suiteName:)` requires no entitlement on a
    /// non-sandboxed app (which Ledge is — `ENABLE_APP_SANDBOX = NO`).
    /// In a sandboxed build the call returns an empty domain and the
    /// filter silently degrades to "show all" — see #68 caveats.
    private func readDisabledCalendarIdentifiers() -> Set<String> {
        guard let defaults = UserDefaults(suiteName: "com.apple.iCal"),
              let disabledByWindow = defaults.dictionary(forKey: "DisabledCalendars"),
              let ids = disabledByWindow["MainWindow"] as? [String]
        else {
            return []
        }
        return Set(ids)
    }
}
