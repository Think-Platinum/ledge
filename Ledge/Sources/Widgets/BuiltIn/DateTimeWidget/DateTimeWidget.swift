import SwiftUI
import Combine
import EventKit

/// Enhanced date/time widget with configurable display options and multiple timezone support.
///
/// Displays the current time with optional additional timezones. The number of timezones
/// shown automatically adjusts based on widget size.
struct DateTimeWidget {

    struct Config: Codable {
        var use24Hour: Bool = true
        var showSeconds: Bool = true
        var showDate: Bool = true
        var dateFormat: String = "EEEE, d MMMM"
        var primaryTimezone: String? = nil  // nil = local timezone
        var additionalTimezones: [String] = []  // e.g., ["America/New_York", "Europe/London", "Asia/Tokyo"]
        var tintWithCalendarColor: Bool = false
    }

    static let descriptor = WidgetDescriptor(
        typeID: "com.ledge.datetime",
        displayName: "Date & Time",
        description: "Displays current date and time with optional additional timezones",
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
            let layout = calculateLayout(size: geometry.size)
            
            VStack(spacing: layout.spacing) {
                Spacer()

                // Primary time display
                primaryTimeView(layout: layout)

                // Date (or current event name when in a meeting)
                if config.showDate {
                    Text(currentEventTitle ?? dateString(for: config.primaryTimezone))
                        .font(.system(size: layout.dateFontSize, weight: .regular))
                        .foregroundColor(currentEventColor?.opacity(0.7) ?? theme.secondaryText)
                        .lineLimit(1)
                }

                // Additional timezones (if space allows and configured)
                if !config.additionalTimezones.isEmpty && layout.maxAdditionalTimezones > 0 {
                    Divider()
                        .background(theme.secondaryText.opacity(0.3))
                        .padding(.horizontal, layout.spacing * 2)
                    
                    additionalTimezonesView(layout: layout)
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

    // MARK: - Layout Calculation

    private struct LayoutMetrics {
        let timeFontSize: CGFloat
        let dateFontSize: CGFloat
        let timezoneFontSize: CGFloat
        let spacing: CGFloat
        let maxAdditionalTimezones: Int
    }

    private func calculateLayout(size: CGSize) -> LayoutMetrics {
        let height = size.height
        let width = size.width
        
        // Determine size category based on height
        let isCompact = height < 150      // Small widgets (2 rows)
        let isMedium = height < 250       // Medium widgets (3-4 rows)
        let isLarge = height >= 250       // Large widgets (5-6 rows)
        
        // Primary time font size scales with width
        let timeFontSize: CGFloat
        let dateFontSize: CGFloat
        let timezoneFontSize: CGFloat
        let spacing: CGFloat
        let maxAdditionalTimezones: Int
        
        if isCompact {
            // Compact: show primary time only, no room for additional timezones
            timeFontSize = min(width * 0.15, 48.0)
            dateFontSize = 12.0
            timezoneFontSize = 0  // Not shown
            spacing = 4
            maxAdditionalTimezones = 0
        } else if isMedium {
            // Medium: can show 1-2 additional timezones
            timeFontSize = min(width * 0.18, 60.0)
            dateFontSize = min(width * 0.05, 16.0)
            timezoneFontSize = min(width * 0.045, 14.0)
            spacing = 6
            maxAdditionalTimezones = height >= 200 ? 2 : 1
        } else {
            // Large: can show 3-4 additional timezones
            timeFontSize = min(width * 0.18, 72.0)
            dateFontSize = min(width * 0.05, 18.0)
            timezoneFontSize = min(width * 0.045, 16.0)
            spacing = 8
            maxAdditionalTimezones = height >= 320 ? 4 : 3
        }
        
        return LayoutMetrics(
            timeFontSize: timeFontSize,
            dateFontSize: dateFontSize,
            timezoneFontSize: timezoneFontSize,
            spacing: spacing,
            maxAdditionalTimezones: maxAdditionalTimezones
        )
    }

    // MARK: - Primary Time View

    private func primaryTimeView(layout: LayoutMetrics) -> some View {
        Text(timeString(for: config.primaryTimezone))
            .font(.system(size: layout.timeFontSize, weight: .thin, design: .monospaced))
            .foregroundColor(currentEventColor ?? theme.primaryText)
            .minimumScaleFactor(0.3)
            .lineLimit(1)
            .animation(.easeInOut(duration: 0.6), value: currentEventColor != nil)
    }

    // MARK: - Additional Timezones View

    private func additionalTimezonesView(layout: LayoutMetrics) -> some View {
        let timezonesToShow = Array(config.additionalTimezones.prefix(layout.maxAdditionalTimezones))
        
        return VStack(spacing: layout.spacing / 2) {
            ForEach(timezonesToShow, id: \.self) { timezoneID in
                timezoneRow(timezoneID: timezoneID, layout: layout)
            }
        }
        .padding(.horizontal, layout.spacing)
    }

    private func timezoneRow(timezoneID: String, layout: LayoutMetrics) -> some View {
        HStack(spacing: layout.spacing) {
            // City name (abbreviated)
            Text(cityName(for: timezoneID))
                .font(.system(size: layout.timezoneFontSize, weight: .medium, design: .rounded))
                .foregroundColor(theme.secondaryText)
                .frame(minWidth: 60, alignment: .leading)
                .lineLimit(1)
            
            Spacer()
            
            // Time in that timezone
            Text(timeString(for: timezoneID))
                .font(.system(size: layout.timezoneFontSize, weight: .regular, design: .monospaced))
                .foregroundColor(theme.primaryText.opacity(0.9))
                .lineLimit(1)
            
            // Offset indicator (e.g., "+2h", "-5h")
            if let offset = timezoneOffset(for: timezoneID) {
                Text(offset)
                    .font(.system(size: layout.timezoneFontSize * 0.8, weight: .regular, design: .monospaced))
                    .foregroundColor(theme.secondaryText.opacity(0.7))
                    .frame(minWidth: 32, alignment: .trailing)
            }
        }
    }

    // MARK: - Formatting Helpers

    private func timeString(for timezoneID: String?) -> String {
        let formatter = DateFormatter()
        if let tzID = timezoneID, let tz = TimeZone(identifier: tzID) {
            formatter.timeZone = tz
        }
        if config.use24Hour {
            formatter.dateFormat = config.showSeconds ? "HH:mm:ss" : "HH:mm"
        } else {
            formatter.dateFormat = config.showSeconds ? "h:mm:ss a" : "h:mm a"
        }
        return formatter.string(from: currentTime)
    }

    private func dateString(for timezoneID: String?) -> String {
        let formatter = DateFormatter()
        if let tzID = timezoneID, let tz = TimeZone(identifier: tzID) {
            formatter.timeZone = tz
        }
        formatter.dateFormat = config.dateFormat
        return formatter.string(from: currentTime)
    }

    /// Extract a short city name from a timezone identifier (e.g., "America/New_York" → "New York")
    private func cityName(for timezoneID: String) -> String {
        let components = timezoneID.split(separator: "/")
        guard let cityPart = components.last else { return timezoneID }
        return cityPart.replacingOccurrences(of: "_", with: " ")
    }

    /// Calculate the hour offset from the primary timezone (e.g., "+2h", "-5h", "=")
    private func timezoneOffset(for timezoneID: String) -> String? {
        guard let targetTZ = TimeZone(identifier: timezoneID) else { return nil }
        
        let primaryTZ: TimeZone
        if let primaryID = config.primaryTimezone, let tz = TimeZone(identifier: primaryID) {
            primaryTZ = tz
        } else {
            primaryTZ = TimeZone.current
        }
        
        let primaryOffset = primaryTZ.secondsFromGMT(for: currentTime)
        let targetOffset = targetTZ.secondsFromGMT(for: currentTime)
        let diffHours = (targetOffset - primaryOffset) / 3600
        
        if diffHours == 0 {
            return "="
        } else if diffHours > 0 {
            return "+\(diffHours)h"
        } else {
            return "\(diffHours)h"
        }
    }

    // MARK: - Config & Event Handling

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
    @State private var showingPrimaryTimezonePicker = false
    @State private var showingAdditionalTimezonePicker = false

    var body: some View {
        Form {
            Section("Time Format") {
                Toggle("24-hour format", isOn: $config.use24Hour)
                Toggle("Show seconds", isOn: $config.showSeconds)
            }
            
            Section("Date Display") {
                Toggle("Show date", isOn: $config.showDate)
                
                if config.showDate {
                    TextField("Date format", text: $config.dateFormat)
                        .textFieldStyle(.roundedBorder)
                    Text("Format: EEEE=weekday, MMMM=month, d=day")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Section("Primary Timezone") {
                HStack {
                    Text("Timezone")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: {
                        showingPrimaryTimezonePicker = true
                    }) {
                        Text(config.primaryTimezone.map { cityName(for: $0) } ?? "Local")
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Section("Additional Timezones") {
                Text("Add up to 4 additional timezones. Visible count depends on widget size.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // List of configured timezones
                ForEach(config.additionalTimezones, id: \.self) { tzID in
                    HStack {
                        Text(cityName(for: tzID))
                            .foregroundColor(.primary)
                        Spacer()
                        Text(tzID)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button(action: {
                            config.additionalTimezones.removeAll { $0 == tzID }
                            saveConfig()
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                // Add new timezone button
                if config.additionalTimezones.count < 4 {
                    Button(action: {
                        showingAdditionalTimezonePicker = true
                    }) {
                        Label("Add Timezone", systemImage: "plus.circle")
                    }
                }
            }
            
            Section("Calendar Integration") {
                Toggle("Tint with calendar event color", isOn: $config.tintWithCalendarColor)
                Text("Shows current meeting name and uses calendar color when in an event")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear { loadConfig() }
        .onChange(of: config.use24Hour) { _, _ in saveConfig() }
        .onChange(of: config.showSeconds) { _, _ in saveConfig() }
        .onChange(of: config.showDate) { _, _ in saveConfig() }
        .onChange(of: config.dateFormat) { _, _ in saveConfig() }
        .onChange(of: config.primaryTimezone) { _, _ in saveConfig() }
        .onChange(of: config.tintWithCalendarColor) { _, _ in saveConfig() }
        .sheet(isPresented: $showingPrimaryTimezonePicker) {
            TimezonePickerSheet(
                title: "Select Primary Timezone",
                allowLocal: true,
                excludeTimezones: [],
                onSelect: { tzID in
                    config.primaryTimezone = tzID
                    saveConfig()
                    showingPrimaryTimezonePicker = false
                }
            )
        }
        .sheet(isPresented: $showingAdditionalTimezonePicker) {
            TimezonePickerSheet(
                title: "Add Timezone",
                allowLocal: false,
                excludeTimezones: [config.primaryTimezone].compactMap { $0 } + config.additionalTimezones,
                onSelect: { tzID in
                    if let tzID, config.additionalTimezones.count < 4 {
                        config.additionalTimezones.append(tzID)
                        saveConfig()
                    }
                    showingAdditionalTimezonePicker = false
                }
            )
        }
    }

    private func cityName(for timezoneID: String) -> String {
        let components = timezoneID.split(separator: "/")
        guard let cityPart = components.last else { return timezoneID }
        return cityPart.replacingOccurrences(of: "_", with: " ")
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
// MARK: - Timezone Picker Sheet

struct TimezonePickerSheet: View {
    let title: String
    let allowLocal: Bool
    let excludeTimezones: [String]
    let onSelect: (String?) -> Void
    
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss
    
    // Common timezones for quick access
    private let commonTimezones = [
        "America/New_York",
        "America/Los_Angeles",
        "America/Chicago",
        "America/Denver",
        "America/Toronto",
        "America/Mexico_City",
        "America/Sao_Paulo",
        "Europe/London",
        "Europe/Paris",
        "Europe/Berlin",
        "Europe/Rome",
        "Europe/Madrid",
        "Europe/Moscow",
        "Asia/Tokyo",
        "Asia/Shanghai",
        "Asia/Hong_Kong",
        "Asia/Singapore",
        "Asia/Seoul",
        "Asia/Dubai",
        "Asia/Kolkata",
        "Australia/Sydney",
        "Australia/Melbourne",
        "Pacific/Auckland",
        "Africa/Johannesburg",
        "Africa/Cairo"
    ]
    
    private var allTimezones: [String] {
        TimeZone.knownTimeZoneIdentifiers
    }
    
    private var filteredTimezones: [String] {
        let available = allTimezones.filter { !excludeTimezones.contains($0) }
        
        if searchText.isEmpty {
            return available
        }
        
        let search = searchText.lowercased()
        return available.filter { tzID in
            // Search by timezone ID
            if tzID.lowercased().contains(search) {
                return true
            }
            // Search by city name
            let city = cityName(for: tzID).lowercased()
            if city.contains(search) {
                return true
            }
            return false
        }
    }
    
    private var suggestedTimezones: [String] {
        // Show common timezones that aren't excluded
        commonTimezones.filter { !excludeTimezones.contains($0) }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search city or timezone...", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button(action: {
                            searchText = ""
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)
                
                // Results list
                List {
                    // Local option (only for primary timezone)
                    if allowLocal && searchText.isEmpty {
                        Button(action: {
                            onSelect(nil)
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Local")
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text("System timezone")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    
                    // Suggested timezones (when not searching)
                    if searchText.isEmpty && !suggestedTimezones.isEmpty {
                        Section("Suggested") {
                            ForEach(suggestedTimezones, id: \.self) { tzID in
                                timezoneRow(tzID)
                            }
                        }
                    }
                    
                    // All filtered timezones
                    Section(searchText.isEmpty ? "All Timezones" : "Search Results") {
                        if filteredTimezones.isEmpty {
                            Text("No timezones found")
                                .foregroundColor(.secondary)
                                .font(.body)
                        } else {
                            ForEach(filteredTimezones, id: \.self) { tzID in
                                timezoneRow(tzID)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func timezoneRow(_ tzID: String) -> some View {
        Button(action: {
            onSelect(tzID)
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cityName(for: tzID))
                        .font(.body)
                        .foregroundColor(.primary)
                    Text(tzID)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(currentTime(for: tzID))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
    
    private func cityName(for timezoneID: String) -> String {
        let components = timezoneID.split(separator: "/")
        guard let cityPart = components.last else { return timezoneID }
        return cityPart.replacingOccurrences(of: "_", with: " ")
    }
    
    private func currentTime(for timezoneID: String) -> String {
        guard let tz = TimeZone(identifier: timezoneID) else { return "" }
        let formatter = DateFormatter()
        formatter.timeZone = tz
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }
}

