import AppKit
import SwiftUI

/// AppKit-backed omnibox: a real NSTextField (reliable first responder, IME,
/// undo) styled like Apheleia's URL input, with suggestion-list key handling.
struct OmniboxField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var focusToken: Int
    var cornerRadius: CGFloat = 6
    var fontSize: CGFloat = 14
    var horizontalInset: CGFloat = 12
    var trailingInset: CGFloat = 12
    var onMove: ((Int) -> Void)? = nil
    var onEscape: (() -> Void)? = nil
    var onFocusChange: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> OmniboxContainer {
        let container = OmniboxContainer()
        let field = OmniboxTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.textColor = NSColor(ApheleiaTheme.textPrimary)
        field.font = .systemFont(ofSize: fontSize)
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.onFocus = { [weak coordinator = context.coordinator] in coordinator?.setFocused(true) }

        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.addSubview(field)
        let leading = field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontalInset)
        let trailing = field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -trailingInset)
        NSLayoutConstraint.activate([
            leading,
            trailing,
            field.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        container.field = field
        container.leadingConstraint = leading
        container.trailingConstraint = trailing
        context.coordinator.field = field
        context.coordinator.container = container
        applyPlaceholder(field)
        container.apply(focused: false, cornerRadius: cornerRadius)
        return container
    }

    private func applyPlaceholder(_ field: NSTextField) {
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor(ApheleiaTheme.placeholder),
                .font: NSFont.systemFont(ofSize: fontSize),
            ]
        )
    }

    func updateNSView(_ container: OmniboxContainer, context: Context) {
        context.coordinator.parent = self
        guard let field = container.field else { return }
        if field.placeholderAttributedString?.string != placeholder { applyPlaceholder(field) }
        if field.font?.pointSize != fontSize { field.font = .systemFont(ofSize: fontSize) }
        container.leadingConstraint?.constant = horizontalInset
        container.trailingConstraint?.constant = -trailingInset
        if field.stringValue != text, field.currentEditor() == nil {
            field.stringValue = text
        }
        container.apply(focused: context.coordinator.focused, cornerRadius: cornerRadius)

        if context.coordinator.lastFocusToken != focusToken {
            let first = context.coordinator.lastFocusToken == -1
            context.coordinator.lastFocusToken = focusToken
            if !first || focusToken > 0 {
                DispatchQueue.main.async {
                    guard let window = container.window else { return }
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(field)
                    field.currentEditor()?.selectAll(nil)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OmniboxField
        weak var field: NSTextField?
        weak var container: OmniboxContainer?
        var lastFocusToken = -1
        private(set) var focused = false

        init(_ parent: OmniboxField) {
            self.parent = parent
        }

        func setFocused(_ value: Bool) {
            guard focused != value else { return }
            focused = value
            container?.apply(focused: value, cornerRadius: parent.cornerRadius)
            parent.onFocusChange?(value)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            setFocused(true)
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            setFocused(true)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            setFocused(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = textView.string
                parent.onSubmit()
                return true
            case #selector(NSResponder.moveDown(_:)):
                guard let onMove = parent.onMove else { return false }
                onMove(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                guard let onMove = parent.onMove else { return false }
                onMove(-1)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape?()
                return parent.onEscape != nil
            default:
                return false
            }
        }
    }
}

final class OmniboxTextField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }
}

final class OmniboxContainer: NSView {
    weak var field: NSTextField?
    var leadingConstraint: NSLayoutConstraint?
    var trailingConstraint: NSLayoutConstraint?

    override var acceptsFirstResponder: Bool { true }

    func apply(focused: Bool, cornerRadius: CGFloat) {
        guard let layer else { return }
        layer.cornerRadius = cornerRadius
        layer.backgroundColor = NSColor(focused ? ApheleiaTheme.urlBarFocus : ApheleiaTheme.urlBar).cgColor
        layer.borderWidth = focused ? 2 : 0
        layer.borderColor = NSColor(ApheleiaTheme.accent).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        guard let field else { return }
        if window?.firstResponder !== field.currentEditor() {
            window?.makeFirstResponder(field)
        }
        super.mouseDown(with: event)
    }
}
