import AppKit

/// Development-only hooks (enabled with BETTERWEB_DEBUG=1). Post the distributed
/// notification `dev.betterweb.debug` with an `action` in userInfo:
///   snapshot — write the window to ~/Library/Logs/BetterWeb/snapshot.png
///   omnibox:<text> / navigate:<url> / newtab / sidebar
@MainActor
enum DebugHooks {
    private static var observer: NSObjectProtocol?

    static func install(model: AppModel) {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.betterweb.debug"), object: nil, queue: .main
        ) { note in
            let action = (note.object as? String) ?? ""
            MainActor.assumeIsolated { handle(action, model: model) }
        }
        AppLog.info("debug hooks installed")
    }

    private static func handle(_ action: String, model: AppModel) {
        AppLog.info("debug action: \(action)")
        if action == "snapshot" {
            snapshot()
        } else if action == "newtab" {
            model.newTab()
        } else if action == "sidebar" {
            model.sidebarCollapsed.toggle()
        } else if action.hasPrefix("omnibox:") {
            model.submitOmnibox(String(action.dropFirst("omnibox:".count)))
        } else if action.hasPrefix("navigate:") {
            model.navigateActive(to: String(action.dropFirst("navigate:".count)))
        } else if action.hasPrefix("select:"), let i = Int(action.dropFirst("select:".count)) {
            model.selectTab(atIndex: i)
        } else if action.hasPrefix("type:") {
            for ch in action.dropFirst("type:".count) { sendKey(String(ch)) }
        } else if action.hasPrefix("key:") {
            // key:<keyCode>:<chars>[:cmd]
            let parts = action.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count >= 3, let code = UInt16(parts[1]) {
                sendKey(String(parts[2]), keyCode: code, flags: parts.count > 3 ? [.command] : [])
            }
        } else if action.hasPrefix("scroll:"), let dy = Int32(action.dropFirst("scroll:".count)) {
            sendScroll(dy: dy)
        } else if action.hasPrefix("click:") {
            let xy = action.dropFirst("click:".count).split(separator: ",").compactMap { Double($0) }
            if xy.count == 2 { sendClick(CGPoint(x: xy[0], y: xy[1])) }
        } else if action == "responder" {
            let r = NSApp.keyWindow?.firstResponder
            AppLog.info("key window=\(NSApp.keyWindow != nil) active=\(NSApp.isActive) firstResponder=\(String(describing: r))")
        }
    }

    private static var window: NSWindow? {
        NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })
    }

    private static func sendKey(_ chars: String, keyCode: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
        guard let window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode
            ) {
                NSApp.sendEvent(event)
            }
        }
    }

    /// Point in window coordinates from the top-left (like the screenshot).
    private static func sendClick(_ topLeft: CGPoint) {
        guard let window else { return }
        let p = NSPoint(x: topLeft.x, y: window.frame.height - topLeft.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) {
                NSApp.sendEvent(event)
            }
        }
    }

    private static func sendScroll(dy: Int32) {
        guard let window,
              let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)
        else { return }
        let content = window.contentView?.bounds ?? .zero
        let local = NSPoint(x: content.midX + 120, y: content.midY)
        let screen = window.convertPoint(toScreen: local)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screen.x, y: mainHeight - screen.y)
        if let event = NSEvent(cgEvent: cg) {
            window.sendEvent(event)
        }
    }

    private static func snapshot() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }),
              let image = CGWindowListCreateImage(
                .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]
              ) else {
            AppLog.info("snapshot failed")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        let url = AppPaths.logsDir.appendingPathComponent("snapshot.png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        AppLog.info("snapshot written \(image.width)x\(image.height)")
    }
}
