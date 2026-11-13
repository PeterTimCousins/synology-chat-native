#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import SynologyChatNative

/// The private-state seed enters the real editor only once. No save/menu/API action.
@MainActor final class NativeVirtualEditorOffscreenTests:XCTestCase {
    private let original = "Synthetic offscreen original café 😀\nSecond line for a real editor."
    @MainActor private final class Census {
        let values = NSHashTable<NSView>.weakObjects()
        var maximum = 0
        func observe(_ document:NativeVirtualTimeline.Document) {
            let cells = document.subviews.compactMap { $0 as? NativeVirtualTimeline.Cell }
            for cell in cells { if let host = cell.host { values.add(host) } }
            maximum = max(maximum,values.allObjects.count)
            XCTAssertLessThanOrEqual(maximum,32);XCTAssertLessThanOrEqual(cells.count,32)
            let indexes = cells.map { document.row(for:$0) }
            XCTAssertEqual(indexes,indexes.sorted());XCTAssertTrue(indexes.allSatisfy({ $0 >= 0 }))
        }
    }
    @MainActor private struct Harness {
        let model:NativeChatPreviewModel
        let root:NSHostingView<AnyView>
        let window:NSWindow
        let scroll:NativeTimelineScrollView
        let document:NativeVirtualTimeline.Document
        let owner:UUID
        let secondOwner:UUID?
        let thread:Bool
        let census:Census
    }
    @MainActor private struct Editing {
        let text:NSTextView
        let cell:NativeVirtualTimeline.Cell
        let host:NSHostingView<AnyView>
        let undo:UndoManager
        let content:Data
        let selection:NSRange
        let neighbor:NativeVirtualTimeline.Cell
        let neighborHost:NSHostingView<AnyView>
    }
    private func post(_ id:Int64,thread:Int64? = nil,text:String? = nil) throws -> ChatPost {
        var object:[String:Any] = ["post_id":id,"channel_id":23,"creator_id":id%2+10,"type":"normal","create_at":1000+id,"message":text ?? "Synthetic offscreen row \(id)"]
        if let thread { object["thread_id"] = thread }
        return try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:object))
    }
    private func make(thread:Bool,secondEditor:Bool = false) async throws -> Harness {
        _ = NSApplication.shared
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,notificationDefaults:nil),owner = UUID()
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":23,"name":"Synthetic offscreen editor","type":"channel","encrypted":false,"unread":0}"#.utf8))]
        model.selection = 23;model.draft = "Synthetic main offscreen draft"
        let rows = try (100..<160).map { try post(Int64($0),thread:thread ? 9000 : nil,text:$0 == 120 ? original : nil) }
        if thread {
            model.posts = try (500..<510).map { try post(Int64($0)) };model.threadRoot = try post(9000)
            model.replies = rows;model.replyDraft = "Synthetic separate reply offscreen draft";model.nativeThreadScrollPostID = 120
        } else {
            model.posts = rows;model.threadDrafts[9000] = "Synthetic separate reply offscreen draft";model.scrollPostID = 120
        }
        let secondOwner = secondEditor ? UUID() : nil
        var fixtures:[Int64:NativeMessageEditorFixture] = [120:.init(owner:owner,text:original)]
        if let secondOwner { fixtures[130] = .init(owner:secondOwner,text:"Synthetic offscreen row 130") }
        let view = NativeVirtualTimeline(model:model,onBottomChanged:{ _ in },fixtureEditors:fixtures,inThread:thread)
        let root = NSHostingView(rootView:AnyView(view.environment(\.nativeChatStyle,ChatAppearanceStyle.dark).environment(\.colorScheme,.dark)))
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:680,height:520),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = root
        addTeardownBlock { @MainActor in model.endMessageEditing(owner:owner);root.rootView = AnyView(EmptyView());root.layoutSubtreeIfNeeded();window.contentView = nil;window.close() }
        var candidate:NativeTimelineScrollView?
        for _ in 0..<40 {
            root.layoutSubtreeIfNeeded();candidate = scrolls(root).first
            if candidate != nil { break };try await Task.sleep(nanoseconds:15_000_000)
        }
        let scroll = try XCTUnwrap(candidate),document = try XCTUnwrap(scroll.documentView as? NativeVirtualTimeline.Document)
        let value = Harness(model:model,root:root,window:window,scroll:scroll,document:document,owner:owner,secondOwner:secondOwner,thread:thread,census:Census())
        try await settle(value)
        if thread { model.nativeThreadScrollPostID = nil } else { model.scrollPostID = nil }
        root.layoutSubtreeIfNeeded();try await settle(value)
        return value
    }
    private func scrolls(_ view:NSView)->[NativeTimelineScrollView] { (view as? NativeTimelineScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
    private func editors(_ view:NSView)->[NSTextView] {
        let own = (view as? NSTextView).map { $0.isEditable && !$0.isFieldEditor ? [$0] : [] } ?? []
        return own+view.subviews.flatMap(editors)
    }
    private func cell(_ id:Int64,in value:Harness)->NativeVirtualTimeline.Cell? {
        value.document.canonicalRows.firstIndex(of:.post(id)).flatMap { value.document.hostedView(forRow:$0) as? NativeVirtualTimeline.Cell }
    }
    private func settle(_ value:Harness) async throws {
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds:15_000_000);value.root.layoutSubtreeIfNeeded();value.root.needsDisplay = true;value.root.displayIfNeeded()
        }
        value.census.observe(value.document);XCTAssertFalse(value.window.isVisible)
    }
    private func begin(_ value:Harness) async throws -> Editing {
        let neighbor = try XCTUnwrap(cell(119,in:value)),neighborHost = try XCTUnwrap(neighbor.host)
        value.model.beginMessageEditing(owner:value.owner);try await settle(value)
        let candidates = editors(value.document);XCTAssertEqual(candidates.count,1)
        let text = try XCTUnwrap(candidates.first),editingCell = try XCTUnwrap(cell(120,in:value)),host = try XCTUnwrap(editingCell.host),undo = try XCTUnwrap(text.undoManager)
        XCTAssertEqual(text.string,original);XCTAssertTrue(value.window.makeFirstResponder(text));XCTAssertTrue(text.allowsUndo)
        text.setSelectedRange(NSRange(location:(original as NSString).length,length:0))
        undo.beginUndoGrouping();text.insertText(" e\u{301} 😀 unsaved",replacementRange:text.selectedRange());undo.endUndoGrouping()
        text.setSelectedRange(NSRange(location:(original as NSString).length+1,length:2))
        try await settle(value)
        XCTAssertNotEqual(Data(text.string.utf8),Data(original.utf8));XCTAssertGreaterThan(text.selectedRange().length,0);XCTAssertTrue(undo.canUndo)
        return Editing(text:text,cell:editingCell,host:host,undo:undo,content:Data(text.string.utf8),selection:text.selectedRange(),neighbor:neighbor,neighborHost:neighborHost)
    }
    private func scrollTo(_ id:Int64,in value:Harness) async throws {
        for _ in 0..<20 {
            let index = try XCTUnwrap(value.document.canonicalRows.firstIndex(of:.post(id))),row = value.document.rect(ofRow:index)
            value.scroll.contentView.scroll(to:NSPoint(x:0,y:min(max(0,value.document.bounds.height-value.scroll.contentView.bounds.height),row.minY)))
            value.scroll.reflectScrolledClipView(value.scroll.contentView);try await settle(value)
            if row.intersects(value.scroll.documentVisibleRect),cell(id,in:value)?.host != nil { return }
        }
        XCTFail("Target \(id) did not become visible");throw ChatAPIError.invalidResponse
    }
    private func assertRetained(_ state:Editing,in value:Harness,label:String,file:StaticString = #filePath,line:UInt = #line) {
        let current = cell(120,in:value)
        XCTAssertTrue(current === state.cell,"\(label): active cell was replaced/retired",file:file,line:line)
        XCTAssertTrue(current?.host === state.host,"\(label): active host was replaced/retired",file:file,line:line)
        XCTAssertTrue(state.text.isDescendant(of:state.host),"\(label)",file:file,line:line)
        XCTAssertTrue(state.host.superview === state.cell && state.cell.superview === value.document,"\(label)",file:file,line:line)
        XCTAssertTrue(editors(value.document).contains(where:{ $0 === state.text }),"\(label)",file:file,line:line)
        XCTAssertEqual(value.model.activeMessageEditor,value.owner,"\(label)",file:file,line:line)
        XCTAssertTrue(value.window.firstResponder === state.text,"\(label)",file:file,line:line)
        XCTAssertEqual(Data(state.text.string.utf8),state.content,"\(label)",file:file,line:line)
        XCTAssertEqual(state.text.selectedRange(),state.selection,"\(label)",file:file,line:line)
        XCTAssertTrue(state.text.undoManager === state.undo && state.undo.canUndo,"\(label)",file:file,line:line)
        if let index = value.document.canonicalRows.firstIndex(of:.post(120)),current?.superview === value.document {
            XCTAssertEqual(value.document.row(for:state.text),index,"\(label)",file:file,line:line)
            let canonical = value.document.rect(ofRow:index),actual = state.cell.frame,tolerance = 1/value.window.backingScaleFactor
            XCTAssertEqual(actual.minY,canonical.minY,accuracy:tolerance,"\(label)",file:file,line:line)
            XCTAssertEqual(actual.height,canonical.height,accuracy:tolerance,"\(label)",file:file,line:line)
        }
    }
    private func assertCanonical(_ value:Harness,file:StaticString = #filePath,line:UInt = #line) {
        let rows = value.thread ? value.model.replies : value.model.posts
        XCTAssertEqual(rows.map(\.id),Array(Int64(100)..<160),file:file,line:line)
        XCTAssertEqual(rows.first(where:{ $0.id == 120 })?.message,original,file:file,line:line)
        XCTAssertEqual(value.model.draft,"Synthetic main offscreen draft",file:file,line:line)
        XCTAssertEqual(value.model.threadDrafts[9000],"Synthetic separate reply offscreen draft",file:file,line:line)
        if value.thread { XCTAssertEqual(value.model.posts.map(\.id),Array(Int64(500)..<510),file:file,line:line) }
        XCTAssertFalse(value.model.connected,file:file,line:line);XCTAssertFalse(value.window.isVisible,file:file,line:line)
    }
    private func retention(thread:Bool) async throws {
        let value = try await make(thread:thread),state = try await begin(value)
        let token = value.model.nativeThreadViewportToken,account = value.model.accountGeneration
        for target:Int64 in [150,100] {
            try await scrollTo(target,in:value)
            let index = try XCTUnwrap(value.document.canonicalRows.firstIndex(of:.post(120)))
            XCTAssertFalse(value.document.rect(ofRow:index).intersects(value.scroll.documentVisibleRect))
            assertRetained(state,in:value,label:"away at \(target)");assertCanonical(value)
            XCTAssertNil(state.neighbor.host);XCTAssertNil(state.neighborHost.superview);XCTAssertNil(state.neighbor.superview)
            XCTAssertEqual(value.model.accountGeneration,account);XCTAssertEqual(value.model.nativeThreadViewportToken,token)
            for size in [NSSize(width:790,height:580),NSSize(width:610,height:480),NSSize(width:680,height:520)] {
                value.window.setContentSize(size);try await settle(value)
                assertRetained(state,in:value,label:"offscreen resize at \(target), size \(size)")
                XCTAssertFalse(value.document.rect(ofRow:index).intersects(value.scroll.documentVisibleRect))
                assertCanonical(value)
            }
        }
        try await scrollTo(120,in:value);assertRetained(state,in:value,label:"returned without reopening");assertCanonical(value)
        XCTAssertEqual(editors(value.document).filter({ $0 === state.text }).count,1)
        state.undo.undo();try await settle(value);XCTAssertEqual(state.text.string,original);XCTAssertTrue(state.undo.canRedo)
        state.undo.redo();try await settle(value);XCTAssertEqual(Data(state.text.string.utf8),state.content)
        XCTAssertTrue(state.text.undoManager === state.undo);assertCanonical(value)
    }
    func testMainEditorSurvivesBeyondOverscanAndReturnsWithNativeUndo() async throws { try await retention(thread:false) }
    func testThreadEditorSurvivesBeyondOverscanAndReturnsWithNativeUndo() async throws { try await retention(thread:true) }
    func testEndingOffscreenOwnerReleasesMainEditorHost() async throws {
        let value = try await make(thread:false),state = try await begin(value)
        let stale = try XCTUnwrap(state.cell.debugEditorChange)
        try await scrollTo(150,in:value);assertRetained(state,in:value,label:"release precondition")
        value.model.endMessageEditing(owner:value.owner);try await settle(value)
        XCTAssertNil(value.model.activeMessageEditor);XCTAssertNil(state.cell.host);XCTAssertNil(state.host.superview);XCTAssertNil(state.cell.superview)
        XCTAssertNil(cell(120,in:value));assertCanonical(value)
        let clip = value.scroll.documentVisibleRect
        stale(value.owner,true);stale(value.owner,false);try await settle(value)
        XCTAssertNil(state.cell.debugEditorChange);XCTAssertNil(cell(120,in:value));XCTAssertNil(value.model.activeMessageEditor)
        XCTAssertEqual(value.scroll.documentVisibleRect,clip);assertCanonical(value)
    }
    func testDeletingOffscreenThreadReplyReleasesItsEditorHost() async throws {
        let value = try await make(thread:true),state = try await begin(value)
        let stale = try XCTUnwrap(state.cell.debugEditorChange)
        try await scrollTo(150,in:value);assertRetained(state,in:value,label:"delete precondition")
        value.model.replies.removeAll { $0.id == 120 };try await settle(value)
        XCTAssertFalse(value.document.canonicalRows.contains(.post(120)))
        XCTAssertNil(state.cell.host);XCTAssertNil(state.host.superview);XCTAssertNil(state.cell.superview);XCTAssertNil(value.model.activeMessageEditor)
        XCTAssertEqual(value.model.draft,"Synthetic main offscreen draft");XCTAssertEqual(value.model.replyDraft,"Synthetic separate reply offscreen draft")
        let clip = value.scroll.documentVisibleRect
        stale(value.owner,true);stale(value.owner,false);try await settle(value)
        XCTAssertNil(state.cell.debugEditorChange);XCTAssertNil(cell(120,in:value));XCTAssertNil(value.model.activeMessageEditor)
        XCTAssertEqual(value.scroll.documentVisibleRect,clip);XCTAssertFalse(value.document.canonicalRows.contains(.post(120)))
    }
    func testRootReplacementReleasesOffscreenEditorAndRejectsOldHostCallback() async throws {
        let value = try await make(thread:true),state = try await begin(value)
        let host = try XCTUnwrap(state.host as? NativeVirtualTimeline.Host),late = try XCTUnwrap(host.invalidated),stale = try XCTUnwrap(state.cell.debugEditorChange)
        try await scrollTo(150,in:value);assertRetained(state,in:value,label:"root replacement precondition")
        value.model.threadRoot = try post(9001)
        value.model.replies = try (300..<360).map { try post(Int64($0),thread:9001) }
        late();try await settle(value)
        XCTAssertNil(host.invalidated);XCTAssertNil(state.host.superview);XCTAssertNil(state.cell.superview);XCTAssertNil(value.model.activeMessageEditor)
        XCTAssertFalse(value.document.canonicalRows.contains(.post(120)));XCTAssertTrue(value.document.canonicalRows.contains(.threadRoot(9001)))
        let clip = value.scroll.documentVisibleRect
        late();stale(value.owner,true);stale(value.owner,false);try await settle(value);XCTAssertEqual(value.scroll.documentVisibleRect,clip)
        XCTAssertNil(state.cell.debugEditorChange);XCTAssertNil(value.model.activeMessageEditor)
        XCTAssertFalse(value.document.canonicalRows.contains(.post(120)));XCTAssertNil(cell(120,in:value))
        XCTAssertEqual(value.model.draft,"Synthetic main offscreen draft");XCTAssertEqual(value.model.threadDrafts[9000],"Synthetic separate reply offscreen draft")
        XCTAssertEqual(value.model.replies.map(\.id),Array(Int64(300)..<360))
    }
    func testSwitchingActiveEditorRejectsOldRowCallbacksAndRetainsOnlyNewOwner() async throws {
        let value = try await make(thread:false,secondEditor:true),first = try await begin(value)
        let stale = try XCTUnwrap(first.cell.debugEditorChange),secondOwner = try XCTUnwrap(value.secondOwner)
        // A delayed false callback cannot release the same still-active owner.
        stale(value.owner,false)
        try await scrollTo(150,in:value);assertRetained(first,in:value,label:"late false while original owner active")
        try await scrollTo(130,in:value)
        value.model.beginMessageEditing(owner:secondOwner);try await settle(value)
        let secondCell = try XCTUnwrap(cell(130,in:value)),secondHost = try XCTUnwrap(secondCell.host)
        let secondText = try XCTUnwrap(editors(secondCell).first),secondUndo = try XCTUnwrap(secondText.undoManager)
        let secondOriginal = "Synthetic offscreen row 130"
        XCTAssertEqual(secondText.string,secondOriginal);XCTAssertTrue(value.window.makeFirstResponder(secondText))
        secondText.setSelectedRange(NSRange(location:(secondOriginal as NSString).length,length:0))
        secondUndo.beginUndoGrouping();secondText.insertText(" second e\u{301} 😀",replacementRange:secondText.selectedRange());secondUndo.endUndoGrouping()
        secondText.setSelectedRange(NSRange(location:0,length:3));try await settle(value)
        let content = Data(secondText.string.utf8),selection = secondText.selectedRange()
        try await scrollTo(150,in:value)
        XCTAssertNil(cell(120,in:value));XCTAssertNil(first.cell.host);XCTAssertNil(first.host.superview)
        let clip = value.scroll.documentVisibleRect
        stale(value.owner,true);stale(value.owner,false);try await settle(value)
        XCTAssertNil(cell(120,in:value));XCTAssertNil(first.cell.debugEditorChange)
        XCTAssertTrue(cell(130,in:value) === secondCell);XCTAssertTrue(secondCell.host === secondHost)
        XCTAssertTrue(secondHost.superview === secondCell && secondCell.superview === value.document)
        XCTAssertEqual(value.model.activeMessageEditor,secondOwner);XCTAssertTrue(value.window.firstResponder === secondText)
        XCTAssertEqual(Data(secondText.string.utf8),content);XCTAssertEqual(secondText.selectedRange(),selection)
        XCTAssertTrue(secondText.undoManager === secondUndo && secondUndo.canUndo)
        XCTAssertEqual(value.scroll.documentVisibleRect,clip)
        try await scrollTo(130,in:value)
        XCTAssertTrue(editors(secondCell).contains(where:{ $0 === secondText }))
        secondUndo.undo();try await settle(value);XCTAssertEqual(secondText.string,secondOriginal)
        secondUndo.redo();try await settle(value);XCTAssertEqual(Data(secondText.string.utf8),content)
        assertCanonical(value)
    }
    func testAccountResetReleasesOffscreenEditorAndRejectsCapturedOwnerCallbacks() async throws {
        let value = try await make(thread:false),state = try await begin(value)
        let stale = try XCTUnwrap(state.cell.debugEditorChange),account = value.model.accountGeneration
        try await scrollTo(150,in:value);assertRetained(state,in:value,label:"account reset precondition")
        value.model.signOutLocally();try await settle(value)
        XCTAssertNotEqual(value.model.accountGeneration,account)
        XCTAssertNil(value.model.activeMessageEditor);XCTAssertNil(state.cell.host);XCTAssertNil(state.host.superview);XCTAssertNil(state.cell.superview)
        XCTAssertTrue(value.model.posts.isEmpty);XCTAssertTrue(value.model.replies.isEmpty)
        XCTAssertFalse(value.document.canonicalRows.contains(.post(120)))
        let clip = value.scroll.documentVisibleRect
        stale(value.owner,true);stale(value.owner,false);try await settle(value)
        XCTAssertNil(state.cell.debugEditorChange);XCTAssertNil(value.model.activeMessageEditor)
        XCTAssertFalse(value.document.canonicalRows.contains(.post(120)));XCTAssertNil(cell(120,in:value))
        XCTAssertEqual(value.scroll.documentVisibleRect,clip);XCTAssertFalse(value.window.isVisible)
    }

}
#endif
