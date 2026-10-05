import AppKit
import Combine
import Foundation
import WebKit

enum BrowseEvent {
    case ready(version: String)
    case urlChanged(tab: String, url: String)
    case titleChanged(tab: String, title: String)
    case loadStatus(tab: String, status: String)
    case history(tab: String, canGoBack: Bool, canGoForward: Bool)
    case statusText(tab: String, text: String?)
    case audio(tab: String, playing: Bool)
    case zoom(tab: String, level: Double)
    case adoptedTab(opener: String?, tab: UUID, url: String, activate: Bool)
    case closeRequested(tab: String)
    case crashed(tab: String)
    case error(String)
}

/// Page surface: sanitized HTML from the sidecar, Playwright/Chromium when that is not enough.
@MainActor
final class BrowseSession: NSObject {
    let events = PassthroughSubject<BrowseEvent, Never>()
    let host = EngineHostView()
    var client: SearchClient?

    private(set) var isRunning = false
    private var views: [UUID: PageView] = [:]
    private var activeID: UUID?

    func start() throws {
        if isRunning { return }
        isRunning = true
        events.send(.ready(version: "HTML reader · Chromium fallback"))
    }

    func stopAndWait() {
        for view in views.values { view.stopLoading() }
        views.removeAll()
        host.show(nil)
    }

    func clearSiteData(completion: @escaping () -> Void) {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast, completionHandler: completion)
    }

    func open(tab: UUID, url: String) {
        let view = makeView(for: tab)
        Task { await load(tab: tab, view: view, url: url) }
    }

    func close(tab: UUID) {
        guard let view = views.removeValue(forKey: tab) else { return }
        if activeID == tab {
            activeID = nil
            host.show(nil)
        }
        view.stopLoading()
        view.removeFromSuperview()
    }

    func activate(tab: UUID?) {
        activeID = tab
        host.show(tab.flatMap { views[$0] })
    }

    func navigate(tab: UUID, url: String) {
        if let view = views[tab] {
            Task { await load(tab: tab, view: view, url: url) }
        } else {
            open(tab: tab, url: url)
        }
    }

    func goBack(tab: UUID) { views[tab]?.goBack() }
    func goForward(tab: UUID) { views[tab]?.goForward() }
    func reload(tab: UUID) {
        guard let view = views[tab] else { return }
        if let current = view.url?.absoluteString, !current.isEmpty, !current.hasPrefix("about:") {
            Task { await load(tab: tab, view: view, url: current) }
        } else {
            view.reload()
        }
    }

    func zoom(_ factor: Double) {
        guard let activeID, let view = views[activeID] else { return }
        view.pageZoom = CGFloat(factor)
        events.send(.zoom(tab: activeID.uuidString, level: factor))
    }

    func focus() {
        guard let activeID, let view = views[activeID] else { return }
        view.window?.makeFirstResponder(view)
    }

    func blur() {
        guard let activeID, let view = views[activeID], view.window?.firstResponder === view else { return }
        view.window?.makeFirstResponder(nil)
    }

    @discardableResult
    private func makeView(for tab: UUID) -> PageView {
        if let existing = views[tab] { return existing }
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .default()
        let view = PageView(frame: .zero, configuration: config)
        view.tabID = tab
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        views[tab] = view
        if tab == activeID { host.show(view) }
        return view
    }

    private func load(tab: UUID, view: PageView, url: String) async {
        let key = tab.uuidString
        events.send(.loadStatus(tab: key, status: "Loading"))
        events.send(.urlChanged(tab: key, url: url))
        guard let client else {
            events.send(.error("Search sidecar is not attached"))
            events.send(.loadStatus(tab: key, status: "Complete"))
            return
        }
        var healthy = false
        for _ in 0..<120 {
            if (try? await client.health()) == true {
                healthy = true
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard healthy else {
            events.send(.error("Search sidecar is not ready"))
            events.send(.loadStatus(tab: key, status: "Complete"))
            return
        }
        do {
            let page = try await client.browse(url: url)
            if page.mode == "reader", !page.html.isEmpty {
                view.loadHTMLString(page.html, baseURL: URL(string: page.url))
            } else if let embed = page.embed_url, let embedURL = URL(string: embed) {
                view.load(URLRequest(url: embedURL))
            } else if page.mode == "live", let live = URL(string: page.url) {
                view.load(URLRequest(url: live))
            } else {
                let message = page.error ?? "Could not open this page."
                view.loadHTMLString("<p style='font:15px sans-serif;padding:24px'>\(message)</p>", baseURL: nil)
            }
            if !page.title.isEmpty {
                events.send(.titleChanged(tab: key, title: page.title))
            }
        } catch {
            events.send(.error(error.localizedDescription))
            view.loadHTMLString(
                "<p style='font:15px sans-serif;padding:24px'>Could not open this page: \(error.localizedDescription)</p>",
                baseURL: nil
            )
            events.send(.loadStatus(tab: key, status: "Complete"))
        }
    }

    private func key(for view: WKWebView) -> String? {
        (view as? PageView)?.tabID?.uuidString
    }
}

extension BrowseSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = key(for: webView) else { return }
        events.send(.loadStatus(tab: tab, status: "Complete"))
        events.send(.history(tab: tab, canGoBack: webView.canGoBack, canGoForward: webView.canGoForward))
        if let title = webView.title, !title.isEmpty {
            events.send(.titleChanged(tab: tab, title: title))
        }
        if let url = webView.url?.absoluteString, !url.hasPrefix("about:") {
            events.send(.urlChanged(tab: tab, url: url))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let tab = key(for: webView) else { return }
        events.send(.loadStatus(tab: tab, status: "Complete"))
        events.send(.error(error.localizedDescription))
    }
}

extension BrowseSession: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url?.absoluteString {
            let id = UUID()
            events.send(.adoptedTab(opener: key(for: webView), tab: id, url: url, activate: true))
        }
        return nil
    }
}

final class PageView: WKWebView {
    var tabID: UUID?
}

final class EngineHostView: NSView {
    private weak var current: WKWebView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func show(_ view: WKWebView?) {
        guard view !== current else { return }
        let hadFocus = current.map { window?.firstResponder === $0 } ?? false
        current?.removeFromSuperview()
        current = view
        guard let view else { return }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        if hadFocus { window?.makeFirstResponder(view) }
    }
}
