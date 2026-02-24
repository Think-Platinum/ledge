import SwiftUI
import Combine
import EventKit

/// Enhanced date/time widget with configurable display options.
///
/// Replaces the basic ClockWidget with richer formatting: 24h mode,
/// seconds, date, timezone selection, and font scaling with container size.
struct DateTimeWidget {

    struct Config: Codable {
        var use24Hour: Bool = true
        var showSeconds: Bool = true
        var showDate: Bool = true
        var dateFormat: String = "EEEE, d MMMM"
        var timezone: String? = nil  // nil = local
        var tintWithCalendarColor: Bool = false
    }

    static let descriptor = WidgetDescriptor(
        typeID: "com.ledge.datetime",
        displayName: "Date & Time",
        description: "Displays current date and time with configurable format",
        iconSystemName: "clock",
        minimumSize: .threeByTwo,
        defaultSize: .fourByFour,
        maximumSize: .eightBySix,
        defaultConfiguration: try? JSONEncoder().encode(Config()),
        viewFactory: { instanceID, configStore in
            AnyView(DateTimeWidgetView(instanceID: instanceID, configStore: configStore))
        },
        settingsFactory: { instanceID, configStore in
            AnyView(DateTimeSettingsView(instanceID: instanceID, configStore: configStore))
        }
    )
}

// MARK: - View

struct DateTimeWidgetView: View {
    @Environment(\.theme) private var theme
    let instanceID: UUID
    let configStore: WidgetConfigStore

    @State private var currentTime = Date()
    @State private var config = DateTimeWidget.Config()
    @State private var currentEventColor: Color? = nil
    @State private var currentEventTitle: String? = nil

    private let eventStore = EKEventStore()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private let eventCheckTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.height < 150
            let timeFontSize = isCompact ? min(geometry.size.width * 0.15, 48.0) : min(geometry.size.width * 0.18, 72.0)
            let dateFontSize = isCompact ? 12.0 : min(geometry.size.width * 0.05, 18.0)

            VStack(spacing: isCompact ? 4 : 8) {
                Spacer()

                // Time
                Text(timeString)
                    .font(.system(size: timeFontSize, weight: .thin, design: .monospaced))
                    .foregroundColor(currentEventColor ?? theme.primaryText)
                    .minimumScaleFactor(0.3)
                    .lineLimit(1)
                    .animation(.easeInOut(duration: 0.6), value: currentEventColor != nil)

                // Date (or current event name when in a meeting)
                if config.showDate {
                    Text(currentEventTitle ?? dateString)
                        .font(.system(size: dateFontSize, weight: .regular))
                        .foregroundColor(currentEventColor?.opacity(0.7) ?? theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            loadConfig()
            checkCurrentEvent()
        }
        .onReceive(timer) { time in currentTime = time }
        .onReceive(eventCheckTimer) { _ in checkCurrentEvent() }
        .onReceive(configStore.configDidChange) { changedID in
            if changedID == instanceID { loadConfig() }
        }
    }

    private var timeString: String {
        let formatter = DateFormatter()
        if let tz = config.timezone { formatter.timeZone = TimeZone(identifier: tz) }
        if config.use24Hour {
            formatter.dateFormat = config.showSeconds ? "HH:mm:ss" : "HH:mm"
        } else {
            formatter.dateFormat = config.showSeconds ? "h:mm:ss a" : "h:mm a"
        }
        return formatter.string(from: currentTime)
    }

    private var dateString: String {
        let formatter = DateFormatter()
        if let tz = config.timezone { formatter.timeZone = TimeZone(identifier: tz) }
        formatter.dateFormat = config.dateFormat
        return formatter.string(from: currentTime)
    }

    private func loadConfig() {
        if let saved: DateTimeWidget.Config = configStore.read(instanceID: instanceID, as: DateTimeWidget.Config.self) {
            config = saved
        }
    }

    /// Check if the user is currently in a calendar event and tint accordingly.
    /// Only activates if calendar permission was already granted (e.g. by the Calendar widget).
    private func checkCurrentEvent() {
        guard config.tintWithCalendarColor else {
            currentEventColor = nil
            currentEventTitle = nil
            return
        }

        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            currentEventColor = nil
            currentEventTitle = nil
            return
        }

        let now = Date()
        let soon = Calendar.current.date(byAdding: .minute, value: 1, to: now)!
        let predicate = eventStore.predicateForEvents(withStart: now, end: soon, calendars: nil)
        let events = eventStore.events(matching: predicate)

        // Find the first non-all-day event currently happening
        if let event = events.first(where: { !$0.isAllDay && $0.startDate <= now && $0.endDate > now }),
           let cgColor = event.calendar?.cgColor {
            currentEventColor = Color(cgColor: cgColor)
            currentEventTitle = event.title
        } else {
            currentEventColor = nil
            currentEventTitle = nil
        }
    }
}

// MARK: - Settings

struct DateTimeSettingsView: View {
    let instanceID: UUID
    let configStore: WidgetConfigStore

    @State private var config = DateTimeWidget.Config()

    var body: some View {
        Form {
            Toggle("24-hour format", isOn: $config.use24Hour)
            Toggle("Show seconds", isOn: $config.showSeconds)
            Toggle("Show date", isOn: $config.showDate)

            if config.showDate {
                TextField("Date format", text: $config.dateFormat)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("Tint with calendar event color", isOn: $config.tintWithCalendarColor)
        }
        .onAppear { loadConfig() }
        .onChange(of: config.use24Hour) { _, _ in saveConfig() }
        .onChange(of: config.showSeconds) { _, _ in saveConfig() }
        .onChange(of: config.showDate) { _, _ in saveConfig() }
        .onChange(of: config.dateFormat) { _, _ in saveConfig() }
        .onChange(of: config.tintWithCalendarColor) { _, _ in saveConfig() }
    }

    private func loadConfig() {
        if let saved: DateTimeWidget.Config = configStore.read(instanceID: instanceID, as: DateTimeWidget.Config.self) {
            config = saved
        }
    }

    private func saveConfig() {
        configStore.write(instanceID: instanceID, value: config)
    }
}
