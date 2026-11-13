import AppKit
import SwiftUI

/// The picker keeps search editing in the native field editor. Grid selection
/// starts only with vertical navigation and never wraps past a result boundary.
enum NativeEmojiPickerNavigation {
    enum Command { case up, down, left, right, submit, cancel }

    static func move(selected: Int?, count: Int, columns: Int = 8, command: Command) -> Int? {
        guard count > 0, columns > 0 else { return nil }
        let current = selected.flatMap { (0..<count).contains($0) ? $0 : nil }
        guard let current else {
            switch command {
            case .down: return 0
            case .up: return count - 1
            default: return nil
            }
        }
        switch command {
        case .up: return max(0, current - columns)
        case .down: return min(count - 1, current + columns)
        case .left: return max(0, current - 1)
        case .right: return min(count - 1, current + 1)
        default: return current
        }
    }

    static func submissionIndex(selected: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        if let selected, (0..<count).contains(selected) { return selected }
        return 0
    }
}

struct NativeEmojiPickerSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let label: String
    var placeholder = "Search emoji"
    let command: (NativeEmojiPickerNavigation.Command) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(string: text)
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.setAccessibilityLabel(label)
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(label)
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true, field.stringValue != text {
            field.stringValue = text
        }
        if focused, field.currentEditor() == nil {
            DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
                guard let field, coordinator?.parent.focused == true else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }
    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) { field.delegate = nil }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeEmojiPickerSearchField
        init(_ parent: NativeEmojiPickerSearchField) { self.parent = parent }
        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
        func controlTextDidBeginEditing(_ note: Notification) {
            DispatchQueue.main.async { [weak self] in self?.parent.focused = true }
        }
        func controlTextDidEndEditing(_ note: Notification) {
            DispatchQueue.main.async { [weak self] in self?.parent.focused = false }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // IME candidates and modified arrows belong to AppKit. In
            // particular, Shift-arrow must continue selecting search text.
            guard !textView.hasMarkedText() else { return false }
            let modifiers = NSApp.currentEvent?.modifierFlags.intersection([.command, .control, .option, .shift]) ?? []
            guard modifiers.isEmpty else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)): return parent.command(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.command(.down)
            case #selector(NSResponder.moveLeft(_:)): return parent.command(.left)
            case #selector(NSResponder.moveRight(_:)): return parent.command(.right)
            case #selector(NSResponder.insertNewline(_:)): return parent.command(.submit)
            case #selector(NSResponder.cancelOperation(_:)): return parent.command(.cancel)
            default: return false
            }
        }
    }
}
