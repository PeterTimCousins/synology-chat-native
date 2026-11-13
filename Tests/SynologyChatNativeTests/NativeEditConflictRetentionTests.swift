#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import SynologyChatNative

/// Real hosted editor, synthetic connection, actual owned model-save boundary.
/// This deliberately makes no claim of Save button, menu or physical activation.
@MainActor final class NativeEditConflictRetentionTests:XCTestCase {
    private let original = "Synthetic conflict original café 😀\nNative editor second line."
    private let remote = "Remote canonical change to synthetic post120"
    private func scrolls(_ view:NSView)->[NativeTimelineScrollView] { (view as? NativeTimelineScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
    private func editors(_ view:NSView)->[NSTextView] {
        let own = (view as? NSTextView).map { $0.isEditable && !$0.isFieldEditor ? [$0] : [] } ?? []
        return own+view.subviews.flatMap(editors)
    }
    private func settle(_ view:NSView) async throws {
        for _ in 0..<12 { try await Task.sleep(nanoseconds:15_000_000);view.layoutSubtreeIfNeeded();view.needsDisplay = true;view.displayIfNeeded() }
    }
    func testHostedEditorRetainsNativeDraftWhenOwnedModelSaveRejectsCanonicalConflict() async throws {
        _ = NSApplication.shared;EditConflictProtocol.reset(original:original,remote:remote)
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            guard session.baseURL.scheme == "https",session.baseURL.host == "edit-conflict.invalid" else { throw ChatAPIError.invalidResponse }
            let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [EditConflictProtocol.self];config.httpShouldSetCookies = false;config.urlCache = nil
            return try ChatAPIClient(session:session,network:URLSession(configuration:config))
        },downloadPreferences:.init(defaults:nil),emojiPreferences:.init(defaults:nil),notificationDefaults:nil)
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://edit-conflict.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic-edit-conflict",importedFromOfficialApp:false))
        XCTAssertTrue(model.connected);XCTAssertEqual(model.userID,10)
        model.suspendLiveForProbe();model.liveStatus = .live;model.selection = 23;model.error = nil
        model.loadSelection();await model.historyTask?.value
        XCTAssertNil(model.error);XCTAssertEqual(model.posts.map(\.id),Array(Int64(100)..<130))
        let canonical = try XCTUnwrap(model.posts.first(where:{ $0.id == 120 })),owner = UUID()
        XCTAssertEqual(canonical.message,original);XCTAssertTrue(model.canChangeOwnMessage(canonical))
        model.draft = "Synthetic main conflict composer draft";model.threadDrafts[9000] = "Synthetic separate reply conflict draft";model.scrollPostID = 120
        let timeline = NativeVirtualTimeline(model:model,onBottomChanged:{ _ in },fixtureEditors:[120:.init(owner:owner,text:original)])
        let root = NSHostingView(rootView:AnyView(timeline.environment(\.nativeChatStyle,ChatAppearanceStyle.dark).environment(\.colorScheme,.dark)))
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:680,height:520),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = root
        addTeardownBlock { @MainActor in model.endMessageEditing(owner:owner);model.signOutLocally();root.rootView = AnyView(EmptyView());root.layoutSubtreeIfNeeded();window.contentView = nil;window.close() }
        var candidate:NativeTimelineScrollView?
        for _ in 0..<40 { root.layoutSubtreeIfNeeded();candidate = scrolls(root).first;if candidate != nil { break };try await Task.sleep(nanoseconds:15_000_000) }
        let scroll = try XCTUnwrap(candidate),document = try XCTUnwrap(scroll.documentView as? NativeVirtualTimeline.Document)
        try await settle(root);model.scrollPostID = nil;root.layoutSubtreeIfNeeded();try await settle(root)
        model.beginMessageEditing(owner:owner,post:canonical)
        let session = try XCTUnwrap(model.messageEditorSession(owner:owner));try await settle(root)
        let index = try XCTUnwrap(document.canonicalRows.firstIndex(of:.post(120)))
        let cell = try XCTUnwrap(document.hostedView(forRow:index) as? NativeVirtualTimeline.Cell),host = try XCTUnwrap(cell.host)
        let candidates = editors(cell);XCTAssertEqual(candidates.count,1)
        let text = try XCTUnwrap(candidates.first),undo = try XCTUnwrap(text.undoManager)
        XCTAssertEqual(text.string,original);XCTAssertTrue(window.makeFirstResponder(text));XCTAssertTrue(text.allowsUndo)
        text.setSelectedRange(NSRange(location:(original as NSString).length,length:0))
        undo.beginUndoGrouping();text.insertText(" e\u{301} 😀 unsaved conflict",replacementRange:text.selectedRange());undo.endUndoGrouping()
        text.setSelectedRange(NSRange(location:(original as NSString).length+1,length:2));try await settle(root)
        let content = Data(text.string.utf8),selection = text.selectedRange(),account = model.accountGeneration,token = model.historyViewportToken
        XCTAssertGreaterThan(selection.length,0);XCTAssertTrue(undo.canUndo);XCTAssertNotEqual(content,Data(original.utf8))
        let observedHosts = NSHashTable<NSView>.weakObjects()
        var measurements:[[String:Any]] = []
        @MainActor func assertRetained(_ phase:String) throws {
            let currentIndex = try XCTUnwrap(document.canonicalRows.firstIndex(of:.post(120)))
            let current = document.hostedView(forRow:currentIndex) as? NativeVirtualTimeline.Cell
            let sample:[String:Any] = ["phase":phase,"model_save_boundary_not_button_activation":true,"same_cell":current === cell,"same_host":current?.host === host,
                "same_editor":editors(document).contains(where:{ $0 === text }),"first_responder":window.firstResponder === text,
                "content_exact":Data(text.string.utf8) == content,"selection":NSStringFromRange(text.selectedRange()),"can_undo":undo.canUndo,
                "owner":model.activeMessageEditor?.uuidString as Any? ?? NSNull(),"session":model.messageEditorSession(owner:owner)?.uuidString as Any? ?? NSNull(),
                "canonical_message":model.posts.first(where:{ $0.id == 120 })?.message as Any? ?? NSNull(),"wire_sets":EditConflictProtocol.sets]
            measurements.append(sample)
            XCTAssertTrue(current === cell,"\(sample)");XCTAssertTrue(current?.host === host,"\(sample)")
            XCTAssertTrue(text.isDescendant(of:host) && host.superview === cell && cell.superview === document,"\(sample)")
            XCTAssertTrue(editors(document).contains(where:{ $0 === text }),"\(sample)")
            XCTAssertEqual(document.row(for:text),currentIndex);XCTAssertEqual(current?.row,.post(120))
            XCTAssertTrue(window.firstResponder === text,"\(sample)");XCTAssertEqual(Data(text.string.utf8),content,"\(sample)")
            XCTAssertEqual(text.selectedRange(),selection,"\(sample)");XCTAssertTrue(text.undoManager === undo && undo.canUndo,"\(sample)")
            XCTAssertEqual(model.activeMessageEditor,owner);XCTAssertEqual(model.messageEditorSession(owner:owner),session)
            XCTAssertEqual(model.accountGeneration,account);XCTAssertEqual(model.historyViewportToken,token)
            XCTAssertEqual(model.draft,"Synthetic main conflict composer draft");XCTAssertEqual(model.threadDrafts[9000],"Synthetic separate reply conflict draft")
            let cells = document.subviews.compactMap { $0 as? NativeVirtualTimeline.Cell }
            for item in cells { if let native = item.host { observedHosts.add(native) } }
            XCTAssertLessThanOrEqual(observedHosts.allObjects.count,32);XCTAssertLessThanOrEqual(cells.count,32)
            let order = cells.map { document.row(for:$0) };XCTAssertEqual(order,order.sorted())
            XCTAssertFalse(window.isVisible)
        }
        try assertRetained("before-remote-change")
        EditConflictProtocol.changed = true
        model.handleLiveEvent(.init(name:"client.post.update",payload:.object(["channel_id":.integer(23),"post_id":.integer(120)])))
        for _ in 0..<60 { if model.posts.first(where:{ $0.id == 120 })?.message == remote { break };try await Task.sleep(nanoseconds:15_000_000) }
        try await settle(root)
        let renderedPost = try XCTUnwrap(model.posts.first(where:{ $0.id == 120 }))
        XCTAssertEqual(renderedPost.message,remote);XCTAssertEqual(renderedPost.update_at,3000)
        XCTAssertTrue(model.canChangeOwnMessage(renderedPost),"Conflict rejection must not be an authorization false-positive")
        XCTAssertGreaterThan(EditConflictProtocol.singleReads,0)
        try assertRetained("canonical-changed-while-editor-open")
        let readsBefore = EditConflictProtocol.singleReads
        // Calls the same owned save API as the UI, with the NEW rendered post;
        // immutable session baseline must still reject the concurrent change.
        let saved = await model.edit(renderedPost,text:text.string,owner:owner,session:session)
        XCTAssertFalse(saved);XCTAssertEqual(EditConflictProtocol.sets,0)
        XCTAssertGreaterThan(EditConflictProtocol.singleReads,readsBefore,"Actual model preflight must run")
        XCTAssertNotNil(model.error);XCTAssertFalse(model.pendingMessageActions.contains(120))
        for delay:UInt64 in [100_000_000,100_000_000,800_000_000] { try await Task.sleep(nanoseconds:delay);root.layoutSubtreeIfNeeded();try assertRetained("conflict-rejected-\(delay)") }
        XCTAssertEqual(model.posts.first(where:{ $0.id == 120 })?.message,remote)
        undo.undo();try await settle(root);XCTAssertEqual(text.string,original);XCTAssertTrue(undo.canRedo)
        undo.redo();try await settle(root);XCTAssertEqual(Data(text.string.utf8),content)
        XCTAssertTrue(text.undoManager === undo);XCTAssertEqual(model.activeMessageEditor,owner);XCTAssertEqual(model.messageEditorSession(owner:owner),session)
        XCTAssertEqual(EditConflictProtocol.sets,0);XCTAssertEqual(EditConflictProtocol.unexpected,[])
        XCTAssertEqual(model.posts.map(\.id),Array(Int64(100)..<130));XCTAssertEqual(model.posts.first(where:{ $0.id == 120 })?.message,remote)
        print("SYNTHETIC_HOSTED_EDIT_CONFLICT "+String(decoding:try JSONSerialization.data(withJSONObject:measurements,options:.sortedKeys),as:UTF8.self))
    }
}

private final class EditConflictProtocol:URLProtocol {
    @MainActor static var original = "",remote = "",changed = false,sets = 0,singleReads = 0,unexpected:[String] = []
    private let lock = NSLock();private var stopped = false
    private var isStopped:Bool { lock.lock();defer { lock.unlock() };return stopped }
    @MainActor static func reset(original:String,remote:String) { Self.original = original;Self.remote = remote;changed = false;sets = 0;singleReads = 0;unexpected = [] }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func stopLoading() { lock.lock();stopped = true;lock.unlock() }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var bytes = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable,data.count < 16_384 { let count = stream.read(&bytes,maxLength:min(bytes.count,16_384-data.count));if count <= 0 { break };data.append(contentsOf:bytes.prefix(count)) } }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        DispatchQueue.main.async { self.route(fields) }
    }
    @MainActor private func route(_ values:[String:String]) {
        guard !isStopped else { return }
        guard let url = request.url,url.scheme == "https",url.host == "edit-conflict.invalid" else { Self.unexpected.append("foreign-origin");fail();return }
        if url.path == "/webman/3rdparty/Chat/config" { fail();return }
        func field(_ key:String)->String { let raw = values[key] ?? "";return (try? JSONSerialization.jsonObject(with:Data(raw.utf8),options:.fragmentsAllowed) as? String) ?? raw }
        let endpoint = url.lastPathComponent,method = field("method"),payload:[String:Any]
        switch (endpoint,method) {
        case ("SYNO.API.Info","query"):
            let names = ["SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Channel.Member","SYNO.Chat.Misc","SYNO.Chat.Post","SYNO.Chat.Post.File","SYNO.Chat.Admin.Setting","SYNO.Chat.User.Preference","SYNO.Chat.Post.Subscribe"]
            payload = Dictionary(uniqueKeysWithValues:names.map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"] as [String:Any]) })
        case ("SYNO.Chat.User","list"):payload = ["users":[["user_id":10,"username":"synthetic-edit-conflict","nickname":"Synthetic Alex","type":"human","human_type":"dsm"],["user_id":20,"username":"synthetic-peer","nickname":"Synthetic Jordan","type":"human","human_type":"dsm"]]]
        case ("SYNO.Chat.Channel","list"):payload = ["channels":[["channel_id":23,"name":"Synthetic edit conflict","type":"private","encrypted":false,"is_joined":true,"creator_id":10,"unread":0]]]
        case ("SYNO.Chat.Channel.Member","get"):payload = ["user_ids":[10,20]]
        case ("SYNO.Chat.Misc","acl"):payload = ["acls":[]]
        case ("SYNO.Chat.Admin.Setting","get"):payload = ["hide_post_url_preview":true,"allow_read_status":false,"file_size_limit":0]
        case ("SYNO.Chat.User.Preference","get"):payload = ["preferences":["theme_style":"dark","theme_background":0,"prefer_user_name_format":"nickname","sidebar_pinning_unread":false,"notification_showmessage":false,"notification_browser_active":false,"notification_mute":true,"calendar_enable":false,"recent_emoji":[]]]
        case ("SYNO.Chat.Post.Subscribe","get"):payload = ["subscribes":[]]
        case ("SYNO.Chat.Post","list"):
            guard field("channel_id") == "23",field("thread_id").isEmpty else { Self.unexpected.append("wrong-post-scope");fail();return }
            let ids:[Int]
            if field("post_id") == "120",field("prev_count") == "0",field("next_count") == "0" { Self.singleReads += 1;ids = [120] }
            else if field("post_id").isEmpty,field("prev_count") == "30",field("next_count") == "0" { ids = Array(100..<130) }
            else { Self.unexpected.append("unknown-post-window");fail();return }
            payload = ["posts":ids.map { id -> [String:Any] in
                var row:[String:Any] = ["post_id":id,"channel_id":23,"creator_id":id%2 == 0 ? 10 : 20,"type":"normal","message":id == 120 ? (Self.changed ? Self.remote : Self.original) : "Synthetic conflict adjacent \(id)","create_at":1000+id]
                if id == 120 { row["update_at"] = Self.changed ? 3000 : 2000 };return row
            }]
        case ("SYNO.Chat.Post","set"):Self.sets += 1;fail();return
        default:Self.unexpected.append(endpoint+":"+method);fail();return
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject:["success":true,"data":payload]) else { fail();return }
        send(bytes)
    }
    private func send(_ data:Data) { guard !isStopped,let url = request.url,let response = HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"]) else { return };client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    private func fail() { guard !isStopped else { return };client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL)) }
}
#endif
