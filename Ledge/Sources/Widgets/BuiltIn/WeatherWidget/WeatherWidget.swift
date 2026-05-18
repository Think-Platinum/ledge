import SwiftUI
import Combine

/// Weather widget showing current conditions and forecast.
///
/// Uses Open-Meteo API (free, no key) for weather data.
/// Supports auto-location via CoreLocation or manual coordinates.
struct WeatherWidget {

    struct Config: Codable {
        var locationMode: LocationMode = .auto
        var latitude: Double = 40.7128  // Default: New York
        var longitude: Double = -74.0060
        var locationName: String?       // Resolved place name for manual mode (e.g. "Edinburgh, GB")
        var temperatureUnit: String = "celsius"
        var forecastDays: Int = 3

        enum LocationMode: String, Codable {
            case auto
            case manual
        }
    }

    static let descriptor = WidgetDescriptor(
        typeID: "com.ledge.weather",
        displayName: "Weather",
        description: "Current conditions and forecast",
        iconSystemName: "cloud.sun",
        minimumSize: .threeByTwo,
        defaultSize: .fourByThree,
        maximumSize: .fourByThree,
        defaultConfiguration: try? JSONEncoder().encode(Config()),
        viewFactory: { instanceID, configStore in
            AnyView(WeatherWidgetView(instanceID: instanceID, configStore: configStore))
        },
        settingsFactory: { instanceID, configStore in
            AnyView(WeatherSettingsView(instanceID: instanceID, configStore: configStore))
        },
        requiredPermissions: [.location]
    )
}

// MARK: - View

struct WeatherWidgetView: View {
    @Environment(\.theme) private var theme
    let instanceID: UUID
    let configStore: WidgetConfigStore

    @State private var config = WeatherWidget.Config()
    @State private var weather: OpenMeteoClient.WeatherData?
    @State private var locationManager = LocationManager()
    @State private var locationName: String?
    @State private var lastRefresh: Date?

    private let client = OpenMeteoClient()
    private let refreshTimer = Timer.publish(every: 900, on: .main, in: .common).autoconnect() // 15 min

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.height < 150

            if let weather {
                if isCompact {
                    compactView(weather: weather)
                } else {
                    fullView(weather: weather, width: geometry.size.width, height: geometry.size.height)
                }
            } else {
                loadingView
            }
        }
        .onAppear {
            loadConfig()
            setupLocation()
            fetchWeather()
        }
        .onReceive(refreshTimer) { _ in fetchWeather() }
        .onChange(of: locationManager.latitude) { _, _ in fetchWeather() }
        .onReceive(configStore.configDidChange) { changedID in
            if changedID == instanceID {
                loadConfig()
                setupLocation()
                fetchWeather()
            }
        }
    }

    // MARK: - Compact (1 row)

    private func compactView(weather: OpenMeteoClient.WeatherData) -> some View {
        HStack(spacing: 14) {
            Image(systemName: OpenMeteoClient.sfSymbol(for: weather.weatherCode, isDay: weather.isDay))
                .font(.system(size: 36))
                .symbolRenderingMode(.multicolor)

            VStack(alignment: .leading, spacing: 2) {
                Text(temperatureString(weather.temperature))
                    .font(.system(size: 32, weight: .light, design: .rounded))
                    .foregroundColor(theme.primaryText)
                Text(OpenMeteoClient.description(for: weather.weatherCode))
                    .font(.system(size: 15))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            if let name = locationName ?? locationManager.locationName {
                Text(name)
                    .font(.system(size: 14))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .padding(14)
    }

    // MARK: - Full (2+ rows)

    private func fullView(weather: OpenMeteoClient.WeatherData, width: CGFloat, height: CGFloat = 300) -> some View {
        VStack(spacing: 10) {
            // Tight top spacing at 2-row height, flexible at larger sizes
            if height <= 250 {
                Spacer().frame(height: 4)
            } else {
                Spacer()
            }

            // Current conditions + details
            HStack(spacing: 16) {
                Image(systemName: OpenMeteoClient.sfSymbol(for: weather.weatherCode, isDay: weather.isDay))
                    .font(.system(size: 52))
                    .symbolRenderingMode(.multicolor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(temperatureString(weather.temperature))
                        .font(.system(size: 48, weight: .light, design: .rounded))
                        .foregroundColor(theme.primaryText)

                    Text(OpenMeteoClient.description(for: weather.weatherCode))
                        .font(.system(size: 18))
                        .foregroundColor(theme.secondaryText)

                    if let name = locationName ?? locationManager.locationName {
                        Text(name)
                            .font(.system(size: 14))
                            .foregroundColor(theme.tertiaryText)
                    }
                }

                Spacer()

                // Details stacked vertically on the right
                VStack(alignment: .trailing, spacing: 8) {
                    detailItem(icon: "thermometer", label: "Feels", value: temperatureString(weather.apparentTemperature))
                    detailItem(icon: "humidity", label: "Humidity", value: "\(weather.humidity)%")
                    detailItem(icon: "wind", label: "Wind", value: String(format: "%.0f km/h", weather.windSpeed))
                }
            }
            .padding(.horizontal, 16)

            // Forecast — show as many days as width allows (min 50pt per day)
            if !weather.dailyForecast.isEmpty {
                Divider().background(theme.primaryText.opacity(0.1))
                    .padding(.horizontal, 16)

                let rawMaxDays = max(1, Int(width / 50))
                let maxDays = width < 400 ? min(rawMaxDays, 5) : rawMaxDays
                let daysToShow = min(weather.dailyForecast.count, maxDays)

                HStack(spacing: 0) {
                    ForEach(Array(weather.dailyForecast.prefix(daysToShow))) { day in
                        VStack(spacing: 5) {
                            Text(dayAbbrev(day.date))
                                .font(.system(size: 13))
                                .foregroundColor(theme.tertiaryText)
                            Image(systemName: OpenMeteoClient.sfSymbol(for: day.weatherCode, isDay: true))
                                .font(.system(size: 20))
                                .symbolRenderingMode(.multicolor)
                            Text(temperatureString(day.tempMax))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(theme.primaryText.opacity(0.85))
                            Text(temperatureString(day.tempMin))
                                .font(.system(size: 13))
                                .foregroundColor(theme.tertiaryText)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 12)
            }

            Spacer()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading weather...")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func detailItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(theme.tertiaryText)
            Text(value)
                .font(.system(size: 15))
                .foregroundColor(theme.secondaryText)
        }
    }

    private func temperatureString(_ temp: Double) -> String {
        let unit = config.temperatureUnit == "fahrenheit" ? "F" : "C"
        return String(format: "%.0f°%@", temp, unit)
    }

    private func dayAbbrev(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    private func setupLocation() {
        if config.locationMode == .auto {
            locationManager.requestLocation()
        }
    }

    private func fetchWeather() {
        let lat: Double
        let lon: Double

        if config.locationMode == .auto,
           let locLat = locationManager.latitude,
           let locLon = locationManager.longitude {
            lat = locLat
            lon = locLon
            locationName = locationManager.locationName
        } else {
            lat = config.latitude
            lon = config.longitude
            locationName = config.locationName
        }

        Task {
            if let data = await client.fetchWeather(
                latitude: lat,
                longitude: lon,
                temperatureUnit: config.temperatureUnit
            ) {
                weather = data
                lastRefresh = Date()
            }
        }
    }

    private func loadConfig() {
        if let saved: WeatherWidget.Config = configStore.read(instanceID: instanceID, as: WeatherWidget.Config.self) {
            config = saved
        }
    }
}

// MARK: - Settings

struct WeatherSettingsView: View {
    let instanceID: UUID
    let configStore: WidgetConfigStore

    @State private var config = WeatherWidget.Config()
    @State private var searchQuery: String = ""
    @State private var searchResults: [OpenMeteoGeocodingClient.Place] = []
    @State private var isSearching: Bool = false
    @State private var searchTask: Task<Void, Never>?

    private let geocoder = OpenMeteoGeocodingClient()

    var body: some View {
        Form {
            Picker("Location", selection: $config.locationMode) {
                Text("Auto-detect").tag(WeatherWidget.Config.LocationMode.auto)
                Text("Manual").tag(WeatherWidget.Config.LocationMode.manual)
            }

            if config.locationMode == .manual {
                manualLocationSection
            }

            Picker("Temperature", selection: $config.temperatureUnit) {
                Text("Celsius").tag("celsius")
                Text("Fahrenheit").tag("fahrenheit")
            }

            Stepper("Forecast days: \(config.forecastDays)", value: $config.forecastDays, in: 1...5)
        }
        .onAppear { loadConfig() }
        .onChange(of: config.locationMode) { _, _ in saveConfig() }
        .onChange(of: config.temperatureUnit) { _, _ in saveConfig() }
        .onChange(of: config.forecastDays) { _, _ in saveConfig() }
    }

    @ViewBuilder
    private var manualLocationSection: some View {
        if let name = config.locationName {
            HStack {
                Image(systemName: "mappin.circle.fill")
                    .foregroundColor(.accentColor)
                Text(name)
                    .font(.system(size: 13))
                Spacer()
                Button("Change") { config.locationName = nil }
                    .buttonStyle(.borderless)
            }
        } else {
            TextField("Search city (e.g. Edinburgh)", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .onChange(of: searchQuery) { _, newValue in
                    scheduleSearch(query: newValue)
                }

            if isSearching {
                HStack {
                    ProgressView().scaleEffect(0.6)
                    Text("Searching…").font(.system(size: 12)).foregroundColor(.secondary)
                }
            } else if !searchResults.isEmpty {
                ForEach(searchResults) { place in
                    Button(action: { select(place: place) }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name).font(.system(size: 13, weight: .medium))
                                Text([place.admin1, place.country].compactMap { $0 }.joined(separator: ", "))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else if searchQuery.trimmingCharacters(in: .whitespaces).count >= 2 {
                Text("No matches")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func scheduleSearch(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            if Task.isCancelled { return }
            let results = await geocoder.search(query: trimmed)
            if Task.isCancelled { return }
            await MainActor.run {
                searchResults = results
                isSearching = false
            }
        }
    }

    private func select(place: OpenMeteoGeocodingClient.Place) {
        config.latitude = place.latitude
        config.longitude = place.longitude
        config.locationName = place.shortLabel
        searchQuery = ""
        searchResults = []
        saveConfig()
    }

    private func loadConfig() {
        if let saved: WeatherWidget.Config = configStore.read(instanceID: instanceID, as: WeatherWidget.Config.self) {
            config = saved
        }
    }

    private func saveConfig() {
        configStore.write(instanceID: instanceID, value: config)
    }
}
