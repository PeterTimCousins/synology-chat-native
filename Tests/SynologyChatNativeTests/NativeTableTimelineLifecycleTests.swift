#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import SynologyChatNative

/// Real, never-visible AppKit graph and real message rows, with no API client.
@MainActor final class NativeTableTimelineLifecycleTests:XCTestCase {
    @MainActor private struct Harness {
        let model:NativeChatPreviewModel
        let coordinator:NativeTableTimeline.Coordinator
        let scroll:NativeTableTimeline.Scroll
        let table:NativeTableTimeline.Table
        let window:NSWindow
        func update() { coordinator.update(NativeTableTimeline(model:model,onBottomChanged:{ _ in })) }
    }
    private func posts(channel:Int64 = 23) throws -> [ChatPost] {
        try (100..<160).map { id in
            try JSONDecoder().decode(ChatPost.self,from:Data("""
            {"post_id":\(id),"channel_id":\(channel),"creator_id":\(id % 2 + 10),"type":"normal","message":"Synthetic lifecycle row \(id): an isolated reader with no account or server.","create_at":\(1000+id)}
            """.utf8))
        }
    }
    private func host() async throws -> Harness {
        _ = NSApplication.shared
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,notificationDefaults:nil)
        model.channels = try [23,24].map { id in
            try JSONDecoder().decode(ChatChannel.self,from:Data("""
            {"channel_id":\(id),"name":"Synthetic isolated \(id)","type":"channel","encrypted":false,"unread":0}
            """.utf8))
        }
        model.selection = 23;model.posts = try posts();model.draft = "Synthetic draft must survive"
        let timeline = NativeTableTimeline(model:model,onBottomChanged:{ _ in }),coordinator = timeline.makeCoordinator()
        let scroll = timeline.makeTimelineView(coordinator:coordinator)
        let table = try XCTUnwrap(scroll.documentView as? NativeTableTimeline.Table)
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:600,height:360),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = scroll
        let result = Harness(model:model,coordinator:coordinator,scroll:scroll,table:table,window:window)
        result.update();await settle(result)
        addTeardownBlock { @MainActor in coordinator.detach();window.contentView = nil;window.close() }
        XCTAssertFalse(window.isVisible);XCTAssertEqual(table.numberOfRows,62)
        return result
    }
    private func settle(_ host:Harness) async {
        for _ in 0..<8 {
            host.window.contentView?.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        XCTAssertFalse(host.window.isVisible)
    }
    private func position(_ id:Int64,in host:Harness) async throws -> Int {
        host.model.scrollPostID = id;host.update();await settle(host)
        host.model.scrollPostID = nil;host.update();await settle(host)
        let index = Int(id-100)+1
        host.scroll.contentView.scroll(to:NSPoint(x:0,y:host.table.rect(ofRow:index).minY))
        host.scroll.reflectScrolledClipView(host.scroll.contentView)
        await settle(host)
        XCTAssertNotNil((host.table.view(atColumn:0,row:index,makeIfNecessary:false) as? NativeTableTimeline.Cell)?.host)
        return index
    }
    private func offset(_ row:Int,in host:Harness)->CGFloat { host.table.rect(ofRow:row).minY-host.scroll.documentVisibleRect.minY }
    private func key(_ code:UInt16,in host:Harness,modifiers:NSEvent.ModifierFlags = []) throws -> NSEvent {
        let characters:[UInt16:String] = [115:"\u{F729}",119:"\u{F72B}",116:"\u{F72C}",121:"\u{F72D}",125:"\u{F701}",126:"\u{F700}"]
        return try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,
            windowNumber:host.window.windowNumber,context:nil,characters:characters[code] ?? "x",charactersIgnoringModifiers:characters[code] ?? "x",isARepeat:false,keyCode:code))
    }
    private func localPageDown(_ host:Harness) throws {
        // Deliver only to this owned scroll view; never post to the desktop.
        let event = try key(121,in:host)
        XCTAssertTrue(host.window.makeFirstResponder(host.table))
        host.table.keyDown(with:event)
    }
    func testLocalPageDownBeforeQueuedNavigationCommitOwnsReadingPosition() async throws {
        let host = try await host()
        _ = try await position(120,in:host)
        let beforeInput = host.table.debugDiagnostics["input_generation"] as? String
        host.model.scrollPostID = 150;host.update() // Queued, not committed.
        let beforeKey = host.scroll.documentVisibleRect.minY
        try localPageDown(host)
        let afterKey = host.scroll.documentVisibleRect.minY
        let range = host.table.rows(in:host.scroll.documentVisibleRect)
        let row = try XCTUnwrap((range.location..<(range.location+range.length)).first { index in
            let frame = host.table.rect(ofRow:index)
            return index > 0 && index < 61 && frame.intersection(host.scroll.documentVisibleRect).height >= min(20,frame.height)
        })
        let readerOffset = offset(row,in:host)
        XCTAssertNotEqual(host.table.debugDiagnostics["input_generation"] as? String,beforeInput)
        XCTAssertNotEqual(beforeKey,afterKey,"The local AppKit key event must actually move the owned scroll view")
        await settle(host)
        XCTAssertEqual(offset(row,in:host),readerOffset,accuracy:1/host.window.backingScaleFactor)
        // An unrelated model refresh must not revive the old navigation revision.
        host.update();await settle(host)
        XCTAssertEqual(offset(row,in:host),readerOffset,accuracy:1/host.window.backingScaleFactor)
        XCTAssertEqual(host.model.draft,"Synthetic draft must survive")
    }
    func testVerticalReadingKeysMoveAndClampWithoutSelectingMessageRows() async throws {
        let host = try await host()
        _ = try await position(120,in:host)
        for code:UInt16 in [125,126,121,116,119,115] {
            let visible = host.scroll.documentVisibleRect,document = host.table.bounds
            let line = max(1,host.scroll.verticalLineScroll),page = max(line,visible.height-host.scroll.verticalPageScroll)
            let maximum = max(document.minY,document.maxY-visible.height)
            let expected:CGFloat
            switch code {
            case 125:expected = visible.minY+line
            case 126:expected = visible.minY-line
            case 121:expected = visible.minY+page
            case 116:expected = visible.minY-page
            case 119:expected = maximum
            default:expected = document.minY
            }
            host.table.keyDown(with:try key(code,in:host))
            XCTAssertEqual(host.scroll.documentVisibleRect.minY,min(maximum,max(document.minY,expected)),accuracy:1/host.window.backingScaleFactor)
            XCTAssertEqual(host.table.selectedRow,-1)
            await settle(host)
        }
        host.table.keyDown(with:try key(126,in:host))
        XCTAssertEqual(host.scroll.documentVisibleRect.minY,0)
        host.table.keyDown(with:try key(119,in:host));await settle(host)
        host.table.keyDown(with:try key(125,in:host))
        XCTAssertEqual(host.scroll.documentVisibleRect.maxY,host.table.bounds.maxY,accuracy:1/host.window.backingScaleFactor)
        XCTAssertEqual(host.model.draft,"Synthetic draft must survive")
    }
    func testModifiedShortcutsAndNonNavigationKeysAreNotConsumedByReader() async throws {
        let host = try await host()
        _ = try await position(120,in:host)
        let original = host.scroll.documentVisibleRect,input = host.table.debugDiagnostics["input_generation"] as? String
        for flags:NSEvent.ModifierFlags in [.command,.control,.option,.shift] {
            XCTAssertFalse(host.scroll.handleNavigation(try key(121,in:host,modifiers:flags)))
        }
        XCTAssertFalse(host.scroll.handleNavigation(try key(7,in:host)))
        XCTAssertEqual(host.scroll.documentVisibleRect,original)
        XCTAssertEqual(host.table.debugDiagnostics["input_generation"] as? String,input)
    }
    func testCapturedOldHostCallbacksCannotRestoreOldConversationAfterReplacement() async throws {
        let host = try await host(),row = try await position(120,in:host)
        let oldCell = try XCTUnwrap(host.table.view(atColumn:0,row:row,makeIfNecessary:false) as? NativeTableTimeline.Cell)
        let oldHost = try XCTUnwrap(oldCell.host),lateInvalidation = try XCTUnwrap(oldHost.invalidated)
        let oldGeometry = try XCTUnwrap(host.table.geometryChanged),oldToken = host.model.historyViewportToken
        oldGeometry() // Queue work for the old scope.
        host.model.selection = 24;host.model.posts = try posts(channel:24);host.update()
        XCTAssertNotEqual(host.model.historyViewportToken,oldToken)
        lateInvalidation();oldGeometry();await settle(host)
        XCTAssertEqual(host.table.debugDiagnostics["channel"] as? String,"24")
        XCTAssertEqual(host.table.debugDiagnostics["token"] as? String,host.model.historyViewportToken.uuidString)
        XCTAssertNil(oldHost.invalidated);XCTAssertNil(oldHost.superview)
        let newRow = try await position(130,in:host),baseline = offset(newRow,in:host)
        lateInvalidation();oldGeometry();await settle(host)
        XCTAssertEqual(offset(newRow,in:host),baseline,accuracy:1/host.window.backingScaleFactor)
        XCTAssertEqual(host.model.selection,24);XCTAssertEqual(host.model.posts.map(\.channel_id),Array(repeating:24,count:60))
    }
    func testQueuedCallbacksAfterAccountResetCannotCommitOldScopeBeforeRepresentableUpdate() async throws {
        let host = try await host(),row = try await position(120,in:host)
        let cell = try XCTUnwrap(host.table.view(atColumn:0,row:row,makeIfNecessary:false) as? NativeTableTimeline.Cell)
        let late = try XCTUnwrap(cell.host?.invalidated),geometry = try XCTUnwrap(host.table.geometryChanged)
        let oldAccount = host.model.accountGeneration,commits = host.table.debugDiagnostics["height_commits"] as? Int
        geometry();host.model.signOutLocally();XCTAssertNotEqual(host.model.accountGeneration,oldAccount)
        late();await settle(host)
        XCTAssertEqual(host.table.debugDiagnostics["height_commits"] as? Int,commits,"A stale callback must stop before AppKit remeasurement")
        host.update();await settle(host)
        XCTAssertEqual(host.table.debugDiagnostics["account"] as? Int,host.model.accountGeneration)
        XCTAssertEqual(host.table.numberOfRows,3);XCTAssertTrue(host.model.posts.isEmpty)
    }
    func testDetachedQueuedAndCapturedCallbacksCannotMutateReaderOrRetainHosts() async throws {
        let host = try await host(),row = try await position(120,in:host)
        let cell = try XCTUnwrap(host.table.view(atColumn:0,row:row,makeIfNecessary:false) as? NativeTableTimeline.Cell)
        let oldHost = try XCTUnwrap(cell.host),late = try XCTUnwrap(oldHost.invalidated)
        let geometry = try XCTUnwrap(host.table.geometryChanged),input = try XCTUnwrap(host.scroll.input)
        geometry()
        host.coordinator.detach()
        XCTAssertNil(host.table.delegate);XCTAssertNil(host.table.dataSource)
        XCTAssertNil(host.table.geometryChanged);XCTAssertNil(host.scroll.input)
        XCTAssertNil(oldHost.invalidated);XCTAssertNil(oldHost.superview)
        // Detaching the data source itself legitimately empties/resizes the
        // document. Only subsequent stale callbacks must leave it unchanged.
        await settle(host);let baseline = host.scroll.documentVisibleRect
        late();geometry();input();await settle(host)
        XCTAssertEqual(host.scroll.documentVisibleRect,baseline)
        XCTAssertEqual(host.model.selection,23);XCTAssertEqual(host.model.draft,"Synthetic draft must survive")
    }
}
#endif
