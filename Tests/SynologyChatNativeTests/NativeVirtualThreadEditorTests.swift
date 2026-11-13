#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import SynologyChatNative

/// Seeds only the private row editor state. The rendered TextEditor, AppKit
/// responder, undo manager and thread geometry are real; no API client exists.
/// No menu authorisation, save action or physical-input acceptance is claimed.
@MainActor final class NativeVirtualThreadEditorTests:XCTestCase {
    private let original = "Synthetic editor original café 😀\nSecond line for caret movement."
    @MainActor private struct Harness {
        let model:NativeChatPreviewModel
        let root:NSHostingView<AnyView>
        let scroll:NativeTableTimeline.Scroll
        let table:NativeVirtualTimeline.Document
        let window:NSWindow
        let owner:UUID
        let initialText:String
        let threadToken:UUID
        func update() {
            // @ObservedObject drives updateNSView inside SwiftUI's real
            // transaction. Do not manually interleave coordinator updates
            // with the hosted rows' own observed-model update cycle.
            root.layoutSubtreeIfNeeded()
        }
    }
    private func post(_ id:Int64,text:String? = nil,root:Int64? = 9000) throws -> ChatPost {
        var object:[String:Any] = ["post_id":id,"channel_id":23,"creator_id":id%2+10,"type":"normal","message":text ?? "Synthetic adjacent row \(id)","create_at":1000+id]
        if let root { object["thread_id"] = root }
        return try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:object))
    }
    private func settle(_ host:Harness) async throws {
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds:15_000_000)
            host.window.contentView?.layoutSubtreeIfNeeded()
            host.window.contentView?.needsDisplay = true
            host.window.contentView?.displayIfNeeded()
        }
        XCTAssertFalse(host.window.isVisible)
    }
    private func editors(_ view:NSView)->[NSTextView] {
        let own = (view as? NSTextView).map { $0.isEditable && !$0.isFieldEditor ? [$0] : [] } ?? []
        return own+view.subviews.flatMap(editors)
    }
    private func tableScroll(_ view:NSView)->NativeTableTimeline.Scroll? {
        if let value = view as? NativeTableTimeline.Scroll { return value }
        for child in view.subviews { if let value = tableScroll(child) { return value } }
        return nil
    }
    private func editor(_ host:Harness) throws -> NSTextView {
        let values = editors(host.table)
        XCTAssertEqual(values.count,1)
        return try XCTUnwrap(values.first)
    }
    private func host() async throws -> Harness {
        _ = NSApplication.shared
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,notificationDefaults:nil),owner = UUID()
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":23,"name":"Synthetic editor channel","type":"channel","encrypted":false,"unread":0}"#.utf8))]
        model.selection = 23
        model.posts = try (500..<510).map { try post(Int64($0),text:"Separate synthetic main post \($0)",root:nil) }
        model.threadRoot = try post(9000,text:"Synthetic editor thread root",root:nil)
        model.replies = try (100..<160).map { try post(Int64($0),text:$0 == 120 ? original : nil) }
        model.nativeThreadScrollPostID = 120;model.draft = "Synthetic ordinary composer draft"
        model.replyDraft = "Synthetic separate reply composer draft"
        let timeline = NativeVirtualTimeline(model:model,onBottomChanged:{ _ in },fixtureEditors:[120:.init(owner:owner,text:original)],inThread:true)
        let root = NSHostingView(rootView:AnyView(timeline.environment(\.nativeChatStyle,ChatAppearanceStyle.dark).environment(\.colorScheme,.dark)))
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:680,height:520),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = root
        addTeardownBlock { @MainActor in root.rootView = AnyView(EmptyView());root.layoutSubtreeIfNeeded();window.contentView = nil;window.close() }
        for _ in 0..<40 {
            root.layoutSubtreeIfNeeded()
            if tableScroll(root) != nil { break }
            try await Task.sleep(nanoseconds:15_000_000)
        }
        let scroll = try XCTUnwrap(tableScroll(root)),table = try XCTUnwrap(scroll.documentView as? NativeVirtualTimeline.Document)
        let result = Harness(model:model,root:root,scroll:scroll,table:table,window:window,owner:owner,initialText:original,threadToken:model.nativeThreadViewportToken)
        result.update();try await settle(result)
        model.nativeThreadScrollPostID = nil;result.update();try await settle(result)
        model.beginMessageEditing(owner:owner);try await settle(result)
        let editor = try editor(result)
        XCTAssertEqual(editor.string,original);XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(window.firstResponder === editor);XCTAssertEqual(model.activeMessageEditor,owner)
        return result
    }
    private func updatePredecessor(_ host:Harness) async throws {
        let index = try XCTUnwrap(host.model.replies.firstIndex(where:{ $0.id == 119 }))
        host.model.replies[index] = try post(119,text:"Synthetic changed predecessor with a longer body to trigger neighbouring row remeasurement.")
        host.update();try await settle(host)
    }
    private func assertOwnedState(_ host:Harness,text:NSTextView,file:StaticString = #filePath,line:UInt = #line) throws {
        let index = try XCTUnwrap(host.table.canonicalRows.firstIndex(of:.post(120)),file:file,line:line)
        let cell = try XCTUnwrap(host.table.hostedView(forRow:index) as? NativeVirtualTimeline.Cell,file:file,line:line)
        XCTAssertEqual(cell.row,.post(120),file:file,line:line)
        XCTAssertEqual(host.table.row(for:text),index,file:file,line:line)
        XCTAssertTrue(text.isDescendant(of:cell),file:file,line:line)
        let canonical = host.table.rect(ofRow:index),actual = cell.convert(cell.bounds,to:host.table),tolerance = 1/host.window.backingScaleFactor
        XCTAssertEqual(actual.minY,canonical.minY,accuracy:tolerance,file:file,line:line)
        XCTAssertEqual(actual.height,canonical.height,accuracy:tolerance,file:file,line:line)
        XCTAssertEqual(host.model.posts.map(\.id),Array(Int64(500)..<510),file:file,line:line)
        XCTAssertEqual(host.model.posts.map(\.message),(500..<510).map { "Separate synthetic main post \($0)" },file:file,line:line)
        XCTAssertEqual(host.model.replies.first(where:{ $0.id == 120 })?.message,original,file:file,line:line)
        XCTAssertTrue(host.model.replies.allSatisfy({ $0.thread_id == 9000 }),file:file,line:line)
        XCTAssertEqual(host.model.threadRoot?.id,9000,file:file,line:line)
        XCTAssertEqual(host.model.nativeThreadViewportToken,host.threadToken,file:file,line:line)
        XCTAssertEqual(host.model.draft,"Synthetic ordinary composer draft",file:file,line:line)
        XCTAssertEqual(host.model.replyDraft,"Synthetic separate reply composer draft",file:file,line:line)
        XCTAssertEqual(host.model.activeMessageEditor,host.owner,file:file,line:line)
        XCTAssertEqual(host.table.debugDiagnostics["host_order_is_canonical"] as? Bool,true,file:file,line:line)
        let hosts = host.table.debugDiagnostics["max_hosted_cells"] as? Int ?? Int.max
        XCTAssertGreaterThan(hosts,0,file:file,line:line);XCTAssertLessThanOrEqual(hosts,32,file:file,line:line)
        XCTAssertFalse(host.model.connected,file:file,line:line);XCTAssertFalse(host.window.isVisible,file:file,line:line)
    }
    @MainActor private final class Measurements { var values:[[String:Any]] = [] }
    private func geometry(_ host:Harness,text:NSTextView,label:String)->[String:Any] {
        let index = host.table.canonicalRows.firstIndex(of:.post(120)) ?? -1
        let attached = text.window === host.window && text.isDescendant(of:host.table)
        let row = host.table.rect(ofRow:index),frame = attached ? text.convert(text.bounds,to:host.table) : .zero
        var chain:[[String:String]] = [],view:NSView? = text
        var actualCell:NativeVirtualTimeline.Cell?
        while let current = view,current !== host.table {
            chain.append(["type":String(describing:type(of:current)),"frame":NSStringFromRect(current.frame),"bounds":NSStringFromRect(current.bounds)])
            view = current.superview
            if let cell = current as? NativeVirtualTimeline.Cell { actualCell = cell }
        }
        return ["phase":label,"synthetic_only":true,"editor_attached":attached,"thread_root_id":host.model.threadRoot?.id as Any? ?? NSNull(),"thread_token":host.model.nativeThreadViewportToken.uuidString,"clip_y":host.scroll.documentVisibleRect.minY,"view_chain":chain,
                "application_running":NSApplication.shared.isRunning,"activation_policy":NSApplication.shared.activationPolicy().rawValue,
                "expected_index":index,"actual_row_for_view":host.table.row(for:text),"cell_row":actualCell?.row.map { String(describing:$0) } ?? "nil",
                "expected_cell_is_actual":host.table.hostedView(forRow:index) === actualCell,
                "row_y":row.minY,"row_height":row.height,"row_offset":row.minY-host.scroll.documentVisibleRect.minY,
                "text_y":frame.minY,"text_offset":frame.minY-host.scroll.documentVisibleRect.minY,
                "text_frame":NSStringFromRect(text.frame),"text_bounds":NSStringFromRect(text.bounds),
                "inner_visible":text.enclosingScrollView.map { NSStringFromRect($0.documentVisibleRect) } ?? "none",
                "table":host.table.debugDiagnostics]
    }
    func testInlineEditorRetainsIdentityFocusSelectionAndUndoAcrossNeighbourUpdate() async throws {
        let host = try await host(),text = try editor(host)
        let undo = try XCTUnwrap(text.undoManager)
        XCTAssertTrue(text.allowsUndo)
        text.setSelectedRange(NSRange(location:(original as NSString).length,length:0))
        undo.beginUndoGrouping();text.insertText(" e\u{301} 😀",replacementRange:text.selectedRange());undo.endUndoGrouping()
        let edited = text.string,selection = text.selectedRange()
        XCTAssertNotEqual(edited,original);XCTAssertTrue(undo.canUndo)
        try await updatePredecessor(host)
        XCTAssertTrue(try editor(host) === text);XCTAssertTrue(host.window.firstResponder === text)
        XCTAssertEqual(Data(text.string.utf8),Data(edited.utf8));XCTAssertEqual(text.selectedRange(),selection)
        XCTAssertTrue(text.undoManager === undo);XCTAssertTrue(undo.canUndo)
        undo.undo();try await settle(host);XCTAssertEqual(text.string,original)
        undo.redo();try await settle(host);XCTAssertEqual(Data(text.string.utf8),Data(edited.utf8))
        XCTAssertEqual(host.model.activeMessageEditor,host.owner)
        XCTAssertEqual(host.model.replies.first(where:{ $0.id == 120 })?.message,original)
        XCTAssertEqual(host.model.draft,"Synthetic ordinary composer draft")
        try assertOwnedState(host,text:text)
    }
    func testInlineTextResponderConsumesArrowWithoutPagingOuterTimeline() async throws {
        let host = try await host(),text = try editor(host)
        text.setSelectedRange(NSRange(location:0,length:0))
        let before = host.scroll.documentVisibleRect,input = host.table.debugDiagnostics["input_generation"] as? String
        let event = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:host.window.windowNumber,context:nil,characters:"\u{F701}",charactersIgnoringModifiers:"\u{F701}",isARepeat:false,keyCode:125))
        host.window.firstResponder?.keyDown(with:event)
        XCTAssertGreaterThan(text.selectedRange().location,0,"The actual text responder must move the caret")
        try await settle(host)
        XCTAssertEqual(host.scroll.documentVisibleRect.origin,before.origin)
        XCTAssertEqual(host.table.debugDiagnostics["input_generation"] as? String,input)
        XCTAssertTrue(host.window.firstResponder === text);XCTAssertEqual(text.string,original)
        try assertOwnedState(host,text:text)
    }
    func testMarkedTextSurvivesNeighbourRefreshWithoutCommittingToCanonicalPost() async throws {
        let host = try await host(),text = try editor(host)
        text.setSelectedRange(NSRange(location:0,length:0))
        text.setMarkedText("にほ",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:0,length:0))
        XCTAssertTrue(text.hasMarkedText())
        let marked = text.markedRange(),selection = text.selectedRange(),content = Data(text.string.utf8)
        try await updatePredecessor(host)
        XCTAssertTrue(try editor(host) === text);XCTAssertTrue(text.hasMarkedText())
        XCTAssertEqual(text.markedRange(),marked);XCTAssertEqual(text.selectedRange(),selection)
        XCTAssertEqual(Data(text.string.utf8),content);XCTAssertTrue(host.window.firstResponder === text)
        XCTAssertEqual(host.model.replies.first(where:{ $0.id == 120 })?.message,original)
        XCTAssertEqual(host.model.activeMessageEditor,host.owner)
        text.unmarkText()
        try assertOwnedState(host,text:text)
    }
    func testPrependingRowsPreservesActiveEditorDraftFocusAndUndo() async throws {
        let host = try await host(),text = try editor(host),undo = try XCTUnwrap(try editor(host).undoManager)
        text.setSelectedRange(NSRange(location:(text.string as NSString).length,length:0))
        undo.beginUndoGrouping();text.insertText(" — unsaved 😀",replacementRange:text.selectedRange());undo.endUndoGrouping()
        try await settle(host)
        let content = Data(text.string.utf8),selection = text.selectedRange()
        let index = try XCTUnwrap(host.table.canonicalRows.firstIndex(of:.post(120)))
        let textOffset = text.convert(text.bounds,to:host.table).minY-host.scroll.documentVisibleRect.minY
        let rowOffset = host.table.rect(ofRow:index).minY-host.scroll.documentVisibleRect.minY
        let measurements = Measurements();measurements.values.append(geometry(host,text:text,label:"before-thread-prepend"))
        host.model.replies = try (97..<100).map { try post(Int64($0)) }+host.model.replies
        measurements.values.append(geometry(host,text:text,label:"thread-model-changed-before-update"))
        host.update()
        var tasks:[Task<Void,Error>] = []
        for (label,delay) in [("100ms",UInt64(100_000_000)),("200ms",UInt64(200_000_000)),("1sec",UInt64(1_000_000_000))] {
            tasks.append(Task { @MainActor [self] in
                try await Task.sleep(nanoseconds:delay)
                let currentIndex = try XCTUnwrap(host.table.canonicalRows.firstIndex(of:.post(120)))
                let actualTextOffset = text.convert(text.bounds,to:host.table).minY-host.scroll.documentVisibleRect.minY
                let actualRowOffset = host.table.rect(ofRow:currentIndex).minY-host.scroll.documentVisibleRect.minY
                var sample = geometry(host,text:text,label:"after-thread-prepend-"+label)
                sample["text_offset_delta"] = actualTextOffset-textOffset;sample["row_offset_delta"] = actualRowOffset-rowOffset
                measurements.values.append(sample)
                XCTAssertTrue(try editor(host) === text);XCTAssertTrue(host.window.firstResponder === text)
                XCTAssertEqual(Data(text.string.utf8),content);XCTAssertEqual(text.selectedRange(),selection)
                XCTAssertTrue(text.undoManager === undo);XCTAssertTrue(undo.canUndo)
                XCTAssertEqual(actualTextOffset,textOffset,accuracy:1/host.window.backingScaleFactor,"Geometry: \(sample)")
                XCTAssertEqual(actualRowOffset,rowOffset,accuracy:1/host.window.backingScaleFactor,"Geometry: \(sample)")
                try assertOwnedState(host,text:text)
            })
        }
        defer { for task in tasks { task.cancel() } }
        // Preserve the installed-host main test's own layout/display settling;
        // timed tasks above only read and assert, without geometry fixups.
        try await settle(host);try await Task.sleep(nanoseconds:800_000_000)
        for task in tasks { try await task.value }
        print("SYNTHETIC_THREAD_EDITOR_PREPEND "+String(decoding:try JSONSerialization.data(withJSONObject:measurements.values,options:.sortedKeys),as:UTF8.self))
        let expected:[NativeTableTimelineState.Row] = [.top,.threadRoot(9000),.threadDivider]+(97..<160).map { NativeTableTimelineState.Row.post(Int64($0)) }+[.bottom]
        XCTAssertEqual(host.table.canonicalRows,expected);XCTAssertEqual(host.table.numberOfRows,67)
        XCTAssertEqual(host.model.replies.map(\.id),Array(Int64(97)..<160))
        undo.undo();try await settle(host);XCTAssertEqual(text.string,original)
        undo.redo();try await settle(host);XCTAssertEqual(Data(text.string.utf8),content)
        try assertOwnedState(host,text:text)
    }
    func testWindowResizePreservesMarkedCompositionAndActualEditorIdentity() async throws {
        let host = try await host(),text = try editor(host)
        text.setMarkedText("にほん",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:0,length:0))
        let marked = text.markedRange(),selection = text.selectedRange(),content = Data(text.string.utf8)
        XCTAssertTrue(text.hasMarkedText())
        for size in [NSSize(width:790,height:580),NSSize(width:610,height:480),NSSize(width:680,height:520)] {
            host.window.setContentSize(size);host.update();try await settle(host)
            XCTAssertTrue(try editor(host) === text);XCTAssertTrue(host.window.firstResponder === text)
            XCTAssertTrue(text.hasMarkedText());XCTAssertEqual(text.markedRange(),marked)
            XCTAssertEqual(text.selectedRange(),selection);XCTAssertEqual(Data(text.string.utf8),content)
            XCTAssertEqual(host.model.activeMessageEditor,host.owner)
            XCTAssertTrue(text.convert(text.bounds,to:host.table).intersects(host.scroll.documentVisibleRect))
            try assertOwnedState(host,text:text)
        }
        XCTAssertEqual(host.model.replies.first(where:{ $0.id == 120 })?.message,original)
        text.unmarkText()
        try assertOwnedState(host,text:text)
    }
}
#endif
