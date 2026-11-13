import AppKit
import SwiftUI

/// Edits use UTF-16 ranges, matching NSTextView and Synology's string offsets.
/// Invalid/stale selections fall back to the end without splitting a surrogate.
enum ChatComposerEdit {
    struct Result: Equatable { let text: String; let selection: NSRange }
    static func validRange(_ selection: NSRange, in text: String) -> Range<String.Index>? {
        let count = text.utf16.count
        guard selection.location >= 0, selection.length >= 0, selection.location <= count,
              selection.length <= count - selection.location, let range = Range(selection, in: text) else { return nil }
        let boundaries = Set(text.indices).union([text.endIndex])
        return boundaries.contains(range.lowerBound) && boundaries.contains(range.upperBound) ? range : nil
    }
    static func insert(_ token: String, into text: String, selection: NSRange, separated: Bool = false) -> Result {
        let valid = validRange(selection, in: text)
        let range = valid ?? text.endIndex..<text.endIndex
        let prefix = text[..<range.lowerBound]; let suffix = text[range.upperBound...]
        let before = separated && prefix.last.map({ !$0.isWhitespace }) == true ? " " : ""
        let after = separated && (suffix.first.map({ !$0.isWhitespace }) ?? true) ? " " : ""
        let value = before + token + after
        let edited = String(prefix) + value + String(suffix)
        let existingSeparator = separated && after.isEmpty && suffix.first?.isWhitespace == true ? String(suffix.first!).utf16.count : 0
        return .init(text: edited, selection: NSRange(location: prefix.utf16.count + value.utf16.count + existingSeparator, length: 0))
    }
}

/// Plain native editing with an explicit selection binding. Local undo history
/// belongs to this composer instance, never another conversation or editor.
enum NativeComposerCompletionKey { case previous, next, accept, dismiss }

struct NativeComposerText: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var focused: Binding<Bool>
    let label: String
    var help = "Drop files or paste an image to review attachments before sending."
    var onAttachmentInput:((NativeComposerAttachmentInput)->Void)? = nil
    var onCompletionKey: ((NativeComposerCompletionKey) -> Bool)? = nil
    var onHeightChanged:((CGFloat)->Void)? = nil
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        makeComposerView(coordinator:context.coordinator)
    }
    /// Shared native construction for hidden lifecycle checks.
    func makeComposerView(coordinator:Coordinator)->SizingScroll {
        let scroll = SizingScroll()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let view = ComposerTextView(frame: .zero)
        view.isRichText = false; view.allowsUndo = true; view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.font = .systemFont(ofSize: 14); view.textColor = NSColor.labelColor
        view.insertionPointColor = .labelColor; view.textContainerInset = NSSize(width: 4, height: 4)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.string = text
        view.delegate = coordinator
        view.registerForDraggedTypes(NativeComposerAttachmentReader.types)
        view.setAccessibilityHelp(help)
        view.onAttachmentInput = { [weak coordinator] input in
            guard let coordinator,coordinator.parent.enabled else { return }
            coordinator.parent.onAttachmentInput?(input)
        }
        view.onCompletionKey = { [weak coordinator] key in
            guard let coordinator, coordinator.parent.enabled else { return false }
            return coordinator.parent.onCompletionKey?(key) ?? false
        }
        view.onFormat = { [weak coordinator] style in
            guard let coordinator, coordinator.parent.enabled else { return }
            let edit = ChatComposerEdit.format(style,text:coordinator.parent.text,selection:coordinator.parent.selection)
            coordinator.parent.text = edit.text; coordinator.parent.selection = edit.selection
            coordinator.parent.focused.wrappedValue = true
        }
        view.onFocusChanged = { [weak coordinator] active in
            DispatchQueue.main.async { coordinator?.parent.focused.wrappedValue = active }
        }
        scroll.documentView = view
        view.setAccessibilityLabel(label)
        coordinator.configureHeightReporter(scroll:scroll,view:view)
        return scroll
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.detachHeightReporter()
        guard let view = scroll.documentView as? ComposerTextView else { return }
        view.onCompletionKey = nil; view.delegate = nil; view.onFocusChanged = nil; view.onFormat = nil;view.onAttachmentInput = nil;view.unregisterDraggedTypes()
        view.undoManager?.removeAllActions(); view.string = ""
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerTextView else { return }
        context.coordinator.updating = true
        defer { context.coordinator.updating = false;context.coordinator.configureHeightReporter(scroll:scroll,view:view) }
        view.isEditable = enabled; view.setAccessibilityLabel(label)
        if view.string != text {
            view.breakUndoCoalescing()
            if text.isEmpty {
                view.string = text
                view.undoManager?.removeAllActions() // A sent/cleared draft must not revive through Undo.
            } else {
                view.replaceWithUndo(text)
            }
        }
        let desired = ChatComposerEdit.validRange(selection, in: text) == nil ? NSRange(location: text.utf16.count, length: 0) : selection
        if view.selectedRange() != desired { view.setSelectedRange(desired) }
        if focused.wrappedValue, enabled, view.window?.firstResponder !== view {
            DispatchQueue.main.async { [weak view] in
                guard let view, context.coordinator.parent.focused.wrappedValue, view.isEditable else { return }
                view.window?.makeFirstResponder(view)
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposerText
        var updating = false
        private weak var heightScroll:SizingScroll?
        private weak var heightView:ComposerTextView?
        private var heightEpoch = UUID()
        private var heightQueued = false
        private var lastHeight:CGFloat?
        private var hasHadWindow = false
        private(set) var heightMeasurementCount = 0
        init(_ parent: NativeComposerText) { self.parent = parent }
        func configureHeightReporter(scroll:NSScrollView,view:ComposerTextView) {
            guard parent.onHeightChanged != nil,let sizingScroll = scroll as? SizingScroll else { detachHeightReporter();return }
            if heightScroll !== sizingScroll || heightView !== view { attachHeightReporter(scroll:sizingScroll,view:view) }
            else { scheduleHeightReport() }
        }
        func attachHeightReporter(scroll:SizingScroll,view:ComposerTextView) {
            detachHeightReporter();heightScroll = scroll;heightView = view;hasHadWindow = scroll.window != nil
            scroll.onSizingLayout = { [weak self] in self?.scheduleHeightReport() }
            scroll.onSizingWindowChanged = { [weak self,weak scroll] in
                guard let self,let scroll,self.heightScroll === scroll else { return }
                self.cancelHeightReports()
                if scroll.window != nil { self.hasHadWindow = true }
                self.scheduleHeightReport()
            }
            scheduleHeightReport()
        }
        func detachHeightReporter() {
            heightScroll?.onSizingLayout = nil;heightScroll?.onSizingWindowChanged = nil
            heightScroll = nil;heightView = nil;hasHadWindow = false;cancelHeightReports()
        }
        private func cancelHeightReports() { heightEpoch = UUID();heightQueued = false;lastHeight = nil }
        func scheduleHeightReport() {
            guard parent.onHeightChanged != nil else { cancelHeightReports();return }
            guard !heightQueued,let scroll = heightScroll,let view = heightView,
                  !hasHadWindow || scroll.window != nil,scroll.documentView === view else { return }
            heightQueued = true
            let epoch = heightEpoch,window = scroll.window.map(ObjectIdentifier.init)
            DispatchQueue.main.async { [weak self,weak scroll,weak view] in
                guard let self,self.heightEpoch == epoch else { return }
                self.heightQueued = false
                guard let scroll,let view,self.heightScroll === scroll,self.heightView === view,
                      scroll.documentView === view,(view.delegate as? Coordinator) === self,
                      scroll.window.map(ObjectIdentifier.init) == window,
                      self.parent.onHeightChanged != nil else { return }
                scroll.layoutSubtreeIfNeeded();view.layoutSubtreeIfNeeded()
                guard let height = NativeComposerMeasuredHeight.height(in:view,scale:scroll.window?.backingScaleFactor ?? 1) else { return }
                guard self.heightEpoch == epoch,self.heightScroll === scroll,self.heightView === view,
                      scroll.documentView === view,(view.delegate as? Coordinator) === self,
                      scroll.window.map(ObjectIdentifier.init) == window,let callback = self.parent.onHeightChanged else { return }
                self.heightMeasurementCount += 1
                guard self.lastHeight != height else { return }
                self.lastHeight = height;callback(height)
            }
        }
        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.selection = view.selectedRange(); parent.text = view.string
            scheduleHeightReport()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.selection = view.selectedRange()
        }
        func textDidBeginEditing(_ notification: Notification) { if !updating { parent.focused.wrappedValue = true } }
        func textDidEndEditing(_ notification: Notification) { if !updating { parent.focused.wrappedValue = false } }
    }
    final class SizingScroll:NSScrollView {
        var onSizingLayout:(()->Void)?
        var onSizingWindowChanged:(()->Void)?
        private var lastSizingWidth:CGFloat?
        override func layout() {
            super.layout()
            let width = contentSize.width
            if lastSizingWidth != width { lastSizingWidth = width;onSizingLayout?() }
        }
        override func setFrameSize(_ newSize:NSSize) {
            let previous = frame.size;super.setFrameSize(newSize)
            if previous.width != newSize.width { onSizingLayout?() }
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow();onSizingWindowChanged?() }
    }
    final class ComposerTextView: NSTextView {
        var onCompletionKey: ((NativeComposerCompletionKey) -> Bool)?
        var onFormat: ((ChatComposerEdit.Style) -> Void)?
        var onAttachmentInput:((NativeComposerAttachmentInput)->Void)?
        private var attachmentDrop = false { didSet { needsDisplay = true } }
        @discardableResult func consumeAttachment(_ pasteboard:NSPasteboard) -> Bool {
            guard isEditable else { return NativeComposerAttachmentReader.hasAttachment(pasteboard) }
            let input = NativeComposerAttachmentReader.read(pasteboard)
            if case .none = input { return false }
            if let onAttachmentInput { onAttachmentInput(input) } else { NSSound.beep() }
            return true
        }
        override func paste(_ sender:Any?) { if !consumeAttachment(.general) { super.paste(sender) } }
        override func pasteAsPlainText(_ sender:Any?) { if !consumeAttachment(.general) { super.pasteAsPlainText(sender) } }
        func attachmentDragOperation(_ pasteboard:NSPasteboard) -> NSDragOperation {
            isEditable && onAttachmentInput != nil && NativeComposerAttachmentReader.hasAttachment(pasteboard) ? .copy : []
        }
        override func draggingEntered(_ sender:NSDraggingInfo) -> NSDragOperation {
            guard NativeComposerAttachmentReader.hasAttachment(sender.draggingPasteboard) else { return super.draggingEntered(sender) }
            let operation:NSDragOperation = sender.draggingSourceOperationMask.contains(.copy) ? attachmentDragOperation(sender.draggingPasteboard) : [];attachmentDrop = operation == .copy;return operation
        }
        override func draggingUpdated(_ sender:NSDraggingInfo) -> NSDragOperation {
            guard NativeComposerAttachmentReader.hasAttachment(sender.draggingPasteboard) else { return super.draggingUpdated(sender) }
            let operation:NSDragOperation = sender.draggingSourceOperationMask.contains(.copy) ? attachmentDragOperation(sender.draggingPasteboard) : [];attachmentDrop = operation == .copy;return operation
        }
        override func draggingExited(_ sender:NSDraggingInfo?) { attachmentDrop = false;super.draggingExited(sender) }
        override func prepareForDragOperation(_ sender:NSDraggingInfo) -> Bool {
            if NativeComposerAttachmentReader.hasAttachment(sender.draggingPasteboard) { return sender.draggingSourceOperationMask.contains(.copy) && attachmentDragOperation(sender.draggingPasteboard) == .copy }
            return super.prepareForDragOperation(sender)
        }
        override func performDragOperation(_ sender:NSDraggingInfo) -> Bool {
            attachmentDrop = false
            if NativeComposerAttachmentReader.hasAttachment(sender.draggingPasteboard) {
                // Editing state and source operations can change after hover or
                // prepare. Accept only the copy we can still stage at release.
                guard sender.draggingSourceOperationMask.contains(.copy),
                      attachmentDragOperation(sender.draggingPasteboard) == .copy else { return false }
                return consumeAttachment(sender.draggingPasteboard)
            }
            return super.performDragOperation(sender)
        }
        override func draw(_ dirtyRect:NSRect) {
            super.draw(dirtyRect)
            if attachmentDrop {
                NSColor(calibratedRed:113.0/255,green:210.0/255,blue:183.0/255,alpha:0.9).setStroke()
                let border = NSBezierPath(roundedRect:bounds.insetBy(dx:2,dy:2),xRadius:6,yRadius:6);border.lineWidth = 2;border.stroke()
            }
        }
        private func formattingShortcut(_ event: NSEvent) -> Bool {
            guard window?.isKeyWindow == true, window?.firstResponder === self else { return false }
            let modifiers = event.modifierFlags.intersection([.command,.shift,.option,.control])
            let style: ChatComposerEdit.Style?
            if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "b" { style = .bold }
            else if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "i" { style = .italic }
            else if modifiers == [.command,.shift], event.charactersIgnoringModifiers?.lowercased() == "c" { style = .codeBlock }
            else { style = nil }
            guard isEditable, let style, let onFormat else { return false }
            onFormat(style); return true
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            formattingShortcut(event) || super.performKeyEquivalent(with:event)
        }
        func completionShortcut(_ event: NSEvent) -> Bool {
            guard isEditable, !hasMarkedText(), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
            let key: NativeComposerCompletionKey
            switch event.keyCode {
            case 125: key = .next
            case 126: key = .previous
            case 36, 48, 76: key = .accept
            case 53: key = .dismiss
            default: return false
            }
            return onCompletionKey?(key) ?? false
        }
        override func keyDown(with event: NSEvent) {
            if completionShortcut(event) { return }
            if !formattingShortcut(event) { super.keyDown(with:event) }
        }
        var onFocusChanged: ((Bool) -> Void)?
        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder(); if result { onFocusChanged?(true) }; return result
        }
        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder(); if result { onFocusChanged?(false) }; return result
        }
        private let composerUndo = UndoManager()
        override var undoManager: UndoManager? { composerUndo }
        func replaceWithUndo(_ value: String, selection: NSRange? = nil) {
            let previous = string; let previousSelection = selectedRange()
            composerUndo.registerUndo(withTarget: self) { target in
                target.replaceWithUndo(previous, selection: previousSelection)
            }
            string = value
            setSelectedRange(selection ?? NSRange(location: value.utf16.count, length: 0))
            didChangeText()
        }
        @objc func undo(_ sender: Any?) { composerUndo.undo() }
        @objc func redo(_ sender: Any?) { composerUndo.redo() }
        override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            if item.action == Selector(("undo:")) { return isEditable && composerUndo.canUndo }
            if item.action == Selector(("redo:")) { return isEditable && composerUndo.canRedo }
            if item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:)) {
                if NativeComposerAttachmentReader.hasAttachment(.general) { return isEditable && onAttachmentInput != nil }
            }
            return super.validateUserInterfaceItem(item)
        }
    }
}
