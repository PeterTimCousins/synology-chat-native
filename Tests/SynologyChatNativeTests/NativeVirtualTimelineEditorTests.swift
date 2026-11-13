#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import SynologyChatNative

/// Seeds only the private row editor state. The rendered TextEditor, AppKit
/// responder, undo manager and table geometry are real; no API client exists.
@MainActor final class NativeVirtualTimelineEditorTests:XCTestCase {
    private let original = "Synthetic editor original café 😀\nSecond line for caret movement."
    @MainActor private struct Harness {
        let model:NativeChatPreviewModel
        let root:NSHostingView<AnyView>
        let scroll:NativeTableTimeline.Scroll
        let table:NativeVirtualTimeline.Document
        let window:NSWindow
        let owner:UUID
        let initialText:String
        func update() {
            // @ObservedObject drives updateNSView inside SwiftUI's real
            // transaction. Do not manually interleave coordinator updates
            // with the hosted rows' own observed-model update cycle.
            root.layoutSubtreeIfNeeded()
        }
    }
    private func post(_ id:Int64,text:String? = nil) throws -> ChatPost {
        let object:[String:Any] = ["post_id":id,"channel_id":23,"creator_id":id%2+10,"type":"normal","message":text ?? "Synthetic adjacent row \(id)","create_at":1000+id]
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
        model.selection = 23;model.posts = try (100..<160).map { try post(Int64($0),text:$0 == 120 ? original : nil) }
        model.scrollPostID = 120;model.draft = "Synthetic ordinary composer draft"
        let timeline = NativeVirtualTimeline(model:model,onBottomChanged:{ _ in },fixtureEditors:[120:.init(owner:owner,text:original)])
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
        let result = Harness(model:model,root:root,scroll:scroll,table:table,window:window,owner:owner,initialText:original)
        result.update();try await settle(result)
        model.scrollPostID = nil;result.update();try await settle(result)
        model.beginMessageEditing(owner:owner);try await settle(result)
        let editor = try editor(result)
        XCTAssertEqual(editor.string,original);XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(window.firstResponder === editor);XCTAssertEqual(model.activeMessageEditor,owner)
        return result
    }
    private func updatePredecessor(_ host:Harness) async throws {
        let index = try XCTUnwrap(host.model.posts.firstIndex(where:{ $0.id == 119 }))
        host.model.posts[index] = try post(119,text:"Synthetic changed predecessor with a longer body to trigger neighbouring row remeasurement.")
        host.update();try await settle(host)
    }
    private func geometry(_ host:Harness,text:NSTextView,label:String)->[String:Any] {
        let index = (host.model.posts.firstIndex(where:{ $0.id == 120 }) ?? -2)+1
        let row = host.table.rect(ofRow:index),frame = text.convert(text.bounds,to:host.table)
        var chain:[[String:String]] = [],view:NSView? = text
        var actualCell:NativeVirtualTimeline.Cell?
        while let current = view,current !== host.table {
            chain.append(["type":String(describing:type(of:current)),"frame":NSStringFromRect(current.frame),"bounds":NSStringFromRect(current.bounds)])
            view = current.superview
            if let cell = current as? NativeVirtualTimeline.Cell { actualCell = cell }
        }
        return ["phase":label,"synthetic_only":true,"clip_y":host.scroll.documentVisibleRect.minY,"view_chain":chain,
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
        XCTAssertEqual(host.model.posts.first(where:{ $0.id == 120 })?.message,original)
        XCTAssertEqual(host.model.draft,"Synthetic ordinary composer draft")
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
        XCTAssertEqual(host.model.posts.first(where:{ $0.id == 120 })?.message,original)
        XCTAssertEqual(host.model.activeMessageEditor,host.owner)
        text.unmarkText()
    }
    func testPrependingRowsPreservesActiveEditorDraftFocusAndUndo() async throws {
        let host = try await host(),text = try editor(host),undo = try XCTUnwrap(try editor(host).undoManager)
        text.setSelectedRange(NSRange(location:(text.string as NSString).length,length:0))
        undo.beginUndoGrouping();text.insertText(" — unsaved 😀",replacementRange:text.selectedRange());undo.endUndoGrouping()
        // Establish the pre-prepend geometry after native caret reveal and
        // text layout from the typing itself have settled.
        try await settle(host)
        let content = Data(text.string.utf8),selection = text.selectedRange()
        let offset = text.convert(text.bounds,to:host.table).minY-host.scroll.documentVisibleRect.minY
        var measurements = [geometry(host,text:text,label:"before-prepend")]
        host.model.posts = try (97..<100).map { try post(Int64($0)) }+host.model.posts
        measurements.append(geometry(host,text:text,label:"model-changed-before-update"))
        host.update();try await settle(host)
        measurements.append(geometry(host,text:text,label:"after-prepend-settle"))
        try await Task.sleep(nanoseconds:800_000_000)
        measurements.append(geometry(host,text:text,label:"after-prepend-one-second"))
        print("SYNTHETIC_EDITOR_PREPEND "+String(decoding:try JSONSerialization.data(withJSONObject:measurements,options:.sortedKeys),as:UTF8.self))
        XCTAssertEqual(host.table.numberOfRows,65)
        XCTAssertTrue(try editor(host) === text);XCTAssertTrue(host.window.firstResponder === text)
        XCTAssertEqual(Data(text.string.utf8),content);XCTAssertEqual(text.selectedRange(),selection)
        XCTAssertEqual(text.convert(text.bounds,to:host.table).minY-host.scroll.documentVisibleRect.minY,offset,accuracy:1/host.window.backingScaleFactor)
        XCTAssertTrue(text.undoManager === undo);XCTAssertTrue(undo.canUndo)
        undo.undo();try await settle(host);XCTAssertEqual(text.string,original)
        XCTAssertEqual(host.model.activeMessageEditor,host.owner)
        XCTAssertEqual(host.model.draft,"Synthetic ordinary composer draft")
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
        }
        XCTAssertEqual(host.model.posts.first(where:{ $0.id == 120 })?.message,original)
        text.unmarkText()
    }
}
#endif
