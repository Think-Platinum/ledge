import SwiftUI
import WebKit

/// NSViewRepresentable wrapper for WKWebView.
///
/// Suppresses JS alerts via WKUIDelegate to prevent the app from being
/// activated (which would break the non-activating panel). Popups are
/// re-homed into a non-activating panel so OAuth handshakes that rely on
/// `window.opener.postMessage` can complete without activating Ledge.
struct WebViewRepresentable: NSViewRepresentable {
    let url: URL
    var zoomLevel: Double = 1.0
    var customCSS: String?

    /// Bump to trigger `webView.reload()` from the outside without rebuilding
    /// the view (preserves cookies, sessionStorage, in-memory JS state).
    var reloadToken: Int = 0

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        // Persistent cookies + storage, shared across every widget and every
        // popup. The default data store is itself a singleton (so being
        // explicit is documentation more than wiring), but it matters that
        // *every* configuration we hand to WebKit references it — popups
        // inherit this configuration via createWebViewWith, so they end up
        // in the same WebContent process as the opener (macOS 12+ manages
        // process pooling automatically from the configuration) and the
        // window.opener.postMessage link OAuth callbacks rely on stays live.
        config.websiteDataStore = .default()
        // The default WebKit UA omits the "Version/X Safari/..." suffix —
        // some sites (incl. GitHub OAuth) apply stricter cookie rules or
        // refuse to set durable session cookies for non-Safari user agents.
        // applicationNameForUserAgent is appended to the default UA string.
        config.applicationNameForUserAgent = "Version/17.6 Safari/605.1.15"

        // Block JavaScript focus-stealing — window.focus() and similar calls
        // can activate the Ledge app and steal focus from the foreground app.
        let antiFocusScript = WKUserScript(
            source: """
            window.focus = function() {};
            window.blur = function() {};
            if (window.opener) { window.opener.focus = function() {}; }
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false  // Also inject into iframes
        )
        config.userContentController.addUserScript(antiFocusScript)

        // Inject custom CSS if provided
        if let css = customCSS, !css.isEmpty {
            let script = WKUserScript(
                source: "var style = document.createElement('style'); style.textContent = `\(css.replacingOccurrences(of: "`", with: "\\`"))`; document.head.appendChild(style);",
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(script)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.pageZoom = zoomLevel
        webView.setValue(false, forKey: "drawsBackground")

        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
        if webView.pageZoom != zoomLevel {
            webView.pageZoom = zoomLevel
        }
        if reloadToken != context.coordinator.lastReloadToken {
            context.coordinator.lastReloadToken = reloadToken
            webView.reload()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        var lastReloadToken: Int = 0

        /// Open `window.open` / `target=_blank` requests in a separate
        /// non-activating panel. Returning the new WKWebView preserves the
        /// `window.opener` link and reuses the supplied configuration (which
        /// carries our shared process pool + data store), so OAuth flows
        /// that hand a token back via `window.opener.postMessage` can
        /// complete and the resulting session cookies land in the same
        /// store the widget reads from.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                      for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let popup = WKWebView(
                frame: NSRect(x: 0, y: 0, width: 640, height: 720),
                configuration: configuration
            )
            _ = WebPopupWindowController(popup: popup, openedBy: webView)
            return popup
        }

        // Suppress JavaScript alerts
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                      initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                      initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            completionHandler(false)
        }
    }
}

/// Hosts a WKWebView popup in a non-activating panel.
///
/// Mirrors LedgePanel's focus pattern (`.nonactivatingPanel`, `canBecomeKey = true`,
/// `canBecomeMain = false`) so the popup can accept touch / mouse / keyboard
/// input on the Xeneon Edge without activating the Ledge app — preserving the
/// foundational rule that Ledge never steals focus from the user's foreground app.
///
/// Retains itself via the `active` dictionary; releases when the panel closes
/// or when `window.close()` is called from inside the popup (the typical
/// final step of an OAuth callback page).
final class WebPopupWindowController: NSObject, WKUIDelegate, NSWindowDelegate {

    /// Strong references keyed by the popup's identity. Without this the
    /// controller would be deallocated as soon as `createWebViewWith` returns,
    /// since uiDelegate is weak.
    private static var active: [ObjectIdentifier: WebPopupWindowController] = [:]

    private let panel: NSPanel
    private weak var popup: WKWebView?

    init(popup: WKWebView, openedBy opener: WKWebView) {
        self.popup = popup

        let size = NSSize(width: 640, height: 720)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Match the widget panel's behaviour: visible above standard chrome,
        // never hidden when the app loses focus, joins every Space, doesn't
        // cycle. Without `.screenSaver` it would sit behind the LedgePanel
        // (which is at `.screenSaver`) and the user could never see it.
        panel.level = .screenSaver
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = popup.url?.host ?? opener.url?.host ?? "Sign in"
        panel.isReleasedWhenClosed = false
        panel.contentView = popup

        // Centre over the opener's window (typically the Xeneon Edge panel)
        // so the popup appears where the user just tapped.
        if let openerWindow = opener.window {
            let openerFrame = openerWindow.frame
            panel.setFrameOrigin(NSPoint(
                x: openerFrame.midX - size.width / 2,
                y: openerFrame.midY - size.height / 2
            ))
        } else {
            panel.center()
        }

        self.panel = panel
        super.init()

        panel.delegate = self
        popup.uiDelegate = self
        Self.active[ObjectIdentifier(popup)] = self

        // orderFrontRegardless (not makeKeyAndOrderFront) — same reason as the
        // widget panel: avoid any path that activates the app.
        panel.orderFrontRegardless()
    }

    static func dismiss(for popup: WKWebView) {
        if let controller = Self.active.removeValue(forKey: ObjectIdentifier(popup)) {
            controller.panel.close()
        }
    }

    // MARK: - WKUIDelegate

    /// OAuth callback pages typically finish with `window.close()` — honour it.
    func webViewDidClose(_ webView: WKWebView) {
        Self.dismiss(for: webView)
    }

    /// A popup that itself opens another popup — recurse with the same pattern.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                  for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let nested = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 720),
            configuration: configuration
        )
        _ = WebPopupWindowController(popup: nested, openedBy: webView)
        return nested
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                  initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                  initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }

    // MARK: - NSWindowDelegate

    /// User closed the panel via the title-bar X — clean up the retain.
    func windowWillClose(_ notification: Notification) {
        if let popup = popup {
            Self.active.removeValue(forKey: ObjectIdentifier(popup))
        }
    }
}
