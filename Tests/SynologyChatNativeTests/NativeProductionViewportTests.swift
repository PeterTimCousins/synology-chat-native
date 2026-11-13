import AppKit
import SwiftUI
import XCTest
@testable import SynologyChatNative

/// These cases deliberately compile without DEBUG or any fixture editor types.
/// No API client, account, credentials, visible window or external calls exist.
@MainActor final class NativeProductionViewportTests:XCTestCase {
    private struct Harness {
        let model:NativeChatPreviewModel
        let host:NSHostingView<AnyView>
        let window:NSWindow
        let scroll:NativeTimelineScrollView
        let document:NativeVirtualTimeline.Document
    }
    private func post(_ id:Int64,thread:Int64? = nil,text:String? = nil) throws -> ChatPost {
        var fields:[String:Any] = ["post_id":id,"channel_id":23,"creator_id":10,"type":"normal","create_at":1000+id,"message":text ?? "Synthetic production viewport row \(id)"]
        if let thread { fields["thread_id"] = thread }
        return try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:fields))
    }
    private func scrolls(_ view:NSView)->[NativeTimelineScrollView] {
        (view as? NativeTimelineScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
    }
    private func settle(_ value:Harness) async throws {
        for _ in 0..<12 { try await Task.sleep(nanoseconds:15_000_000);value.host.layoutSubtreeIfNeeded() }
        XCTAssertFalse(value.window.isVisible)
    }
    private func make(thread:Bool) async throws -> Harness {
        _ = NSApplication.shared
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,notificationDefaults:nil)
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":23,"name":"Synthetic release viewport","type":"channel","encrypted":false,"unread":0}"#.utf8))]
        model.selection = 23;model.connected = true;model.liveStatus = .live
        model.posts = try (500..<530).map { try post(Int64($0)) }
        model.draft = "Synthetic unsent main draft"
        let appearance = NativeAppearancePreferences(defaults:nil),content:AnyView
        if thread {
            model.threadRoot = try post(9000)
            model.replies = try (100..<190).map { try post(Int64($0),thread:9000) }
            model.replyDraft = "Synthetic unsent thread draft"
            content = AnyView(NativeThreadView(appearancePreferences:appearance,model:model).usingNativeMessageViewport())
        } else {
            content = AnyView(NativeChatPreviewView(model:model,appearancePreferences:appearance).usingNativeMessageViewport())
        }
        let host = NSHostingView(rootView:AnyView(content.environment(\.nativeChatStyle,ChatAppearanceStyle.dark).preferredColorScheme(.dark)))
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:thread ? 640 : 1100,height:thread ? 680 : 800),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = host
        addTeardownBlock { @MainActor in model.signOutLocally();host.rootView = AnyView(EmptyView());window.contentView = nil;window.close() }
        var found:NativeTimelineScrollView?
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds:15_000_000);host.layoutSubtreeIfNeeded()
            found = scrolls(host).first { $0.documentView is NativeVirtualTimeline.Document && $0.contentView.bounds.height > 0 }
            if found != nil { break }
        }
        let scroll = try XCTUnwrap(found),document = try XCTUnwrap(scroll.documentView as? NativeVirtualTimeline.Document)
        let result = Harness(model:model,host:host,window:window,scroll:scroll,document:document)
        try await settle(result);return result
    }
    private func readable(_ value:Harness)->(id:Int64,offset:CGFloat)? {
        let clip = value.scroll.documentVisibleRect
        for (index,row) in value.document.canonicalRows.enumerated() {
            guard case let .post(id) = row else { continue }
            let rect = value.document.rect(ofRow:index)
            if rect.intersection(clip).height >= min(20,rect.height),value.document.hostedView(forRow:index) != nil { return (id,rect.minY-clip.minY) }
        }
        return nil
    }
    private func assertBoundedOrder(_ value:Harness,file:StaticString = #filePath,line:UInt = #line) {
        let indexes = value.document.subviews.map { value.document.row(for:$0) }
        XCTAssertTrue(indexes.allSatisfy { $0 >= 0 },file:file,line:line)
        XCTAssertEqual(indexes,indexes.sorted(),file:file,line:line)
        XCTAssertLessThanOrEqual(indexes.count,32,file:file,line:line)
    }
    private func capture(_ value:Harness,name:String) throws {
        guard let path = ProcessInfo.processInfo.environment["NATIVE_PRODUCTION_VIEWPORT_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath:path,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        value.host.needsDisplay = true;value.host.displayIfNeeded()
        let bitmap = try XCTUnwrap(value.host.bitmapImageRepForCachingDisplay(in:value.host.bounds))
        value.host.cacheDisplay(in:value.host.bounds,to:bitmap)
        let bytes = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        try bytes.write(to:directory.appendingPathComponent(name+".png"),options:.withoutOverwriting)
    }
    func testMainSelectorUsesNativeViewportWithoutDebugFixtures() async throws {
        let value = try await make(thread:false)
        XCTAssertEqual(value.document.canonicalRows.compactMap { if case let .post(id) = $0 { return id };return nil },Array(Int64(500)..<530))
        XCTAssertNotNil(readable(value));assertBoundedOrder(value)
        XCTAssertEqual(value.model.draft,"Synthetic unsent main draft")
        try capture(value,name:"main-viewport")
    }
    func testThreadSelectorRetainsOlderPixelThroughRealRowReflowWithoutDebugFixtures() async throws {
        let value = try await make(thread:true),token = value.model.nativeThreadViewportToken
        value.model.nativeThreadScrollPostID = 140;value.model.objectWillChange.send();try await settle(value)
        let index = try XCTUnwrap(value.document.canonicalRows.firstIndex(of:.post(140)))
        XCTAssertNotNil(value.document.hostedView(forRow:index))
        value.model.nativeThreadScrollPostID = nil;value.model.objectWillChange.send();try await settle(value)
        value.scroll.contentView.scroll(to:NSPoint(x:0,y:value.document.rect(ofRow:index).minY));value.scroll.reflectScrolledClipView(value.scroll.contentView)
        try await settle(value)
        let baseline = try XCTUnwrap(readable(value));XCTAssertEqual(baseline.id,140)
        let grown = try post(139,thread:9000,text:"Synthetic changed predecessor\n"+String(repeating:"Synthetic longer canonical line.\n",count:15))
        value.model.replies = try (100...190).filter { $0 != 143 }.map { id in id == 139 ? grown : try post(Int64(id),thread:9000) }
        for delay:UInt64 in [100_000_000,100_000_000,800_000_000] {
            try await Task.sleep(nanoseconds:delay);value.host.layoutSubtreeIfNeeded()
            let actual = try XCTUnwrap(readable(value))
            XCTAssertEqual(actual.id,baseline.id);XCTAssertEqual(actual.offset,baseline.offset,accuracy:1/value.window.backingScaleFactor)
            XCTAssertEqual(value.model.nativeThreadViewportToken,token);assertBoundedOrder(value)
        }
        XCTAssertEqual(value.model.replyDraft,"Synthetic unsent thread draft")
        XCTAssertEqual(value.model.posts.map(\.id),Array(Int64(500)..<530))
        XCTAssertEqual(value.model.replies.map(\.id),(100...190).filter { $0 != 143 }.map(Int64.init))
        try capture(value,name:"thread-reflow")
    }
    func testOptimizedViewportReleasesOffscreenHostsAcrossRepeatedReading() async throws {
        let value = try await make(thread:true),liveHosts = NSHashTable<NSView>.weakObjects()
        func recordHosts() {
            for child in value.document.subviews {
                if let host = (child as? NativeVirtualTimeline.Cell)?.host { liveHosts.add(host) }
            }
        }
        for id:Int64 in [100,120,140,160,180,140,110,160,120] {
            recordHosts()
            let index = try XCTUnwrap(value.document.canonicalRows.firstIndex(of:.post(id)))
            value.scroll.contentView.scroll(to:NSPoint(x:0,y:value.document.rect(ofRow:index).minY));value.scroll.reflectScrolledClipView(value.scroll.contentView)
            try await settle(value);recordHosts()
            XCTAssertNotNil(readable(value));assertBoundedOrder(value)
            XCTAssertGreaterThan(liveHosts.allObjects.count,0);XCTAssertLessThanOrEqual(liveHosts.allObjects.count,32)
        }
        XCTAssertEqual(value.model.replies.map(\.id),Array(Int64(100)..<190))
        XCTAssertEqual(value.model.replyDraft,"Synthetic unsent thread draft")
        try capture(value,name:"thread-recycled")
    }
    func testThreadContextAtBottomKeepsItsVisibleReplyWhenLaterRepliesAreAppended() async throws {
        let value = try await make(thread:true),token = value.model.nativeThreadViewportToken
        value.model.threadViewingContext = true;value.model.canLoadNewerReplies = true;try await settle(value)
        XCTAssertTrue(value.document.canonicalRows.contains(.newer))
        value.scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,value.document.bounds.maxY-value.scroll.documentVisibleRect.height)))
        value.scroll.reflectScrolledClipView(value.scroll.contentView);try await settle(value)
        let baseline = try XCTUnwrap(readable(value))
        XCTAssertTrue(NativeScrollVisibility.isAtBottom(content:value.document.bounds,visible:value.scroll.documentVisibleRect,flipped:true))
        value.model.replies += try (190..<220).map { try post(Int64($0),thread:9000) }
        for delay:UInt64 in [100_000_000,100_000_000,800_000_000] {
            try await Task.sleep(nanoseconds:delay);value.host.layoutSubtreeIfNeeded()
            let actual = try XCTUnwrap(readable(value))
            XCTAssertEqual(actual.id,baseline.id);XCTAssertEqual(actual.offset,baseline.offset,accuracy:1/value.window.backingScaleFactor)
            XCTAssertEqual(value.model.nativeThreadViewportToken,token);XCTAssertTrue(value.model.threadViewingContext)
            assertBoundedOrder(value)
        }
        XCTAssertFalse(NativeScrollVisibility.isAtBottom(content:value.document.bounds,visible:value.scroll.documentVisibleRect,flipped:true))
        XCTAssertEqual(value.model.replyDraft,"Synthetic unsent thread draft")
        try capture(value,name:"thread-forward-context")
    }
}
