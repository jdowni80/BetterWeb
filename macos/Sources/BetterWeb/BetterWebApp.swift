import AppKit
import SwiftUI

@main
struct BetterWebApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            BrowserShellView()
                .environmentObject(appDelegate.model)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 860)
        .commands { BrowserCommands(model: appDelegate.model) }
    }
}

private struct BrowserCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { model.newTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Tab in Group") { model.newTab(inGroup: model.groupID(containing: model.activeTabID), after: model.activeTabID) }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("New Group") { model.newGroup() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Close Tab") { model.closeActiveTab() }
                .keyboardShortcut("w", modifiers: .command)
            Button("Reopen Closed Tab") { model.restoreClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!model.hasClosedTabs)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Page Link") { model.copyActiveURL() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button(model.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") { model.sidebarCollapsed.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Divider()
            Button("Reload Page") { model.reload() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { model.setZoom(nil) }
                .keyboardShortcut("0", modifiers: .command)
        }
        CommandMenu("Go") {
            Button("Back") { model.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canGoBack(model.activeTab))
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.canGoForward(model.activeTab))
            Button("Back ") { model.goBack() }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                .disabled(!model.canGoBack(model.activeTab))
            Button("Forward ") { model.goForward() }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                .disabled(!model.canGoForward(model.activeTab))
            Divider()
            Button("Focus Address Bar") { model.requestOmniboxFocus() }
                .keyboardShortcut("l", modifiers: .command)
            Button("Search") { model.requestOmniboxFocus() }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("History") { model.showHistory() }
                .keyboardShortcut("y", modifiers: .command)
            Button("Settings…") { model.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("Tab") {
            Button("Previous Tab") { model.selectAdjacentTab(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next Tab") { model.selectAdjacentTab(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Tab ") { model.selectAdjacentTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab ") { model.selectAdjacentTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Divider()
            ForEach(1...9, id: \.self) { n in
                Button(n == 9 ? "Last Tab" : "Tab \(n)") { model.selectTab(atIndex: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
            Divider()
            Button(model.activeTab.pinned ? "Unpin Tab" : "Pin Tab") { model.togglePin(model.activeTabID) }
            Button(model.activeIsBookmarked ? "Remove Bookmark" : "Bookmark Tab") { model.toggleBookmarkActive() }
                .keyboardShortcut("d", modifiers: .command)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Writes to a dead helper's stdin must fail with EPIPE, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        // Unbundled (swift run) executables otherwise stay background apps that never get key events.
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
        }
        AppLog.info("BetterWeb launched bundle=\(Bundle.main.bundlePath)")
        if ProcessInfo.processInfo.environment["BETTERWEB_DEBUG"] == "1" {
            DebugHooks.install(model: model)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Window chrome: transparent title bar, dark appearance, traffic lights hidden
/// with the sidebar (as in Apheleia).
struct WindowAccessor: NSViewRepresentable {
    var sidebarCollapsed: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(ApheleiaTheme.bgPrimary)
        window.appearance = NSAppearance(named: .darkAqua)
        window.tabbingMode = .disallowed
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = sidebarCollapsed
        }
    }
}
