#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeVirtualTimelineLifecycleTests:XCTestCase {
    @MainActor private struct Harness {
        let model:NativeChatPreviewModel
        let coordinator:NativeVirtualTimeline.Coordinator
        let scroll:NativeTableTimeline.Scroll
        let document:NativeVirtualTimeline.Document
        let window:NSWindow
        func update() { coordinator.update(NativeVirtualTimeline(model:model,onBottomChanged:{ _ in })) }
    }
    private func posts(channel:Int64 = 23) throws -> [ChatPost] {
        try (100..<160).map { id in
            let value:[String:Any] = ["post_id":id,"channel_id":channel,"creator_id":id%2+10,"type":"normal","message":"Synthetic isolated viewport row \(id)","create_at":1000+id]
            return try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:value))
        }
    }
    private func settle(_ value:Harness) async {
        for _ in 0..<10 {
            value.window.contentView?.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        XCTAssertFalse(value.window.isVisible)
    }
    private func harness() async throws -> Harness {
        _ = NSApplication.shared
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,notificationDefaults:nil)
        model.channels = try [23,24].map { id in
            try JSONDecoder().decode(ChatChannel.self,from:Data("""
            {"channel_id":\(id),"name":"Synthetic isolated \(id)","type":"channel","encrypted":false,"unread":0}
            """.utf8))
        }
        model.selection = 23;model.posts = try posts();model.draft = "Synthetic draft retained"
        let view = NativeVirtualTimeline(model:model,onBottomChanged:{ _ in }),coordinator = view.makeCoordinator()
        let scroll = view.makeTimelineView(coordinator:coordinator)
        let document = try XCTUnwrap(scroll.documentView as? NativeVirtualTimeline.Document)
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:600,height:360),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = scroll
        let result = Harness(model:model,coordinator:coordinator,scroll:scroll,document:document,window:window)
        result.update();await settle(result)
        XCTAssertEqual(document.numberOfRows,62)
        addTeardownBlock { @MainActor in coordinator.detach();window.contentView = nil;window.close() }
        return result
    }
    private func hosted(_ index:Int,in value:Harness) throws -> (NativeVirtualTimeline.Cell,NativeVirtualTimeline.Host) {
        let cell = try XCTUnwrap(value.document.hostedView(forRow:index) as? NativeVirtualTimeline.Cell)
        return (cell,try XCTUnwrap(cell.host as? NativeVirtualTimeline.Host))
    }
    private func position(_ id:Int64,in value:Harness) async throws -> Int {
        value.model.scrollPostID = id;value.update();await settle(value)
        value.model.scrollPostID = nil;value.update();await settle(value)
        let index = try XCTUnwrap(value.document.canonicalRows.firstIndex(of:.post(id)))
        value.scroll.contentView.scroll(to:NSPoint(x:0,y:value.document.rect(ofRow:index).minY))
        value.scroll.reflectScrolledClipView(value.scroll.contentView);await settle(value)
        _ = try hosted(index,in:value)
        return index
    }
    private func offset(_ index:Int,in value:Harness)->CGFloat { value.document.rect(ofRow:index).minY-value.scroll.documentVisibleRect.minY }
    private func key(_ code:UInt16,in value:Harness,flags:NSEvent.ModifierFlags = []) throws -> NSEvent {
        let chars:[UInt16:String] = [115:"\u{F729}",119:"\u{F72B}",116:"\u{F72C}",121:"\u{F72D}",125:"\u{F701}",126:"\u{F700}"]
        return try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:value.window.windowNumber,context:nil,characters:chars[code] ?? "x",charactersIgnoringModifiers:chars[code] ?? "x",isARepeat:false,keyCode:code))
    }
    func testNativePageDownCancelsQueuedOldJumpAndPreservesCurrentReader() async throws {
        let value = try await harness();_ = try await position(120,in:value)
        let beforeInput = value.document.debugDiagnostics["input_generation"] as? String
        value.model.scrollPostID = 150;value.update()
        let before = value.scroll.documentVisibleRect.minY
        XCTAssertTrue(value.window.makeFirstResponder(value.document))
        value.document.keyDown(with:try key(121,in:value))
        XCTAssertNotEqual(value.scroll.documentVisibleRect.minY,before)
        let clip = value.scroll.documentVisibleRect
        let row = try XCTUnwrap(value.document.canonicalRows.indices.first { index in
            let rect = value.document.rect(ofRow:index)
            if case .post = value.document.canonicalRows[index] { return rect.intersection(clip).height >= min(20,rect.height) }
            return false
        })
        let expected = offset(row,in:value)
        XCTAssertNotEqual(value.document.debugDiagnostics["input_generation"] as? String,beforeInput)
        await settle(value);XCTAssertEqual(offset(row,in:value),expected,accuracy:1/value.window.backingScaleFactor)
        value.update();await settle(value)
        XCTAssertEqual(offset(row,in:value),expected,accuracy:1/value.window.backingScaleFactor)
        XCTAssertEqual(value.model.draft,"Synthetic draft retained")
    }
    func testAllVerticalKeysClampAndKeepCanonicalNativeHostOrder() async throws {
        let value = try await harness();_ = try await position(120,in:value)
        for code:UInt16 in [125,126,121,116,119,115] {
            let clip = value.scroll.documentVisibleRect,document = value.document.bounds
            let line = max(1,value.scroll.verticalLineScroll),page = max(line,clip.height-value.scroll.verticalPageScroll)
            let maximum = max(0,document.maxY-clip.height),expected:CGFloat
            switch code {
            case 125:expected = clip.minY+line
            case 126:expected = clip.minY-line
            case 121:expected = clip.minY+page
            case 116:expected = clip.minY-page
            case 119:expected = maximum
            default:expected = 0
            }
            value.document.keyDown(with:try key(code,in:value))
            XCTAssertEqual(value.scroll.documentVisibleRect.minY,min(maximum,max(0,expected)),accuracy:1/value.window.backingScaleFactor)
            await settle(value)
            XCTAssertEqual(value.model.selection,23)
            XCTAssertEqual(value.document.debugDiagnostics["host_order_is_canonical"] as? Bool,true)
        }
    }
    func testModifiedAndOrdinaryKeysLeaveReaderInputAndPositionUnchanged() async throws {
        let value = try await harness();_ = try await position(120,in:value)
        let original = value.scroll.documentVisibleRect,input = value.document.debugDiagnostics["input_generation"] as? String
        for flags:NSEvent.ModifierFlags in [.command,.control,.option,.shift] { XCTAssertFalse(value.scroll.handleNavigation(try key(121,in:value,flags:flags))) }
        XCTAssertFalse(value.scroll.handleNavigation(try key(7,in:value)))
        XCTAssertEqual(value.scroll.documentVisibleRect,original)
        XCTAssertEqual(value.document.debugDiagnostics["input_generation"] as? String,input)
    }
    func testOldHostCallbackCannotChangeReplacementConversation() async throws {
        let value = try await harness(),row = try await position(120,in:value)
        let (oldCell,oldHost) = try hosted(row,in:value),late = try XCTUnwrap(oldHost.invalidated)
        let token = value.model.historyViewportToken
        late();value.model.selection = 24;value.model.posts = try posts(channel:24);value.update()
        XCTAssertNotEqual(token,value.model.historyViewportToken)
        late();await settle(value)
        XCTAssertNil(oldHost.invalidated);XCTAssertNil(oldHost.superview);XCTAssertNil(oldCell.superview)
        XCTAssertEqual(value.document.debugDiagnostics["channel"] as? String,"24")
        XCTAssertEqual(value.document.debugDiagnostics["token"] as? String,value.model.historyViewportToken.uuidString)
        let newRow = try await position(130,in:value),expected = offset(newRow,in:value)
        late();await settle(value)
        XCTAssertEqual(offset(newRow,in:value),expected,accuracy:1/value.window.backingScaleFactor)
        XCTAssertEqual(value.model.posts.map(\.channel_id),Array(repeating:24,count:60))
    }
    func testAccountResetRejectsPendingGeometryBeforeNewViewUpdate() async throws {
        let value = try await harness(),row = try await position(120,in:value)
        let (_,host) = try hosted(row,in:value),late = try XCTUnwrap(host.invalidated)
        let account = value.model.accountGeneration,commits = value.document.debugDiagnostics["height_commits"] as? Int
        late();value.model.signOutLocally();XCTAssertNotEqual(account,value.model.accountGeneration)
        late();await settle(value)
        XCTAssertEqual(value.document.debugDiagnostics["height_commits"] as? Int,commits)
        value.update();await settle(value)
        XCTAssertEqual(value.document.debugDiagnostics["account"] as? Int,value.model.accountGeneration)
        XCTAssertEqual(value.document.numberOfRows,3);XCTAssertTrue(value.model.posts.isEmpty)
    }
    func testDetachedCallbacksCannotRehostOrMoveTheOldReader() async throws {
        let value = try await harness(),row = try await position(120,in:value)
        let (_,host) = try hosted(row,in:value),late = try XCTUnwrap(host.invalidated),input = try XCTUnwrap(value.scroll.input)
        late();value.coordinator.detach();await settle(value)
        let original = value.scroll.documentVisibleRect
        XCTAssertTrue(value.document.subviews.isEmpty);XCTAssertTrue(value.document.debugDiagnostics.isEmpty)
        XCTAssertNil(value.scroll.input);XCTAssertNil(host.invalidated);XCTAssertNil(host.superview)
        late();input();await settle(value)
        XCTAssertEqual(value.scroll.documentVisibleRect,original);XCTAssertTrue(value.document.subviews.isEmpty)
        XCTAssertEqual(value.model.draft,"Synthetic draft retained");XCTAssertEqual(value.model.selection,23)
    }
}
#endif
