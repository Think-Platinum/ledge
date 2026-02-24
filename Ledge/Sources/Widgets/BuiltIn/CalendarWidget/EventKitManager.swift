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
    func fetchEvents(daysAhead: Int = 3) {
        guard hasAccess else { return }

        let now = Date()
        let endDate = Calendar.current.date(byAdding: .day, value: daysAhead, to: now)!

        let predicate = store.predicateForEvents(withStart: now, end: endDate, calendars: nil)
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
}
