#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import SynologyChatNative

/// Real thread reads and hidden observed production views; all transport is synthetic.
@MainActor final class NativeThreadReconnectViewportTests:XCTestCase {
    @MainActor private struct Harness {
        let model:NativeChatPreviewModel
        let root:NSHostingView<AnyView>
        let window:NSWindow
        let scroll:NSScrollView
    }
    private func row(_ id:Int64,thread:Int64? = nil) throws -> ChatPost {
        var value:[String:Any] = ["post_id":id,"channel_id":23,"creator_id":id%2+10,"type":"normal","message":"Synthetic reconnect row \(id)","create_at":1000+id]
        if let thread { value["thread_id"] = thread }
        return try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:value))
    }
    private func settle(_ host:Harness) async throws {
        for _ in 0..<12 { try await Task.sleep(nanoseconds:15_000_000);host.root.layoutSubtreeIfNeeded();host.root.needsDisplay = true;host.root.displayIfNeeded() }
        XCTAssertFalse(host.window.isVisible)
    }
    private func markers(_ view:NSView)->[NativeTimelineRowMarker.Marker] {
        (view as? NativeTimelineRowMarker.Marker).map { [$0] } ?? view.subviews.flatMap(markers)
    }
    private func scrolls(_ view:NSView)->[NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
    }
    private func first(_ host:Harness)->(id:Int64,offset:CGFloat)? {
        guard let document = host.scroll.documentView else { return nil }
        let visible = host.scroll.documentVisibleRect
        return markers(document).compactMap { marker -> (id:Int64,offset:CGFloat,position:CGFloat)? in
            guard (100...190).contains(marker.postID) else { return nil }
            let frame = marker.convert(marker.bounds,to:document),intersection = frame.intersection(visible)
            guard frame.height > 0,intersection.height >= min(20,frame.height),intersection.width > 0 else { return nil }
            return (marker.postID,document.isFlipped ? frame.minY-visible.minY : visible.maxY-frame.maxY,document.isFlipped ? frame.minY : -frame.maxY)
        }.min(by:{ $0.position < $1.position }).map { ($0.id,$0.offset) }
    }
    private func fixture(virtual:Bool) async throws -> Harness {
        ThreadReconnectProtocol.reset()
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ThreadReconnectProtocol.self];config.httpShouldSetCookies = false;config.urlCache = nil
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://thread-reconnect.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        try await api.discover()
        let model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false,notificationDefaults:nil)
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":23,"name":"Synthetic reconnect","type":"channel","encrypted":false,"unread":0}"#.utf8))]
        model.selection = 23;model.posts = try (500..<510).map { try row(Int64($0)) };model.draft = "Synthetic main reconnect draft"
        let appearance = NativeAppearancePreferences(defaults:nil),base = NativeThreadView(appearancePreferences:appearance,model:model)
        let content = virtual ? AnyView(base.usingNativeVirtualTimeline()) : AnyView(base)
        let root = NSHostingView(rootView:AnyView(content.environment(\.nativeChatStyle,ChatAppearanceStyle.dark).preferredColorScheme(.dark)))
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:640,height:680),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = root
        addTeardownBlock { @MainActor in ThreadReconnectProtocol.cancelPending();root.rootView = AnyView(EmptyView());root.layoutSubtreeIfNeeded();window.contentView = nil;window.close() }
        await model.openThread(try row(9000));XCTAssertNil(model.error)
        XCTAssertEqual(model.replies.map(\.id),Array(Int64(160)...189));XCTAssertTrue(model.canLoadOlderReplies)
        await model.loadOlderReplies();XCTAssertNil(model.error);XCTAssertEqual(model.replies.count,60)
        await model.loadOlderReplies();XCTAssertNil(model.error);XCTAssertEqual(model.replies.map(\.id),Array(Int64(100)...189))
        model.replyDraft = "Synthetic thread reconnect draft"
        var selected:NSScrollView?
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds:15_000_000);root.layoutSubtreeIfNeeded();root.needsDisplay = true;root.displayIfNeeded()
            selected = scrolls(root).first { scroll in
                guard scroll.contentView.bounds.width > 400,let document = scroll.documentView else { return false }
                return !markers(document).filter({ (100...189).contains($0.postID) }).isEmpty
            }
            if selected != nil { break }
        }
        let scroll = try XCTUnwrap(selected)
        if virtual { XCTAssertTrue(scroll.documentView is NativeVirtualTimeline.Document) } else { XCTAssertFalse(scroll.documentView is NativeVirtualTimeline.Document) }
        let result = Harness(model:model,root:root,window:window,scroll:scroll);try await settle(result)
        XCTAssertEqual(ThreadReconnectProtocol.pages,["latest","160","130"])
        return result
    }
    private func positionOlderReader(_ host:Harness) async throws -> (id:Int64,offset:CGFloat) {
        let document = try XCTUnwrap(host.scroll.documentView)
        // Setup only: scan actual clip positions until the desired row is hosted,
        // then align its actual marker. No scroll corrections occur after refresh.
        var target:NativeTimelineRowMarker.Marker?
        for step in 0..<41 {
            target = markers(document).first(where:{ $0.postID == 140 })
            if target != nil { break }
            let fraction = CGFloat(step)/40
            host.scroll.contentView.scroll(to:NSPoint(x:0,y:document.bounds.minY+max(0,document.bounds.height-host.scroll.contentView.bounds.height)*fraction))
            host.scroll.reflectScrolledClipView(host.scroll.contentView)
            try await Task.sleep(nanoseconds:20_000_000);host.root.layoutSubtreeIfNeeded();host.root.needsDisplay = true;host.root.displayIfNeeded()
        }
        let marker = try XCTUnwrap(target),frame = marker.convert(marker.bounds,to:document)
        let y = document.isFlipped ? frame.minY : frame.maxY-host.scroll.contentView.bounds.height
        host.scroll.contentView.scroll(to:NSPoint(x:0,y:y));host.scroll.reflectScrolledClipView(host.scroll.contentView)
        try await settle(host)
        let actual = try XCTUnwrap(first(host));XCTAssertEqual(actual.id,140)
        XCTAssertFalse(NativeScrollVisibility.isAtBottom(content:document.bounds,visible:host.scroll.documentVisibleRect,flipped:document.isFlipped))
        return actual
    }
    private func scenario(virtual:Bool,invalidCallbacks:Bool = false,fullSelectionRefresh:Bool = false) async throws {
        let host = try await fixture(virtual:virtual),baseline = try await positionOlderReader(host)
        let model = host.model,token = model.nativeThreadViewportToken,account = model.accountGeneration
        let document = try XCTUnwrap(host.scroll.documentView),documentID = ObjectIdentifier(document),scrollID = ObjectIdentifier(host.scroll)
        if invalidCallbacks {
            model.noteThreadViewport(postID:baseline.id,atBottom:true,token:UUID(),account:account,channelID:23,rootID:9000)
            model.noteThreadViewport(postID:baseline.id,atBottom:true,token:token,account:account+1,channelID:23,rootID:9000)
            model.noteThreadViewport(postID:baseline.id,atBottom:true,token:token,account:account,channelID:24,rootID:9000)
            model.noteThreadViewport(postID:baseline.id,atBottom:true,token:token,account:account,channelID:23,rootID:9001)
            model.noteThreadViewport(postID:509,atBottom:true,token:token,account:account,channelID:23,rootID:9000)
            model.noteTimelineViewport(postID:509,atBottom:true,token:model.historyViewportToken,account:account,channelID:23)
        }
        ThreadReconnectProtocol.holdAnchor = true
        let refresh = Task<Void,Never> { @MainActor in
            if fullSelectionRefresh {
                model.loadSelection(preservingThread:true,preservingViewport:true)
                await model.historyTask?.value
            } else { await model.refreshOpenThreadPreservingReader() }
        }
        defer { refresh.cancel();ThreadReconnectProtocol.cancelPending() }
        for _ in 0..<60 { if !ThreadReconnectProtocol.pending.isEmpty { break };try await Task.sleep(nanoseconds:10_000_000) }
        let held = try XCTUnwrap(ThreadReconnectProtocol.pending.first)
        XCTAssertEqual(held.fields["post_id"],String(baseline.id),"Actual scoped viewport reporting must select the reader; requests=\(ThreadReconnectProtocol.requests)")
        XCTAssertEqual(held.fields["prev_count"],"15");XCTAssertEqual(held.fields["next_count"],"15")
        XCTAssertTrue(model.loadingThread);XCTAssertEqual(model.nativeThreadViewportToken,token)
        XCTAssertEqual(model.replies.map(\.id),Array(Int64(100)...189),"Refresh must retain the loaded reader while waiting")
        ThreadReconnectProtocol.release();await refresh.value
        XCTAssertNil(model.error)
        XCTAssertEqual(model.nativeThreadViewportToken,token)
        XCTAssertEqual(model.replies.map(\.id),(100...190).filter { $0 != 143 }.map(Int64.init))
        XCTAssertTrue(model.replies.first(where:{ $0.id == 139 })?.message.hasPrefix("Changed synthetic predecessor") == true)
        XCTAssertFalse(model.replies.contains(where:{ $0.id == 143 }));XCTAssertEqual(model.replies.last?.id,190)
        var measurements:[[String:Any]] = []
        for (label,delay) in [("100ms",UInt64(100_000_000)),("200ms",UInt64(100_000_000)),("1sec",UInt64(800_000_000))] {
            try await Task.sleep(nanoseconds:delay)
            host.root.layoutSubtreeIfNeeded();host.root.needsDisplay = true;host.root.displayIfNeeded()
            let actual = first(host)
            var sample:[String:Any] = ["phase":label,"virtual":virtual,"baseline_id":baseline.id,"baseline_offset":baseline.offset,
                "actual_id":actual.map { $0.id as Any } ?? NSNull(),"actual_offset":actual.map { $0.offset as Any } ?? NSNull(),
                "clip":NSStringFromRect(host.scroll.documentVisibleRect),"document":NSStringFromRect(document.bounds),"token":model.nativeThreadViewportToken.uuidString]
            if let native = document as? NativeVirtualTimeline.Document { sample["virtual_diagnostics"] = native.debugDiagnostics }
            measurements.append(sample)
            XCTAssertEqual(actual?.id,baseline.id,"Geometry: \(sample)")
            XCTAssertEqual(try XCTUnwrap(actual?.offset),baseline.offset,accuracy:1/host.window.backingScaleFactor,"Geometry: \(sample)")
            XCTAssertEqual(host.scroll.documentView.map(ObjectIdentifier.init),documentID);XCTAssertEqual(ObjectIdentifier(host.scroll),scrollID)
            XCTAssertEqual(model.nativeThreadViewportToken,token);XCTAssertEqual(model.accountGeneration,account)
        }
        print("SYNTHETIC_THREAD_RECONNECT_VIEWPORT "+String(decoding:try JSONSerialization.data(withJSONObject:measurements,options:.sortedKeys),as:UTF8.self))
        XCTAssertEqual(model.draft,"Synthetic main reconnect draft");XCTAssertEqual(model.replyDraft,"Synthetic thread reconnect draft")
        XCTAssertEqual(model.posts.map(\.id),Array(Int64(500)..<510));XCTAssertEqual(model.threadRoot?.id,9000)
        XCTAssertFalse(model.connected);XCTAssertFalse(host.window.isVisible)
        XCTAssertEqual(ThreadReconnectProtocol.unknown,[]);XCTAssertEqual(ThreadReconnectProtocol.writes,0)
        XCTAssertEqual(ThreadReconnectProtocol.pages.suffix(2),["anchor:140","latest"])
        if let native = document as? NativeVirtualTimeline.Document {
            XCTAssertEqual(native.debugDiagnostics["host_order_is_canonical"] as? Bool,true)
            XCTAssertLessThanOrEqual(native.debugDiagnostics["max_hosted_cells"] as? Int ?? Int.max,32)
        }
    }
    func testVirtualReconnectRetainsRealOlderReplyPixelAndReconcilesCanonicalWindow() async throws { try await scenario(virtual:true) }
    func testStandardReconnectRetainsRealOlderReplyPixelAndReconcilesCanonicalWindow() async throws { try await scenario(virtual:false) }
    func testWrongThreadViewportTicketsAndMainViewportCannotRetargetVirtualReconnect() async throws { try await scenario(virtual:true,invalidCallbacks:true) }
    func testFullSelectionReconnectRetainsActualVirtualThreadReader() async throws { try await scenario(virtual:true,fullSelectionRefresh:true) }
    func testInitialStandardThreadConsumesLatestScrollBeforeOlderReaderInput() async throws {
        let host = try await fixture(virtual:false),document = try XCTUnwrap(host.scroll.documentView)
        XCTAssertTrue(NativeScrollVisibility.isAtBottom(content:document.bounds,visible:host.scroll.documentVisibleRect,flipped:document.isFlipped))
        _ = try await positionOlderReader(host)
        XCTAssertEqual(first(host)?.id,140)
    }
    func testStandardThreadContextDoesNotJumpPastNewlyLoadedLaterReplies() async throws {
        let host = try await fixture(virtual:false),document = try XCTUnwrap(host.scroll.documentView)
        host.model.threadViewingContext = true;host.model.canLoadNewerReplies = true;try await settle(host)
        let y = document.isFlipped ? max(document.bounds.minY,document.bounds.maxY-host.scroll.documentVisibleRect.height) : document.bounds.minY
        host.scroll.contentView.scroll(to:NSPoint(x:0,y:y));host.scroll.reflectScrolledClipView(host.scroll.contentView)
        try await settle(host)
        let baseline = try XCTUnwrap(first(host)),token = host.model.nativeThreadViewportToken
        XCTAssertTrue(NativeScrollVisibility.isAtBottom(content:document.bounds,visible:host.scroll.documentVisibleRect,flipped:document.isFlipped))
        host.model.replies += try (190..<220).map { try row(Int64($0),thread:9000) }
        for delay:UInt64 in [100_000_000,100_000_000,800_000_000] {
            try await Task.sleep(nanoseconds:delay);host.root.layoutSubtreeIfNeeded()
            let current = try XCTUnwrap(first(host))
            XCTAssertEqual(current.id,baseline.id);XCTAssertEqual(current.offset,baseline.offset,accuracy:1/host.window.backingScaleFactor)
            XCTAssertEqual(host.model.nativeThreadViewportToken,token);XCTAssertTrue(host.model.threadViewingContext)
        }
        XCTAssertFalse(NativeScrollVisibility.isAtBottom(content:document.bounds,visible:host.scroll.documentVisibleRect,flipped:document.isFlipped))
        XCTAssertEqual(host.model.replyDraft,"Synthetic thread reconnect draft")
        XCTAssertEqual(ThreadReconnectProtocol.unknown,[]);XCTAssertEqual(ThreadReconnectProtocol.writes,0)
    }
}

private final class ThreadReconnectProtocol:URLProtocol {
    @MainActor static var requests:[[String:String]] = [],pages:[String] = [],unknown:[String] = []
    @MainActor static var writes = 0,holdAnchor = false,updated = false
    @MainActor static var pending:[ThreadReconnectProtocol] = []
    @MainActor var fields:[String:String] = [:]
    private let lock = NSLock();private var stopped = false
    private var isStopped:Bool { lock.lock();defer { lock.unlock() };return stopped }
    @MainActor static func reset() { cancelPending();requests = [];pages = [];unknown = [];writes = 0;holdAnchor = false;updated = false }
    @MainActor static func cancelPending() { let values = pending;pending = [];for value in values { value.fail() } }
    @MainActor static func release() { updated = true;holdAnchor = false;let values = pending;pending = [];for value in values { value.respond() } }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func stopLoading() { lock.lock();stopped = true;lock.unlock() }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var bytes = [UInt8](repeating:0,count:2048)
            while stream.hasBytesAvailable,data.count < 16_384 { let count = stream.read(&bytes,maxLength:min(bytes.count,16_384-data.count));if count <= 0 { break };data.append(contentsOf:bytes.prefix(count)) }
        }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let values = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        DispatchQueue.main.async { self.route(values) }
    }
    @MainActor private func route(_ values:[String:String]) {
        guard !isStopped,let url = request.url,url.scheme == "https",url.host == "thread-reconnect.invalid" else { fail();return }
        fields = values.mapValues { raw in (try? JSONSerialization.jsonObject(with:Data(raw.utf8),options:.fragmentsAllowed) as? String) ?? raw }
        Self.requests.append(fields)
        if url.lastPathComponent == "SYNO.API.Info",fields["method"] == "query" {
            send(["SYNO.Chat.Post":["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"]]);return
        }
        if url.lastPathComponent == "SYNO.Chat.Post",fields["method"] == "list",fields["channel_id"] == "23",fields["thread_id"] == nil {
            let ids:[Int]
            if fields["post_id"] == "9000",fields["prev_count"] == "0",fields["next_count"] == "0" { ids = [9000] }
            else if fields["post_id"] == nil,fields["prev_count"] == "30",fields["next_count"] == "0" { ids = Array(500..<510) }
            else { Self.unknown.append("unexpected-main-page");fail();return }
            send(["posts":ids.map { id -> [String:Any] in ["post_id":id,"channel_id":23,"thread_id":0,"creator_id":10,"type":"normal","message":"Synthetic reconnect row \(id)","create_at":1000+id] }]);return
        }
        guard url.lastPathComponent == "SYNO.Chat.Post",fields["method"] == "list",fields["channel_id"] == "23",fields["thread_id"] == "9000" else {
            if ["set","create","read","delete","update"].contains(fields["method"] ?? "") { Self.writes += 1 } else { Self.unknown.append(url.lastPathComponent+":"+(fields["method"] ?? "")) };fail();return
        }
        if fields["prev_count"] == "15",fields["next_count"] == "15",let anchor = fields["post_id"],Int(anchor) != nil {
            Self.pages.append("anchor:"+anchor)
            if Self.holdAnchor { Self.pending.append(self);return };respond();return
        }
        guard fields["prev_count"] == "30",fields["next_count"] == "0",[nil,"160","130"].contains(fields["post_id"]) else { Self.unknown.append("unexpected-page:\(fields)");fail();return }
        Self.pages.append(fields["post_id"] ?? "latest");respond()
    }
    @MainActor private func respond() {
        let ids:[Int]
        if fields["next_count"] == "15",let raw = fields["post_id"],let anchor = Int(raw) { ids = Array((anchor-15)...(anchor+15)) }
        else if fields["post_id"] == "160" { ids = Array(130...159) }
        else if fields["post_id"] == "130" { ids = Array(100...129) }
        else { ids = Self.updated ? Array(161...190) : Array(160...189) }
        let rows:[[String:Any]] = ids.filter { !(Self.updated && $0 == 143) }.map { id in
            let text = Self.updated && id == 139 ? "Changed synthetic predecessor\n"+(1...15).map { "Synthetic long line \($0) for canonical predecessor measurement." }.joined(separator:"\n") : "Synthetic reconnect row \(id)"
            return ["post_id":id,"channel_id":23,"thread_id":9000,"creator_id":id%2+10,"type":"normal","message":text,"create_at":1000+id]
        }
        send(["posts":rows])
    }
    @MainActor private func send(_ payload:[String:Any]) {
        guard !isStopped,let url = request.url,let response = HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"]),let bytes = try? JSONSerialization.data(withJSONObject:["success":true,"data":payload]) else { fail();return }
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:bytes);client?.urlProtocolDidFinishLoading(self)
    }
    private func fail() { guard !isStopped else { return };client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL)) }
}
#endif
