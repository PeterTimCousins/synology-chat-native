import AppKit
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatImageViewerTests: XCTestCase {
    private func post(_ id: Int64, channel: Int64 = 93, image: Bool = true, deleted: Bool = false,name:String = "synthetic.png") throws -> ChatPost {
        try JSONDecoder().decode(ChatPost.self, from: JSONSerialization.data(withJSONObject: [
            "post_id": id, "channel_id": channel, "creator_id": 10, "message": "Synthetic image caption",
            "type": "file", "create_at": 1000, "delete_at": deleted ? 1001 : 0,
            "file_props": ["name": name, "is_image": image, "size": 100]]))
    }
    private func network() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ImageViewerStub.self]
        return URLSession(configuration: config)
    }
    private func model(encryption: ChatEncryptionSession? = nil) async throws -> NativeChatPreviewModel {
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://synthetic.invalid")!, sid: "synthetic", synoToken: "synthetic"),
                                    network: network(), makeAttachmentNetwork: network)
        try await api.discover()
        let model = NativeChatPreviewModel(client: api, restoreNotificationPreference: false, encryption: encryption)
        model.channels = [try JSONDecoder().decode(ChatChannel.self, from: Data(#"{"channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0}"#.utf8))]
        model.selection = 93; model.connected = true; model.liveStatus = .live
        addTeardownBlock { @MainActor in model.signOutLocally() }
        return model
    }
    private func png(width: Int = 1200, height: Int = 800) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    override func tearDown() {
        ImageViewerStub.onRequest = nil; ImageViewerStub.stall = false; ImageViewerStub.onStop = nil;ImageViewerStub.mime = "image/png"
        super.tearDown()
    }

    func testLargePreviewRouteAndDecoderPreserveUsefulDetail() async throws {
        ImageViewerStub.payload = try png()
        let model = try await model(); let target = try post(1); model.posts = [target]
        var previewType: String?
        ImageViewerStub.onRequest = { request in
            var fields = URLComponents()
            fields.percentEncodedQuery = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let value = fields.queryItems?.first(where: { $0.name == "type" })?.value
            previewType = value
        }
        model.openImage(target)
        await model.imageViewerTask?.value
        XCTAssertEqual(previewType, String(data: try JSONEncoder().encode("XL"), encoding: .utf8))
        XCTAssertNil(model.imageViewerError)
        XCTAssertEqual(model.imageViewerImage?.size.width, 1200)
        XCTAssertEqual(NativeImagePreview.decode(ImageViewerStub.payload)?.size.width, 640)
        XCTAssertNil(NativeImagePreview.decode(ImageViewerStub.payload, maximumPixelSize: 8192))
    }

    func testAnimatedGIFUsesAuthenticatedOriginalAndRetainsFrames() async throws {
        ImageViewerStub.payload = try NativeSyntheticAnimatedImage.gif();let model = try await model(),target = try post(1,name:"synthetic.gif");model.posts = [target]
        var method:String?;ImageViewerStub.onRequest = {request in var fields = URLComponents();fields.percentEncodedQuery = String(decoding:request.httpBody ?? Data(),as:UTF8.self);method = fields.queryItems?.first {$0.name == "method"}?.value}
        model.openImage(target);await model.imageViewerTask?.value
        XCTAssertEqual(method,"get");XCTAssertEqual(model.imageViewerFrameCount,2);XCTAssertTrue(model.imageViewerOriginal);XCTAssertNil(model.imageViewerError)
        let rep = try XCTUnwrap(model.imageViewerImage?.representations.compactMap {$0 as? NSBitmapImageRep}.first)
        rep.setProperty(.currentFrame,withValue:0);let first = rep.colorAt(x:180,y:10)
        rep.setProperty(.currentFrame,withValue:1);XCTAssertNotEqual(first,rep.colorAt(x:180,y:10))
        model.closeImageViewer();XCTAssertEqual(model.imageViewerFrameCount,1);XCTAssertFalse(model.imageViewerOriginal);XCTAssertNil(model.imageViewerImage)
    }
    func testInlineThumbnailRetainsSmallGIFAnimationAndCachesIt() async throws {
        ImageViewerStub.payload = try NativeSyntheticAnimatedImage.gif()
        let model = try await model(), target = try post(1,name:"synthetic.gif")
        var reads = 0
        ImageViewerStub.onRequest = { _ in reads += 1 }
        let loaded = await model.thumbnail(for:target)
        let image = try XCTUnwrap(loaded)
        let frames = image.representations.compactMap { $0 as? NSBitmapImageRep }.first?.value(forProperty:.frameCount) as? Int ?? 1
        XCTAssertEqual(frames,2,"The ordinary timeline thumbnail must retain the GIF's animation")
        let cached = await model.thumbnail(for:target)
        XCTAssertTrue(cached === image)
        XCTAssertEqual(reads,1)
    }
    func testFullSizeRetainsPixelsBeyondThumbnailLimit() async throws {
        ImageViewerStub.payload = try png(width:6000,height:2);let model = try await model(),target = try post(1);model.posts = [target]
        model.openImage(target);await model.imageViewerTask?.value;XCTAssertEqual(model.imageViewerImage?.size.width,4096)
        model.viewOriginalImage();await model.imageViewerTask?.value;XCTAssertEqual(model.imageViewerImage?.size.width,6000);XCTAssertTrue(model.imageViewerOriginal);XCTAssertEqual(model.imageViewerFrameCount,1)
    }
    func testOverlongAnimationAndInvalidDataFailBoundedDecoder() throws {
        XCTAssertNil(NativeViewerImage.decode(Data("invalid image".utf8),original:true))
        let tooMany = try NativeSyntheticAnimatedImage.gif(frames:NativeViewerImage.maximumFrames+1,width:1,height:1)
        XCTAssertNil(NativeViewerImage.decode(tooMany,original:false));XCTAssertNotNil(NativeImagePreview.decode(tooMany))
    }
    func testNASOctetStreamGIFThumbnailAcceptedButOtherBinaryRejected() async throws {
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://synthetic.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:network());try await api.discover()
        ImageViewerStub.mime = "application/octet-stream";ImageViewerStub.payload = try NativeSyntheticAnimatedImage.gif()
        let data = try await api.thumbnail(postID:1,size:.large);XCTAssertEqual(data,ImageViewerStub.payload)
        ImageViewerStub.payload = Data("not an image".utf8)
        do {_ = try await api.thumbnail(postID:1,size:.large);XCTFail("Non-image binary thumbnail accepted")} catch {}
    }
    func testGalleryUsesOnlyVisibleNondeletedImagesFromCurrentContext() async throws {
        ImageViewerStub.payload = try png(width: 20, height: 10)
        let model = try await model(); let first = try post(1); let second = try post(2)
        model.posts = [first, second, try post(3, image: false), try post(4, deleted: true), try post(5, channel: 94)]
        model.openImage(first); await model.imageViewerTask?.value
        XCTAssertEqual(model.imageViewerCount, 2); XCTAssertFalse(model.canViewPreviousImage); XCTAssertTrue(model.canViewNextImage)
        model.moveViewerImage(by: 1); await model.imageViewerTask?.value
        XCTAssertEqual(model.imageViewerPost?.id, 2); XCTAssertFalse(model.canViewNextImage)
        model.closeImageViewer(); XCTAssertNil(model.imageViewerImage)
        model.threadRoot = try post(10, image: false); model.replies = [second]
        model.openImage(second); await model.imageViewerTask?.value
        XCTAssertEqual(model.imageViewerCount, 1)
        model.closeThread(); XCTAssertNil(model.imageViewerPost)
        model.openImage(try post(99)); XCTAssertNil(model.imageViewerPost)
    }

    func testLibraryGalleryOpensOlderResultsWithoutReplacingTimelineAndRejectsOtherContexts() async throws {
        ImageViewerStub.payload = try png(width:20,height:10)
        let model = try await model(); let current = try post(99); model.posts = [current]
        let older = try post(1); let next = try post(2)
        model.openLibraryImage(older,context:[older,next,try post(3,channel:94),try post(4,deleted:true),try post(5,image:false)])
        await model.imageViewerTask?.value
        XCTAssertEqual(model.imageViewerPost?.id,1);XCTAssertEqual(model.imageViewerCount,2)
        XCTAssertEqual(model.posts.map(\.id),[99])
        model.moveViewerImage(by:1);await model.imageViewerTask?.value;XCTAssertEqual(model.imageViewerPost?.id,2)
        model.closeImageViewer()
        model.openLibraryImage(older,context:[next]);XCTAssertNil(model.imageViewerPost)
        model.threadRoot = current
        model.openLibraryImage(older,context:[older]);XCTAssertNil(model.imageViewerPost)
        model.threadRoot = nil;model.selection = 94
        model.openLibraryImage(older,context:[older]);XCTAssertNil(model.imageViewerPost)
    }

    func testConversationLibraryDoesNotAdvertiseObscuredChatAsVisible() async throws {
        let model = try await model();model.posts = [try post(1)]
        model.updateReadingVisibility(active:true,atBottom:true)
        XCTAssertNotNil(model.notificationVisibleLocation)
        model.conversationLibraryVisible = true
        model.updateReadingVisibility(active:true,atBottom:true)
        XCTAssertNil(model.notificationVisibleLocation)
        model.conversationLibraryVisible = false
        model.updateReadingVisibility(active:true,atBottom:true)
        XCTAssertNotNil(model.notificationVisibleLocation)
    }

    func testClosingOrLockingViewerCancelsLoadAndCannotPublishLateImage() async throws {
        ImageViewerStub.payload = try png(width: 20, height: 10)
        let model = try await model(); let target = try post(1); model.posts = [target]
        for invalidate in [ { model.closeImageViewer() }, { model.lockEncryption(reload: false) }, { model.signOutLocally() } ] {
            let started = expectation(description: "Viewer request started")
            let stopped = expectation(description: "Viewer request cancelled")
            ImageViewerStub.stall = true
            ImageViewerStub.onRequest = { _ in started.fulfill() }
            ImageViewerStub.onStop = { stopped.fulfill() }
            model.openImage(target); let task = model.imageViewerTask
            await fulfillment(of: [started], timeout: 2)
            invalidate(); await task?.value
            await fulfillment(of: [stopped], timeout: 2)
            XCTAssertNil(model.imageViewerPost); XCTAssertNil(model.imageViewerImage); XCTAssertNil(model.imageViewerError)
        }
    }

    func testCorruptImageShowsRecoverableErrorAndViewerDoesNotSuppressNotifications() async throws {
        ImageViewerStub.payload = Data("Not an image".utf8)
        let model = try await model(); let target = try post(1); model.posts = [target]
        model.updateReadingVisibility(active: true, atBottom: true)
        XCTAssertNotNil(model.notificationVisibleLocation)
        model.openImage(target); await model.imageViewerTask?.value
        XCTAssertNil(model.notificationVisibleLocation); XCTAssertNotNil(model.imageViewerError)
        ImageViewerStub.payload = try png(width: 20, height: 10)
        model.retryViewerImage(); await model.imageViewerTask?.value
        XCTAssertNil(model.imageViewerError); XCTAssertNotNil(model.imageViewerImage)
        model.closeImageViewer(); model.updateReadingVisibility(active: true, atBottom: true)
        XCTAssertNotNil(model.notificationVisibleLocation)
    }

    func testEncryptedViewerUsesAuthenticatedOriginalAndLockClearsIt() async throws {
        struct CryptoFixture: Decodable { let password, publicKey, wrappedPrivateKey, wrappedChannelKey, channelKey: String }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ChatCrypto", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(CryptoFixture.self, from: Data(contentsOf: url))
        let encryption = ChatEncryptionSession()
        try encryption.unlock(.init(public_key: fixture.publicKey, private_key_enc: fixture.wrappedPrivateKey), password: fixture.password)
        ImageViewerStub.payload = try ChatContentCrypto.encryptAttachment(png(width: 200, height: 100), key: ChatContentCrypto.decodeBase64(fixture.channelKey))
        let model = try await model(encryption: encryption)
        model.channels = [try JSONDecoder().decode(ChatChannel.self, from: JSONSerialization.data(withJSONObject: [
            "channel_id": 93, "name": "Encrypted synthetic", "type": "private", "unread": 0,
            "encrypted": true, "channel_key_enc": fixture.wrappedChannelKey]))]
        let target = try post(1); model.posts = [target]
        var original = false
        ImageViewerStub.onRequest = { request in
            original = String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("method=get")
        }
        model.openImage(target); await model.imageViewerTask?.value
        XCTAssertTrue(original); XCTAssertEqual(model.imageViewerImage?.size.width, 200)
        model.lockEncryption(reload: false)
        XCTAssertNil(model.imageViewerPost); XCTAssertNil(model.imageViewerImage)
        model.openImage(target); XCTAssertNil(model.imageViewerPost)
    }

    func testChannelRemovalEnvelopeChangeAndSelectionClearVisibleImage() async throws {
        ImageViewerStub.payload = try png(width: 20, height: 10)
        let model = try await model(); let target = try post(1); model.posts = [target]
        let originalChannel = model.channels
        model.openImage(target); await model.imageViewerTask?.value
        model.channels = []
        XCTAssertNil(model.imageViewerImage); XCTAssertNil(model.imageViewerPost)
        model.channels = originalChannel
        model.openImage(target); await model.imageViewerTask?.value
        model.selection = 94
        XCTAssertNil(model.imageViewerImage); XCTAssertNil(model.imageViewerPost)
        model.selection = 93
        model.openImage(target); await model.imageViewerTask?.value
        model.channels = [try JSONDecoder().decode(ChatChannel.self, from: Data(#"{"channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0,"channel_key_enc":"changed-envelope"}"#.utf8))]
        XCTAssertNil(model.imageViewerImage); XCTAssertNil(model.imageViewerPost)
    }

    func testSaveAndOpenRequiresSuccessfulExplicitDestination() async throws {
        ImageViewerStub.payload = try png(width: 20, height: 10)
        let model = try await model(); let target = try post(1)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: file) }
        var opened: [URL] = []
        await model.saveAttachment(target, chooseDestination: { _ in nil }, openAfterSaving: { opened.append($0); return true }, confirmOpening: { _ in .open })
        XCTAssertTrue(opened.isEmpty)
        await model.saveAttachment(target, chooseDestination: { _ in file }, openAfterSaving: { opened.append($0); return true }, confirmOpening: { _ in .open })
        XCTAssertEqual(opened, [file]); XCTAssertEqual(try Data(contentsOf: file), ImageViewerStub.payload)
    }
}

private final class ImageViewerStub: URLProtocol {
    static var mime = "image/png"
    static var payload = Data()
    static var stall = false
    static var onRequest: ((URLRequest) -> Void)?
    static var onStop: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let discovery = request.url!.path.contains("SYNO.API.Info")
        if !discovery {
            var observed = request
            if observed.httpBody == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
                observed.httpBody = bytes
            }
            Self.onRequest?(observed)
            if Self.stall { return }
        }
        let bytes = discovery ? Data(#"{"success":true,"data":{"SYNO.Chat.Post.File":{"path":"entry.cgi","minVersion":1,"maxVersion":2,"requestFormat":"JSON"}}}"#.utf8) : Self.payload
        let headers = discovery ? ["Content-Type": "application/json"] : ["Content-Type": Self.mime, "Content-Disposition": "attachment; filename=synthetic.png"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { if Self.stall { Self.onStop?() } }
}
