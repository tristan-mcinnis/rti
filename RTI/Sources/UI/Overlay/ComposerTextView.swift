import AppKit
import HouseDesign
import RTICore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The field

/// The composer's text field: a growing, multi-line NSTextView. It asks
/// `onKey` about each key first; marked text (IME composition) always goes
/// to the text system, so Return that commits a pinyin syllable never sends.
struct ComposerTextView: NSViewRepresentable {
    enum KeyOutcome {
        case handled
        case passThrough
        case moveFocus(forward: Bool)
    }

    @Binding var text: String
    var fontSize: CGFloat
    /// Bump to put the keys in this field.
    var focusToken: Int
    var accessibilityName: String
    var onKey: (ComposerKey, ComposerKeyModifiers, Bool) -> KeyOutcome

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, focusToken: focusToken)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .automatic

        let textView = RoutingTextView()
        textView.delegate = context.coordinator
        textView.onKey = onKey
        textView.string = text
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = House.NSColorToken.textPrimary
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        textView.insertionPointColor = House.NSColorToken.textPrimary
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setAccessibilityLabel(accessibilityName)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? RoutingTextView else { return }
        context.coordinator.text = $text
        textView.onKey = onKey
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
        }
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = House.NSColorToken.textPrimary
        textView.setAccessibilityLabel(accessibilityName)
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            // One hop, so the focus change lands after the window finishes
            // its becomeKey transition and SwiftUI finishes this update.
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var focusToken: Int

        init(text: Binding<String>, focusToken: Int) {
            self.text = text
            self.focusToken = focusToken
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }

    final class RoutingTextView: NSTextView {
        var onKey: ((ComposerKey, ComposerKeyModifiers, Bool) -> KeyOutcome)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let (key, modifiers) = Self.map(event)
            if !hasMarkedText(), key == .a || key == .s, modifiers == [.command, .shift],
               let result = onKey?(key, modifiers, false), case .handled = result
            {
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func keyDown(with event: NSEvent) {
            // IME composition owns every key until it commits.
            guard !hasMarkedText(), let onKey else {
                super.keyDown(with: event)
                return
            }
            let (key, modifiers) = Self.map(event)
            switch onKey(key, modifiers, hasMarkedText()) {
            case .handled:
                return
            case .passThrough:
                super.keyDown(with: event)
            case let .moveFocus(forward):
                if forward {
                    window?.selectNextKeyView(self)
                } else {
                    window?.selectPreviousKeyView(self)
                }
            }
        }

        static func map(_ event: NSEvent) -> (ComposerKey, ComposerKeyModifiers) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var modifiers: ComposerKeyModifiers = []
            if flags.contains(.shift) {
                modifiers.insert(.shift)
            }
            if flags.contains(.command) {
                modifiers.insert(.command)
            }
            if flags.contains(.option) {
                modifiers.insert(.option)
            }
            if flags.contains(.control) {
                modifiers.insert(.control)
            }

            let key: ComposerKey = switch event.keyCode {
            case 36, 76: .returnKey
            case 53: .escape
            case 48: modifiers.contains(.shift) ? .backTab : .tab
            case 126: .upArrow
            case 125: .downArrow
            case 123: .leftArrow
            case 124: .rightArrow
            case 51: .backspace
            default:
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "k": .k
                case "a": .a
                case "s": .s
                default: .other
                }
            }
            if key == .backTab {
                modifiers.remove(.shift)
            }
            return (key, modifiers)
        }
    }
}
