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
    /// In-page link or JS navigation. `reload` means load through `/api/browse`.
    case userNavigate(tab: String, url: String, reload: Bool)
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
    private var sidecarLoading: Set<UUID> = []
    private var lastHandledURL: [UUID: String] = [:]

    func start() throws {
        if isRunning { return }
        isRunning = true
        events.send(.ready(version: "HTML reader · Chromium fallback"))
    }

    func stopAndWait() {
        for view in views.values {
            pauseMedia(view)
            view.stopLoading()
        }
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
        pauseMedia(view)
        if activeID == tab {
            activeID = nil
            host.show(nil)
        }
        view.stopLoading()
        view.removeFromSuperview()
        sidecarLoading.remove(tab)
        lastHandledURL[tab] = nil
    }

    func activate(tab: UUID?) {
        for (id, view) in views where id != tab {
            pauseMedia(view)
        }
        activeID = tab
        if let tab, let view = views[tab] {
            view.setAllMediaPlaybackSuspended(false)
        }
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
        view.onURLChange = { [weak self] webView in
            self?.mainFrameURLChanged(webView)
        }
        view.startObservingURL()
        views[tab] = view
        if tab == activeID { host.show(view) }
        return view
    }

    private func load(tab: UUID, view: PageView, url: String) async {
        let key = tab.uuidString
        pauseMedia(view)
        sidecarLoading.insert(tab)
        lastHandledURL[tab] = Self.stripFragment(url)
        events.send(.loadStatus(tab: key, status: "Loading"))
        events.send(.urlChanged(tab: key, url: url))
        guard let client else {
            sidecarLoading.remove(tab)
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
            sidecarLoading.remove(tab)
            events.send(.error("Search sidecar is not ready"))
            events.send(.loadStatus(tab: key, status: "Complete"))
            return
        }
        do {
            let page = try await client.browse(url: url)
            lastHandledURL[tab] = Self.stripFragment(page.url.isEmpty ? url : page.url)
            if page.mode == "reader", !page.html.isEmpty {
                view.loadHTMLString(page.html, baseURL: URL(string: page.url))
            } else if let embed = page.embed_url, let embedURL = URL(string: embed) {
                view.load(URLRequest(url: embedURL))
            } else if page.mode == "live", let live = URL(string: page.url) {
                view.load(URLRequest(url: live))
            } else {
                sidecarLoading.remove(tab)
                let message = page.error ?? "Could not open this page."
                view.loadHTMLString("<p style='font:15px sans-serif;padding:24px'>\(message)</p>", baseURL: nil)
            }
            if !page.title.isEmpty {
                events.send(.titleChanged(tab: key, title: page.title))
            }
        } catch {
            sidecarLoading.remove(tab)
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

    private func pauseMedia(_ view: WKWebView) {
        view.setAllMediaPlaybackSuspended(true)
        view.pauseAllMediaPlayback()
        view.evaluateJavaScript(
            "document.querySelectorAll('video,audio').forEach(function(el){el.pause();});"
        )
    }

    private func mainFrameURLChanged(_ webView: WKWebView) {
        guard let id = (webView as? PageView)?.tabID, !sidecarLoading.contains(id) else { return }
        guard let url = webView.url, Self.isHTTP(url) else { return }
        if url.path.lowercased().contains("/embed/") { return }
        let abs = Self.stripFragment(url.absoluteString)
        guard abs != lastHandledURL[id] else { return }
        lastHandledURL[id] = abs
        events.send(.urlChanged(tab: id.uuidString, url: abs))
        events.send(.userNavigate(tab: id.uuidString, url: abs, reload: false))
    }

    private static func stripFragment(_ raw: String) -> String {
        String(raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }

    private static func isHTTP(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}

extension BrowseSession: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
            return
        }
        guard let url = navigationAction.request.url, Self.isHTTP(url),
              let id = (webView as? PageView)?.tabID else {
            decisionHandler(.allow)
            return
        }
        if sidecarLoading.contains(id) {
            decisionHandler(.allow)
            return
        }
        switch navigationAction.navigationType {
        case .backForward, .reload, .formSubmitted:
            decisionHandler(.allow)
        case .linkActivated:
            decisionHandler(.cancel)
            pauseMedia(webView)
            events.send(.userNavigate(tab: id.uuidString, url: Self.stripFragment(url.absoluteString), reload: true))
        default:
            let abs = Self.stripFragment(url.absoluteString)
            if abs == lastHandledURL[id] {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            pauseMedia(webView)
            events.send(.userNavigate(tab: id.uuidString, url: abs, reload: true))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = (webView as? PageView)?.tabID else { return }
        let tab = id.uuidString
        sidecarLoading.remove(id)
        events.send(.loadStatus(tab: tab, status: "Complete"))
        events.send(.history(tab: tab, canGoBack: webView.canGoBack, canGoForward: webView.canGoForward))
        if let title = webView.title, !title.isEmpty {
            events.send(.titleChanged(tab: tab, title: title))
        }
        guard let url = webView.url, Self.isHTTP(url), !url.path.lowercased().contains("/embed/") else { return }
        let abs = Self.stripFragment(url.absoluteString)
        if abs != lastHandledURL[id] {
            lastHandledURL[id] = abs
            events.send(.urlChanged(tab: tab, url: abs))
            events.send(.userNavigate(tab: tab, url: abs, reload: false))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let tab = key(for: webView), let id = (webView as? PageView)?.tabID else { return }
        sidecarLoading.remove(id)
        events.send(.loadStatus(tab: tab, status: "Complete"))
        events.send(.error(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webView(webView, didFail: navigation, withError: error)
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
    var onURLChange: ((WKWebView) -> Void)?
    private var urlObservation: NSKeyValueObservation?

    func startObservingURL() {
        guard urlObservation == nil else { return }
        urlObservation = observe(\.url, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.onURLChange?(view) }
        }
    }
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
