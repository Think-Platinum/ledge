import SwiftUI

/// Defines the visual theme for all Ledge widgets and UI.
struct LedgeTheme: Equatable, Sendable {
    let name: String

    // Dashboard
    let dashboardBackground: Color

    // Widget container
    let widgetBackground: Color
    let widgetBorderColor: Color
    let widgetBorderWidth: CGFloat
    let widgetCornerRadius: CGFloat

    // Text
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color

    // Accent
    let accent: Color

    // Glass-effect properties (Liquid Glass theme)
    let glassHighlightColor: Color
    let glassHighlightWidth: CGFloat
    let glassShadowColor: Color
    let glassShadowRadius: CGFloat
    let glassInnerGlow: Bool
    /// The background style this theme looks best with (nil = no preference).
    let preferredBackgroundStyle: WidgetBackgroundStyle?

    init(
        name: String,
        dashboardBackground: Color,
        widgetBackground: Color,
        widgetBorderColor: Color,
        widgetBorderWidth: CGFloat,
        widgetCornerRadius: CGFloat,
        primaryText: Color,
        secondaryText: Color,
        tertiaryText: Color,
        accent: Color,
        glassHighlightColor: Color = .clear,
        glassHighlightWidth: CGFloat = 0,
        glassShadowColor: Color = .clear,
        glassShadowRadius: CGFloat = 0,
        glassInnerGlow: Bool = false,
        preferredBackgroundStyle: WidgetBackgroundStyle? = nil
    ) {
        self.name = name
        self.dashboardBackground = dashboardBackground
        self.widgetBackground = widgetBackground
        self.widgetBorderColor = widgetBorderColor
        self.widgetBorderWidth = widgetBorderWidth
        self.widgetCornerRadius = widgetCornerRadius
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.tertiaryText = tertiaryText
        self.accent = accent
        self.glassHighlightColor = glassHighlightColor
        self.glassHighlightWidth = glassHighlightWidth
        self.glassShadowColor = glassShadowColor
        self.glassShadowRadius = glassShadowRadius
        self.glassInnerGlow = glassInnerGlow
        self.preferredBackgroundStyle = preferredBackgroundStyle
    }
}

// MARK: - Built-in Themes

extension LedgeTheme {

    // MARK: Liquid Glass (Default)

    static let liquidGlass = LedgeTheme(
        name: "Liquid Glass",
        dashboardBackground: Color(white: 0.06),
        widgetBackground: Color.white.opacity(0.06),
        widgetBorderColor: Color.white.opacity(0.25),
        widgetBorderWidth: 0.5,
        widgetCornerRadius: 16,
        primaryText: .white,
        secondaryText: Color.white.opacity(0.65),
        tertiaryText: Color.white.opacity(0.38),
        accent: Color(red: 0.4, green: 0.7, blue: 1.0),
        // Glass-specific properties
        glassHighlightColor: Color.white.opacity(0.12),
        glassHighlightWidth: 0.5,
        glassShadowColor: Color.black.opacity(0.3),
        glassShadowRadius: 12,
        glassInnerGlow: true,
        preferredBackgroundStyle: .blur
    )

    // MARK: Classic Themes

    static let dark = LedgeTheme(
        name: "Dark",
        dashboardBackground: .black,
        widgetBackground: Color.white.opacity(0.08),
        widgetBorderColor: Color.white.opacity(0.12),
        widgetBorderWidth: 0.5,
        widgetCornerRadius: 12,
        primaryText: .white,
        secondaryText: Color.white.opacity(0.6),
        tertiaryText: Color.white.opacity(0.35),
        accent: .blue
    )

    static let light = LedgeTheme(
        name: "Light",
        dashboardBackground: Color(white: 0.92),
        widgetBackground: .white,
        widgetBorderColor: Color.black.opacity(0.08),
        widgetBorderWidth: 0.5,
        widgetCornerRadius: 12,
        primaryText: .black,
        secondaryText: Color.black.opacity(0.6),
        tertiaryText: Color.black.opacity(0.35),
        accent: .blue
    )

    static let midnight = LedgeTheme(
        name: "Midnight",
        dashboardBackground: Color(red: 0.05, green: 0.05, blue: 0.15),
        widgetBackground: Color(red: 0.1, green: 0.1, blue: 0.22).opacity(0.8),
        widgetBorderColor: Color(red: 0.3, green: 0.3, blue: 0.6).opacity(0.4),
        widgetBorderWidth: 0.5,
        widgetCornerRadius: 12,
        primaryText: Color(red: 0.95, green: 0.95, blue: 1.0),
        secondaryText: Color(red: 0.72, green: 0.72, blue: 0.92),
        tertiaryText: Color(red: 0.52, green: 0.52, blue: 0.72),
        accent: Color(red: 0.55, green: 0.55, blue: 1.0)
    )

    static let ocean = LedgeTheme(
        name: "Ocean",
        dashboardBackground: Color(red: 0.02, green: 0.08, blue: 0.12),
        widgetBackground: Color(red: 0.05, green: 0.15, blue: 0.2).opacity(0.8),
        widgetBorderColor: Color(red: 0.1, green: 0.4, blue: 0.5).opacity(0.3),
        widgetBorderWidth: 0.5,
        widgetCornerRadius: 12,
        primaryText: Color(red: 0.85, green: 0.95, blue: 1.0),
        secondaryText: Color(red: 0.5, green: 0.75, blue: 0.85),
        tertiaryText: Color(red: 0.3, green: 0.5, blue: 0.6),
        accent: Color(red: 0.2, green: 0.7, blue: 0.8)
    )

    static let forest = LedgeTheme(
        name: "Forest",
        dashboardBackground: Color(red: 0.04, green: 0.08, blue: 0.04),
        widgetBackground: Color(red: 0.08, green: 0.15, blue: 0.08).opacity(0.8),
        widgetBorderColor: Color(red: 0.2, green: 0.4, blue: 0.2).opacity(0.3),
        widgetBorderWidth: 0.5,
        widgetCornerRadius: 12,
        primaryText: Color(red: 0.9, green: 1.0, blue: 0.9),
        secondaryText: Color(red: 0.6, green: 0.8, blue: 0.6),
        tertiaryText: Color(red: 0.35, green: 0.55, blue: 0.35),
        accent: Color(red: 0.3, green: 0.8, blue: 0.4)
    )

    static let allThemes: [LedgeTheme] = [.liquidGlass, .dark, .light, .midnight, .ocean, .forest]
}

// MARK: - Theme Mode

enum ThemeMode: String, Codable, CaseIterable {
    case auto = "Auto"
    case liquidGlass = "Liquid Glass"
    case dark = "Dark"
    case light = "Light"
    case midnight = "Midnight"
    case ocean = "Ocean"
    case forest = "Forest"

    var theme: LedgeTheme {
        switch self {
        case .auto: return .liquidGlass  // resolved at runtime based on system appearance
        case .liquidGlass: return .liquidGlass
        case .dark: return .dark
        case .light: return .light
        case .midnight: return .midnight
        case .ocean: return .ocean
        case .forest: return .forest
        }
    }
}

// MARK: - Widget Background Style

/// Controls how widget backgrounds are rendered.
enum WidgetBackgroundStyle: String, Codable, CaseIterable {
    case solid = "Solid"
    case blur = "Blur"
    case transparent = "Transparent"

    var displayName: String { rawValue }
}

/// Controls what's shown behind the widget grid.
enum DashboardBackgroundMode: String, Codable, CaseIterable {
    case themeColor = "Theme Color"
    case image = "Image"

    var displayName: String { rawValue }
}

// MARK: - Theme Manager

@Observable
class ThemeManager {

    var mode: ThemeMode = .liquidGlass {
        didSet {
            guard isLoaded else { return }
            saveKey(key, value: mode.rawValue)
        }
    }

    /// The resolved theme, accounting for system appearance in auto mode.
    var resolvedTheme: LedgeTheme {
        if mode == .auto {
            return systemIsDark ? .liquidGlass : .light
        }
        return mode.theme
    }

    /// Tracks system appearance for auto mode.
    var systemIsDark: Bool = true

    // MARK: - Appearance Settings

    /// How widget backgrounds are rendered.
    var widgetBackgroundStyle: WidgetBackgroundStyle = .solid {
        didSet {
            guard isLoaded else { return }
            saveKey(bgStyleKey, value: widgetBackgroundStyle.rawValue)
        }
    }

    /// What's shown behind the widget grid.
    var dashboardBackgroundMode: DashboardBackgroundMode = .themeColor {
        didSet {
            guard isLoaded else { return }
            saveKey(bgModeKey, value: dashboardBackgroundMode.rawValue)
        }
    }

    /// Path to a custom background image (when dashboardBackgroundMode == .image).
    var backgroundImagePath: String = "" {
        didSet {
            guard isLoaded else { return }
            saveKey(bgImageKey, value: backgroundImagePath)
            loadBackgroundImage()
        }
    }

    /// The loaded background NSImage, if any.
    var backgroundImage: NSImage? = nil

    /// The macOS desktop wallpaper for the Xeneon Edge screen.
    /// Used as a fallback when the user hasn't configured a custom background image.
    /// Populated by `loadDesktopWallpaper(for:)` when the panel is shown.
    var desktopWallpaper: NSImage? = nil

    private let key = "com.ledge.themeMode"
    private let bgStyleKey = "com.ledge.widgetBackgroundStyle"
    private let bgModeKey = "com.ledge.dashboardBackgroundMode"
    private let bgImageKey = "com.ledge.backgroundImagePath"

    /// Guard against didSet firing during init (especially with @Observable)
    private var isLoaded = false

    init() {
        // Load all saved values before enabling persistence
        if let saved = UserDefaults.standard.string(forKey: key),
           let mode = ThemeMode(rawValue: saved) {
            self.mode = mode
        }
        if let saved = UserDefaults.standard.string(forKey: bgStyleKey),
           let style = WidgetBackgroundStyle(rawValue: saved) {
            self.widgetBackgroundStyle = style
        }
        if let saved = UserDefaults.standard.string(forKey: bgModeKey),
           let bgMode = DashboardBackgroundMode(rawValue: saved) {
            self.dashboardBackgroundMode = bgMode
        }
        if let saved = UserDefaults.standard.string(forKey: bgImageKey), !saved.isEmpty {
            self.backgroundImagePath = saved
        }
        detectSystemAppearance()
        loadBackgroundImage()
        // Enable persistence now that init is complete
        isLoaded = true
    }

    /// Save a single key immediately and synchronize
    private func saveKey(_ key: String, value: String) {
        UserDefaults.standard.set(value, forKey: key)
        UserDefaults.standard.synchronize()
    }

    func detectSystemAppearance() {
        guard let appearance = NSApp?.effectiveAppearance else { return }
        systemIsDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func loadBackgroundImage() {
        guard !backgroundImagePath.isEmpty else {
            backgroundImage = nil
            return
        }
        backgroundImage = NSImage(contentsOfFile: backgroundImagePath)
    }

    /// Load the macOS desktop wallpaper for a given screen.
    /// Called once when the panel is shown on the Xeneon Edge.
    func loadDesktopWallpaper(for screen: NSScreen) {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            desktopWallpaper = nil
            return
        }
        // desktopImageURL may return a folder (for rotating wallpapers) or a file
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            // Folder — try to find the first image inside
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil
            ) {
                let imageExtensions = Set(["jpg", "jpeg", "png", "heic", "tiff", "bmp"])
                if let firstImage = contents.first(where: { imageExtensions.contains($0.pathExtension.lowercased()) }) {
                    desktopWallpaper = NSImage(contentsOf: firstImage)
                    return
                }
            }
            desktopWallpaper = nil
        } else {
            desktopWallpaper = NSImage(contentsOf: url)
        }
    }
}

// MARK: - Environment Key

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = LedgeTheme.liquidGlass
}

extension EnvironmentValues {
    var theme: LedgeTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
