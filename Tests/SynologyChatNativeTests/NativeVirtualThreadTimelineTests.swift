#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import SynologyChatNative

/// Synthetic model state and real hidden native hosts; no API/client/session.
@MainActor final class NativeVirtualThreadTimelineTests:XCTestCase {
    @MainActor private final class Bottoms { var values:[Bool] = [] }
    @MainActor private struct Harness {
        let model:NativeChatPreviewModel
        let coordinator:NativeVirtualTimeline.Coordinator
        let scroll:NativeTableTimeline.Scroll
        let document:NativeVirtualTimeline.Document
        let window:NSWindow
        let bottoms:Bottoms
        func update() { coordinator.update(NativeVirtualTimeline(model:model,onBottomChanged:{ bottoms.values.append($0) },inThread:true)) }
    }
    private func post(_ id:Int64,root:Int64? = nil,text:String? = nil) throws -> ChatPost {
        var object:[String:Any] = ["post_id":id,"channel_id":23,"creator_id":id%2+10,"type":"normal","message":text ?? "Synthetic thread viewport row \(id)","create_at":1000+id]
        if let root { object["thread_id"] = root }
        return try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:object))
    }
    private func replies(root:Int64,start:Int64 = 100) throws -> [ChatPost] { try (start..<(start+60)).map { try post($0,root:root) } }
    private func settle(_ value:Harness) async {
        for _ in 0..<10 {
            value.window.contentView?.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        XCTAssertFalse(value.window.isVisible)
    }
    private func harness(context:Bool = false,older:Bool = false) async throws -> Harness {
        _ = NSApplication.shared
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,notificationDefaults:nil)
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":23,"name":"Synthetic thread viewport","type":"channel","encrypted":false,"unread":0}"#.utf8))]
        model.selection = 23;model.posts = try (500..<510).map { try post(Int64($0),text:"Separate main message \($0)") }
        model.threadRoot = try post(9000,text:"Synthetic thread root A")
        model.replies = try replies(root:9000);model.threadViewingContext = context;model.canLoadOlderReplies = older
        model.draft = "Synthetic main draft retained";model.replyDraft = "Synthetic thread reply draft retained"
        let bottoms = Bottoms(),view = NativeVirtualTimeline(model:model,onBottomChanged:{ bottoms.values.append($0) },inThread:true),coordinator = view.makeCoordinator()
        let scroll = view.makeTimelineView(coordinator:coordinator)
        let document = try XCTUnwrap(scroll.documentView as? NativeVirtualTimeline.Document)
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:600,height:360),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = scroll
        let result = Harness(model:model,coordinator:coordinator,scroll:scroll,document:document,window:window,bottoms:bottoms)
        addTeardownBlock { @MainActor in coordinator.detach();window.contentView = nil;window.close() }
        result.update();await settle(result)
        return result
    }
    private func row(_ id:Int64,in value:Harness) throws -> Int { try XCTUnwrap(value.document.canonicalRows.firstIndex(of:.post(id))) }
    private func hosted(_ index:Int,in value:Harness) throws -> (NativeVirtualTimeline.Cell,NativeVirtualTimeline.Host) {
        let cell = try XCTUnwrap(value.document.hostedView(forRow:index) as? NativeVirtualTimeline.Cell)
        return (cell,try XCTUnwrap(cell.host as? NativeVirtualTimeline.Host))
    }
    private func position(_ id:Int64,in value:Harness) async throws -> Int {
        value.model.nativeThreadScrollPostID = id;value.update();await settle(value)
        value.model.nativeThreadScrollPostID = nil;value.update();await settle(value)
        let index = try row(id,in:value)
        value.scroll.contentView.scroll(to:NSPoint(x:0,y:value.document.rect(ofRow:index).minY))
        value.scroll.reflectScrolledClipView(value.scroll.contentView);await settle(value)
        _ = try hosted(index,in:value)
        return index
    }
    private func offset(_ index:Int,in value:Harness)->CGFloat { value.document.rect(ofRow:index).minY-value.scroll.documentVisibleRect.minY }
    private func firstReadable(in value:Harness)->Int64? {
        let clip = value.scroll.documentVisibleRect
        for index in value.document.canonicalRows.indices {
            guard case let .post(id) = value.document.canonicalRows[index] else { continue }
            let frame = value.document.rect(ofRow:index)
            if frame.intersection(clip).height >= min(20,frame.height) { return id }
        }
        return nil
    }
    private func bottom(_ value:Harness)->Bool { NativeScrollVisibility.isAtBottom(content:value.document.bounds,visible:value.scroll.documentVisibleRect,flipped:true) }
    private func installSiblingResizeContainer(_ value:Harness) async {
        let size = value.window.contentLayoutRect.size
        value.window.contentView = nil
        let container = NSView(frame:NSRect(origin:.zero,size:size))
        value.window.contentView = container
        value.scroll.autoresizingMask = [.width]
        value.scroll.frame = container.bounds;container.addSubview(value.scroll)
        await settle(value)
    }
    func testSiblingFrameOnlyResizeKeepsLatestWithoutTimelineUpdate() async throws {
        let value = try await harness();await installSiblingResizeContainer(value)
        XCTAssertTrue(bottom(value))
        let input = value.document.debugDiagnostics["input_generation"] as? String
        for height:CGFloat in [240,360] {
            // No model update or coordinator.update: emulate a sibling editor.
            value.scroll.setFrameSize(NSSize(width:600,height:height));await settle(value)
            XCTAssertEqual(value.scroll.documentVisibleRect.height,height,accuracy:1/value.window.backingScaleFactor)
            XCTAssertEqual(value.document.bounds.maxY-value.scroll.documentVisibleRect.maxY,0,accuracy:1/value.window.backingScaleFactor)
            XCTAssertTrue(bottom(value));XCTAssertEqual(value.document.debugDiagnostics["input_generation"] as? String,input)
            assertHostInvariants(value)
        }
    }
    func testSiblingFrameOnlyResizeRetainsOlderReplyOffsetWithoutTimelineUpdate() async throws {
        let value = try await harness();await installSiblingResizeContainer(value)
        let index = try await position(120,in:value),before = offset(index,in:value)
        let input = value.document.debugDiagnostics["input_generation"] as? String
        for height:CGFloat in [240,360] {
            value.scroll.setFrameSize(NSSize(width:600,height:height));await settle(value)
            XCTAssertEqual(value.scroll.documentVisibleRect.height,height,accuracy:1/value.window.backingScaleFactor)
            XCTAssertEqual(firstReadable(in:value),120)
            XCTAssertEqual(offset(index,in:value),before,accuracy:1/value.window.backingScaleFactor)
            XCTAssertFalse(bottom(value));XCTAssertEqual(value.document.debugDiagnostics["input_generation"] as? String,input)
            assertHostInvariants(value)
        }
    }
    func testNativePageUpAfterSiblingResizeCancelsPendingLatestRetention() async throws {
        let value = try await harness();await installSiblingResizeContainer(value)
        // Establish actual destination geometry before asserting a stable
        // readable ID. An unhosted estimated90pt row can become a14pt tail
        // after its real75pt measurement without moving its retained offset.
        _ = try await position(150,in:value)
        let warmed = try (150...154).map { id -> (Int64,CGFloat) in
            let index = try row(Int64(id),in:value),(_,host) = try hosted(index,in:value)
            let height = value.document.rect(ofRow:index).height
            XCTAssertEqual(height,host.fittingSize.height,accuracy:1/value.window.backingScaleFactor)
            return (Int64(id),height)
        }
        scrollToLatestForInputSetup(value);await settle(value)
        XCTAssertTrue(bottom(value))
        value.scroll.setFrameSize(NSSize(width:600,height:240))
        let input = value.document.debugDiagnostics["input_generation"] as? String
        let event = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:value.window.windowNumber,context:nil,characters:"\u{F72C}",charactersIgnoringModifiers:"\u{F72C}",isARepeat:false,keyCode:116))
        value.document.keyDown(with:event)
        let id = try XCTUnwrap(firstReadable(in:value)),index = try row(id,in:value),expected = offset(index,in:value)
        XCTAssertEqual(value.document.rect(ofRow:index).height,try XCTUnwrap(warmed.first(where:{ $0.0 == id })?.1),accuracy:1/value.window.backingScaleFactor)
        let beforeFrame = value.document.rect(ofRow:index),beforeHosted = value.document.hostedView(forRow:index) != nil
        XCTAssertNotEqual(value.document.debugDiagnostics["input_generation"] as? String,input)
        await settle(value)
        XCTAssertEqual(firstReadable(in:value),id,"Reference \(id) before=\(beforeFrame), hosted=\(beforeHosted), after=\(value.document.rect(ofRow:index)), offset \(expected)→\(offset(index,in:value))")
        XCTAssertEqual(offset(index,in:value),expected,accuracy:1/value.window.backingScaleFactor)
        XCTAssertFalse(bottom(value));assertHostInvariants(value)
    }
    private func scrollToLatestForInputSetup(_ value:Harness) {
        value.scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,value.document.bounds.height-value.scroll.documentVisibleRect.height)))
        value.scroll.reflectScrolledClipView(value.scroll.contentView)
    }
    func testColdPageUpAfterSiblingResizeRealizesRequestedRowsWithoutLatestRevival() async throws {
        let value = try await harness();await installSiblingResizeContainer(value)
        value.scroll.setFrameSize(NSSize(width:600,height:240))
        let event = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:value.window.windowNumber,context:nil,characters:"\u{F72C}",charactersIgnoringModifiers:"\u{F72C}",isARepeat:false,keyCode:116))
        value.document.keyDown(with:event)
        let clip = value.scroll.documentVisibleRect
        let requested = value.document.canonicalRows.enumerated().compactMap { index,row -> Int64? in
            if case let .post(id) = row,value.document.rect(ofRow:index).intersects(clip) { return id }
            return nil
        }
        XCTAssertFalse(requested.isEmpty);XCTAssertFalse(requested.contains(159))
        XCTAssertTrue(requested.contains { id in
            guard let index = value.document.canonicalRows.firstIndex(of:.post(id)) else { return false }
            return value.document.hostedView(forRow:index) == nil
        },"This case must start with genuinely unhosted destination rows")
        await settle(value)
        let visible = try XCTUnwrap(firstReadable(in:value)),index = try row(visible,in:value),actual = offset(index,in:value)
        XCTAssertTrue(requested.contains(visible));_ = try hosted(index,in:value)
        XCTAssertFalse(bottom(value));assertHostInvariants(value)
        value.update();await settle(value)
        XCTAssertEqual(firstReadable(in:value),visible)
        XCTAssertEqual(offset(index,in:value),actual,accuracy:1/value.window.backingScaleFactor)
        XCTAssertFalse(bottom(value));assertHostInvariants(value)
    }
    func testReaderReplacementInsideNativeResizeReleasesOwnershipForNewReader() async throws {
        let value = try await harness();await installSiblingResizeContainer(value)
        let original = try XCTUnwrap(value.scroll.viewportResize)
        let replacement = try post(9100,text:"Synthetic replacement during resize"),newReplies = try replies(root:9100,start:200)
        var replaced = false
        value.scroll.viewportResize = { [weak model = value.model] starting in
            original(starting)
            if starting,!replaced {
                replaced = true;model?.threadRoot = replacement;model?.replies = newReplies
            }
        }
        value.scroll.setFrameSize(NSSize(width:600,height:240))
        XCTAssertTrue(replaced)
        value.update();await settle(value)
        XCTAssertEqual(value.document.debugDiagnostics["root_id"] as? String,"9100")
        let index = try row(220,in:value)
        value.scroll.contentView.scroll(to:NSPoint(x:0,y:value.document.rect(ofRow:index).minY))
        value.scroll.reflectScrolledClipView(value.scroll.contentView);await settle(value)
        _ = try hosted(index,in:value)
        XCTAssertEqual(firstReadable(in:value),220)
        XCTAssertEqual(offset(index,in:value),0,accuracy:1/value.window.backingScaleFactor)
        XCTAssertEqual(value.document.debugDiagnostics["host_order_is_canonical"] as? Bool,true)
        XCTAssertFalse(value.window.isVisible);XCTAssertFalse(value.model.connected)
    }
    private func assertHostInvariants(_ value:Harness,file:StaticString = #filePath,line:UInt = #line) {
        let info = value.document.debugDiagnostics
        let maxHosts = info["max_hosted_cells"] as? Int ?? Int.max
        XCTAssertGreaterThan(maxHosts,0,file:file,line:line);XCTAssertLessThanOrEqual(maxHosts,32,file:file,line:line)
        XCTAssertEqual(info["host_order_is_canonical"] as? Bool,true,file:file,line:line)
        XCTAssertEqual(value.model.draft,"Synthetic main draft retained",file:file,line:line)
        XCTAssertEqual(value.model.threadDrafts[9000],"Synthetic thread reply draft retained",file:file,line:line)
        XCTAssertFalse(value.model.connected,file:file,line:line);XCTAssertFalse(value.window.isVisible,file:file,line:line)
    }
    func testThreadRowsHaveExactRootDividerContextAndOlderOrderWithoutMainPosts() async throws {
        let value = try await harness(context:true,older:true)
        let expected:[NativeTableTimelineState.Row] = [.top,.threadRoot(9000),.threadDivider,.threadLatest,.older]+(100..<160).map { .post(Int64($0)) }+[.bottom]
        XCTAssertEqual(value.document.canonicalRows,expected)
        XCTAssertEqual(value.document.numberOfRows,66)
        XCTAssertFalse(value.document.canonicalRows.contains(.post(9000)))
        XCTAssertTrue((500..<510).allSatisfy { !value.document.canonicalRows.contains(.post(Int64($0))) })
        // A root echoed into replies must still have only the distinct root role.
        value.model.replies = [try XCTUnwrap(value.model.threadRoot)]+value.model.replies
        value.update();await settle(value);XCTAssertEqual(value.document.canonicalRows,expected)
        value.model.replies = [];value.update();await settle(value)
        XCTAssertEqual(value.document.canonicalRows,[.top,.threadRoot(9000),.threadDivider,.threadLatest,.older,.empty,.bottom])
        assertHostInvariants(value)
    }
    func testRootReplacementRejectsOldGeometryBeforeParentUpdateAndDetachesOldHost() async throws {
        let value = try await harness(),index = try await position(120,in:value)
        let (oldCell,oldHost) = try hosted(index,in:value),late = try XCTUnwrap(oldHost.invalidated)
        let commits = value.document.debugDiagnostics["height_commits"] as? Int,clip = value.scroll.documentVisibleRect,callbacks = value.bottoms.values.count
        let token = value.model.nativeThreadViewportToken
        late();value.model.threadRoot = try post(9001,text:"Synthetic thread root B");value.model.replies = try replies(root:9001,start:300)
        // Root ID is an independent scope discriminator even if generation did not change.
        XCTAssertEqual(value.model.nativeThreadViewportToken,token)
        late();await settle(value)
        XCTAssertEqual(value.document.debugDiagnostics["height_commits"] as? Int,commits)
        XCTAssertEqual(value.scroll.documentVisibleRect,clip)
        XCTAssertEqual(value.bottoms.values.count,callbacks)
        value.update();await settle(value)
        XCTAssertNil(oldHost.invalidated);XCTAssertNil(oldHost.superview);XCTAssertNil(oldCell.superview)
        XCTAssertTrue(value.document.canonicalRows.contains(.threadRoot(9001)))
        XCTAssertFalse(value.document.canonicalRows.contains(.threadRoot(9000)))
        XCTAssertFalse(value.document.canonicalRows.contains(.post(120)))
        let current = try await position(320,in:value),expected = offset(current,in:value)
        late();await settle(value)
        XCTAssertEqual(offset(current,in:value),expected,accuracy:1/value.window.backingScaleFactor)
        XCTAssertEqual(value.model.replies.map(\.thread_id),Array(repeating:Optional<Int64>(9001),count:60))
        assertHostInvariants(value)
    }
    func testCloseAndReopenSameRootChangesThreadTokenAndRejectsStaleCallback() async throws {
        let value = try await harness(),index = try await position(120,in:value)
        let (_,oldHost) = try hosted(index,in:value),late = try XCTUnwrap(oldHost.invalidated)
        let token = value.model.nativeThreadViewportToken,mainToken = value.model.historyViewportToken
        let root = try XCTUnwrap(value.model.threadRoot),originalReplies = value.model.replies
        let commits = value.document.debugDiagnostics["height_commits"] as? Int
        value.model.closeThread()
        XCTAssertNotEqual(value.model.nativeThreadViewportToken,token)
        XCTAssertEqual(value.model.historyViewportToken,mainToken)
        XCTAssertNil(value.model.nativeThreadScrollPostID)
        late();await settle(value)
        XCTAssertEqual(value.document.debugDiagnostics["height_commits"] as? Int,commits)
        value.model.threadRoot = root;value.model.replies = originalReplies;value.update();await settle(value)
        XCTAssertNil(oldHost.invalidated);XCTAssertNil(oldHost.superview)
        XCTAssertTrue(value.document.canonicalRows.contains(.threadRoot(9000)))
        XCTAssertEqual(value.document.debugDiagnostics["token"] as? String,value.model.nativeThreadViewportToken.uuidString)
        let current = try await position(125,in:value),expected = offset(current,in:value)
        late();await settle(value);XCTAssertEqual(offset(current,in:value),expected,accuracy:1/value.window.backingScaleFactor)
        assertHostInvariants(value)
    }
    func testThreadNavigationIgnoresMainHistoryTargetTokenAndLatestArrayChanges() async throws {
        let value = try await harness(),index = try await position(120,in:value)
        let expected = offset(index,in:value),threadToken = value.model.nativeThreadViewportToken
        let mainRevision = value.model.historyScrollRevision,mainToken = value.model.historyViewportToken
        value.model.scrollPostID = 509;XCTAssertNotEqual(value.model.historyScrollRevision,mainRevision)
        value.update();await settle(value)
        XCTAssertEqual(firstReadable(in:value),120);XCTAssertEqual(offset(try row(120,in:value),in:value),expected,accuracy:1/value.window.backingScaleFactor)
        value.model.posts.append(try post(510,text:"Separate incoming main message"));value.update();await settle(value)
        XCTAssertEqual(firstReadable(in:value),120);XCTAssertEqual(offset(try row(120,in:value),in:value),expected,accuracy:1/value.window.backingScaleFactor)
        // With client nil, this changes the main viewport token and clears its
        // history without fetching; preservingThread keeps this root/replies.
        value.model.loadSelection(preservingThread:true)
        XCTAssertNotEqual(value.model.historyViewportToken,mainToken)
        value.update();await settle(value)
        XCTAssertEqual(value.model.nativeThreadViewportToken,threadToken)
        XCTAssertEqual(firstReadable(in:value),120);XCTAssertEqual(offset(try row(120,in:value),in:value),expected,accuracy:1/value.window.backingScaleFactor)
        XCTAssertEqual(value.model.replies.map(\.id),Array(Int64(100)..<160))
        assertHostInvariants(value)
        // The private latestHistoryScrollRevision UUID is deliberately not
        // mutated by a test-only setter; latest main-array changes are covered.
    }
    func testPrependRetainsFirstReadableReplyAndOneBackingPixelOffset() async throws {
        let value = try await harness(older:true),index = try await position(120,in:value)
        let expected = offset(index,in:value),originalMain = value.model.posts.map(\.id),replyDraft = value.model.replyDraft
        XCTAssertEqual(firstReadable(in:value),120)
        value.model.replies = try (97..<100).map { try post(Int64($0),root:9000) }+value.model.replies
        value.update()
        for delay:UInt64 in [100_000_000,100_000_000,800_000_000] {
            try await Task.sleep(nanoseconds:delay);await settle(value)
            let current = try row(120,in:value)
            XCTAssertEqual(firstReadable(in:value),120,"Geometry: \(value.document.debugDiagnostics)")
            XCTAssertEqual(offset(current,in:value),expected,accuracy:1/value.window.backingScaleFactor,"Geometry: \(value.document.debugDiagnostics)")
        }
        XCTAssertEqual(value.model.replies.map(\.id),Array(Int64(97)..<160))
        XCTAssertEqual(value.model.posts.map(\.id),originalMain);XCTAssertEqual(value.model.replyDraft,replyDraft)
        assertHostInvariants(value)
    }
    func testIncomingReplyFollowsBottomButPreservesAnOlderReader() async throws {
        let value = try await harness(),mainIDs = value.model.posts.map(\.id)
        XCTAssertTrue(bottom(value),"Initial geometry: \(value.document.debugDiagnostics)")
        value.model.replies.append(try post(160,root:9000));value.update();await settle(value)
        XCTAssertTrue(bottom(value),"Incoming bottom geometry: \(value.document.debugDiagnostics)")
        let last = try row(160,in:value)
        XCTAssertTrue(value.document.rect(ofRow:last).intersects(value.scroll.documentVisibleRect));_ = try hosted(last,in:value)
        let reader = try await position(120,in:value),expected = offset(reader,in:value)
        XCTAssertFalse(bottom(value))
        value.model.replies.append(try post(161,root:9000));value.update();await settle(value)
        XCTAssertEqual(firstReadable(in:value),120)
        XCTAssertEqual(offset(try row(120,in:value),in:value),expected,accuracy:1/value.window.backingScaleFactor)
        XCTAssertFalse(bottom(value));XCTAssertFalse(value.document.rect(ofRow:try row(161,in:value)).intersects(value.scroll.documentVisibleRect))
        XCTAssertEqual(value.model.replies.map(\.id),Array(Int64(100)...161));XCTAssertEqual(value.model.posts.map(\.id),mainIDs)
        assertHostInvariants(value)
    }
}
#endif
