import AppKit
import SwiftUI

struct ContentAreaView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let tab = model.activeTab
        let isPage = tab.pageURL != nil

        ZStack {
            // The engine surface stays mounted so its size (and the page viewport) never jitters.
            EngineContentView()
                .opacity(isPage ? 1 : 0)
                .allowsHitTesting(isPage)

            if isPage {
                if !model.browseState.isReady || !model.sidecarState.isReady {
                    EngineStateOverlay()
                }
            } else {
                Group {
                    switch tab.content {
                    case .blank: NewTabSearchView()
                    case .search: SearchResultsView()
                    case .history: HistoryPanelView()
                    case .settings: SettingsPanelView()
                    case .page: EmptyView()
                    }
                }
                .id(tab.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ApheleiaTheme.bgPrimary)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if isPage, let status = model.hoverStatus {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(ApheleiaTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(ApheleiaTheme.bgSecondary.opacity(0.95), in: UnevenRoundedRectangle(topTrailingRadius: 4))
                    .overlay(UnevenRoundedRectangle(topTrailingRadius: 4).stroke(ApheleiaTheme.border, lineWidth: 0.5))
                    .frame(maxWidth: 520, alignment: .leading)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ApheleiaTheme.bgPrimary)
        .clipped()
    }
}

private struct EngineStateOverlay: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            switch (model.browseState, model.sidecarState) {
            case (.failed(let message), _), (_, .failed(let message)):
                failed(message)
            case (.starting, _), (_, .starting):
                ProgressView().controlSize(.small)
                Text("Loading page…")
                    .foregroundStyle(ApheleiaTheme.textMuted)
            case (.ready, .ready):
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ApheleiaTheme.bgPrimary)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(ApheleiaTheme.textMuted)
            Text("The page engine isn't running")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ApheleiaTheme.textPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(ApheleiaTheme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .textSelection(.enabled)
            Button(action: model.retryServices) {
                Text("Restart engine")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .frame(height: 30)
            }
            .buttonStyle(AccentButtonStyle())
        }
    }
}

// MARK: - History

struct HistoryPanelView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter = ""

    private var entries: [HistoryEntry] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.history.entries }
        return model.history.entries.filter {
            $0.url.lowercased().contains(q) || ($0.title ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "History", subtitle: "\(model.history.entries.count) \(model.history.entries.count == 1 ? "entry" : "entries") · stored only on this Mac")

            HStack(spacing: 10) {
                OmniboxField(text: $filter, placeholder: "Search history", onSubmit: {}, focusToken: 0)
                    .frame(height: 32)
                    .frame(maxWidth: 360)
                Spacer()
                if !model.history.entries.isEmpty {
                    Button("Clear All History", role: .destructive) { model.history.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(hex: 0xF2A49A))
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 12)

            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock")
                        .font(.system(size: 36))
                        .foregroundStyle(ApheleiaTheme.textMuted)
                    Text(filter.isEmpty ? "No history yet" : "No matches")
                        .foregroundStyle(ApheleiaTheme.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            HistoryRow(entry: entry)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .background(ApheleiaTheme.bgPrimary)
    }
}

private struct HistoryRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: HistoryEntry
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            if entry.entryType == "search" {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(ApheleiaTheme.textMuted)
                    .frame(width: 16)
            } else {
                FaviconView(host: URL(string: entry.url)?.host)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title?.isEmpty == false ? entry.title! : entry.url)
                    .font(.system(size: 13))
                    .foregroundStyle(ApheleiaTheme.textPrimary)
                    .lineLimit(1)
                if entry.entryType != "search" {
                    Text(entry.url)
                        .font(.system(size: 11))
                        .foregroundStyle(ApheleiaTheme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            if hovering {
                Button { model.history.delete(entry) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ApheleiaTheme.textMuted)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Remove from history")
            }
            Text(relativeTime(entry.timestamp))
                .font(.system(size: 11))
                .foregroundStyle(ApheleiaTheme.textMuted)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? ApheleiaTheme.bgElevated : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if entry.entryType == "search" {
                model.runSearch(query: entry.url)
            } else {
                model.navigateActive(to: entry.url)
            }
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return "Just now" }
        if diff < 3600 { return "\(Int(diff / 60))m ago" }
        if diff < 86400 { return "\(Int(diff / 3600))h ago" }
        if diff < 604_800 { return "\(Int(diff / 86400))d ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Settings

struct SettingsPanelView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PanelHeader(title: "Settings", subtitle: "Customize your browsing experience")
                    .padding(.horizontal, -32)

                section("Search", "CraftRank ranks human-made, high-thought pages first.") {
                    Picker("", selection: $model.searchMode) {
                        ForEach(SearchMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }

                section("Engines", "Everything runs locally on this Mac.") {
                    VStack(alignment: .leading, spacing: 10) {
                        EngineRow(
                            name: "HTML reader",
                            role: "text pages; Chromium if that fails",
                            state: model.browseState,
                            detail: model.browseState.isReady ? model.browseVersion : nil
                        )
                        EngineRow(
                            name: "CraftRank",
                            role: "search & ranking",
                            state: model.sidecarState,
                            detail: model.sidecarState.isReady ? "127.0.0.1:\(model.sidecar.port)" : nil
                        )
                        ForEach(model.engines.filter { $0.id == "lightpanda" }) { engine in
                            EngineRow(
                                name: engine.name,
                                role: "page fetch for search",
                                state: engine.available ? .ready : .failed(engine.detail),
                                detail: engine.available ? engine.detail : nil
                            )
                        }
                        if case .failed = model.browseState {
                            retryButton
                        } else if case .failed = model.sidecarState {
                            retryButton
                        }
                    }
                }

                section("Privacy", "No ads, no tracking, no third-party services.") {
                    VStack(alignment: .leading, spacing: 8) {
                        bullet("Ad & tracker requests are blocked inside the engine (EasyList, EasyPrivacy, cookie-banner lists) before they leave the Mac.")
                        bullet("Text pages render as sanitized HTML. JS and media fall back to Chromium via Playwright.")
                        bullet("Suggestions come from your own history and bookmarks only.")
                        bullet("Favicons are fetched from the site itself, never a favicon service.")
                        HStack(spacing: 10) {
                            Button("Clear History") { model.history.clear() }
                            Button("Clear Cookies & Site Data") { model.clearSiteData() }
                        }
                        .padding(.top, 6)
                    }
                }

                section("Diagnostics", "Logs for the app, page engine, and search engine.") {
                    Button("Open Logs Folder") {
                        NSWorkspace.shared.open(AppPaths.logsDir)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .background(ApheleiaTheme.bgPrimary)
    }

    private var retryButton: some View {
        Button(action: model.retryServices) {
            Text("Restart engines")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 28)
        }
        .buttonStyle(AccentButtonStyle())
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(ApheleiaTheme.textMuted)
            Text(text).foregroundStyle(ApheleiaTheme.textSecondary)
        }
        .font(.system(size: 13))
    }

    private func section<Content: View>(
        _ title: String,
        _ description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ApheleiaTheme.textPrimary)
            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(ApheleiaTheme.textMuted)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ApheleiaTheme.bgSecondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct EngineRow: View {
    let name: String
    let role: String
    let state: ServiceState
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ApheleiaTheme.textPrimary)
            Text(role)
                .font(.system(size: 13))
                .foregroundStyle(ApheleiaTheme.textMuted)
            Spacer(minLength: 8)
            Text(statusText)
                .font(.system(size: 12))
                .foregroundStyle(ApheleiaTheme.textMuted)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private var color: Color {
        switch state {
        case .ready: return Color(hex: 0x4ADE80)
        case .starting: return Color(hex: 0xFBBF24)
        case .failed: return Color(hex: 0xF87171)
        }
    }

    private var statusText: String {
        switch state {
        case .ready: return detail ?? "running"
        case .starting: return "starting…"
        case .failed(let message): return message
        }
    }
}

struct PanelHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(ApheleiaTheme.textPrimary)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(ApheleiaTheme.textMuted)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
