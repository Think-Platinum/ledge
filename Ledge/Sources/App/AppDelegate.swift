import AppKit
import SwiftUI
import os.log

/// AppKit delegate that manages the LedgePanel lifecycle.
///
/// The AppDelegate is responsible for:
/// 1. Creating the DisplayManager, LayoutManager, WidgetConfigStore, and ThemeManager
/// 2. Detecting the Xeneon Edge on launch
/// 3. Registering built-in widgets
/// 4. Creating and displaying the widget panel
/// 5. Managing the system tray icon and settings window
class AppDelegate: NSObject, NSApplicationDelegate {

    private let logger = Logger(subsystem: "com.ledge.app", category: "AppDelegate")

    /// The display manager — shared with the settings UI via @EnvironmentObject.
    let displayManager = DisplayManager()

    /// The layout manager — manages active layout and persistence.
    let layoutManager = LayoutManager()

    /// The widget config store — per-instance config persistence.
    let configStore = WidgetConfigStore()

    /// The theme manager — controls visual theme across dashboard and settings.
    let themeManager = ThemeManager()

    /// System tray status item.
    private var statusItem: NSStatusItem?

    /// Observers for settings window pinning.
    private var windowObservers: [Any] = []

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Skip all hardware/permission work when running under XCTest.
        // The test runner gets killed if we trigger Accessibility prompts
        // or try to create CGEventTaps.
        guard !AppEnvironment.isTesting else {
            logger.info("Ledge launched in test environment — skipping hardware init")
            return
        }

        logger.info("Ledge starting up...")

        // Register all built-in widgets
        WidgetRegistry.shared.registerBuiltInWidgets()

        // Create the system tray icon
        setupStatusItem()

        // Attempt to detect the Xeneon Edge and show the panel
        displayManager.detectXenonEdge()

        if displayManager.xeneonScreen != nil {
            // Request Accessibility permission early — before the fullscreen transition.
            // The system dialog must appear BEFORE the fullscreen helper covers the Edge,
            // otherwise it gets hidden behind the fullscreen Space.
            displayManager.ensureAccessibilityPermission { [weak self] in
                guard let self else { return }

                // Now determine which widget permissions are needed and gate on those too.
                let requiredPerms = self.requiredWidgetPermissions()

                self.displayManager.showPanelWhenReady(requiredPermissions: requiredPerms) { [weak self] in
                    guard let self else { return }

                    // Configure panel transparency for blur/image backgrounds
                    self.configurePanelTransparency()

                    // Load the macOS desktop wallpaper for the Edge as a fallback background.
                    // In fullscreen mode the desktop is hidden, so we capture the wallpaper
                    // to use when no custom background image is configured.
                    if let screen = self.displayManager.xeneonScreen {
                        self.themeManager.loadDesktopWallpaper(for: screen)
                    }

                    let dashboardView = DashboardView(
                        layoutManager: self.layoutManager,
                        configStore: self.configStore,
                        registry: WidgetRegistry.shared
                    )
                    .environmentObject(self.displayManager)
                    .environment(self.themeManager)
                    self.displayManager.setPanelContent(dashboardView)

                    // Start touch remapper — Accessibility is already granted at this point.
                    self.displayManager.startTouchRemapper()

                    self.logger.info("Panel displayed on Xeneon Edge")
                }
            }
        } else {
            logger.warning("Xeneon Edge not found on launch — panel not shown")
        }

        // Stay as .accessory permanently (hidden from Dock/CMD+TAB). The menu bar
        // icon provides access to settings. We never toggle to .regular because
        // switching back to .accessory destabilises the Edge panel and causes
        // macOS to maximize the frontmost main-display window.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
            self.observeSettingsWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Ledge shutting down")
        layoutManager.save()
        displayManager.stopTouchRemapper()
        displayManager.destroyPanel()
    }

    /// Keep the app running when all windows are closed (the panel is still active).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - System Tray

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Ledge")
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Show Settings", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())

        let panelItem = NSMenuItem(title: "Toggle Panel", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(panelItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Quit Ledge", action: #selector(quitApp), keyEquivalent: "q")

        statusItem?.menu = menu
    }

    @objc private func showSettings() {
        // Activate the app so the settings window can come to front.
        // We stay as .accessory — the window won't appear in Dock/CMD+TAB
        // but the menu bar icon provides access. This avoids all the
        // side-effects of toggling activation policy (.regular → .accessory)
        // which destabilised the Edge panel and maximised main display windows.
        NSApp.activate(ignoringOtherApps: true)

        if let window = findSettingsWindow() {
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                if let window = self?.findSettingsWindow() {
                    window.isReleasedWhenClosed = false
                    window.makeKeyAndOrderFront(nil)
                } else {
                    self?.logger.warning("Settings window not found — retrying")
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        if let window = self?.findSettingsWindow() {
                            window.isReleasedWhenClosed = false
                            window.makeKeyAndOrderFront(nil)
                        } else {
                            self?.logger.error("Settings window could not be found or created")
                        }
                    }
                }
            }
        }
    }

    /// Locate the SwiftUI-created settings window among all app windows.
    private func findSettingsWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.styleMask.contains(.titled)
            && !(window is LedgePanel)
            && !(window is FullscreenHelperWindow)
        }
    }

    // MARK: - Settings Window Observation

    /// Pin settings windows so SwiftUI doesn't release them on close.
    /// Since we stay as .accessory permanently, we no longer toggle
    /// activation policy on close — eliminating the side-effects.
    private func observeSettingsWindow() {
        // Pin any settings window that SwiftUI already created.
        for window in NSApp.windows {
            if window.styleMask.contains(.titled)
                && !(window is LedgePanel)
                && !(window is FullscreenHelperWindow) {
                window.isReleasedWhenClosed = false
                logger.debug("Existing settings window pinned on observer setup")
            }
        }

        // Pin settings windows the moment they appear so showSettings() can always find them.
        let appearObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            if window.styleMask.contains(.titled)
                && !(window is LedgePanel)
                && !(window is FullscreenHelperWindow) {
                window.isReleasedWhenClosed = false
                self?.logger.debug("Settings window pinned (isReleasedWhenClosed = false)")
            }
        }
        windowObservers.append(appearObserver)
    }

    @objc private func togglePanel() {
        if displayManager.isActive {
            displayManager.hidePanel()
        } else {
            // Ensure any stuck blanking state is cleared before reshowing —
            // otherwise the menu toggle re-orders a panel whose content is
            // still hidden and the user sees a black rectangle.
            displayManager.unblankDisplay(reason: "user toggle")
            displayManager.showPanel()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Panel Configuration

    /// Configure the panel's opacity based on the current background settings.
    /// Blur and Transparent widget styles require a non-opaque panel so the
    /// desktop wallpaper or background image shows through gaps between widgets.
    /// Solid mode keeps the panel opaque for best performance.
    private func configurePanelTransparency() {
        // Respect the theme's preferred background style (e.g. Liquid Glass → .blur)
        // before falling back to the user's manual setting.
        let effectiveStyle = themeManager.resolvedTheme.preferredBackgroundStyle
            ?? themeManager.widgetBackgroundStyle
        let needsTransparency = effectiveStyle != .solid
        displayManager.panel?.setTransparent(needsTransparency)
    }

    // MARK: - Permission Helpers

    /// Collect the set of permissions required by widgets in the active layout.
    private func requiredWidgetPermissions() -> Set<WidgetPermission> {
        var perms = Set<WidgetPermission>()
        for placement in layoutManager.activeLayout.placements {
            if let descriptor = WidgetRegistry.shared.registeredTypes[placement.widgetTypeID] {
                perms.formUnion(descriptor.requiredPermissions)
            }
        }
        return perms
    }
}
