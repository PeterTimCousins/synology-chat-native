import XCTest
@testable import SynologyChatNative

@MainActor final class ChatMessageWebsiteTests:XCTestCase {
    override func setUp() { super.setUp();WebsiteProtocol.reset() }
    override func tearDown() { WebsiteProtocol.held = nil;WebsiteProtocol.onHeld = nil;super.tearDown() }
    private func post() throws -> ChatPost { try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:WebsiteProtocol.source)) }
    private func model() async throws -> NativeChatPreviewModel {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [WebsiteProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://message-website-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        try await api.discover()
        let model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false)
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:WebsiteProtocol.channel))]
        model.selection = 93;model.connected = true;model.liveStatus = .live;model.posts = [try post()]
        model.handleLiveEvent(.init(name:"client.broadcast",payload:.object(["type":.string("setting.update"),"data":.object(["hide_post_url_preview":.bool(false)])])))
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    private let url = URL(string:"https://example.test/page")!
    func testLINERequiresExplicitReviewThenCanonicalSingleOpenAndDetectsEdits() async throws {
        let destination = URL(string:"line://msg/text/Synthetic%20message")!
        WebsiteProtocol.source["message"] = "<" + destination.absoluteString + "|Open LINE>"
        let model = try await model(),review = try model.messageLinkIntent(try post(),destination:destination,source:.body)
        XCTAssertTrue(review.requiresConfirmation);XCTAssertFalse(review.flaggedByServer)
        var opened:[URL] = []
        guard case .confirmation(let confirmation) = try await model.openMessageLink(review,open:{ opened.append($0);return true }) else { return XCTFail("Application opened without review") }
        XCTAssertTrue(opened.isEmpty)
        _ = try await model.openMessageLink(confirmation,allowUnsafe:true,open:{ opened.append($0);return true })
        XCTAssertEqual(opened,[destination]);XCTAssertTrue(WebsiteProtocol.methods.allSatisfy { $0 == "list" })
        WebsiteProtocol.source["message"] = "line://msg/text/Changed"
        do { _ = try await model.openMessageLink(confirmation,allowUnsafe:true,open:{ opened.append($0);return true });XCTFail("Changed app target opened") } catch { }
        XCTAssertEqual(opened,[destination])
        XCTAssertThrowsError(try model.messageLinkIntent(try post(),destination:destination,source:.card(0)))
    }
    func testLINEApplicationApprovalCannotApproveANewServerUnsafeFlag() async throws {
        let destination = URL(string:"line://msg/text/Synthetic")!
        WebsiteProtocol.source["message"] = destination.absoluteString
        let model = try await model(),review = try model.messageLinkIntent(try post(),destination:destination,source:.body)
        WebsiteProtocol.source["props"] = ["safe_url":false]
        var opens = 0
        guard case .confirmation(let flagged) = try await model.openMessageLink(review,allowUnsafe:true,open:{ _ in opens += 1;return true }) else { return XCTFail("Application review bypassed the new unsafe flag") }
        XCTAssertTrue(flagged.flaggedByServer);XCTAssertEqual(opens,0)
        XCTAssertTrue(ChatMessageLinkPresentation.message(destination,flagged:flagged.flaggedByServer).contains("Synology also marked"))
        _ = try await model.openMessageLink(flagged,allowUnsafe:true,open:{ _ in opens += 1;return true })
        XCTAssertEqual(opens,1)
    }
    func testLINEBotOwnershipAndApplicationFailureDoNotRetry() async throws {
        let destination = URL(string:"line://msg/text/Synthetic")!,text = "Open " + "line://msg/text/Synthetic"
        WebsiteProtocol.source["message"] = "Synthetic bot"
        WebsiteProtocol.source["props"] = ["safe_url":true,"attachments":[["text":text]]]
        let model = try await model(),source = try post()
        XCTAssertThrowsError(try model.messageLinkIntent(source,destination:destination,source:.body))
        let review = try model.messageLinkIntent(source,destination:destination,source:.botText(text))
        var opens = 0
        do { _ = try await model.openMessageLink(review,allowUnsafe:true,open:{ _ in opens += 1;return false });XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("LINE could not be opened")) }
        XCTAssertEqual(opens,1)
        WebsiteProtocol.source["props"] = ["attachments":[]]
        do { _ = try await model.openMessageLink(review,allowUnsafe:true,open:{ _ in opens += 1;return true });XCTFail() } catch { }
        XCTAssertEqual(opens,1)
    }
    func testExplicitYouTubePlaybackUsesCanonicalReadAndRetainsFlaggedLinkReview() async throws {
        let destination = URL(string:"https://youtu.be/M7lc1UVf-VE?t=12s")!
        WebsiteProtocol.source["message"] = destination.absoluteString
        WebsiteProtocol.source["url_props"] = [["url":destination.absoluteString,"title":"Synthetic YouTube preview"]]
        let model = try await model(),opening = NativeMessageWebsiteOpening(),source = try post()
        WebsiteProtocol.source["props"] = ["safe_url":false]
        var videos:[ChatYouTubeVideo] = []
        // Flagged cards are deliberately hidden by policy. Exercise the
        // retained action through the rendered body link's warning instead.
        opening.begin(model:model,post:source,destination:destination,source:.body,open:{ url in
            guard let video = ChatYouTubeVideo(url:url) else { return false };videos.append(video);return true
        })
        for _ in 0..<100 where opening.busy { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertFalse(opening.busy);XCTAssertNil(opening.error);XCTAssertTrue(videos.isEmpty)
        let review = try XCTUnwrap(opening.pending)
        opening.confirm(review,model:model)
        for _ in 0..<100 where opening.busy { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertFalse(opening.busy);XCTAssertNil(opening.error)
        XCTAssertEqual(videos.count,1);XCTAssertEqual(videos.first?.id,"M7lc1UVf-VE");XCTAssertEqual(videos.first?.startSeconds,12)
        XCTAssertTrue(WebsiteProtocol.methods.allSatisfy { $0 == "list" })
        opening.clear()
    }
    func testSafeYouTubeCardPublishesOnlyAfterCanonicalValidation() async throws {
        let destination = URL(string:"https://youtu.be/M7lc1UVf-VE")!
        WebsiteProtocol.source["message"] = destination.absoluteString
        WebsiteProtocol.source["url_props"] = [["url":destination.absoluteString]]
        let model = try await model(),opening = NativeMessageWebsiteOpening()
        var videos:[ChatYouTubeVideo] = []
        opening.begin(model:model,post:try post(),destination:destination,source:.card(0),open:{ url in
            guard let video = ChatYouTubeVideo(url:url) else { return false };videos.append(video);return true
        })
        XCTAssertTrue(videos.isEmpty)
        for _ in 0..<100 where opening.busy { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertNil(opening.error);XCTAssertNil(opening.pending);XCTAssertEqual(videos.count,1)
        XCTAssertTrue(WebsiteProtocol.methods.allSatisfy { $0 == "list" })
        opening.clear()
    }
    func testRetiredYouTubePlayCannotPublishAfterHeldCanonicalRead() async throws {
        let destination = URL(string:"https://www.youtube.com/watch?v=M7lc1UVf-VE")!
        WebsiteProtocol.source["message"] = destination.absoluteString
        WebsiteProtocol.source["url_props"] = [["url":destination.absoluteString]]
        let model = try await model(),opening = NativeMessageWebsiteOpening(),held = expectation(description:"Held play validation")
        WebsiteProtocol.holdPost = true;WebsiteProtocol.onHeld = { held.fulfill() }
        var plays = 0
        opening.begin(model:model,post:try post(),destination:destination,source:.card(0),open:{ _ in plays += 1;return true })
        await fulfillment(of:[held],timeout:2)
        opening.clear();WebsiteProtocol.release()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(plays,0);XCTAssertFalse(opening.busy);XCTAssertNil(opening.pending);XCTAssertNil(opening.error)
    }
    func testRenderedBodyAndLabelledLinksUseCanonicalReadWithNoMutationsOrCodeNavigation() async throws {
        let model = try await model(),source = try post()
        let review = try model.messageLinkIntent(source,destination:url,source:.body)
        var opened:[URL] = []
        let result = try await model.openMessageLink(review,open:{ opened.append($0);return true })
        guard case .opened = result else { return XCTFail() };XCTAssertEqual(opened,[url])
        XCTAssertTrue(WebsiteProtocol.methods.allSatisfy { $0 == "list" })
        let links = ChatMessageLinks.renderedDestinations("<https://example.test/page|Label> `https://code.test/`\n```\nhttps://fence.test/\n```")
        XCTAssertEqual(links,[url])
        for invalid in ["https://example.test/?_sid=secret","mailto:self@example.test","file:///tmp/private"] {
            XCTAssertThrowsError(try model.messageLinkIntent(source,destination:URL(string:invalid)!,source:.body))
        }
    }
    func testCachedAndRemoteEditsCannotOpenCapturedDestination() async throws {
        let model = try await model(),review = try model.messageLinkIntent(try post(),destination:url,source:.body)
        WebsiteProtocol.source["message"] = "No website anymore"
        var opens = 0
        do { _ = try await model.openMessageLink(review,open:{ _ in opens += 1;return true });XCTFail() } catch { }
        XCTAssertEqual(opens,0)
        model.posts = [try post()];let before = WebsiteProtocol.methods.count
        do { _ = try await model.openMessageLink(review,open:{ _ in opens += 1;return true });XCTFail() } catch { }
        XCTAssertEqual(WebsiteProtocol.methods.count,before);XCTAssertEqual(opens,0)
    }
    func testPreviewCardIdentityAndGlobalHideAreRechecked() async throws {
        let model = try await model(),source = try post()
        let review = try model.messageLinkIntent(source,destination:url,source:.card(0))
        WebsiteProtocol.source["url_props"] = [["url":"https://changed.test/","title":"Changed"]]
        var opens = 0
        do { _ = try await model.openMessageLink(review,open:{ _ in opens += 1;return true });XCTFail() } catch { }
        XCTAssertEqual(opens,0)
        WebsiteProtocol.reset()
        model.handleLiveEvent(.init(name:"client.broadcast",payload:.object(["type":.string("setting.update"),"data":.object(["hide_post_url_preview":.bool(true)])])))
        XCTAssertThrowsError(try model.messageLinkIntent(source,destination:url,source:.card(0)))
    }
    func testNewUnsafeFlagRequiresFreshBoundConfirmationAndChangedTargetCannotReuseIt() async throws {
        let model = try await model(),review = try model.messageLinkIntent(try post(),destination:url,source:.body)
        WebsiteProtocol.source["props"] = ["safe_url":false]
        var opens = 0
        let result = try await model.openMessageLink(review,allowUnsafe:true,open:{ _ in opens += 1;return true })
        guard case .confirmation(let confirmation) = result else { return XCTFail("Old safe review reused confirmation") }
        XCTAssertTrue(confirmation.requiresConfirmation);XCTAssertEqual(opens,0)
        _ = try await model.openMessageLink(confirmation,allowUnsafe:true,open:{ _ in opens += 1;return true })
        XCTAssertEqual(opens,1)
        WebsiteProtocol.source["message"] = "https://changed.test/"
        do { _ = try await model.openMessageLink(confirmation,allowUnsafe:true,open:{ _ in opens += 1;return true });XCTFail() } catch { }
        XCTAssertEqual(opens,1)
    }
    func testBotTextMustStillBelongToCanonicalAttachment() async throws {
        let text = "Bot text https://example.test/page"
        WebsiteProtocol.source["message"] = "Bot message"
        WebsiteProtocol.source["props"] = ["safe_url":true,"attachments":[["text":text]]]
        let model = try await model(),source = try post()
        XCTAssertThrowsError(try model.messageLinkIntent(source,destination:url,source:.body))
        let review = try model.messageLinkIntent(source,destination:url,source:.botText(text))
        var opens = 0
        _ = try await model.openMessageLink(review,open:{ _ in opens += 1;return true });XCTAssertEqual(opens,1)
        WebsiteProtocol.source["props"] = ["safe_url":true,"attachments":[]]
        do { _ = try await model.openMessageLink(review,open:{ _ in opens += 1;return true });XCTFail() } catch { }
        XCTAssertEqual(opens,1)
    }
    func testRevokedChannelAndBrowserFailureDoNotRetryOrOpenAnotherTarget() async throws {
        let model = try await model(),review = try model.messageLinkIntent(try post(),destination:url,source:.body)
        WebsiteProtocol.channel["is_joined"] = false
        var opens = 0
        do { _ = try await model.openMessageLink(review,open:{ _ in opens += 1;return true });XCTFail() } catch { }
        XCTAssertEqual(opens,0)
        WebsiteProtocol.channel["is_joined"] = true
        do { _ = try await model.openMessageLink(review,open:{ _ in opens += 1;return false });XCTFail() } catch { }
        XCTAssertEqual(opens,1)
    }
    func testSignoutDuringHeldCanonicalReadCannotLaunchBrowser() async throws {
        let model = try await model(),review = try model.messageLinkIntent(try post(),destination:url,source:.body),held = expectation(description:"Held canonical post")
        WebsiteProtocol.holdPost = true;WebsiteProtocol.onHeld = { held.fulfill() };var opens = 0
        let operation = Task { try await model.openMessageLink(review,open:{ _ in opens += 1;return true }) }
        await fulfillment(of:[held],timeout:2);model.signOutLocally();WebsiteProtocol.release()
        do { _ = try await operation.value;XCTFail() } catch is CancellationError { }
        XCTAssertEqual(opens,0)
    }
    func testPreviewPreferenceChangeDuringReadAndEncryptionTransitionRetireNavigation() async throws {
        let model = try await model(),review = try model.messageLinkIntent(try post(),destination:url,source:.card(0)),held = expectation(description:"Held preview read")
        WebsiteProtocol.holdPost = true;WebsiteProtocol.onHeld = { held.fulfill() };var opens = 0
        let operation = Task { try await model.openMessageLink(review,open:{ _ in opens += 1;return true }) }
        await fulfillment(of:[held],timeout:2)
        model.handleLiveEvent(.init(name:"client.broadcast",payload:.object(["type":.string("setting.update"),"data":.object(["hide_post_url_preview":.bool(true)])])))
        WebsiteProtocol.release()
        do { _ = try await operation.value;XCTFail() } catch { }
        XCTAssertEqual(opens,0)
        WebsiteProtocol.holdPost = false
        let body = try model.messageLinkIntent(try post(),destination:url,source:.body),before = WebsiteProtocol.methods.count
        var encrypted = WebsiteProtocol.channel;encrypted["encrypted"] = true
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:encrypted))]
        do { _ = try await model.openMessageLink(body,open:{ _ in opens += 1;return true });XCTFail() } catch { }
        XCTAssertEqual(WebsiteProtocol.methods.count,before);XCTAssertEqual(opens,0)
    }
}

private final class WebsiteProtocol:URLProtocol {
    static var source:[String:Any] = [:],channel:[String:Any] = [:]
    static var methods:[String] = []
    static var holdPost = false
    static var held:WebsiteProtocol?
    static var onHeld:(()->Void)?
    static func reset() { source = ["post_id":1,"channel_id":93,"creator_id":10,"message":"Read <https://example.test/page|this page>","type":"normal","create_at":1000,"props":["safe_url":true],"url_props":[["url":"https://example.test/page","title":"Synthetic card"]]];channel = ["channel_id":93,"name":"Synthetic","type":"anonymous","encrypted":false,"unread":0];methods = [];holdPost = false;held = nil;onHeld = nil }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "message-website-fixture.invalid" else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        let endpoint = request.url!.lastPathComponent
        if endpoint == "SYNO.API.Info" { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.Post","SYNO.Chat.Channel"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) })]);return }
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };bytes.append(contentsOf:buffer.prefix(n)) } }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
        let fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last });Self.methods.append(fields["method"] ?? "")
        if endpoint == "SYNO.Chat.Post",Self.holdPost { Self.held = self;Self.onHeld?();return }
        if endpoint == "SYNO.Chat.Channel" { finish(["success":true,"data":["channels":[Self.channel]]]) }
        else if endpoint == "SYNO.Chat.Post" { finish(["success":true,"data":["posts":[Self.source]]]) }
        else { finish(["success":false,"error":["code":400]]) }
    }
    static func release() { if let held { Self.held = nil;held.finish(["success":true,"data":["posts":[source]]]) } }
    private func finish(_ object:[String:Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject:object)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:bytes);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
