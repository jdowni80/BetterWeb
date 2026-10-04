import AppKit
import SwiftUI

/// Apheleia's dark theme, value for value.
enum ApheleiaTheme {
    static let bgPrimary = Color(hex: 0x282828)
    static let bgSecondary = Color(hex: 0x1E1E1E)
    static let bgElevated = Color(hex: 0x2D2D2D)
    static let bgHover = Color(hex: 0x2A2A2A)
    static let bgActiveTab = Color(hex: 0x37373D)
    static let border = Color(hex: 0x3A3A3A)
    static let navGroupHover = Color(hex: 0x3D3D3D)
    static let navButtonHover = Color(hex: 0x4D4D4D)
    static let rowButtonHover = Color(hex: 0x4A4A4A)
    static let textPrimary = Color(hex: 0xE8E8E8)
    static let textSecondary = Color(hex: 0xCCCCCC)
    static let textMuted = Color(hex: 0x888888)
    static let textFaint = Color(hex: 0x666666)
    static let placeholder = Color(hex: 0x6B7280)
    static let urlBar = Color(hex: 0x16213E)
    static let urlBarFocus = Color(hex: 0x1F2F50)
    static let accent = Color(hex: 0x4A6FA5)
    static let accentHover = Color(hex: 0x5A7FB5)
    static let accentPressed = Color(hex: 0x3A5F95)
    static let link = Color(hex: 0x8AB0E6)
    static let pin = Color(hex: 0xEAB308)
    static let dropIndicator = Color(hex: 0x3B82F6)
    static let suggestBg = Color(hex: 0x1E1E2E)
    static let suggestBorder = Color(hex: 0x313244)
    static let suggestText = Color(hex: 0xCDD6F4)
    static let suggestIcon = Color(hex: 0x6C7086)

    static let barHeight: CGFloat = 80
    static let sidebarWidth: CGFloat = 240
    static let trafficLightPad: CGFloat = 52
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

/// Apheleia nav button: 28×28, rounded, #4d4d4d on hover, 40% when disabled.
struct ChromeIconButton: View {
    let systemName: String
    var enabled: Bool = true
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ApheleiaTheme.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hovering && enabled ? ApheleiaTheme.navButtonHover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Square 32pt chrome button on the secondary background (sidebar toggle, menu).
struct ChromeSquareButton<Label: View>: View {
    var help: String = ""
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(ApheleiaTheme.textSecondary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering ? ApheleiaTheme.navGroupHover : ApheleiaTheme.bgSecondary)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Accent button with Apheleia's hover / pressed shades.
struct AccentButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        AccentButtonBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct AccentButtonBody: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(configuration.isPressed ? ApheleiaTheme.accentPressed
                              : hovering ? ApheleiaTheme.accentHover : ApheleiaTheme.accent)
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Lets empty chrome areas drag the window (the title bar is hidden), double-click zooms.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

/// Favicon fetched from the site itself — never through a third-party favicon service.
struct FaviconView: View {
    let host: String?
    var size: CGFloat = 16

    var body: some View {
        if let host, let url = URL(string: "https://\(host)/favicon.ico") {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().interpolation(.high).frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                } else {
                    globe
                }
            }
            .frame(width: size, height: size)
        }
    }

    private var globe: some View {
        Image(systemName: "globe")
            .font(.system(size: size * 0.8))
            .foregroundStyle(ApheleiaTheme.textMuted)
            .frame(width: size, height: size)
    }
}
