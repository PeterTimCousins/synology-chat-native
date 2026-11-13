import AppKit
import SwiftUI

enum NativeSearchFieldCommand { case previous, next, tab, submit, cancel }

/// Standard AppKit search editing, including field-editor selection and IME.
/// Only completion/navigation commands are intercepted; normal text shortcuts
/// and marked-text composition remain owned by the system field editor.
struct NativeSearchTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var focused: Bool
    let placeholder: String
    let command: (NativeSearchFieldCommand) -> Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context:Context) -> NSSearchField {
        let field = NSSearchField(string:text)
        field.placeholderString = placeholder;field.font = .systemFont(ofSize:13)
        field.isBezeled = false;field.isBordered = false;field.drawsBackground = false;field.focusRingType = .none
        field.setAccessibilityLabel("Search message text")
        field.delegate = context.coordinator;context.coordinator.field = field
        return field
    }
    func updateNSView(_ field:NSSearchField,context:Context) {
        let coordinator = context.coordinator;coordinator.parent = self;coordinator.updating = true
        defer { coordinator.updating = false }
        let editor = field.currentEditor() as? NSTextView
        if editor?.hasMarkedText() != true {
            if field.stringValue != text { field.stringValue = text }
            let range = ChatComposerEdit.validRange(selection,in:text) == nil ? NSRange(location:text.utf16.count,length:0) : selection
            if let editor,editor.selectedRange() != range { editor.setSelectedRange(range) }
        }
        if focused,field.currentEditor() == nil {
            DispatchQueue.main.async { [weak field,weak coordinator] in
                guard let field,let coordinator,coordinator.parent.focused else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }
    static func dismantleNSView(_ field:NSSearchField,coordinator:Coordinator) {
        field.delegate = nil;coordinator.field = nil;field.stringValue = ""
    }
    final class Coordinator:NSObject,NSSearchFieldDelegate {
        var parent:NativeSearchTextField
        weak var field:NSSearchField?
        var updating = false
        init(_ parent:NativeSearchTextField) {
            self.parent = parent;super.init()
            NotificationCenter.default.addObserver(self,selector:#selector(selectionChanged(_:)),name:NSTextView.didChangeSelectionNotification,object:nil)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        @objc private func selectionChanged(_ note:Notification) {
            guard !updating,let editor = note.object as? NSTextView,editor === field?.currentEditor() else { return }
            parent.selection = editor.selectedRange()
        }
        func controlTextDidBeginEditing(_ note:Notification) { DispatchQueue.main.async { [weak self] in self?.parent.focused = true } }
        func controlTextDidEndEditing(_ note:Notification) { DispatchQueue.main.async { [weak self] in self?.parent.focused = false } }
        func controlTextDidChange(_ note:Notification) {
            guard !updating,let field = note.object as? NSSearchField else { return }
            parent.text = field.stringValue
            parent.selection = field.currentEditor()?.selectedRange ?? NSRange(location:field.stringValue.utf16.count,length:0)
        }
        func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)):return parent.command(.previous)
            case #selector(NSResponder.moveDown(_:)):return parent.command(.next)
            case #selector(NSResponder.insertTab(_:)):return parent.command(.tab)
            case #selector(NSResponder.insertNewline(_:)):return parent.command(.submit)
            case #selector(NSResponder.cancelOperation(_:)):return parent.command(.cancel)
            default:return false
            }
        }
    }
}
