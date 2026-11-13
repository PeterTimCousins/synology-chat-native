import AppKit
import SwiftUI

enum NativeQuickSwitchKeys {
    static func matches(_ characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        let relevant = modifiers.intersection([.command, .control, .option, .shift])
        return characters?.lowercased() == "k" && (relevant == .command || relevant == .control)
    }
}
/// This monitor sees this app's own events only and is bound to its hosting window.
struct NativeQuickSwitchKeysView: NSViewRepresentable {
    let connected: Bool
    let presented: Bool
    let action: () -> Void
    func makeNSView(context: Context) -> KeyView { let view = KeyView(); view.parent = self; view.install(); return view }
    func updateNSView(_ view: KeyView, context: Context) { view.parent = self }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.uninstall() }
    final class KeyView: NSView {
        var parent: NativeQuickSwitchKeysView?
        private var monitor: Any?
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let parent, parent.connected, let window = self.window,
                      NativeQuickSwitchKeys.matches(event.charactersIgnoringModifiers, modifiers: event.modifierFlags) else { return event }
                let target = window.attachedSheet ?? window
                guard NSApp.keyWindow === target, event.window === target, window.attachedSheet == nil || parent.presented else { return event }
                if (target.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
                if !event.isARepeat { parent.action() }
                return nil
            }
        }
        func uninstall() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
struct NativeQuickSwitchSearch: NSViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(); field.placeholderString = "Jump to a conversation or channel"; field.font = .systemFont(ofSize: 17)
        field.delegate = context.coordinator; field.setAccessibilityLabel("Quick switch search"); field.focusRingType = .none
        context.coordinator.field = field; return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self; field.isEnabled = enabled
        if field.stringValue != text { field.stringValue = text }
        if enabled && !context.coordinator.focused {
            context.coordinator.focused = true
            DispatchQueue.main.async { [weak field] in if let field, field.window != nil { field.window?.makeFirstResponder(field) } }
        }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeQuickSwitchSearch
        weak var field: NSSearchField?
        var focused = false
        init(_ parent: NativeQuickSwitchSearch) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) { if let field { parent.text = field.stringValue } }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.pageUp(_:)): parent.move(-10)
            case #selector(NSResponder.pageDown(_:)): parent.move(10)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
}
