import AppKit
import SwiftUI

/// Embeds the engine host; the active tab's page view shows sidecar HTML
/// (Playwright/Chromium when the text fetch is not enough).
struct EngineContentView: NSViewRepresentable {
    @EnvironmentObject private var model: AppModel

    func makeNSView(context: Context) -> EngineHostView {
        model.browse.host
    }

    func updateNSView(_ view: EngineHostView, context: Context) {}
}
