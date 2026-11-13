#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import SynologyChatNative

/// Actual model reconnect + observed native editor. No account or real transport.
@MainActor final class NativeReconnectEditorRetentionTests:XCTestCase {
    private static let original = "Synthetic reconnect original café 😀\nSecond real editor line."
    @MainActor private struct Harness {
        let model:NativeChatPreviewModel
        let host:NSHostingView<AnyView>
        let window:NSWindow
        let scroll:NativeTimelineScrollView
        let document:NativeVirtualTimeline.Document
        let owner:UUID
        let thread:Bool
    }
    private func scrolls(_ view:NSView)->[NativeTimelineScrollView] { (view as? NativeTimelineScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
    private func editors(_ view:NSView)->[NSTextView] {
        let own = (view as? NSTextView).map { $0.isEditable && !$0.isFieldEditor ? [$0] : [] } ?? []
        return own+view.subviews.flatMap(editors)
    }
    private func settle(_ value:Harness) async throws {
        for _ in 0..<12 { try await Task.sleep(nanoseconds:15_000_000);value.host.layoutSubtreeIfNeeded();value.host.needsDisplay = true;value.host.displayIfNeeded() }
        XCTAssertFalse(value.window.isVisible)
    }
    private func make(thread:Bool) async throws -> Harness {
        _ = NSApplication.shared;ReconnectEditorProtocol.reset(thread:thread,original:Self.original)
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ReconnectEditorProtocol.self];config.httpShouldSetCookies = false;config.urlCache = nil
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://reconnect-editor.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        try await api.discover()
        let model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false,notificationDefaults:nil),owner = UUID()
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":23,"name":"Synthetic editor reconnect","type":"channel","encrypted":false,"unread":0}"#.utf8))]
        model.selection = 23;model.loadSelection();await model.historyTask?.value
        XCTAssertNil(model.error);XCTAssertEqual(model.posts.count,30)
        if thread {
            let root = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:ReconnectEditorProtocol.root()))
            await model.openThread(root);XCTAssertNil(model.error);XCTAssertEqual(model.replies.map(\.id),Array(Int64(100)..<130))
        }
        model.draft = "Synthetic main reconnect editor draft";model.threadDrafts[9000] = "Synthetic reply reconnect editor draft"
        if thread { model.nativeThreadScrollPostID = 120 } else { model.scrollPostID = 120 }
        let timeline = NativeVirtualTimeline(model:model,onBottomChanged:{ _ in },fixtureEditors:[120:.init(owner:owner,text:Self.original)],inThread:thread)
        let host = NSHostingView(rootView:AnyView(timeline.environment(\.nativeChatStyle,ChatAppearanceStyle.dark).environment(\.colorScheme,.dark)))
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:680,height:thread ? 520 : 900),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = host
        addTeardownBlock { @MainActor in ReconnectEditorProtocol.cancelPending();model.endMessageEditing(owner:owner);host.rootView = AnyView(EmptyView());host.layoutSubtreeIfNeeded();window.contentView = nil;window.close() }
        var candidate:NativeTimelineScrollView?
        for _ in 0..<40 { host.layoutSubtreeIfNeeded();candidate = scrolls(host).first;if candidate != nil { break };try await Task.sleep(nanoseconds:15_000_000) }
        let scroll = try XCTUnwrap(candidate),document = try XCTUnwrap(scroll.documentView as? NativeVirtualTimeline.Document)
        let value = Harness(model:model,host:host,window:window,scroll:scroll,document:document,owner:owner,thread:thread)
        try await settle(value)
        if thread { model.nativeThreadScrollPostID = nil } else { model.scrollPostID = nil }
        host.layoutSubtreeIfNeeded();try await settle(value)
        return value
    }
    private func scenario(thread:Bool) async throws {
        let value = try await make(thread:thread),model = value.model
        let actualPost = try XCTUnwrap((thread ? model.replies : model.posts).first(where:{ $0.id == 120 }))
        model.beginMessageEditing(owner:value.owner,post:actualPost);try await settle(value)
        let index = try XCTUnwrap(value.document.canonicalRows.firstIndex(of:.post(120)))
        let cell = try XCTUnwrap(value.document.hostedView(forRow:index) as? NativeVirtualTimeline.Cell),host = try XCTUnwrap(cell.host)
        let allEditors = editors(cell);XCTAssertEqual(allEditors.count,1)
        let text = try XCTUnwrap(allEditors.first),undo = try XCTUnwrap(text.undoManager)
        XCTAssertEqual(text.string,Self.original);XCTAssertTrue(value.window.makeFirstResponder(text))
        text.setSelectedRange(NSRange(location:(text.string as NSString).length,length:0))
        undo.beginUndoGrouping();text.insertText(" e\u{301} 😀 unsaved reconnect",replacementRange:text.selectedRange());undo.endUndoGrouping()
        text.setSelectedRange(NSRange(location:(Self.original as NSString).length+1,length:2));try await settle(value)
        // Setup only: the main reader reports latest so reconnect performs its
        // actual raw latest read. The large viewport still contains editor120.
        if !thread {
            value.scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,value.document.bounds.height-value.scroll.contentView.bounds.height)))
            value.scroll.reflectScrolledClipView(value.scroll.contentView);try await settle(value)
            XCTAssertTrue(NativeScrollVisibility.isAtBottom(content:value.document.bounds,visible:value.scroll.documentVisibleRect,flipped:true))
            XCTAssertTrue(cell.frame.intersects(value.scroll.documentVisibleRect))
        }
        let expectedText = Data(text.string.utf8),selection = text.selectedRange()
        XCTAssertGreaterThan(selection.length,0);XCTAssertTrue(undo.canUndo)
        let mainToken = model.historyViewportToken,threadToken = model.nativeThreadViewportToken,account = model.accountGeneration
        let originalMainIDs = model.posts.map(\.id),originalReplyIDs = model.replies.map(\.id)
        var measurements:[[String:Any]] = []
        let retainedHosts = NSHashTable<NSView>.weakObjects()
        @MainActor func check(_ phase:String) throws {
            let currentIndex = try XCTUnwrap(value.document.canonicalRows.firstIndex(of:.post(120)))
            let currentCell = value.document.hostedView(forRow:currentIndex) as? NativeVirtualTimeline.Cell
            let attached = text.isDescendant(of:host) && host.superview === cell && cell.superview === value.document
            let record:[String:Any] = ["phase":phase,"thread":thread,"owner":model.activeMessageEditor?.uuidString as Any? ?? NSNull(),
                "same_cell":currentCell === cell,"same_host":currentCell?.host === host,"same_editor":editors(value.document).contains(where:{ $0 === text }),
                "attached":attached,"content_exact":Data(text.string.utf8) == expectedText,"selection":NSStringFromRange(text.selectedRange()),
                "first_responder":value.window.firstResponder === text,"can_undo":undo.canUndo,"clip":NSStringFromRect(value.scroll.documentVisibleRect),
                "main_token":model.historyViewportToken.uuidString,"thread_token":model.nativeThreadViewportToken.uuidString,"loading_main":model.loadingHistory,"loading_thread":model.loadingThread]
            measurements.append(record)
            XCTAssertTrue(currentCell === cell,"\(record)");XCTAssertTrue(currentCell?.host === host,"\(record)")
            XCTAssertTrue(editors(value.document).contains(where:{ $0 === text }),"\(record)");XCTAssertTrue(attached,"\(record)")
            XCTAssertEqual(model.activeMessageEditor,value.owner,"\(record)");XCTAssertTrue(value.window.firstResponder === text,"\(record)")
            XCTAssertEqual(Data(text.string.utf8),expectedText,"\(record)");XCTAssertEqual(text.selectedRange(),selection,"\(record)")
            XCTAssertTrue(text.undoManager === undo && undo.canUndo,"\(record)")
            XCTAssertEqual(model.historyViewportToken,mainToken,"\(record)")
            if thread { XCTAssertEqual(model.nativeThreadViewportToken,threadToken,"\(record)") }
            XCTAssertEqual(model.accountGeneration,account)
            XCTAssertEqual(model.draft,"Synthetic main reconnect editor draft");XCTAssertEqual(model.threadDrafts[9000],"Synthetic reply reconnect editor draft")
            let cells = value.document.subviews.compactMap { $0 as? NativeVirtualTimeline.Cell }
            for child in cells { if let hosted = child.host { retainedHosts.add(hosted) } }
            XCTAssertLessThanOrEqual(retainedHosts.allObjects.count,32);XCTAssertLessThanOrEqual(cells.count,32)
            let order = cells.map { value.document.row(for:$0) };XCTAssertEqual(order,order.sorted());XCTAssertTrue(order.allSatisfy({ $0 >= 0 }))
            XCTAssertFalse(value.window.isVisible)
        }
        try check("before-reconnect")
        ReconnectEditorProtocol.holdMain = true
        model.loadSelection(preservingThread:true,preservingViewport:true)
        for _ in 0..<60 { if !ReconnectEditorProtocol.pending.isEmpty { break };try await Task.sleep(nanoseconds:10_000_000) }
        let held = try XCTUnwrap(ReconnectEditorProtocol.pending.first,"Actual reconnect main latest request missing: \(ReconnectEditorProtocol.requests)")
        XCTAssertNil(held.fields["post_id"]);XCTAssertNil(held.fields["thread_id"])
        XCTAssertEqual(held.fields["prev_count"],"30");XCTAssertEqual(held.fields["next_count"],"0")
        XCTAssertTrue(model.loadingHistory);XCTAssertEqual(model.posts.map(\.id),originalMainIDs)
        XCTAssertEqual(model.replies.map(\.id),originalReplyIDs)
        try await settle(value);try check("held-main-read")
        ReconnectEditorProtocol.release();await model.historyTask?.value
        XCTAssertNil(model.error)
        for delay:UInt64 in [100_000_000,100_000_000,800_000_000] { try await Task.sleep(nanoseconds:delay);value.host.layoutSubtreeIfNeeded();try check("after-release-\(delay)") }
        XCTAssertEqual(model.posts.map(\.id),originalMainIDs);XCTAssertEqual(model.replies.map(\.id),originalReplyIDs)
        let canonical = try XCTUnwrap((thread ? model.replies : model.posts).first(where:{ $0.id == 120 }))
        XCTAssertEqual(canonical.message,Self.original)
        XCTAssertTrue((thread ? model.replies : model.posts).first(where:{ $0.id == 119 })?.message.hasPrefix("Changed canonical predecessor") == true)
        if thread { XCTAssertEqual(model.threadRoot?.id,9000);XCTAssertTrue(ReconnectEditorProtocol.rootReads > 0);XCTAssertGreaterThanOrEqual(ReconnectEditorProtocol.threadReads,2) }
        undo.undo();try await settle(value);XCTAssertEqual(text.string,Self.original);XCTAssertTrue(undo.canRedo)
        undo.redo();try await settle(value);XCTAssertEqual(Data(text.string.utf8),expectedText)
        XCTAssertTrue(text.undoManager === undo);XCTAssertEqual(model.activeMessageEditor,value.owner)
        XCTAssertEqual(ReconnectEditorProtocol.writes,0);XCTAssertEqual(ReconnectEditorProtocol.unexpected,[])
        XCTAssertFalse(model.connected)
        print("SYNTHETIC_RECONNECT_EDITOR "+String(decoding:try JSONSerialization.data(withJSONObject:measurements,options:.sortedKeys),as:UTF8.self))
    }
    func testMainEditorSurvivesActualSameReaderReconnectHoldAndCanonicalRefresh() async throws { try await scenario(thread:false) }
    func testThreadEditorSurvivesMainReconnectHoldAndThreadCanonicalRefresh() async throws { try await scenario(thread:true) }
}

private final class ReconnectEditorProtocol:URLProtocol {
    @MainActor static var threadCase = false,original = "",holdMain = false,updated = false
    @MainActor static var pending:[ReconnectEditorProtocol] = [],requests:[[String:String]] = [],unexpected:[String] = []
    @MainActor static var writes = 0,rootReads = 0,threadReads = 0
    @MainActor var fields:[String:String] = [:]
    private let lock = NSLock();private var stopped = false
    private var isStopped:Bool { lock.lock();defer { lock.unlock() };return stopped }
    @MainActor static func reset(thread:Bool,original:String) { cancelPending();threadCase = thread;Self.original = original;holdMain = false;updated = false;requests = [];unexpected = [];writes = 0;rootReads = 0;threadReads = 0 }
    @MainActor static func root()->[String:Any] { ["post_id":9000,"channel_id":23,"creator_id":10,"type":"normal","message":"Synthetic reconnect root","create_at":1000,"comment_count":30] }
    @MainActor static func release() { updated = true;holdMain = false;let values = pending;pending = [];for value in values { value.respond() } }
    @MainActor static func cancelPending() { let values = pending;pending = [];for value in values { value.fail() } }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func stopLoading() { lock.lock();stopped = true;lock.unlock() }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var bytes = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable,data.count < 16_384 { let count = stream.read(&bytes,maxLength:min(bytes.count,16_384-data.count));if count <= 0 { break };data.append(contentsOf:bytes.prefix(count)) } }
        var components = URLComponents();components.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let values = Dictionary((components.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        DispatchQueue.main.async { self.route(values) }
    }
    @MainActor private func route(_ values:[String:String]) {
        guard !isStopped else { return }
        guard let url = request.url,url.scheme == "https",url.host == "reconnect-editor.invalid" else { Self.unexpected.append("foreign-origin");fail();return }
        fields = values.mapValues { raw in (try? JSONSerialization.jsonObject(with:Data(raw.utf8),options:.fragmentsAllowed) as? String) ?? raw }
        Self.requests.append(fields)
        if url.lastPathComponent == "SYNO.API.Info",fields["method"] == "query" { send(["SYNO.Chat.Post":["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"]]);return }
        guard url.lastPathComponent == "SYNO.Chat.Post",fields["method"] == "list",fields["channel_id"] == "23" else {
            if ["set","create","delete","read","update"].contains(fields["method"] ?? "") { Self.writes += 1 };Self.unexpected.append("unlisted-endpoint");fail();return
        }
        let isThread = fields["thread_id"] == "9000"
        let mainLatest = fields["thread_id"] == nil && fields["post_id"] == nil && fields["prev_count"] == "30" && fields["next_count"] == "0"
        let rootRead = fields["thread_id"] == nil && fields["post_id"] == "9000" && fields["prev_count"] == "0" && fields["next_count"] == "0"
        let latestThread = isThread && fields["post_id"] == nil && fields["prev_count"] == "30" && fields["next_count"] == "0"
        let anchoredThread = isThread && Int(fields["post_id"] ?? "") != nil && fields["prev_count"] == "15" && fields["next_count"] == "15"
        guard mainLatest || rootRead || latestThread || anchoredThread else { Self.unexpected.append("unlisted-window:\(fields)");fail();return }
        if rootRead { Self.rootReads += 1 }
        if isThread { Self.threadReads += 1 }
        if mainLatest && Self.holdMain { Self.pending.append(self);return };respond()
    }
    @MainActor private func respond() {
        if fields["post_id"] == "9000",fields["thread_id"] == nil { send(["posts":[Self.root()]]);return }
        let isThread = fields["thread_id"] == "9000"
        let base = isThread || !Self.threadCase ? 100 : 500
        var ids = Array(base..<(base+30))
        if isThread,let anchor = Int(fields["post_id"] ?? "") { ids = ids.filter { abs($0-anchor) <= 15 } }
        let rows:[[String:Any]] = ids.map { id in
            let editable = id == 120
            let changed = Self.updated && (id == 119 || id == 519)
            var object:[String:Any] = ["post_id":id,"channel_id":23,"creator_id":id%2+10,"type":"normal","message":editable ? Self.original : changed ? "Changed canonical predecessor\nSynthetic additional line\nAnother retained canonical line." : "Synthetic reconnect row \(id)","create_at":1000+id]
            if isThread { object["thread_id"] = 9000 };return object
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
