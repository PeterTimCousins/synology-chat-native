import AppKit
import SwiftUI

struct NativeCodeEditor:NSViewRepresentable {
    @Binding var text:String
    let filename:String
    var editable = true
    var wrap = false
    var findRequest = 0
    let label:String
    // Binding equality can hide a canonically equivalent Unicode replacement
    // from SwiftUI. Keep a byte revision so the existing NSTextView is updated.
    private let contentRevision:Data
    init(text:Binding<String>,filename:String,editable:Bool = true,wrap:Bool = false,findRequest:Int = 0,label:String) {
        _text = text;self.filename = filename;self.editable = editable;self.wrap = wrap;self.findRequest = findRequest;self.label = label
        contentRevision = ChatSnippetRevision.digest(text.wrappedValue)
    }
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator()->Coordinator { Coordinator(self) }
    func makeNSView(context:Context)->NSScrollView {
        let scroll = CodeScrollView();scroll.drawsBackground = false;scroll.hasVerticalScroller = true;scroll.autohidesScrollers = true
        let storage = NSTextStorage(),layout = NSLayoutManager(),container = NSTextContainer(size:.zero)
        layout.addTextContainer(container);storage.addLayoutManager(layout)
        let view = CodeTextView(frame:.zero,textContainer:container)
        view.isRichText = false;view.allowsUndo = true;view.drawsBackground = false;view.isSelectable = true
        view.isAutomaticQuoteSubstitutionEnabled = false;view.isAutomaticDashSubstitutionEnabled = false;view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false;view.isContinuousSpellCheckingEnabled = false;view.smartInsertDeleteEnabled = false
        view.font = .monospacedSystemFont(ofSize:13,weight:.regular);view.textColor = NSColor.labelColor;view.insertionPointColor = .labelColor
        view.textContainerInset = .init(width:16,height:14);view.isVerticallyResizable = true;view.usesFindBar = true
        view.maxSize = .init(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator;view.string = text;view.setSelectedRange(.init(location:0,length:0));view.setAccessibilityLabel(label)
        scroll.documentView = view
        let ruler = CodeLineRuler(scroll:scroll,textView:view);scroll.verticalRulerView = ruler;scroll.hasVerticalRuler = true;scroll.rulersVisible = true
        context.coordinator.view = view;context.coordinator.ruler = ruler;context.coordinator.style()
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) { [weak ruler] _ in Task { @MainActor in ruler?.needsDisplay = true } }
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        let oldFilename = context.coordinator.parent.filename;context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        view.isEditable = editable && enabled
        if !view.string.utf8.elementsEqual(text.utf8) { view.string = text;view.setSelectedRange(.init(location:0,length:0));view.undoManager?.removeAllActions();context.coordinator.style() }
        else if oldFilename != filename { context.coordinator.style() }
        scroll.hasHorizontalScroller = !wrap
        view.isHorizontallyResizable = !wrap;view.autoresizingMask = wrap ? [.width] : []
        view.textContainer?.widthTracksTextView = wrap
        view.textContainer?.containerSize = .init(width:wrap ? scroll.contentSize.width : CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        Self.sizeDocument(scroll)
        if context.coordinator.findRequest != findRequest {
            context.coordinator.findRequest = findRequest
            let action = NSMenuItem();action.tag = NSTextFinder.Action.showFindInterface.rawValue;view.performTextFinderAction(action)
        }
    }
    static func sizeDocument(_ scroll:NSScrollView) {
        guard let view = scroll.documentView as? NSTextView,let layout = view.layoutManager,let container = view.textContainer else { return }
        let origin = scroll.contentView.bounds.origin
        layout.ensureLayout(for:container)
        let used = layout.usedRect(for:container),inset = view.textContainerInset
        let width = container.widthTracksTextView ? scroll.contentSize.width : max(scroll.contentSize.width,used.maxX+inset.width*2)
        let height = max(scroll.contentSize.height,used.maxY+inset.height*2)
        view.setFrameSize(.init(width:max(0,width),height:max(0,height)))
        scroll.contentView.scroll(to:origin);scroll.reflectScrolledClipView(scroll.contentView)
    }
    static func dismantleNSView(_ scroll:NSScrollView,coordinator:Coordinator) {
        coordinator.task?.cancel();coordinator.task = nil
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) };coordinator.observer = nil
        if let view = scroll.documentView as? NSTextView { view.delegate = nil;view.string = "";view.undoManager?.removeAllActions() }
    }
    @MainActor final class Coordinator:NSObject,NSTextViewDelegate {
        var parent:NativeCodeEditor
        weak var view:NSTextView?
        weak var ruler:CodeLineRuler?
        var observer:NSObjectProtocol?
        var task:Task<Void,Never>?
        var findRequest = 0
        var initiallyPositioned = false
        init(_ parent:NativeCodeEditor) { self.parent = parent }
        func textDidChange(_ notification:Notification) { guard let view else { return };parent.text = view.string;style() }
        func style() {
            task?.cancel();guard let view else { return }
            let text = view.string,language = NativeSnippetLanguage.forFilename(parent.filename).id
            ruler?.setText(text)
            task = Task { [weak self] in
                do {
                    let work = Task.detached(priority:.userInitiated) { try NativeSnippetSyntax.tokens(text,language:language) }
                    let tokens = try await withTaskCancellationHandler(operation:{ try await work.value },onCancel:{ work.cancel() })
                    guard !Task.isCancelled,let self,let view = self.view,view.string.utf8.elementsEqual(text.utf8),let storage = view.textStorage else { return }
                    let selected = view.selectedRanges,undo = view.undoManager,register = view.undoManager?.isUndoRegistrationEnabled == true
                    if register { undo?.disableUndoRegistration() };defer { if register { undo?.enableUndoRegistration() } }
                    storage.beginEditing();storage.setAttributes([.font:NSFont.monospacedSystemFont(ofSize:13,weight:.regular),.foregroundColor:NSColor.labelColor],range:.init(location:0,length:storage.length))
                    for token in tokens {
                        let color:NSColor
                        switch token.kind {
                        case .keyword:color = NativeCodeColors.keyword
                        case .string:color = NativeCodeColors.string
                        case .number:color = NativeCodeColors.number
                        case .comment:color = .secondaryLabelColor
                        }
                        storage.addAttribute(.foregroundColor,value:color,range:token.range)
                    }
                    storage.endEditing();view.selectedRanges = selected;self.ruler?.needsDisplay = true
                    if let scroll = view.enclosingScrollView { NativeCodeEditor.sizeDocument(scroll) }
                    if !self.initiallyPositioned,let scroll = view.enclosingScrollView,scroll.contentSize.width > 0 {
                        view.setSelectedRange(.init(location:0,length:0));scroll.contentView.scroll(to:.zero);scroll.reflectScrolledClipView(scroll.contentView);self.initiallyPositioned = true
                    }
                } catch { }
            }
        }
    }
    final class CodeScrollView:NSScrollView {
        private var positioned = false
        private var tiling = false
        override func tile() {
            guard !tiling else { return };tiling = true;defer { tiling = false }
            let origin = positioned ? contentView.bounds.origin : .zero
            super.tile()
            // Legacy scrollers can tile the clip view beneath its ruler. Keep
            // that owned gutter outside the source viewport in every style.
            if rulersVisible,let ruler = verticalRulerView {
                var frame = contentView.frame
                if frame.minX < ruler.frame.maxX {
                    let edge = ruler.frame.maxX;frame.size.width = max(0,frame.maxX-edge);frame.origin.x = edge
                    contentView.frame = frame
                }
            }
            positioned = true;contentView.scroll(to:origin);reflectScrolledClipView(contentView)
        }
    }
    final class CodeTextView:NSTextView {
        private let localUndo = UndoManager()
        override var undoManager:UndoManager? { localUndo }
    }
}

final class CodeLineRuler:NSRulerView {
    private weak var textView:NSTextView?
    private var starts = [0]
    override var isFlipped:Bool { true }
    init(scroll:NSScrollView,textView:NSTextView) {
        self.textView = textView;super.init(scrollView:scroll,orientation:.verticalRuler)
        clientView = textView;ruleThickness = 46
    }
    required init(coder:NSCoder) { super.init(coder:coder) }
    func setText(_ text:String) { starts = [0];for (index,unit) in text.utf16.enumerated() where unit == 10 { starts.append(index+1) };needsDisplay = true }
    private func line(at offset:Int)->Int {
        var low = 0,high = starts.count
        while low < high { let mid = (low+high)/2;if starts[mid] <= offset { low = mid+1 } else { high = mid } }
        return max(1,low)
    }
    override func drawHashMarksAndLabels(in rect:NSRect) {
        NSColor.controlBackgroundColor.setFill();bounds.fill()
        guard let view = textView,let layout = view.layoutManager,let container = view.textContainer else { return }
        let visible = view.visibleRect,range = layout.glyphRange(forBoundingRect:visible,in:container)
        let attributes:[NSAttributedString.Key:Any] = [.font:NSFont.monospacedSystemFont(ofSize:11,weight:.regular),.foregroundColor:NSColor.secondaryLabelColor]
        func draw(_ value:Int,_ y:CGFloat) { let label = String(value) as NSString;label.draw(at:NSPoint(x:ruleThickness-label.size(withAttributes:attributes).width-9,y:y),withAttributes:attributes) }
        var last = 0
        layout.enumerateLineFragments(forGlyphRange:range) { box,_,_,glyphs,_ in
            let number = self.line(at:layout.characterIndexForGlyph(at:glyphs.location))
            if number != last { draw(number,box.minY+view.textContainerOrigin.y-visible.minY+2);last = number }
        }
        if layout.numberOfGlyphs == 0 || view.string.hasSuffix("\n") {
            let box = layout.extraLineFragmentRect;draw(starts.count,box.minY+view.textContainerOrigin.y-visible.minY+2)
        }
    }
}

private enum NativeCodeColors {
    private static func adaptive(_ dark: (Double, Double, Double), _ light: (Double, Double, Double)) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }
    static let keyword = adaptive((0.8, 0.55, 0.85), (0.46, 0.20, 0.65))
    static let string = adaptive((0.44, 0.82, 0.72), (0.08, 0.39, 0.25))
    static let number = adaptive((0.91, 0.69, 0.45), (0.58, 0.26, 0.02))
}
