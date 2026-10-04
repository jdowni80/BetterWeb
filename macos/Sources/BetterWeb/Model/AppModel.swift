import AppKit
import BWEngine
import Combine
import Foundation

enum TabContent: Equatable, Codable {
    case blank
    case search(query: String, mode: SearchMode)
    case page(url: String)
    case history
    case settings
}

enum SearchMode: String, Codable, CaseIterable, Identifiable {
    case live
    case local
    var id: String { rawValue }
    var label: String { self == .live ? "Live web" : "Local seed" }
}

struct BrowserTab: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var address: String
    var content: TabContent
    var pinned: Bool
    /// Non-page places this tab came from before its current page ("search:<q>" or "blank").
    var originStack: [String] = []
    /// Page to return to after going back from a page to its search origin.
    var forwardPage: String?

    static func blank(id: UUID = UUID()) -> BrowserTab {
        BrowserTab(id: id, title: "New Tab", address: "", content: .blank, pinned: false)
    }

    var pageURL: String? {
        if case .page(let url) = content { return url }
        return nil
    }

    var faviconHost: String? {
        guard let url = pageURL, let host = URL(string: url)?.host else { return nil }
        return host
    }
}

struct TabGroup: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var tabIDs: [UUID]
    var collapsed: Bool
    var pinned: Bool

    static func new(name: String = "New Group") -> TabGroup {
        TabGroup(id: UUID(), name: name, tabIDs: [], collapsed: false, pinned: false)
    }
}

/// Live, non-persisted state reported by the Servo helper for a tab.
struct TabRuntime: Equatable {
    var loading = false
    var blocked = 0
    var canGoBack = false
    var canGoForward = false
    var zoom = 1.0
    var audioPlaying = false
}

struct SearchState: Equatable {
    var query: String
    var mode: SearchMode
    var busy = true
    var hits: [SearchHit] = []
    var ranking = ""
    var error: String?
}

enum ServiceState: Equatable {
    case starting
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }
}

private struct PersistedChromeState: Codable {
    var tabs: [BrowserTab]
    var groups: [TabGroup]
    var ungroupedTabIDs: [UUID]
    var activeTabID: UUID
    var sidebarCollapsed: Bool
    var searchMode: SearchMode
}

private struct ClosedTab {
    let tab: BrowserTab
    let groupID: UUID?
}

@MainActor
final class AppModel: ObservableObject {
    @Published var tabs: [BrowserTab]
    @Published var groups: [TabGroup]
    @Published var ungroupedTabIDs: [UUID]
    @Published var activeTabID: UUID
    @Published var sidebarCollapsed = false { didSet { persist() } }
    @Published var omniboxFocusToken = 0
    @Published var searchMode: SearchMode = .live { didSet { persist() } }
    @Published var sidecarState: ServiceState = .starting
    @Published var browseState: ServiceState = .starting
    @Published var browseVersion = ""
    @Published var engines: [EngineStatus] = []
    @Published var runtime: [UUID: TabRuntime] = [:]
    @Published var searches: [UUID: SearchState] = [:]
    @Published var hoverStatus: String?
    @Published var toast: String?
    @Published var editingGroupID: UUID?
    @Published var draggingTabID: UUID?

    let searchClient = SearchClient()
    let sidecar = SidecarProcess()
    let browse = BrowseSession()
    let history = HistoryStore()
    let bookmarks = BookmarkStore()

    private var closedTabs: [ClosedTab] = []
    private var openedInHelper = Set<UUID>()
    private var sidecarTask: Task<Void, Error>?
    private var cancellables = Set<AnyCancellable>()
    private var helperRestarts = 0
    private var terminating = false
    private var started = false
    private var toastTask: Task<Void, Never>?
    private let persistKey = "betterweb.chrome.v2"

    var activeTab: BrowserTab {
        tab(for: activeTabID) ?? tabs[0]
    }

    var activeRuntime: TabRuntime {
        runtime[activeTabID] ?? TabRuntime()
    }

    var hasClosedTabs: Bool { !closedTabs.isEmpty }

    init() {
        if let restored = Self.load(key: "betterweb.chrome.v2"), !restored.tabs.isEmpty {
            tabs = restored.tabs
            groups = restored.groups
            ungroupedTabIDs = restored.ungroupedTabIDs
            activeTabID = restored.activeTabID
            sidebarCollapsed = restored.sidebarCollapsed
            searchMode = restored.searchMode
            let grouped = Set(groups.flatMap(\.tabIDs))
            let allIDs = Set(tabs.map(\.id))
            for i in groups.indices {
                groups[i].tabIDs = groups[i].tabIDs.filter { allIDs.contains($0) }
            }
            ungroupedTabIDs = ungroupedTabIDs.filter { allIDs.contains($0) && !grouped.contains($0) }
            for tab in tabs where !grouped.contains(tab.id) && !ungroupedTabIDs.contains(tab.id) {
                ungroupedTabIDs.append(tab.id)
            }
            if !tabs.contains(where: { $0.id == activeTabID }) {
                activeTabID = tabs[0].id
            }
        } else {
            let initial = BrowserTab.blank()
            tabs = [initial]
            groups = []
            ungroupedTabIDs = [initial.id]
            activeTabID = initial.id
        }

        browse.events
            .sink { [weak self] event in self?.handleBrowseEvent(event) }
            .store(in: &cancellables)
        // Nested stores publish on their own; forward so chrome observing the model refreshes.
        history.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        bookmarks.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func tab(for id: UUID) -> BrowserTab? {
        tabs.first(where: { $0.id == id })
    }

    func requestOmniboxFocus() {
        omniboxFocusToken += 1
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        startBrowseHelper()
        startSidecar()
        syncBrowseToActiveTab()
    }

    func shutdown() {
        terminating = true
        persist()
        browse.stopAndWait()
        sidecar.stop()
    }

    private func startBrowseHelper() {
        browseState = .starting
        do {
            try browse.start()
        } catch {
            browseState = .failed(error.localizedDescription)
            AppLog.info("browse start failed: \(error.localizedDescription)")
        }
    }

    private func startSidecar() {
        sidecarState = .starting
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.sidecar.start(client: self.searchClient)
        }
        sidecarTask = task
        Task { [weak self] in
            do {
                try await task.value
                guard let self else { return }
                self.sidecarState = .ready
                self.engines = (try? await self.searchClient.engines()) ?? []
            } catch {
                self?.sidecarState = .failed(error.localizedDescription)
                AppLog.info("sidecar failed: \(error.localizedDescription)")
            }
        }
    }

    /// Wipes the engine's cookies, site storage, and HTTP cache.
    func clearSiteData() {
        BWEngine.clearSiteData { [weak self] in
            Task { @MainActor in self?.flash("Cookies & site data cleared") }
        }
    }

    func retryServices() {
        if !browseState.isReady {
            helperRestarts = 0
            startBrowseHelper()
        }
        if case .failed = sidecarState {
            startSidecar()
        }
    }

    // MARK: - Tabs & groups

    func newTab(inGroup groupID: UUID? = nil, after anchor: UUID? = nil) {
        let tab = BrowserTab.blank()
        insert(tab, groupID: groupID, after: anchor)
        activate(tab.id)
    }

    private func insert(_ tab: BrowserTab, groupID: UUID?, after anchor: UUID?) {
        tabs.append(tab)
        if let groupID, let gi = groups.firstIndex(where: { $0.id == groupID }) {
            let at = anchor.flatMap { groups[gi].tabIDs.firstIndex(of: $0) }.map { $0 + 1 } ?? groups[gi].tabIDs.count
            groups[gi].tabIDs.insert(tab.id, at: at)
            groups[gi].collapsed = false
        } else {
            let at = anchor.flatMap { ungroupedTabIDs.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            ungroupedTabIDs.insert(tab.id, at: at)
        }
    }

    func groupID(containing tabID: UUID) -> UUID? {
        groups.first(where: { $0.tabIDs.contains(tabID) })?.id
    }

    func newGroup() {
        var group = TabGroup.new()
        if let idx = ungroupedTabIDs.firstIndex(of: activeTabID), tab(for: activeTabID)?.pinned == false {
            ungroupedTabIDs.remove(at: idx)
            group.tabIDs = [activeTabID]
        } else {
            let tab = BrowserTab.blank()
            tabs.append(tab)
            group.tabIDs = [tab.id]
            activeTabID = tab.id
            syncBrowseToActiveTab()
        }
        let firstUnpinned = groups.firstIndex(where: { !$0.pinned }) ?? groups.count
        groups.insert(group, at: firstUnpinned)
        editingGroupID = group.id
        persist()
    }

    func renameGroup(_ id: UUID, to name: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        groups[i].name = trimmed.isEmpty ? "New Group" : trimmed
        editingGroupID = nil
        persist()
    }

    func toggleGroupCollapsed(_ id: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].collapsed.toggle()
        persist()
    }

    func toggleGroupPinned(_ id: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        var group = groups.remove(at: i)
        group.pinned.toggle()
        let firstUnpinned = groups.firstIndex(where: { !$0.pinned }) ?? groups.count
        groups.insert(group, at: group.pinned ? firstUnpinned : firstUnpinned)
        persist()
    }

    /// Ungroups the tabs; they stay open.
    func ungroup(_ id: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let orphaned = groups[i].tabIDs
        groups.remove(at: i)
        ungroupedTabIDs.insert(contentsOf: orphaned, at: 0)
        persist()
    }

    /// Closes the group and every tab in it.
    func closeGroup(_ id: UUID) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        for tabID in group.tabIDs { closeTab(tabID, force: true) }
        groups.removeAll { $0.id == id }
        persist()
    }

    func closeTab(_ id: UUID, force: Bool = false) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[idx].pinned && !force { return }
        let order = visualTabOrder
        let groupID = groupID(containing: id)
        closedTabs.append(ClosedTab(tab: tabs[idx], groupID: groupID))
        if closedTabs.count > 25 { closedTabs.removeFirst() }

        tabs.remove(at: idx)
        ungroupedTabIDs.removeAll { $0 == id }
        for gi in groups.indices { groups[gi].tabIDs.removeAll { $0 == id } }
        groups.removeAll { $0.tabIDs.isEmpty && !$0.pinned }
        runtime[id] = nil
        searches[id] = nil
        if openedInHelper.remove(id) != nil { browse.close(tab: id) }

        if tabs.isEmpty {
            let blank = BrowserTab.blank()
            tabs = [blank]
            ungroupedTabIDs = [blank.id]
            activeTabID = blank.id
            syncBrowseToActiveTab()
        } else if activeTabID == id {
            let pos = order.firstIndex(of: id) ?? 0
            let remaining = order.filter { $0 != id && tab(for: $0) != nil }
            activeTabID = remaining[min(pos, remaining.count - 1)]
            syncBrowseToActiveTab()
        }
        persist()
    }

    func closeActiveTab() {
        closeTab(activeTabID, force: true)
    }

    func restoreClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        let groupExists = closed.groupID.map { gid in groups.contains { $0.id == gid } } ?? false
        insert(closed.tab, groupID: groupExists ? closed.groupID : nil, after: nil)
        activate(closed.tab.id)
    }

    func selectTab(_ id: UUID) {
        guard id != activeTabID || editingGroupID != nil else { return }
        activate(id)
    }

    private func activate(_ id: UUID) {
        activeTabID = id
        hoverStatus = nil
        syncBrowseToActiveTab()
        persist()
    }

    func togglePin(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].pinned.toggle()
        persist()
    }

    func moveTabToGroup(_ tabID: UUID, groupID: UUID?) {
        moveTab(tabID, before: nil, inGroup: groupID)
    }

    /// Drag-and-drop: place `tabID` before `target` inside `groupID` (nil = ungrouped list).
    func moveTab(_ tabID: UUID, before target: UUID?, inGroup groupID: UUID?) {
        guard tabID != target, tab(for: tabID) != nil else { return }
        ungroupedTabIDs.removeAll { $0 == tabID }
        for i in groups.indices { groups[i].tabIDs.removeAll { $0 == tabID } }
        if let groupID, let gi = groups.firstIndex(where: { $0.id == groupID }) {
            let at = target.flatMap { groups[gi].tabIDs.firstIndex(of: $0) } ?? groups[gi].tabIDs.count
            groups[gi].tabIDs.insert(tabID, at: at)
            groups[gi].collapsed = false
        } else {
            let at = target.flatMap { ungroupedTabIDs.firstIndex(of: $0) } ?? ungroupedTabIDs.count
            ungroupedTabIDs.insert(tabID, at: at)
        }
        groups.removeAll { $0.tabIDs.isEmpty && !$0.pinned }
        persist()
    }

    func moveGroup(_ groupID: UUID, before target: UUID?) {
        guard groupID != target, let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let group = groups.remove(at: i)
        let at = target.flatMap { t in groups.firstIndex(where: { $0.id == t }) } ?? groups.count
        groups.insert(group, at: at)
        persist()
    }

    var pinnedUngroupedTabs: [BrowserTab] {
        orderedTabs(ids: ungroupedTabIDs.filter { tab(for: $0)?.pinned == true })
    }

    var unpinnedUngroupedTabs: [BrowserTab] {
        orderedTabs(ids: ungroupedTabIDs.filter { tab(for: $0)?.pinned == false })
    }

    var pinnedGroups: [TabGroup] { groups.filter(\.pinned) }
    var unpinnedGroups: [TabGroup] { groups.filter { !$0.pinned } }

    func orderedTabs(ids: [UUID]) -> [BrowserTab] {
        ids.compactMap { tab(for: $0) }
    }

    /// Sidebar order, top to bottom.
    var visualTabOrder: [UUID] {
        pinnedUngroupedTabs.map(\.id)
            + pinnedGroups.flatMap(\.tabIDs)
            + unpinnedGroups.flatMap(\.tabIDs)
            + unpinnedUngroupedTabs.map(\.id)
    }

    func selectAdjacentTab(_ offset: Int) {
        let order = visualTabOrder
        guard !order.isEmpty, let i = order.firstIndex(of: activeTabID) else { return }
        let next = (i + offset + order.count) % order.count
        activate(order[next])
    }

    func selectTab(atIndex index: Int) {
        let order = visualTabOrder
        guard !order.isEmpty else { return }
        activate(index >= 8 ? order[order.count - 1] : order[min(index, order.count - 1)])
    }

    // MARK: - Omnibox / navigation

    func submitOmnibox(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        switch text.lowercased() {
        case "betterweb://history", "apheleia://history":
            showPanel(.history, title: "History", address: "betterweb://history")
            return
        case "betterweb://settings", "betterweb://config", "apheleia://config":
            showPanel(.settings, title: "Settings", address: "betterweb://settings")
            return
        default:
            break
        }

        if let url = Self.urlIfNavigable(text) {
            history.add(url: url, title: nil, entryType: "url")
            navigateActive(to: url)
        } else {
            history.add(url: text, title: text, entryType: "search")
            runSearch(query: text)
        }
    }

    func showHistory() { showPanel(.history, title: "History", address: "betterweb://history") }
    func showSettings() { showPanel(.settings, title: "Settings", address: "betterweb://settings") }

    private func showPanel(_ content: TabContent, title: String, address: String) {
        if activeTab.content == .blank || activeTab.content == content {
            mutateActive {
                $0.content = content
                $0.title = title
                $0.address = address
            }
        } else {
            var tab = BrowserTab.blank()
            tab.content = content
            tab.title = title
            tab.address = address
            insert(tab, groupID: groupID(containing: activeTabID), after: activeTabID)
            activeTabID = tab.id
        }
        syncBrowseToActiveTab()
        persist()
    }

    func runSearch(query: String) {
        let mode = searchMode
        mutateActive { tab in
            if let url = tab.pageURL { tab.forwardPage = nil; tab.originStack.append("page:\(url)") }
            tab.content = .search(query: query, mode: mode)
            tab.title = query
            tab.address = query
        }
        performSearch(tabID: activeTabID, query: query, mode: mode, force: true)
        syncBrowseToActiveTab()
        persist()
    }

    func openHit(_ hit: SearchHit, newTab: Bool = false) {
        history.add(url: hit.url, title: hit.title, entryType: "link")
        if newTab {
            openInNewTab(url: hit.url, from: activeTabID, activate: false)
        } else {
            navigateActive(to: hit.url)
        }
    }

    func adoptEngineTab(id: UUID, url: String, opener: UUID?, activate shouldActivate: Bool) {
        openedInHelper.insert(id)
        if tabs.contains(where: { $0.id == id }) {
            if shouldActivate { activate(id) }
            return
        }
        var tab = BrowserTab.blank(id: id)
        let address = url.isEmpty ? "about:blank" : url
        tab.content = .page(url: address)
        tab.address = address
        tab.title = URL(string: address)?.host ?? address
        insert(tab, groupID: opener.flatMap { groupID(containing: $0) }, after: opener)
        if shouldActivate { activate(id) } else { persist() }
    }

    func openInNewTab(url: String, from opener: UUID?, activate shouldActivate: Bool) {
        var tab = BrowserTab.blank()
        tab.content = .page(url: url)
        tab.address = url
        tab.title = URL(string: url)?.host ?? url
        let gid = opener.flatMap { groupID(containing: $0) }
        insert(tab, groupID: gid, after: opener)
        if shouldActivate {
            activate(tab.id)
        } else {
            persist()
        }
    }

    func navigateActive(to url: String) {
        let id = activeTabID
        mutateActive { tab in
            switch tab.content {
            case .search(let q, _): tab.originStack.append("search:\(q)")
            case .blank: tab.originStack.append("blank")
            default: break
            }
            tab.forwardPage = nil
            tab.content = .page(url: url)
            tab.address = url
            tab.title = URL(string: url)?.host ?? url
        }
        runtime[id, default: TabRuntime()].loading = true
        if browseState.isReady && openedInHelper.contains(id) {
            browse.navigate(tab: id, url: url)
            browse.activate(tab: id)
        } else {
            syncBrowseToActiveTab()
        }
        persist()
    }

    func canGoBack(_ tab: BrowserTab) -> Bool {
        switch tab.content {
        case .page: return (runtime[tab.id]?.canGoBack ?? false) || !tab.originStack.isEmpty
        case .search: return tab.originStack.last?.hasPrefix("page:") == true
        default: return false
        }
    }

    func canGoForward(_ tab: BrowserTab) -> Bool {
        switch tab.content {
        case .page: return runtime[tab.id]?.canGoForward ?? false
        default: return tab.forwardPage != nil
        }
    }

    func goBack() {
        let tab = activeTab
        if tab.pageURL != nil, runtime[tab.id]?.canGoBack == true {
            browse.goBack(tab: tab.id)
            return
        }
        guard let origin = tab.originStack.last else { return }
        mutateActive { t in
            t.originStack.removeLast()
            if let url = t.pageURL { t.forwardPage = url }
            if origin.hasPrefix("search:") {
                let q = String(origin.dropFirst("search:".count))
                t.content = .search(query: q, mode: searchMode)
                t.address = q
                t.title = q
            } else if origin.hasPrefix("page:") {
                let url = String(origin.dropFirst("page:".count))
                t.content = .page(url: url)
                t.address = url
            } else {
                t.content = .blank
                t.address = ""
                t.title = "New Tab"
            }
        }
        syncBrowseToActiveTab()
        persist()
    }

    func goForward() {
        let tab = activeTab
        if tab.pageURL != nil {
            if runtime[tab.id]?.canGoForward == true { browse.goForward(tab: tab.id) }
            return
        }
        guard let page = tab.forwardPage else { return }
        mutateActive { t in
            switch t.content {
            case .search(let q, _): t.originStack.append("search:\(q)")
            case .blank: t.originStack.append("blank")
            default: break
            }
            t.forwardPage = nil
            t.content = .page(url: page)
            t.address = page
        }
        syncBrowseToActiveTab()
        persist()
    }

    func reload() {
        switch activeTab.content {
        case .page(let url):
            if openedInHelper.contains(activeTabID) {
                browse.reload(tab: activeTabID)
            } else {
                navigateActive(to: url)
            }
        case .search(let q, let mode):
            performSearch(tabID: activeTabID, query: q, mode: mode, force: true)
        default:
            break
        }
    }

    func setZoom(_ factor: Double?) {
        guard activeTab.pageURL != nil else { return }
        let current = runtime[activeTabID]?.zoom ?? 1.0
        let next = factor ?? 1.0
        guard next != current else { return }
        runtime[activeTabID, default: TabRuntime()].zoom = next
        browse.zoom(next)
        flash(String(format: "Zoom %d%%", Int((next * 100).rounded())))
    }

    func zoomIn() { setZoom(min(5.0, ((runtime[activeTabID]?.zoom ?? 1.0) * 1.1 * 100).rounded() / 100)) }
    func zoomOut() { setZoom(max(0.3, ((runtime[activeTabID]?.zoom ?? 1.0) / 1.1 * 100).rounded() / 100)) }

    func copyActiveURL() {
        guard let url = activeTab.pageURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        flash("Copied link")
    }

    func toggleBookmarkActive() {
        guard let url = activeTab.pageURL else { return }
        let added = bookmarks.toggle(url: url, title: activeTab.title)
        flash(added ? "Bookmarked" : "Bookmark removed")
    }

    var activeIsBookmarked: Bool {
        activeTab.pageURL.map { bookmarks.contains(url: $0) } ?? false
    }

    func suggestions(for query: String) -> [Suggestion] {
        history.suggestions(for: query, bookmarks: bookmarks.bookmarks)
    }

    func flash(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: - Internals

    private func syncBrowseToActiveTab() {
        let tab = activeTab
        switch tab.content {
        case .page(let url):
            guard browseState.isReady else { return }
            if !openedInHelper.contains(tab.id) {
                openedInHelper.insert(tab.id)
                runtime[tab.id, default: TabRuntime()].loading = true
                browse.open(tab: tab.id, url: url)
            }
            browse.activate(tab: tab.id)
        case .search(let q, let mode):
            if browseState.isReady { browse.activate(tab: nil) }
            performSearch(tabID: tab.id, query: q, mode: mode, force: false)
        default:
            if browseState.isReady { browse.activate(tab: nil) }
        }
    }

    private func mutateActive(_ body: (inout BrowserTab) -> Void) {
        mutate(activeTabID, body)
    }

    private func mutate(_ id: UUID, _ body: (inout BrowserTab) -> Void) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        var tab = tabs[i]
        body(&tab)
        if tab != tabs[i] { tabs[i] = tab }
    }

    private func performSearch(tabID: UUID, query: String, mode: SearchMode, force: Bool) {
        if !force, let existing = searches[tabID], existing.query == query, existing.mode == mode {
            return
        }
        searches[tabID] = SearchState(query: query, mode: mode)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sidecarTask?.value
                AppLog.info("search start q=\(query) mode=\(mode.rawValue) base=\(self.searchClient.baseURL)")
                let result = try await self.searchClient.search(query: query, mode: mode, limit: 12)
                AppLog.info("search done q=\(query) hits=\(result.hits.count)")
                guard self.searches[tabID]?.query == query else { return }
                self.searches[tabID] = SearchState(
                    query: query, mode: mode, busy: false, hits: result.hits, ranking: result.ranking
                )
            } catch {
                AppLog.info("search failed q=\(query): \(error)")
                guard self.searches[tabID]?.query == query else { return }
                self.searches[tabID] = SearchState(
                    query: query, mode: mode, busy: false, error: error.localizedDescription
                )
            }
        }
    }

    private func handleBrowseEvent(_ event: BrowseEvent) {
        switch event {
        case .ready(let version):
            browseState = .ready
            browseVersion = version
            helperRestarts = 0
            openedInHelper.removeAll()
            syncBrowseToActiveTab()

        case .urlChanged(let tabKey, let url):
            guard let id = UUID(uuidString: tabKey) else { return }
            mutate(id) { tab in
                guard tab.pageURL != nil else { return }
                tab.content = .page(url: url)
                tab.address = url
            }

        case .titleChanged(let tabKey, let title):
            guard let id = UUID(uuidString: tabKey), let tab = tab(for: id), let url = tab.pageURL else { return }
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            mutate(id) { $0.title = clean.isEmpty ? (URL(string: url)?.host ?? url) : clean }
            if !clean.isEmpty { history.add(url: url, title: clean, entryType: "url") }
            persist()

        case .loadStatus(let tabKey, let status):
            guard let id = UUID(uuidString: tabKey) else { return }
            runtime[id, default: TabRuntime()].loading = status != "Complete"
            if status == "Complete", let url = tab(for: id)?.pageURL {
                history.add(url: url, title: tab(for: id)?.title, entryType: "url")
            }

        case .history(let tabKey, let back, let forward):
            guard let id = UUID(uuidString: tabKey) else { return }
            var rt = runtime[id] ?? TabRuntime()
            rt.canGoBack = back
            rt.canGoForward = forward
            if runtime[id] != rt { runtime[id] = rt }

        case .statusText(let tabKey, let text):
            guard UUID(uuidString: tabKey) == activeTabID else { return }
            hoverStatus = (text?.isEmpty == false) ? text : nil

        case .audio(let tabKey, let playing):
            guard let id = UUID(uuidString: tabKey) else { return }
            runtime[id, default: TabRuntime()].audioPlaying = playing

        case .zoom(let tabKey, let level):
            guard let id = UUID(uuidString: tabKey) else { return }
            runtime[id, default: TabRuntime()].zoom = level

        case .adoptedTab(let openerKey, let tabID, let url, let activate):
            adoptEngineTab(id: tabID, url: url, opener: openerKey.flatMap(UUID.init(uuidString:)), activate: activate)

        case .closeRequested(let tabKey):
            if let id = UUID(uuidString: tabKey) { closeTab(id, force: true) }

        case .crashed(let tabKey):
            flash("Page crashed")
            if let id = UUID(uuidString: tabKey) { runtime[id, default: TabRuntime()].loading = false }

        case .error(let message):
            flash(message)
        }
    }

    /// URL for anything that looks navigable; `nil` means "search for it".
    static func urlIfNavigable(_ text: String) -> String? {
        if text.contains(" ") { return nil }
        let lower = text.lowercased()
        for scheme in ["http://", "https://", "about:", "file://", "data:"] where lower.hasPrefix(scheme) {
            return text
        }
        if lower.hasPrefix("localhost") || lower.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil {
            return "http://\(text)"
        }
        let host = lower.split(separator: "/").first.map(String.init) ?? lower
        if host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
           let tld = host.split(separator: ".").last?.split(separator: ":").first,
           tld.count >= 2, tld.allSatisfy(\.isLetter) {
            return "https://\(text)"
        }
        return nil
    }

    private func persist() {
        guard !tabs.isEmpty else { return }
        let state = PersistedChromeState(
            tabs: tabs,
            groups: groups,
            ungroupedTabIDs: ungroupedTabIDs,
            activeTabID: activeTabID,
            sidebarCollapsed: sidebarCollapsed,
            searchMode: searchMode
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
    }

    private static func load(key: String) -> PersistedChromeState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedChromeState.self, from: data)
    }
}
