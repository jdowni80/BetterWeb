import AppKit
import BWEngine
import Combine
import Foundation

enum BrowseEvent {
    case ready(version: String)
    case urlChanged(tab: String, url: String)
    case titleChanged(tab: String, title: String)
    case loadStatus(tab: String, status: String)
    case history(tab: String, canGoBack: Bool, canGoForward: Bool)
    case statusText(tab: String, text: String?)
    case audio(tab: String, playing: Bool)
    case zoom(tab: String, level: Double)
    /// The engine already created the page (popup, target=_blank, "Open in New Tab"); adopt it as a tab.
    case adoptedTab(opener: String?, tab: UUID, url: String, activate: Bool)
    case closeRequested(tab: String)
    case crashed(tab: String)
    case error(String)
}

/// Runs Ladybird in-process (LibWebView drives WebContent, RequestServer, ImageDecoder and the
/// compositor as sandboxed helpers) and keeps one `BWWebView` per open tab.
@MainActor
final class BrowseSession: NSObject {
    let events = PassthroughSubject<BrowseEvent, Never>()
    /// Hosts whichever tab's page is active; SwiftUI embeds this once.
    let host = EngineHostView()

    private(set) var isRunning = false
    private var views: [UUID: BWWebView] = [:]
    private var activeID: UUID?

    func start() throws {
        if isRunning { return }
        try BWEngine.start(withProfile: "betterweb", arguments: [])
        BWEngine.delegate = self
        isRunning = true
        AppLog.info("engine started: \(BWEngine.engineName())")
        events.send(.ready(version: BWEngine.engineName()))
    }

    /// Tabs are torn down on quit; the helpers exit with the app.
    func stopAndWait() {
        for view in views.values { view.close() }
        views.removeAll()
        host.show(nil)
    }

    // MARK: Commands

    func open(tab: UUID, url: String) {
        let view = makeView(for: tab)
        view.loadURL(url)
    }

    func close(tab: UUID) {
        guard let view = views.removeValue(forKey: tab) else { return }
        if activeID == tab {
            activeID = nil
            host.show(nil)
        }
        view.close()
    }

    func activate(tab: UUID?) {
        activeID = tab
        for (id, view) in views { view.pageVisible = (id == tab) }
        host.show(tab.flatMap { views[$0] })
    }

    func navigate(tab: UUID, url: String) {
        if let view = views[tab] { view.loadURL(url) } else { open(tab: tab, url: url) }
    }

    func goBack(tab: UUID) { views[tab]?.goBack() }
    func goForward(tab: UUID) { views[tab]?.goForward() }
    func reload(tab: UUID) { views[tab]?.reload() }

    func zoom(_ factor: Double) {
        guard let activeID, let view = views[activeID] else { return }
        view.setZoom(factor)
    }

    func focus() {
        guard let activeID, let view = views[activeID] else { return }
        view.window?.makeFirstResponder(view)
    }

    func blur() {
        guard let activeID, let view = views[activeID], view.window?.firstResponder === view else { return }
        view.window?.makeFirstResponder(nil)
    }

    var activeView: BWWebView? { activeID.flatMap { views[$0] } }

    // MARK: Views

    @discardableResult
    private func makeView(for tab: UUID) -> BWWebView {
        if let existing = views[tab] { return existing }
        let view = BWWebView()
        adopt(view, as: tab)
        return view
    }

    private func adopt(_ view: BWWebView, as tab: UUID) {
        view.delegate = self
        view.pageVisible = (tab == activeID)
        views[tab] = view
        if tab == activeID { host.show(view) }
    }

    private func key(for view: BWWebView) -> String? {
        views.first(where: { $0.value === view })?.key.uuidString
    }
}

extension BrowseSession: BWEngineDelegate {
    nonisolated func engineRequestsNewTab(activating activate: Bool) -> BWWebView? {
        MainActor.assumeIsolated {
            let id = UUID()
            let view = BWWebView()
            adopt(view, as: id)
            events.send(.adoptedTab(opener: activeID?.uuidString, tab: id, url: view.currentURL, activate: activate))
            return view
        }
    }

    nonisolated func engineActiveWebView() -> BWWebView? {
        MainActor.assumeIsolated { activeView }
    }
}

extension BrowseSession: BWWebViewDelegate {
    nonisolated func webView(_ webView: BWWebView, didChangeURL url: String) {
        MainActor.assumeIsolated {
            guard let tab = key(for: webView) else { return }
            events.send(.urlChanged(tab: tab, url: url))
        }
    }

    nonisolated func webView(_ webView: BWWebView, didChangeTitle title: String) {
        MainActor.assumeIsolated {
            guard let tab = key(for: webView) else { return }
            events.send(.titleChanged(tab: tab, title: title))
        }
    }

    nonisolated func webView(_ webView: BWWebView, loadingStateChanged loading: Bool) {
        MainActor.assumeIsolated {
            guard let tab = key(for: webView) else { return }
            events.send(.loadStatus(tab: tab, status: loading ? "Loading" : "Complete"))
        }
    }

    nonisolated func webView(_ webView: BWWebView, canGoBack back: Bool, canGoForward forward: Bool) {
        MainActor.assumeIsolated {
            guard let tab = key(for: webView) else { return }
            events.send(.history(tab: tab, canGoBack: back, canGoForward: forward))
        }
    }

    nonisolated func webView(_ webView: BWWebView, hoveredLink url: String?) {
        MainActor.assumeIsolated {
            guard let tab = key(for: webView) else { return }
            events.send(.statusText(tab: tab, text: url))
        }
    }

    nonisolated func webView(_ webView: BWWebView, audioStateChanged state: BWAudioState) {
        MainActor.assumeIsolated {
            guard let tab = key(for: webView) else { return }
            events.send(.audio(tab: tab, playing: state == .playing))
        }
    }

    nonisolated func webView(_ webView: BWWebView, zoomChanged level: Double) {
        MainActor.assumeIsolated {
            guard let tab = key(for: webView) else { return }
            events.send(.zoom(tab: tab, level: level))
        }
    }

    nonisolated func webView(_ webView: BWWebView, didOpenChild child: BWWebView, activate: Bool) {
        MainActor.assumeIsolated {
            let id = UUID()
            adopt(child, as: id)
            events.send(.adoptedTab(opener: key(for: webView), tab: id, url: child.currentURL, activate: activate))
        }
    }

    nonisolated func webViewDidRequestClose(_ webView: BWWebView) {
        MainActor.assumeIsolated {
            guard let tab = key(for: webView) else { return }
            events.send(.closeRequested(tab: tab))
        }
    }

    nonisolated func webViewDidCrash(_ webView: BWWebView) {
        MainActor.assumeIsolated {
            guard let tab = key(for: webView) else { return }
            AppLog.info("web content crashed tab=\(tab)")
            events.send(.crashed(tab: tab))
        }
    }

    nonisolated func webView(_ webView: BWWebView, fullscreenChanged fullscreen: Bool) {
        MainActor.assumeIsolated {
            guard let window = webView.window else { return }
            if fullscreen != window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
    }
}

/// Plain container for the active tab's page view; swapping tabs swaps the single subview.
final class EngineHostView: NSView {
    private weak var current: BWWebView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func show(_ view: BWWebView?) {
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
