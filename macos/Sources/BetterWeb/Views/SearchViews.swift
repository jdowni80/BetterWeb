import AppKit
import SwiftUI

/// Apheleia's homepage: centered rounded search (pt-16, max-w-2xl, h-14) and bookmarks.
struct NewTabSearchView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var omnibox = OmniboxController()
    @State private var focusToken = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                ZStack(alignment: .trailing) {
                    OmniboxField(
                        text: $omnibox.text,
                        placeholder: "Search the web or enter a URL",
                        onSubmit: submit,
                        focusToken: focusToken,
                        cornerRadius: 28,
                        fontSize: 16,
                        horizontalInset: 24,
                        trailingInset: 56,
                        onMove: { omnibox.move($0) },
                        onEscape: { omnibox.dismiss() },
                        onFocusChange: { focused in
                            omnibox.focused = focused
                            if !focused { omnibox.dismiss() }
                        }
                    )
                    .onChange(of: omnibox.text) { _, _ in
                        if omnibox.focused { omnibox.edited(model) }
                    }
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)

                    Button(action: submit) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(AccentButtonStyle(cornerRadius: 16))
                    .padding(.trailing, 12)
                }
                .frame(height: 56)
                .overlay(alignment: .topLeading) {
                    if omnibox.showsSuggestions {
                        SuggestionsView(
                            suggestions: omnibox.suggestions,
                            selected: omnibox.selection,
                            onPick: { s in
                                omnibox.dismiss()
                                model.submitOmnibox(s.value)
                            },
                            onHover: { omnibox.selection = $0 }
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(y: 64)
                    }
                }
                .frame(maxWidth: 672)
                .zIndex(10)

                Text("CraftRank local index · human-made pages first · no ads, no tracking")
                    .font(.system(size: 12))
                    .foregroundStyle(ApheleiaTheme.textMuted)
                    .padding(.top, -16)

                BookmarksSection()
                    .frame(maxWidth: 1152)
            }
            .padding(.top, 64)
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .background(ApheleiaTheme.bgPrimary)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focusToken += 1 }
        }
    }

    private func submit() {
        let value = omnibox.submission
        omnibox.dismiss()
        model.submitOmnibox(value)
    }
}

private struct BookmarksSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bookmarks")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ApheleiaTheme.textSecondary)

            if model.bookmarks.bookmarks.isEmpty {
                Text("No bookmarks yet. Use ⌘D to bookmark the current tab.")
                    .font(.system(size: 14))
                    .foregroundStyle(ApheleiaTheme.textSecondary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(model.bookmarks.bookmarks.prefix(10)) { bookmark in
                        BookmarkChip(bookmark: bookmark)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BookmarkChip: View {
    @EnvironmentObject private var model: AppModel
    let bookmark: Bookmark
    @State private var hovering = false

    var body: some View {
        Button {
            model.navigateActive(to: bookmark.url)
        } label: {
            HStack(spacing: 8) {
                FaviconView(host: URL(string: bookmark.url)?.host)
                Text(bookmark.title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(ApheleiaTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(ApheleiaTheme.bgSecondary, in: RoundedRectangle(cornerRadius: 4))
            .opacity(hovering ? 0.8 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(bookmark.url)
        .contextMenu {
            Button("Open in New Tab") { model.openInNewTab(url: bookmark.url, from: model.activeTabID, activate: true) }
            Button("Remove Bookmark", role: .destructive) { model.bookmarks.remove(bookmark) }
        }
    }
}

/// Wrapping row layout (Tailwind `flex flex-wrap`).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Results

struct SearchResultsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let state = model.searches[model.activeTabID]

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let state {
                    header(state)
                    if state.busy {
                        ForEach(0..<5, id: \.self) { _ in SkeletonResult() }
                    } else if let error = state.error {
                        MessageBox(
                            title: "Search didn't finish",
                            detail: error,
                            action: ("Try again", { model.reload() })
                        )
                    } else if state.hits.isEmpty {
                        MessageBox(
                            title: "No results for “\(state.query)”",
                            detail: "The local index has nothing for this. Crawl more pages, or try different words.",
                            action: nil
                        )
                    } else {
                        ForEach(state.hits) { hit in
                            ResultRow(hit: hit)
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ApheleiaTheme.bgPrimary)
    }

    private func header(_ state: SearchState) -> some View {
        HStack(spacing: 10) {
            Text(state.busy ? "Searching…" : "\(state.hits.count) result\(state.hits.count == 1 ? "" : "s")")
                .font(.system(size: 13))
                .foregroundStyle(ApheleiaTheme.textMuted)
            Text(state.mode.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ApheleiaTheme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(ApheleiaTheme.bgElevated, in: Capsule())
            if case .starting = model.sidecarState {
                Text("starting search engine…")
                    .font(.system(size: 12))
                    .foregroundStyle(ApheleiaTheme.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

private struct ResultRow: View {
    @EnvironmentObject private var model: AppModel
    let hit: SearchHit
    @State private var hovering = false

    private var host: String { URL(string: hit.url)?.host ?? hit.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                FaviconView(host: URL(string: hit.url)?.host, size: 14)
                Text(host)
                    .font(.system(size: 12))
                    .foregroundStyle(ApheleiaTheme.textMuted)
                    .lineLimit(1)
            }
            Text(hit.title.isEmpty ? hit.url : hit.title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(ApheleiaTheme.link)
                .underline(hovering, color: ApheleiaTheme.link)
                .lineLimit(2)
            if !hit.snippet.isEmpty {
                Text(hit.snippet)
                    .font(.system(size: 13.5))
                    .foregroundStyle(ApheleiaTheme.textSecondary)
                    .lineSpacing(2)
                    .lineLimit(3)
            }
            if !hit.badges.isEmpty || hovering {
                HStack(spacing: 6) {
                    ForEach(hit.badges, id: \.self) { BadgeView(badge: $0) }
                    Spacer(minLength: 0)
                    if hovering {
                        Text(String(format: "craft %.2f · score %.2f", hit.craft, hit.betterweb_score))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(ApheleiaTheme.textFaint)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? ApheleiaTheme.bgElevated : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            let newTab = NSEvent.modifierFlags.contains(.command)
            model.openHit(hit, newTab: newTab)
        }
        .contextMenu {
            Button("Open") { model.openHit(hit) }
            Button("Open in New Tab") { model.openHit(hit, newTab: true) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hit.url, forType: .string)
            }
        }
        .help(hit.url)
    }
}

private struct BadgeView: View {
    let badge: String

    var body: some View {
        let (fg, bg) = colors
        Text(badge.replacingOccurrences(of: "_", with: " "))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(bg, in: Capsule())
    }

    private var colors: (Color, Color) {
        switch badge {
        case "ai_slop", "bot_spam", "propaganda", "malicious":
            return (Color(hex: 0xF2A49A), Color(hex: 0xF2A49A, opacity: 0.12))
        case "human_craft", "high_thought":
            return (Color(hex: 0x8FCB8E), Color(hex: 0x8FCB8E, opacity: 0.12))
        case "rare_gem", "niche":
            return (Color(hex: 0xE5C07B), Color(hex: 0xE5C07B, opacity: 0.12))
        default:
            return (ApheleiaTheme.textSecondary, ApheleiaTheme.bgElevated)
        }
    }
}

private struct SkeletonResult: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            bar(width: 140, height: 10)
            bar(width: 380, height: 16)
            bar(width: nil, height: 11)
            bar(width: 300, height: 11)
        }
        .padding(12)
        .opacity(pulse ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(), value: pulse)
        .onAppear { pulse = true }
    }

    private func bar(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(ApheleiaTheme.bgElevated)
            .frame(maxWidth: width ?? .infinity)
            .frame(width: width, height: height)
    }
}

struct MessageBox: View {
    let title: String
    let detail: String
    let action: (String, () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ApheleiaTheme.textPrimary)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(ApheleiaTheme.textMuted)
                .textSelection(.enabled)
            if let action {
                Button(action: action.1) {
                    Text(action.0)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                }
                .buttonStyle(AccentButtonStyle())
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ApheleiaTheme.bgSecondary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
    }
}
