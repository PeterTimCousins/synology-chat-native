#if DEBUG
import AppKit
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeLinkPreviewAdmissionTests:XCTestCase {
    private func target(id:Int64 = 731,safe:Bool = true) throws -> ChatPost {
        try JSONDecoder().decode(ChatPost.self,from:Data("""
        {"post_id":\(id),"channel_id":93,"creator_id":10,"type":"normal","message":"Synthetic https://example.test/page","create_at":1000,"url_props":[{"url":"https://example.test/page","image":"https://images.example.test/card.png","hidden":false}],"props":{"safe_url":\(safe)}}
        """.utf8))
    }
    private func makeModel() async throws -> NativeChatPreviewModel {
        AdmissionProtocol.reset()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:4,pixelsHigh:4,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        bitmap.bitmapData?.initialize(repeating:127,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
        AdmissionProtocol.payload = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AdmissionProtocol.self];configuration.httpShouldSetCookies = false;configuration.urlCache = nil
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://admission.synthetic.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:configuration))
        try await api.discover()
        let model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false)
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Synthetic private test","type":"anonymous","encrypted":false,"unread":0}"#.utf8))]
        model.selection = 93;model.connected = true;model.liveStatus = .live
        model.handleLiveEvent(.init(name:"client.broadcast",payload:.object(["type":.string("setting.update"),"data":.object(["hide_post_url_preview":.bool(false)])])))
        model.posts = [try target()]
        addTeardownBlock { @MainActor in model.signOutLocally();AdmissionProtocol.reset() }
        return model
    }
    func testCancelledHeldTransferCannotAdmitAndReentryStartsFreshThenUsesCache() async throws {
        let model = try await makeModel(),post = try target(),preview = try XCTUnwrap(post.url_props?.first)
        let started = expectation(description:"Synthetic transfer held"),stopped = expectation(description:"Cancelled transport stopped")
        AdmissionProtocol.hold = true;AdmissionProtocol.onStart = { started.fulfill() };AdmissionProtocol.onStop = { stopped.fulfill() }
        let operation = Task { await model.linkPreviewImage(for:post,preview:preview) }
        await fulfillment(of:[started],timeout:2)
        operation.cancel();let cancelled = await operation.value
        await fulfillment(of:[stopped],timeout:2)
        XCTAssertNil(cancelled)
        var counts = model.debugLinkPreviewCounts(postID:post.id,asset:.image)
        XCTAssertEqual(counts["start"],1);XCTAssertEqual(counts["caller_cancelled"],1)
        XCTAssertEqual(counts["cache_admit"],0);XCTAssertEqual(counts["transport_return"],0)
        AdmissionProtocol.onStart = nil;AdmissionProtocol.onStop = nil;AdmissionProtocol.releaseHeld()
        let image = await model.linkPreviewImage(for:post,preview:preview)
        XCTAssertNotNil(image);XCTAssertEqual(AdmissionProtocol.requests,2)
        counts = model.debugLinkPreviewCounts(postID:post.id,asset:.image)
        XCTAssertEqual(counts["cache_admit"],1);XCTAssertEqual(counts["transport_return"],1)
        let repeated = await model.linkPreviewImage(for:post,preview:preview)
        XCTAssertNotNil(repeated);XCTAssertEqual(AdmissionProtocol.requests,2)
        XCTAssertEqual(model.debugLinkPreviewCounts(postID:post.id,asset:.image)["cache_hit"],1)
        XCTAssertTrue(AdmissionProtocol.unexpected.isEmpty)
    }
    func testSuccessfulAdmissionIsDistinctFromTransportCompletionAndSurvivesRepeat() async throws {
        let model = try await makeModel(),post = try target(),preview = try XCTUnwrap(post.url_props?.first)
        let first = await model.linkPreviewImage(for:post,preview:preview)
        XCTAssertNotNil(first)
        let admitted = model.debugLinkPreviewCounts(postID:post.id,asset:.image)
        XCTAssertEqual(admitted["start"],1);XCTAssertEqual(admitted["transport_return"],1);XCTAssertEqual(admitted["cache_admit"],1)
        let second = await model.linkPreviewImage(for:post,preview:preview)
        XCTAssertNotNil(second);XCTAssertEqual(AdmissionProtocol.requests,1)
        XCTAssertEqual(model.debugLinkPreviewCounts(postID:post.id,asset:.image)["cache_hit"],1)
        XCTAssertEqual(model.debugLinkPreviewCounts(postID:post.id,asset:.favicon)["start"],0)
        XCTAssertTrue(AdmissionProtocol.unexpected.isEmpty)
    }
    func testCanonicalDenialAndDecodeFailureCannotBeConfusedWithAdmissionAndResetClearsCounts() async throws {
        let model = try await makeModel(),post = try target(),preview = try XCTUnwrap(post.url_props?.first)
        model.posts = [try target(safe:false)]
        let denied = await model.linkPreviewImage(for:post,preview:preview)
        XCTAssertNil(denied);XCTAssertEqual(AdmissionProtocol.requests,0)
        XCTAssertEqual(model.debugLinkPreviewCounts(postID:post.id,asset:.image)["not_authorized"],1)
        model.posts = [post];AdmissionProtocol.payload = Data("not an image".utf8)
        let invalid = await model.linkPreviewImage(for:post,preview:preview)
        XCTAssertNil(invalid)
        let counts = model.debugLinkPreviewCounts(postID:post.id,asset:.image)
        XCTAssertEqual(counts["transport_return"],1);XCTAssertEqual(counts["decode_failure"],1);XCTAssertEqual(counts["cache_admit"],0)
        model.handleLiveEvent(.init(name:"client.broadcast",payload:.object(["type":.string("setting.update"),"data":.object(["hide_post_url_preview":.bool(true)])])))
        XCTAssertTrue(model.debugLinkPreviewCounts(postID:post.id,asset:.image).values.allSatisfy { $0 == 0 })
        XCTAssertTrue(AdmissionProtocol.unexpected.isEmpty)
    }
    func testCanonicalChangeAfterTransportStartsRejectsAdmissionAndOldScopeCannotRepopulateReset() async throws {
        let model = try await makeModel(),post = try target(),preview = try XCTUnwrap(post.url_props?.first)
        let started = expectation(description:"Canonical test held")
        AdmissionProtocol.hold = true;AdmissionProtocol.onStart = { started.fulfill() }
        let operation = Task { await model.linkPreviewImage(for:post,preview:preview) }
        await fulfillment(of:[started],timeout:2)
        model.posts = [try target(safe:false)]
        AdmissionProtocol.onStart = nil;AdmissionProtocol.releaseHeld()
        let rejected = await operation.value;XCTAssertNil(rejected)
        let counts = model.debugLinkPreviewCounts(postID:post.id,asset:.image)
        XCTAssertEqual(counts["transport_return"],1);XCTAssertEqual(counts["not_authorized"],1);XCTAssertEqual(counts["cache_admit"],0)
        model.posts = [post]
        let restarted = expectation(description:"Old scope request held"),stopped = expectation(description:"Old scope transport cancelled")
        AdmissionProtocol.hold = true;AdmissionProtocol.onStart = { restarted.fulfill() };AdmissionProtocol.onStop = { stopped.fulfill() }
        let oldScope = Task { await model.linkPreviewImage(for:post,preview:preview) }
        await fulfillment(of:[restarted],timeout:2);model.signOutLocally()
        let result = await oldScope.value;await fulfillment(of:[stopped],timeout:2);XCTAssertNil(result)
        XCTAssertTrue(model.debugLinkPreviewCounts(postID:post.id,asset:.image).values.allSatisfy { $0 == 0 },"Late old-scope cancellation must not repopulate reset counters")
        AdmissionProtocol.onStart = nil;AdmissionProtocol.onStop = nil;AdmissionProtocol.releaseHeld()
        XCTAssertTrue(AdmissionProtocol.unexpected.isEmpty)
    }
    func testDiagnosticKeyBoundEvictsOldestWithoutRetainingContentOrDestinations() async throws {
        let model = try await makeModel()
        model.channels = []
        for id in Int64(1)...257 {
            let post = try target(id:id),preview = try XCTUnwrap(post.url_props?.first)
            // Missing channel permission denies without sending a request.
            _ = await model.linkPreviewImage(for:post,preview:preview)
        }
        XCTAssertEqual(model.debugLinkPreviewCounts(postID:1,asset:.image)["not_authorized"],0)
        XCTAssertEqual(model.debugLinkPreviewCounts(postID:257,asset:.image)["not_authorized"],1)
        XCTAssertEqual(AdmissionProtocol.requests,0);XCTAssertTrue(AdmissionProtocol.unexpected.isEmpty)
    }
}

private final class AdmissionProtocol:URLProtocol {
    @MainActor static var payload = Data()
    @MainActor static var hold = false
    @MainActor static var requests = 0
    @MainActor static var unexpected:[String] = []
    @MainActor static var onStart:(()->Void)?
    @MainActor static var onStop:(()->Void)?
    @MainActor private static var pending:[AdmissionProtocol] = []
    private let lock = NSLock()
    private var stopped = false
    private var isStopped:Bool { lock.lock();defer { lock.unlock() };return stopped }
    @MainActor static func reset() { payload = Data();hold = false;requests = 0;unexpected = [];onStart = nil;onStop = nil;pending = [] }
    @MainActor static func releaseHeld() { hold = false;let values = pending;pending = [];values.forEach { $0.respond(payload,mime:"image/png") } }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty,let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048)
            while stream.hasBytesAvailable,body.count < 16384 {
                let count = stream.read(&buffer,maxLength:min(buffer.count,16384-body.count))
                if count <= 0 { break };body.append(contentsOf:buffer.prefix(count))
            }
        }
        var components = URLComponents();components.percentEncodedQuery = String(decoding:body,as:UTF8.self)
        let fields = Dictionary((components.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        let validBody = body.count < 16384
        Task { @MainActor in self.route(fields:fields,validBody:validBody) }
    }
    @MainActor private func route(fields:[String:String],validBody:Bool) {
        guard !isStopped else { return }
        guard validBody,request.url?.scheme == "https",request.url?.host == "admission.synthetic.invalid" else { reject();return }
        let path = request.url?.path ?? ""
        if path == "/webapi/query.cgi/SYNO.API.Info",fields["api"] == "SYNO.API.Info",fields["method"] == "query" {
            respond(Data(#"{"success":true,"data":{"SYNO.Chat.Post.File":{"path":"entry.cgi","minVersion":1,"maxVersion":2,"requestFormat":"JSON"}}}"#.utf8),mime:"application/json");return
        }
        guard path == "/webapi/entry.cgi/SYNO.Chat.Post.File",fields["api"] == "SYNO.Chat.Post.File",fields["method"] == "og",fields["post_id"] == "731",
              let encoded = fields["url"],let url = try? JSONDecoder().decode(String.self,from:Data(encoded.utf8)),url == "https://images.example.test/card.png" else { reject();return }
        Self.requests += 1
        if Self.hold { Self.pending.append(self);Self.onStart?() }
        else { respond(Self.payload,mime:"image/png") }
    }
    @MainActor private func reject() { Self.unexpected.append("unexpected synthetic route");client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL)) }
    @MainActor private func respond(_ data:Data,mime:String) {
        guard !isStopped,let url = request.url,let response = HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":mime]) else { return }
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        lock.lock();let first = !stopped;stopped = true;lock.unlock()
        if first { Task { @MainActor in Self.onStop?() } }
    }
}
#endif
