import AppKit
import SwiftUI

/// Apheleia's 80pt top bar: sidebar toggle, nav group, URL input + Go, menu.
struct TopBarView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var omnibox = OmniboxController()
    @State private var navHover = false

    var body: some View {
        let tab = model.activeTab
        let rt = model.activeRuntime

        HStack(spacing: 12) {
            ChromeSquareButton(help: "Toggle sidebar (⌥⌘S)", action: { model.sidebarCollapsed.toggle() }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .medium))
            }

            HStack(spacing: 4) {
                ChromeIconButton(systemName: "chevron.left", enabled: model.canGoBack(tab), help: "Back (⌘[)") {
                    model.goBack()
                }
                ChromeIconButton(systemName: "chevron.right", enabled: model.canGoForward(tab), help: "Forward (⌘])") {
                    model.goForward()
                }
                ChromeIconButton(systemName: rt.loading && tab.pageURL != nil ? "xmark" : "arrow.clockwise", help: "Reload (⌘R)") {
                    model.reload()
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(navHover ? ApheleiaTheme.navGroupHover : .clear))
            .onHover { navHover = $0 }

            HStack(spacing: 8) {
                ZStack(alignment: .trailing) {
                    OmniboxField(
                        text: $omnibox.text,
                        placeholder: "Enter URL or search...",
                        onSubmit: submit,
                        focusToken: model.omniboxFocusToken,
                        trailingInset: tab.pageURL != nil ? 64 : 12,
                        onMove: { omnibox.move($0) },
                        onEscape: escape,
                        onFocusChange: { focused in
                            omnibox.focused = focused
                            if !focused { omnibox.dismiss() }
                        }
                    )
                    .onChange(of: omnibox.text) { _, _ in
                        if omnibox.focused { omnibox.edited(model) }
                    }

                    if tab.pageURL != nil {
                        HStack(spacing: 6) {
                            ShieldBadge(count: rt.blocked)
                            Button { model.toggleBookmarkActive() } label: {
                                Image(systemName: model.activeIsBookmarked ? "star.fill" : "star")
                                    .font(.system(size: 12))
                                    .foregroundStyle(model.activeIsBookmarked ? ApheleiaTheme.pin : ApheleiaTheme.textMuted)
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Bookmark (⌘D)")
                        }
                        .padding(.trailing, 8)
                    }
                }
                .frame(height: 32)
                .overlay(alignment: .topLeading) {
                    if omnibox.showsSuggestions {
                        SuggestionsView(
                            suggestions: omnibox.suggestions,
                            selected: omnibox.selection,
                            onPick: { pick($0) },
                            onHover: { omnibox.selection = $0 }
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(y: 38)
                        .zIndex(10)
                    }
                }
                .zIndex(10)

                Button(action: submit) {
                    Text("Go")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                }
                .buttonStyle(AccentButtonStyle())
            }
            .zIndex(10)

            Menu {
                Button("New Tab") { model.newTab() }
                Button("New Group") { model.newGroup() }
                Divider()
                Button("History") { model.showHistory() }
                Button("Settings") { model.showSettings() }
                Divider()
                Picker("Search", selection: $model.searchMode) {
                    ForEach(SearchMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
                if tab.pageURL != nil {
                    Divider()
                    Button("Copy Link") { model.copyActiveURL() }
                    Button(model.activeIsBookmarked ? "Remove Bookmark" : "Bookmark Page") { model.toggleBookmarkActive() }
                    Button("Zoom In") { model.zoomIn() }
                    Button("Zoom Out") { model.zoomOut() }
                    Button("Actual Size") { model.setZoom(nil) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ApheleiaTheme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(ApheleiaTheme.bgSecondary, in: RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 32, height: 32)
        }
        .padding(.horizontal, 12)
        .frame(height: ApheleiaTheme.barHeight)
        .background(WindowDragArea())
        .background(ApheleiaTheme.bgPrimary)
        .overlay(alignment: .bottom) {
            LoadingBar(active: rt.loading && tab.pageURL != nil)
        }
        .overlay {
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(ApheleiaTheme.accent, in: RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.toast)
        .zIndex(10)
        .onAppear { omnibox.text = tab.address }
        .onChange(of: model.activeTabID) { _, _ in
            omnibox.dismiss()
            omnibox.text = model.activeTab.address
        }
        .onChange(of: tab.address) { _, newValue in
            if !omnibox.focused { omnibox.text = newValue }
        }
    }

    private func submit() {
        let value = omnibox.submission
        omnibox.dismiss()
        omnibox.text = value
        model.submitOmnibox(value)
        if AppModel.urlIfNavigable(value) != nil || value.lowercased().hasPrefix("betterweb://") {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func pick(_ suggestion: Suggestion) {
        omnibox.dismiss()
        omnibox.text = suggestion.value
        model.submitOmnibox(suggestion.value)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func escape() {
        if omnibox.showsSuggestions {
            omnibox.dismiss()
        } else {
            omnibox.text = model.activeTab.address
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
}

/// Blocked trackers/ads on the current page.
private struct ShieldBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: count > 0 ? "shield.lefthalf.filled" : "shield")
                .font(.system(size: 11, weight: .semibold))
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
        }
        .foregroundStyle(count > 0 ? Color(hex: 0x7FB77E) : ApheleiaTheme.textMuted)
        .padding(.horizontal, 5)
        .frame(height: 20)
        .background(count > 0 ? Color(hex: 0x7FB77E, opacity: 0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .help(count > 0 ? "\(count) ads and trackers blocked on this page" : "No trackers seen on this page")
    }
}

/// Thin indeterminate progress line under the top bar while a page loads.
private struct LoadingBar: View {
    let active: Bool
    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { geo in
            if active {
                Rectangle()
                    .fill(ApheleiaTheme.accent)
                    .frame(width: geo.size.width * 0.3, height: 2)
                    .offset(x: geo.size.width * phase)
                    .onAppear {
                        phase = -0.3
                        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                            phase = 1.0
                        }
                    }
            }
        }
        .frame(height: 2)
        .clipped()
        .allowsHitTesting(false)
    }
}
