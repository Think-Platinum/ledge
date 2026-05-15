import SwiftUI

/// Web widget that embeds a webpage via WKWebView.
///
/// Useful for dashboards, status pages, or any web content.
/// Suppresses alerts/popups to maintain non-activating panel behavior.
struct WebWidget {

    struct Config: Codable {
        var urlString: String = "https://example.com"
        var autoRefreshMinutes: Int = 0  // 0 = disabled
        var zoomLevel: Double = 1.0
        var customCSS: String = ""
    }

    static let descriptor = WidgetDescriptor(
        typeID: "com.ledge.web",
        displayName: "Web",
        description: "Embed any webpage",
        iconSystemName: "globe",
        minimumSize: .fourByThree,
        defaultSize: .sixByFour,
        maximumSize: .twentyBySix,
        defaultConfiguration: try? JSONEncoder().encode(Config()),
        viewFactory: { instanceID, configStore in
            AnyView(WebWidgetView(instanceID: instanceID, configStore: configStore))
        },
        settingsFactory: { instanceID, configStore in
            AnyView(WebSettingsView(instanceID: instanceID, configStore: configStore))
        }
    )
}

// MARK: - View

struct WebWidgetView: View {
    @Environment(\.theme) private var theme
    let instanceID: UUID
    let configStore: WidgetConfigStore

    @State private var config = WebWidget.Config()
    /// Bumped when the user script set has to change (custom CSS edit) —
    /// forces a full WKWebView rebuild. Keep rare: a rebuild loses the
    /// page's sessionStorage and any in-memory JS state, which can knock
    /// the user back out of half-finished auth flows.
    @State private var refreshID = UUID()
    /// Bumped on the auto-refresh timer to reload the current page without
    /// tearing down the WKWebView. Cookies, sessionStorage, and the
    /// underlying WebContent process are preserved.
    @State private var reloadToken = 0

    var body: some View {
        Group {
            if let url = URL(string: config.urlString) {
                WebViewRepresentable(
                    url: url,
                    zoomLevel: config.zoomLevel,
                    customCSS: config.customCSS.isEmpty ? nil : config.customCSS,
                    reloadToken: reloadToken
                )
                .id(refreshID)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 28))
                        .foregroundColor(theme.tertiaryText)
                    Text("Invalid URL")
                        .font(.system(size: 13))
                        .foregroundColor(theme.tertiaryText)
                    Text(config.urlString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { loadConfig() }
        .onReceive(configStore.configDidChange) { changedID in
            if changedID == instanceID {
                // URL and zoom changes flow through updateNSView without
                // tearing down the WKWebView — that's what keeps cookies
                // and in-memory session state intact. Only CSS edits
                // require a rebuild, because custom CSS is delivered as a
                // user script that can only be added at view-creation time.
                let previousCSS = config.customCSS
                loadConfig()
                if config.customCSS != previousCSS {
                    refreshID = UUID()
                }
            }
        }
        .onReceive(autoRefreshTimer) { _ in
            if config.autoRefreshMinutes > 0 {
                reloadToken += 1
            }
        }
    }

    private var autoRefreshTimer: Timer.TimerPublisher {
        let interval = config.autoRefreshMinutes > 0 ? TimeInterval(config.autoRefreshMinutes * 60) : 3600
        return Timer.publish(every: interval, on: .main, in: .common)
    }

    private func loadConfig() {
        if let saved: WebWidget.Config = configStore.read(instanceID: instanceID, as: WebWidget.Config.self) {
            config = saved
        }
    }
}

// MARK: - Settings

struct WebSettingsView: View {
    let instanceID: UUID
    let configStore: WidgetConfigStore

    @State private var config = WebWidget.Config()

    var body: some View {
        Form {
            TextField("URL", text: $config.urlString)
                .textFieldStyle(.roundedBorder)

            Stepper("Auto-refresh: \(config.autoRefreshMinutes == 0 ? "Off" : "\(config.autoRefreshMinutes) min")",
                    value: $config.autoRefreshMinutes, in: 0...60)

            HStack {
                Text("Zoom: \(String(format: "%.0f%%", config.zoomLevel * 100))")
                Slider(value: $config.zoomLevel, in: 0.5...2.0, step: 0.1)
            }

            TextField("Custom CSS", text: $config.customCSS, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...5)
        }
        .onAppear { loadConfig() }
        .onChange(of: config.urlString) { _, _ in saveConfig() }
        .onChange(of: config.autoRefreshMinutes) { _, _ in saveConfig() }
        .onChange(of: config.zoomLevel) { _, _ in saveConfig() }
        .onChange(of: config.customCSS) { _, _ in saveConfig() }
    }

    private func loadConfig() {
        if let saved: WebWidget.Config = configStore.read(instanceID: instanceID, as: WebWidget.Config.self) {
            config = saved
        }
    }

    private func saveConfig() {
        configStore.write(instanceID: instanceID, value: config)
    }
}
