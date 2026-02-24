import SwiftUI
import Combine

/// Calendar widget showing upcoming events from macOS calendars.
///
/// Uses EventKit to access calendars synced to macOS (iCloud, Google, Exchange).
/// Color-codes events by calendar. Requires calendar access permission.
struct CalendarWidget {

    struct Config: Codable {
        var daysToShow: Int = 3
        var showAllDayEvents: Bool = true
    }

    static let descriptor = WidgetDescriptor(
        typeID: "com.ledge.calendar",
        displayName: "Calendar",
        description: "Upcoming events from your calendars",
        iconSystemName: "calendar",
        minimumSize: .fourByThree,
        defaultSize: .sixByFour,
        maximumSize: .eightBySix,
        defaultConfiguration: try? JSONEncoder().encode(Config()),
        viewFactory: { instanceID, configStore in
            AnyView(CalendarWidgetView(instanceID: instanceID, configStore: configStore))
        },
        settingsFactory: { instanceID, configStore in
            AnyView(CalendarSettingsView(instanceID: instanceID, configStore: configStore))
        },
        requiredPermissions: [.calendar]
    )
}

// MARK: - View

struct CalendarWidgetView: View {
    @Environment(\.theme) private var theme
    let instanceID: UUID
    let configStore: WidgetConfigStore

    @State private var config = CalendarWidget.Config()
    @State private var eventManager = EventKitManager()
    @State private var currentMeetingColor: Color? = nil

    private let meetingCheckTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "calendar")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.secondaryText)
                Text(Date(), format: .dateTime.month(.wide).day().year())
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if !eventManager.hasAccess {
                // Permission needed
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange.opacity(0.6))
                    Text("Calendar Access Required")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.secondaryText)
                    Text("Grant access in System Settings")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.tertiaryText)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if filteredEvents.isEmpty {
                VStack {
                    Spacer()
                    Text("No upcoming events")
                        .font(.system(size: 16))
                        .foregroundStyle(theme.tertiaryText)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                // Event list
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(groupedEvents, id: \.date) { group in
                            // Day header
                            Text(dayLabel(group.date))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(theme.secondaryText)
                                .padding(.horizontal, 14)
                                .padding(.top, 8)

                            ForEach(group.events) { event in
                                eventRow(event)
                            }
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
        }
        .background(
            // When in a meeting, tint the widget background with the calendar colour
            Group {
                if let meetingColor = currentMeetingColor {
                    meetingColor.opacity(0.15)
                }
            }
        )
        .onAppear {
            loadConfig()
            eventManager.requestAccess()
            checkCurrentMeeting()
        }
        .onReceive(meetingCheckTimer) { _ in
            checkCurrentMeeting()
        }
        .onReceive(configStore.configDidChange) { changedID in
            if changedID == instanceID { loadConfig() }
        }
        .animation(.easeInOut(duration: 0.6), value: currentMeetingColor != nil)
    }

    private var filteredEvents: [EventKitManager.CalendarEvent] {
        var events = eventManager.events
        if !config.showAllDayEvents {
            events = events.filter { !$0.isAllDay }
        }
        return events
    }

    private struct DayGroup {
        let date: Date
        let events: [EventKitManager.CalendarEvent]
    }

    private var groupedEvents: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredEvents) { event in
            calendar.startOfDay(for: event.startDate)
        }
        return grouped.sorted { $0.key < $1.key }
            .map { DayGroup(date: $0.key, events: $0.value) }
    }

    /// Whether an event is currently happening right now.
    private func isEventActive(_ event: EventKitManager.CalendarEvent) -> Bool {
        let now = Date()
        return !event.isAllDay && event.startDate <= now && event.endDate > now
    }

    private func eventRow(_ event: EventKitManager.CalendarEvent) -> some View {
        let calColor = event.calendarColor.map { Color(cgColor: $0) } ?? .blue
        let active = isEventActive(event)

        return HStack(spacing: 10) {
            // Calendar color indicator — use Color view + clipShape instead of
            // Shape.fill() to prevent foregroundStyle from leaking to sibling views
            calColor
                .frame(width: 4)
                .clipShape(RoundedRectangle(cornerRadius: 2))

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.system(size: 18, weight: active ? .semibold : .medium))
                    .foregroundColor(active ? calColor : theme.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if event.isAllDay {
                    Text("All day")
                        .font(.system(size: 15))
                        .foregroundColor(theme.tertiaryText)
                } else {
                    Text("\(event.startDate, format: .dateTime.hour().minute()) – \(event.endDate, format: .dateTime.hour().minute())")
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(active ? calColor.opacity(0.7) : theme.tertiaryText)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(active ? calColor.opacity(0.08) : Color.clear)
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "TODAY" }
        if Calendar.current.isDateInTomorrow(date) { return "TOMORROW" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: date).uppercased()
    }

    /// Check if any non-all-day event is happening right now.
    /// If so, tint the entire Calendar widget background with that event's calendar colour.
    private func checkCurrentMeeting() {
        let now = Date()
        if let activeEvent = eventManager.events.first(where: { !$0.isAllDay && $0.startDate <= now && $0.endDate > now }),
           let cgColor = activeEvent.calendarColor {
            currentMeetingColor = Color(cgColor: cgColor)
        } else {
            currentMeetingColor = nil
        }
    }

    private func loadConfig() {
        if let saved: CalendarWidget.Config = configStore.read(instanceID: instanceID, as: CalendarWidget.Config.self) {
            config = saved
        }
        eventManager.fetchEvents(daysAhead: config.daysToShow)
    }
}

// MARK: - Settings

struct CalendarSettingsView: View {
    let instanceID: UUID
    let configStore: WidgetConfigStore

    @State private var config = CalendarWidget.Config()

    var body: some View {
        Form {
            Stepper("Days to show: \(config.daysToShow)", value: $config.daysToShow, in: 1...7)
            Toggle("Show all-day events", isOn: $config.showAllDayEvents)
        }
        .onAppear { loadConfig() }
        .onChange(of: config.daysToShow) { _, _ in saveConfig() }
        .onChange(of: config.showAllDayEvents) { _, _ in saveConfig() }
    }

    private func loadConfig() {
        if let saved: CalendarWidget.Config = configStore.read(instanceID: instanceID, as: CalendarWidget.Config.self) {
            config = saved
        }
    }

    private func saveConfig() {
        configStore.write(instanceID: instanceID, value: config)
    }
}
