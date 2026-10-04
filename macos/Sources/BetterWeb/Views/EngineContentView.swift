import AppKit
import SwiftUI

/// Embeds the engine's host view; it swaps in the active tab's `BWWebView`, which renders
/// Ladybird's compositor output and takes real AppKit input directly.
struct EngineContentView: NSViewRepresentable {
    @EnvironmentObject private var model: AppModel

    func makeNSView(context: Context) -> EngineHostView {
        model.browse.host
    }

    func updateNSView(_ view: EngineHostView, context: Context) {}
}
