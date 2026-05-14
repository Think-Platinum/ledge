import SwiftUI
import os.log

/// Home Assistant widget for controlling smart home entities.
///
/// Supports lights (toggle + brightness), switches (toggle),
/// and sensors (display value). Uses REST API with long-lived access token.
struct HomeAssistantWidget {

    struct Config: Codable {
        var serverURL: String = ""
        var accessToken: String = ""
        var entries: [EntityEntry] = []
        var pollingInterval: Int = 5  // seconds

        /// Bare entity IDs in widget order. Consumed by `HomeAssistantClient.fetchStates`.
        var entityIDs: [String] { entries.map(\.id) }

        struct EntityEntry: Codable, Identifiable, Hashable {
            let id: String
            var displayName: String?
        }

        private enum CodingKeys: String, CodingKey {
            case serverURL, accessToken, entries, entityIDs, pollingInterval
        }

        init() {}

        // Legacy on-disk shape used `entityIDs: [String]`; migrate it to `entries`
        // with no overrides on first decode. Future writes always emit `entries`.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? ""
            accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
            pollingInterval = try c.decodeIfPresent(Int.self, forKey: .pollingInterval) ?? 5

            if let newEntries = try c.decodeIfPresent([EntityEntry].self, forKey: .entries) {
                entries = newEntries
            } else if let legacyIDs = try c.decodeIfPresent([String].self, forKey: .entityIDs) {
                entries = legacyIDs.map { EntityEntry(id: $0, displayName: nil) }
            } else {
                entries = []
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(serverURL, forKey: .serverURL)
            try c.encode(accessToken, forKey: .accessToken)
            try c.encode(entries, forKey: .entries)
            try c.encode(pollingInterval, forKey: .pollingInterval)
        }
    }

    static let descriptor = WidgetDescriptor(
        typeID: "com.ledge.homeassistant",
        displayName: "Home Assistant",
        description: "Control smart home entities",
        iconSystemName: "house",
        minimumSize: .fourByTwo,
        defaultSize: .sixByThree,
        maximumSize: .tenByFour,
        defaultConfiguration: try? JSONEncoder().encode(Config()),
        viewFactory: { instanceID, configStore in
            AnyView(HomeAssistantWidgetView(instanceID: instanceID, configStore: configStore))
        },
        settingsFactory: { instanceID, configStore in
            AnyView(HomeAssistantSettingsView(instanceID: instanceID, configStore: configStore))
        }
    )
}

// MARK: - View

struct HomeAssistantWidgetView: View {
    @Environment(\.theme) private var theme
    let instanceID: UUID
    let configStore: WidgetConfigStore

    private let logger = Logger(subsystem: "com.ledge.app", category: "HomeAssistantWidget")
    private let debugLog = DebugLogger(category: "HomeAssistantWidget")

    @State private var config = HomeAssistantWidget.Config()
    @State private var client = HomeAssistantClient()
    @State private var entities: [HomeAssistantClient.EntityState] = []
    @State private var pollingTask: Task<Void, Never>?
    @State private var errorMessage: String?
    /// Track configured state from the config struct (not the class) so SwiftUI detects changes.
    @State private var isConfigured = false

    var body: some View {
        Group {
            if !isConfigured {
                notConfiguredView
            } else if !entities.isEmpty {
                entityGrid
            } else if let errorMessage {
                errorView(errorMessage)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading entities...")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: entities.map(\.state))
        .onAppear {
            loadConfig()
            restartPolling()
        }
        .onReceive(configStore.configDidChange) { changedID in
            if changedID == instanceID {
                loadConfig()
                restartPolling()
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(.orange)
            Text("Connection Error")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.primaryText)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }

    private var notConfiguredView: some View {
        VStack(spacing: 8) {
            Image(systemName: "house")
                .font(.system(size: 28))
                .foregroundColor(theme.tertiaryText)
            Text("Not Configured")
                .font(.system(size: 14))
                .foregroundColor(theme.tertiaryText)
            Text("Set up in Settings → Widgets")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var entityGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
                ForEach(entities) { entity in
                    entityCard(entity)
                }
            }
            .padding(12)
        }
    }

    private func entityCard(_ entity: HomeAssistantClient.EntityState) -> some View {
        let isOn = entity.state == "on"
        let isToggleable = ["light", "switch", "fan", "input_boolean"].contains(entity.domain)

        return VStack(spacing: 6) {
            Image(systemName: iconForEntity(entity))
                .font(.system(size: 20))
                .foregroundColor(colorForEntity(entity))
                .contentTransition(.symbolEffect(.replace))

            Text(displayName(for: entity))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.primaryText.opacity(0.85))
                .lineLimit(1)

            if entity.domain == "sensor" || entity.domain == "binary_sensor" {
                Text("\(entity.state)\(entity.unitOfMeasurement.map { " \($0)" } ?? "")")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
            } else if entity.domain == "climate" {
                Text(entity.state.capitalized)
                    .font(.system(size: 11))
                    .foregroundColor(entity.state == "heat" ? .orange : theme.tertiaryText)
            } else if entity.domain == "cover" {
                Text(entity.state.capitalized)
                    .font(.system(size: 11))
                    .foregroundColor(entity.state == "open" ? theme.accent : theme.tertiaryText)
            } else {
                Text(entity.state.capitalized)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 70)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isOn ? Color.yellow.opacity(0.1) : theme.primaryText.opacity(0.03))
                .animation(.easeInOut(duration: 0.4), value: isOn)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            guard isToggleable else { return }
            Task { await client.toggle(entityID: entity.id) }
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                await fetchEntities()
            }
        }
    }

    /// User-supplied display-name override for an entity, falling back to HA's `friendly_name`.
    private func displayName(for entity: HomeAssistantClient.EntityState) -> String {
        if let override = config.entries.first(where: { $0.id == entity.id })?.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        return entity.friendlyName
    }

    private func iconForEntity(_ entity: HomeAssistantClient.EntityState) -> String {
        switch entity.domain {
        case "light": return entity.state == "on" ? "lightbulb.fill" : "lightbulb"
        case "switch": return entity.state == "on" ? "power.circle.fill" : "power.circle"
        case "fan": return entity.state == "on" ? "fan.fill" : "fan"
        case "input_boolean": return entity.state == "on" ? "checkmark.circle.fill" : "circle"
        case "cover":
            if entity.state == "open" { return "blinds.vertical.open" }
            if entity.state == "closed" { return "blinds.vertical.closed" }
            return "blinds.vertical.open"
        case "climate":
            if entity.state == "heat" { return "flame.fill" }
            if entity.state == "cool" { return "snowflake" }
            if entity.state == "auto" { return "thermometer.sun.fill" }
            return "thermometer.medium"
        case "sensor", "binary_sensor":
            if entity.unitOfMeasurement == "°C" || entity.unitOfMeasurement == "°F" { return "thermometer" }
            if entity.unitOfMeasurement == "%" { return "humidity" }
            if entity.unitOfMeasurement == "W" || entity.unitOfMeasurement == "kW" { return "bolt" }
            if entity.unitOfMeasurement == "lx" { return "sun.max" }
            return "gauge"
        case "lock": return entity.state == "locked" ? "lock.fill" : "lock.open"
        default: return "square.fill"
        }
    }

    private func colorForEntity(_ entity: HomeAssistantClient.EntityState) -> Color {
        switch entity.domain {
        case "light": return entity.state == "on" ? .yellow : theme.tertiaryText
        case "switch", "fan", "input_boolean": return entity.state == "on" ? .green : theme.tertiaryText
        case "cover": return entity.state == "open" ? theme.accent : theme.tertiaryText
        case "climate":
            if entity.state == "heat" { return .orange }
            if entity.state == "cool" { return .blue }
            return theme.tertiaryText
        case "lock": return entity.state == "locked" ? .green : .orange
        default: return theme.tertiaryText
        }
    }

    // MARK: - Data

    private func restartPolling() {
        pollingTask?.cancel()
        errorMessage = nil
        pollingTask = Task {
            while !Task.isCancelled {
                await fetchEntities()
                try? await Task.sleep(for: .seconds(config.pollingInterval))
            }
        }
    }

    private func fetchEntities() async {
        let result = await client.fetchStates(entityIDs: config.entityIDs)
        await MainActor.run {
            entities = result.entities
            if !result.errors.isEmpty {
                // Show the first unique error — deduplicate repeated messages
                let uniqueErrors = Array(Set(result.errors))
                errorMessage = uniqueErrors.joined(separator: "\n")
            } else if result.entities.isEmpty && client.isConfigured && !config.entityIDs.isEmpty {
                errorMessage = "No entities returned from \(config.serverURL)"
            } else {
                errorMessage = nil
            }
        }
    }

    private func loadConfig() {
        if let saved: HomeAssistantWidget.Config = configStore.read(instanceID: instanceID, as: HomeAssistantWidget.Config.self) {
            config = saved
            client.serverURL = config.serverURL
            client.accessToken = config.accessToken
            isConfigured = client.isConfigured
            debugLog.debug("Loaded config: serverURL='\(config.serverURL)', entities=\(config.entityIDs), isConfigured=\(isConfigured)")
        } else {
            isConfigured = false
            debugLog.debug("No saved config for instance \(instanceID.uuidString)")
        }
    }
}

// MARK: - Settings

struct HomeAssistantSettingsView: View {
    let instanceID: UUID
    let configStore: WidgetConfigStore

    @State private var config = HomeAssistantWidget.Config()
    @State private var newEntityID: String = ""
    @State private var entityIDError: String?

    // Entity picker state
    @State private var availableEntities: [HomeAssistantClient.EntityState] = []
    @State private var isLoadingEntities = false
    @State private var entityFetchError: String?
    @State private var searchText: String = ""
    @State private var selectedDomainFilter: String? = nil

    /// Entities available to add (not already in config), filtered by search and domain.
    private var filteredEntities: [HomeAssistantClient.EntityState] {
        let existing = Set(config.entityIDs)
        var filtered = availableEntities.filter { !existing.contains($0.id) }
        if let domain = selectedDomainFilter {
            filtered = filtered.filter { $0.domain == domain }
        }
        if !searchText.isEmpty {
            filtered = filtered.filter {
                $0.id.localizedCaseInsensitiveContains(searchText) ||
                $0.friendlyName.localizedCaseInsensitiveContains(searchText)
            }
        }
        return filtered
    }

    /// All unique domains from available entities.
    private var availableDomains: [String] {
        Array(Set(availableEntities.map(\.domain))).sorted()
    }

    /// Whether the server URL and token are filled in.
    private var hasCredentials: Bool {
        !config.serverURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !config.accessToken.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether the current manual entity ID input looks valid (domain.name format).
    private var isValidEntityID: Bool {
        let trimmed = newEntityID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let parts = trimmed.split(separator: ".")
        return parts.count >= 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server URL", text: $config.serverURL)
                    .textFieldStyle(.roundedBorder)
                    .help("e.g., http://homeassistant.local:8123")

                SecureField("Access Token", text: $config.accessToken)
                    .textFieldStyle(.roundedBorder)
                    .help("Long-lived access token from your HA profile")
            }

            Section("Entities") {
                // Currently added entities — each row exposes a display-name override.
                ForEach($config.entries, id: \.id) { $entry in
                    let entity = availableEntities.first { $0.id == entry.id }
                    let placeholder = entity?.friendlyName ?? entry.id
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            TextField(
                                placeholder,
                                text: Binding(
                                    get: { entry.displayName ?? "" },
                                    set: { newValue in
                                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                        entry.displayName = trimmed.isEmpty ? nil : newValue
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .help("Custom display name. Leave blank to use the HA friendly name.")
                            Text(entry.id)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            config.entries.removeAll { $0.id == entry.id }
                            saveConfig()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Entity picker (when entities are loaded from server)
                if !availableEntities.isEmpty {
                    Divider()

                    // Domain filter + search
                    HStack(spacing: 8) {
                        Picker("Domain", selection: $selectedDomainFilter) {
                            Text("All").tag(nil as String?)
                            ForEach(availableDomains, id: \.self) { domain in
                                Text(domain).tag(domain as String?)
                            }
                        }
                        .frame(width: 120)

                        TextField("Search entities...", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Scrollable entity list
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredEntities) { entity in
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entity.friendlyName)
                                            .font(.system(size: 12))
                                        Text(entity.id)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(entity.state)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Button {
                                        config.entries.append(.init(id: entity.id, displayName: nil))
                                        saveConfig()
                                    } label: {
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundColor(.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 3)
                                .padding(.horizontal, 6)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }

                // Fetch / refresh button
                if hasCredentials {
                    HStack {
                        Button(isLoadingEntities ? "Loading..." : (availableEntities.isEmpty ? "Fetch Entities" : "Refresh")) {
                            Task { await fetchAvailableEntities() }
                        }
                        .disabled(isLoadingEntities)

                        if let entityFetchError {
                            Text(entityFetchError)
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                        }

                        Spacer()

                        Text("\(availableEntities.count) entities")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                // Manual fallback entry
                DisclosureGroup("Add manually") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Entity ID (e.g., light.bedroom)", text: $newEntityID)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: newEntityID) { _, _ in entityIDError = nil }
                            Button("Add") {
                                let trimmed = newEntityID.trimmingCharacters(in: .whitespaces)
                                guard !trimmed.isEmpty else { return }
                                guard isValidEntityID else {
                                    entityIDError = "Must include domain (e.g., light.bedroom)"
                                    return
                                }
                                config.entries.append(.init(id: trimmed, displayName: nil))
                                newEntityID = ""
                                entityIDError = nil
                                saveConfig()
                            }
                        }
                        if let entityIDError {
                            Text(entityIDError)
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                        }
                    }
                }
            }

            Section("Polling") {
                Stepper("Interval: \(config.pollingInterval)s", value: $config.pollingInterval, in: 1...60)
            }
        }
        .onAppear { loadConfig() }
        .onChange(of: config.serverURL) { _, _ in saveConfig() }
        .onChange(of: config.accessToken) { _, _ in saveConfig() }
        .onChange(of: config.pollingInterval) { _, _ in saveConfig() }
        .onChange(of: config.entries) { _, _ in saveConfig() }
    }

    private func loadConfig() {
        if let saved: HomeAssistantWidget.Config = configStore.read(instanceID: instanceID, as: HomeAssistantWidget.Config.self) {
            config = saved
        }
        // Auto-fetch entities if we have credentials
        if hasCredentials && availableEntities.isEmpty {
            Task { await fetchAvailableEntities() }
        }
    }

    private func saveConfig() {
        configStore.write(instanceID: instanceID, value: config)
    }

    private func fetchAvailableEntities() async {
        isLoadingEntities = true
        entityFetchError = nil

        let client = HomeAssistantClient()
        var url = config.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty && !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "http://\(url)"
        }
        client.serverURL = url
        client.accessToken = config.accessToken

        let entities = await client.fetchAllStates()
        await MainActor.run {
            isLoadingEntities = false
            if entities.isEmpty {
                entityFetchError = "No entities returned — check URL and token"
            } else {
                availableEntities = entities.sorted { $0.friendlyName < $1.friendlyName }
            }
        }
    }
}
