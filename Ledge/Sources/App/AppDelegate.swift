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

    /// Observer for settings window visibility changes.
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

        // Start as .accessory (hidden from Dock/CMD+TAB) then observe window changes.
        // IMPORTANT: Do NOT call NSApp.activate() here — it steals focus from the
        // foreground app. The panel uses .nonactivatingPanel precisely to avoid this.
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
        // Show in Dock and CMD+TAB while settings is open
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = findSettingsWindow() {
            // Prevent SwiftUI from releasing the window when it's closed —
            // otherwise it won't be in NSApp.windows next time we look.
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
        } else {
            // Window may not exist yet (SwiftUI released it after close, or
            // activation hasn't finished). Retry after a short delay to give
            // the SwiftUI Window scene time to create/register it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                if let window = self?.findSettingsWindow() {
                    window.isReleasedWhenClosed = false
                    window.makeKeyAndOrderFront(nil)
                } else {
                    self?.logger.warning("Settings window not found — attempting scene open")
                    // As a last resort, toggle activation to nudge SwiftUI into
                    // re-creating the Window scene, then try once more.
                    NSApp.setActivationPolicy(.regular)
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

    /// Watch for the settings window being closed so we can hide from CMD+TAB.
    private func observeSettingsWindow() {
        // Pin the settings window the moment it appears so SwiftUI won't
        // release it when closed — this ensures showSettings() can always find it.
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

        // Observe any window closing — check if it was the settings window
        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  window.styleMask.contains(.titled),
                  !(window is LedgePanel),
                  !(window is FullscreenHelperWindow) else { return }
            self?.logger.info("Settings window closed — hiding from CMD+TAB")
            // Delay slightly to let the window fully close
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.updateActivationPolicy()
            }
        }
        windowObservers.append(closeObserver)

        // Also observe window ordering out (minimize, etc.)
        let orderOutObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMiniaturizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  window.styleMask.contains(.titled),
                  !(window is LedgePanel),
                  !(window is FullscreenHelperWindow) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.updateActivationPolicy()
            }
        }
        windowObservers.append(orderOutObserver)
    }

    /// Check if any settings windows are visible and update the activation policy accordingly.
    private func updateActivationPolicy() {
        let hasVisibleSettingsWindow = NSApp.windows.contains { window in
            window.styleMask.contains(.titled)
            && !(window is LedgePanel)
            && !(window is FullscreenHelperWindow)
            && window.isVisible
            && !window.isMiniaturized
        }

        if hasVisibleSettingsWindow {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func togglePanel() {
        if displayManager.isActive {
            displayManager.hidePanel()
        } else {
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
