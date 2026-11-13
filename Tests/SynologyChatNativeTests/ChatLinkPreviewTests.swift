import AppKit
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatLinkPreviewTests: XCTestCase {
    private func post(props: String = #"{"safe_url":true}"#, links: String = #"[{"url":"https://example.test/page","title":"Synthetic preview","description":"Fixture description","image":"https://images.example.test/card.png","hidden":false}]"#) throws -> ChatPost {
        try JSONDecoder().decode(ChatPost.self, from: Data("""
        {"post_id":731,"channel_id":93,"creator_id":10,"type":"normal","message":"Synthetic https://example.test/page","create_at":1000,"url_props":\(links),"props":\(props)}
        """.utf8))
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LinkPreviewStub.self]
        return URLSession(configuration: config)
    }
    private func model() async throws -> (NativeChatPreviewModel, ChatAPIClient) {
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://nas.synthetic.invalid")!, sid: "synthetic", synoToken: "synthetic"), network: session())
        try await api.discover()
        let model = NativeChatPreviewModel(client: api, restoreNotificationPreference: false)
        model.channels = [try JSONDecoder().decode(ChatChannel.self, from: Data(#"{"channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0}"#.utf8))]
        model.selection = 93; model.connected = true; model.liveStatus = .live
        addTeardownBlock { @MainActor in model.signOutLocally() }
        return (model, api)
    }
    private func show(_ model: NativeChatPreviewModel, hidden: Bool) {
        model.handleLiveEvent(.init(name: "client.broadcast", payload: .object([
            "type": .string("setting.update"), "data": .object(["hide_post_url_preview": .bool(hidden)])])))
    }
    override func tearDown() {
        LinkPreviewStub.onRequest = nil; LinkPreviewStub.onStop = nil; LinkPreviewStub.stall = false; LinkPreviewStub.completeHeld = nil
        super.tearDown()
    }

    func testWebNavigationRejectsActiveLocalCredentialAndSessionURLs() {
        for value in ["javascript:alert(1)","file:///tmp/private","data:text/html,test","synology://open", "https://name:password@example.test/", "https://example.test/?_sid=secret", "https://example.test/?sYnOtOkEn=secret", "https://example.test/%0Aunsafe"] {
            XCTAssertNil(ChatMessageLinks.webURL(value), value)
        }
        XCTAssertNotNil(ChatMessageLinks.webURL("https://example.test/path?q=hello%20world#section"))
        XCTAssertNotNil(ChatMessageLinks.webURL("http://example.test/"))
    }

    func testNativeAttributedLinksKeepUnicodeAndVendorLabels() {
        let value = ChatMessageLinks.attributed("Café 👀 <https://example.test/page|Read the page> and https://other.test/path.")
        XCTAssertEqual(String(value.characters), "Café 👀 Read the page and https://other.test/path.")
        let links = value.runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.host), ["example.test", "other.test"])
        XCTAssertTrue(ChatMessageLinks.attributed("file:///private/secret javascript:alert(1)").runs.compactMap(\.link).isEmpty)
    }

    func testMalformedMetadataDoesNotDropMessageAndInvalidSafetyFailsClosed() throws {
        let target = try post(props: #"{"safe_url":"invalid"}"#, links: #"[{"url":12,"image":[],"hidden":"false"}]"#)
        XCTAssertEqual(target.message, "Synthetic https://example.test/page")
        XCTAssertEqual(target.props?.safe_url, false)
        XCTAssertTrue(try XCTUnwrap(target.url_props?.first).hidden)
        XCTAssertNil(try post(links: #"{"invalid":"array"}"#).url_props)
        XCTAssertEqual(try post(props: "[]").props?.safe_url, false)
        XCTAssertTrue(try JSONDecoder().decode(ChatDisplaySettings.self, from: Data("{}".utf8)).hidesPreviews)
    }

    func testGlobalPerCardUnsafeAndEncryptedPoliciesPreserveOriginalIndices() async throws {
        let (model, _) = try await model()
        let target = try post(links: #"[{"url":"https://hidden.test/","hidden":true},{"url":"https://shown.test/","hidden":false},{"url":"file:///private/secret"}]"#)
        XCTAssertTrue(model.linkPreviews(for: target).isEmpty)
        show(model, hidden: false)
        XCTAssertEqual(model.linkPreviews(for: target).map(\.index), [1])
        XCTAssertTrue(model.linkPreviews(for: try post(props: #"{"safe_url":false}"#)).isEmpty)
        XCTAssertTrue(model.linkPreviews(for: try post(props: #"{"encrypted":true}"#)).isEmpty)
        model.handleLiveEvent(.init(name: "client.setting.update", payload: .object([:])))
        XCTAssertTrue(model.linkPreviews(for: target).isEmpty)
    }

    func testServerImageDimensionsDecodeOnlyBoundedPositiveIntegers() throws {
        let valid = try post(links: #"[{"url":"https://example.test/","image_prop":{"width":48,"height":32}}]"#)
        let dimensions = try XCTUnwrap(valid.url_props?.first?.image_prop)
        XCTAssertEqual(dimensions.width,48);XCTAssertEqual(dimensions.height,32);XCTAssertTrue(dimensions.isSmall)
        for metadata in [#"{"width":0,"height":20}"#,#"{"width":20,"height":-1}"#,#"{"width":16001,"height":1}"#,#"{"width":8000,"height":8000}"#,#"{"width":"48","height":32}"#,#"{"width":1.5,"height":32}"#,#"{"width":48}"#,"[]","null"] {
            let value = try post(links: "[{\"url\":\"https://example.test/\",\"title\":\"Retained title\",\"image_prop\":\(metadata)}]")
            XCTAssertEqual(value.url_props?.first?.title,"Retained title");XCTAssertNil(value.url_props?.first?.image_prop)
            XCTAssertEqual(value.message,"Synthetic https://example.test/page")
        }
    }

    func testFaviconUsesNASProxyAndSeparateBoundedCacheFromMainImage() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:128,pixelsHigh:64,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        bitmap.bitmapData?.initialize(repeating:127,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
        LinkPreviewStub.payload = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        let (model,_) = try await model();show(model,hidden:false)
        let target = try post(links:#"[{"url":"https://example.test/page","image":"https://images.example.test/asset.png","favicon":"https://images.example.test/asset.png"}]"#)
        let preview = try XCTUnwrap(target.url_props?.first)
        var routes:[(String?,[String:String])] = []
        LinkPreviewStub.onRequest = { request,fields in routes.append((request.url?.host,fields)) }
        let image = await model.linkPreviewImage(for:target,preview:preview)
        let icon = await model.linkPreviewFavicon(for:target,preview:preview)
        XCTAssertEqual(image?.size.width,128);XCTAssertEqual(icon?.size.width,32)
        XCTAssertEqual(routes.count,2)
        for route in routes {
            XCTAssertEqual(route.0,"nas.synthetic.invalid");XCTAssertEqual(route.1["method"],"og");XCTAssertEqual(route.1["post_id"],"731")
            XCTAssertEqual(try JSONDecoder().decode(String.self,from:Data(try XCTUnwrap(route.1["url"]).utf8)),"https://images.example.test/asset.png")
        }
        _ = await model.linkPreviewFavicon(for:target,preview:preview)
        _ = await model.linkPreviewImage(for:target,preview:preview)
        XCTAssertEqual(routes.count,2)
    }

    func testAbsentInvalidUnsafeEncryptedAndGloballyHiddenFaviconsNeverRequest() async throws {
        let (model,_) = try await model();show(model,hidden:false)
        var requests = 0;LinkPreviewStub.onRequest = { _,_ in requests += 1 }
        for metadata in [#"{"url":"https://example.test/page"}"#,#"{"url":"https://example.test/page","favicon":"file:///tmp/private"}"#,#"{"url":"https://example.test/page","favicon":"https://name:password@example.test/"}"#,#"{"url":"https://example.test/page","favicon":[],"image_prop":false}"#] {
            let target = try post(links:"["+metadata+"]")
            let result = await model.linkPreviewFavicon(for:target,preview:try XCTUnwrap(target.url_props?.first));XCTAssertNil(result)
        }
        for props in [#"{"safe_url":false}"#,#"{"encrypted":true}"#] {
            let target = try post(props:props,links:#"[{"url":"https://example.test/page","favicon":"https://images.example.test/favicon.png"}]"#)
            let result = await model.linkPreviewFavicon(for:target,preview:try XCTUnwrap(target.url_props?.first));XCTAssertNil(result)
        }
        let target = try post(links:#"[{"url":"https://example.test/page","favicon":"https://images.example.test/favicon.png"}]"#)
        show(model,hidden:true)
        let result = await model.linkPreviewFavicon(for:target,preview:try XCTUnwrap(target.url_props?.first));XCTAssertNil(result);XCTAssertEqual(requests,0)
    }

    func testCanonicalMetadataAndSafetyChangesRejectCapturedPreviewAssets() async throws {
        let (model,_) = try await model();show(model,hidden:false)
        let target = try post(links:#"[{"url":"https://example.test/page","image":"https://images.example.test/card.png","favicon":"https://images.example.test/favicon.png"}]"#)
        let preview = try XCTUnwrap(target.url_props?.first)
        var requests = 0;LinkPreviewStub.onRequest = { _,_ in requests += 1 }
        for replacement in [try post(props:#"{"safe_url":false}"#),try post(links:#"[{"url":"https://different.example.test/","image":"https://images.example.test/card.png","favicon":"https://images.example.test/favicon.png"}]"#),try post(links:#"[{"url":"https://example.test/page","hidden":true,"image":"https://images.example.test/card.png","favicon":"https://images.example.test/favicon.png"},{"url":"https://other.example.test/"}]"#)] {
            model.posts = [replacement]
            let image = await model.linkPreviewImage(for:target,preview:preview)
            let icon = await model.linkPreviewFavicon(for:target,preview:preview)
            XCTAssertNil(image);XCTAssertNil(icon)
        }
        XCTAssertEqual(requests,0)
    }

    func testFaviconCompletionCannotPublishAfterCanonicalSafetyChange() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        bitmap.bitmapData?.initialize(repeating:127,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
        LinkPreviewStub.payload = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        let (model,_) = try await model();show(model,hidden:false)
        let target = try post(links:#"[{"url":"https://example.test/page","favicon":"https://images.example.test/favicon.png"}]"#)
        let preview = try XCTUnwrap(target.url_props?.first),started = expectation(description:"Favicon requested")
        LinkPreviewStub.stall = true;LinkPreviewStub.onRequest = { _,_ in started.fulfill() }
        let operation = Task { await model.linkPreviewFavicon(for:target,preview:preview) }
        await fulfillment(of:[started],timeout:2)
        model.posts = [try post(props:#"{"safe_url":false}"#)]
        let complete = try XCTUnwrap(LinkPreviewStub.completeHeld);complete()
        let result = await operation.value;XCTAssertNil(result)
    }

    func testSignOutCancelsFaviconProxyTransfer() async throws {
        let (model,_) = try await model();show(model,hidden:false)
        let target = try post(links:#"[{"url":"https://example.test/page","favicon":"https://images.example.test/favicon.png"}]"#)
        let started = expectation(description:"Favicon requested"),stopped = expectation(description:"Favicon cancelled")
        LinkPreviewStub.stall = true;LinkPreviewStub.onRequest = { _,_ in started.fulfill() };LinkPreviewStub.onStop = { stopped.fulfill() }
        let operation = Task { await model.linkPreviewFavicon(for:target,preview:try XCTUnwrap(target.url_props?.first)) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally()
        let result = try await operation.value;await fulfillment(of:[stopped],timeout:2);XCTAssertNil(result)
    }

    func testPreviewImagesOnlyUseAuthenticatedNASProxyAndHideRouteUsesIndex() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 127, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        LinkPreviewStub.payload = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let (model, api) = try await model(); show(model, hidden: false)
        let target = try post(); let preview = try XCTUnwrap(target.url_props?.first)
        var routes: [(String?, [String: String])] = []
        LinkPreviewStub.onRequest = { request, fields in routes.append((request.url?.host, fields)) }
        let image = await model.linkPreviewImage(for: target, preview: preview)
        XCTAssertNotNil(image)
        XCTAssertEqual(routes.first?.0, "nas.synthetic.invalid")
        XCTAssertEqual(routes.first?.1["method"], "og")
        let encodedURL = try XCTUnwrap(routes.first?.1["url"])
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(encodedURL.utf8)), "https://images.example.test/card.png")
        try await api.hideLinkPreview(postID: 731, index: 1)
        XCTAssertEqual(routes.last?.1["method"], "hide_og"); XCTAssertEqual(routes.last?.1["idx"], "1")
        let settings = try await api.displaySettings(); XCTAssertTrue(settings.hidesPreviews)
    }

    #if DEBUG
    func testLocalFixtureImageViewerUsesOnlyInterceptedNASResponses() async throws {
        let model = try await NativeRichLinksFixture.makeModel()
        defer { model.signOutLocally() }
        let imagePost = try XCTUnwrap(model.posts.first { $0.type == "file" })
        model.openImage(imagePost)
        await model.imageViewerTask?.value
        await model.imageHistoryTask?.value
        XCTAssertEqual(model.imageViewerImage?.size, NSSize(width: 400, height: 160))
        XCTAssertNil(model.imageHistoryError)
        XCTAssertEqual(model.imageViewerCount, 1)
        XCTAssertFalse(model.canViewNextImage); XCTAssertFalse(model.canViewPreviousImage)
        model.closeImageViewer(); XCTAssertNil(model.imageViewerImage)
    }
    func testLocalFixtureExercisesActualCardAndHiddenUnsafeConsumers() async throws {
        let model = try await NativeRichLinksFixture.makeModel()
        defer { model.signOutLocally() }
        XCTAssertEqual(model.posts.count, 4)
        XCTAssertEqual(model.liveStatus, .rejected)
        XCTAssertFalse(model.hidesLinkPreviews)
        XCTAssertEqual(model.linkPreviews(for: model.posts[0]).count, 1)
        XCTAssertTrue(model.linkPreviews(for: model.posts[1]).isEmpty)
        XCTAssertEqual(model.posts[2].props?.safe_url, false)
        let card = try XCTUnwrap(model.posts[0].url_props?.first)
        let image = await model.linkPreviewImage(for: model.posts[0], preview: card)
        XCTAssertEqual(image?.size.width, 400)
    }
    #endif

    func testHidingDuringImageTransferCancelsAndPreventsLatePublication() async throws {
        let (model, _) = try await model(); show(model, hidden: false)
        let target = try post(); let preview = try XCTUnwrap(target.url_props?.first)
        let started = expectation(description: "Proxy image requested")
        let stopped = expectation(description: "Proxy image cancelled")
        LinkPreviewStub.stall = true
        LinkPreviewStub.onRequest = { _, _ in started.fulfill() }; LinkPreviewStub.onStop = { stopped.fulfill() }
        let operation = Task { await model.linkPreviewImage(for: target, preview: preview) }
        await fulfillment(of: [started], timeout: 2)
        show(model, hidden: true)
        let image = await operation.value
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertNil(image); XCTAssertTrue(model.linkPreviews(for: target).isEmpty)
    }
    func testLibraryImageUsesNASProxyEvenWhenInlinePreviewsAreHidden() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        bitmap.bitmapData?.initialize(repeating:255,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
        LinkPreviewStub.payload = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        var routes:[(String,[String:String])] = []
        LinkPreviewStub.onRequest = { request,fields in routes.append((request.url!.host!,fields)) }
        let (model,_) = try await model();let source = try post();show(model,hidden:true)
        let entry = try XCTUnwrap(ChatLinkLibrary.entries([source]).first)
        XCTAssertTrue(model.linkPreviews(for:source).isEmpty);XCTAssertTrue(model.canBrowseLibraryLink(entry))
        let image = await model.libraryLinkImage(entry);XCTAssertNotNil(image)
        let proxy = try XCTUnwrap(routes.first { $0.1["method"] == "og" })
        XCTAssertEqual(proxy.0,"nas.synthetic.invalid");XCTAssertEqual(proxy.1["post_id"],"731")
        let encodedURL = try XCTUnwrap(proxy.1["url"])
        XCTAssertEqual(try JSONDecoder().decode(String.self,from:Data(encodedURL.utf8)),"https://images.example.test/card.png")
    }
    func testLibraryEditedMessageRetiresRemovedLinkBeforeNavigationOrImageRequest() async throws {
        let (model, _) = try await model(), source = try post()
        let entry = try XCTUnwrap(ChatLinkLibrary.entries([source]).first)
        model.posts = [try post(links: #"[{"url":"https://replacement.test/","image":"https://images.example.test/new.png"}]"#)]
        var requests = 0; LinkPreviewStub.onRequest = { _, _ in requests += 1 }
        XCTAssertFalse(model.canBrowseLibraryLink(entry))
        let image = await model.libraryLinkImage(entry)
        XCTAssertNil(image); XCTAssertEqual(requests, 0)
    }
    func testLibraryEditedImageHidesAlreadyLoadedAssetAndRejectsCacheHit() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        LinkPreviewStub.payload = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        let (model, _) = try await model(), source = try post()
        model.posts = [source]
        let entry = try XCTUnwrap(ChatLinkLibrary.entries([source]).first)
        let loaded = await model.libraryLinkImage(entry)
        XCTAssertNotNil(loaded); XCTAssertTrue(model.canShowLibraryLinkImage(entry))
        model.posts = [try post(links: #"[{"url":"https://example.test/page","image":"https://images.example.test/replaced.png"}]"#)]
        XCTAssertTrue(model.canBrowseLibraryLink(entry)); XCTAssertFalse(model.canShowLibraryLinkImage(entry))
        let cached = await model.libraryLinkImage(entry)
        XCTAssertNil(cached)
    }
    func testLibraryChangedImageDuringTransferCannotPublishOldAsset() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        LinkPreviewStub.payload = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        let (model, _) = try await model(), source = try post()
        model.posts = [source]
        let entry = try XCTUnwrap(ChatLinkLibrary.entries([source]).first)
        let started = expectation(description: "Library image requested")
        LinkPreviewStub.stall = true; LinkPreviewStub.onRequest = { _, _ in started.fulfill() }
        let operation = Task { await model.libraryLinkImage(entry) }
        await fulfillment(of: [started], timeout: 2)
        model.posts = [try post(links: #"[{"url":"https://example.test/page","image":"https://images.example.test/replaced.png"}]"#)]
        XCTAssertTrue(model.canBrowseLibraryLink(entry), "Same website remains navigable")
        try XCTUnwrap(LinkPreviewStub.completeHeld)()
        let image = await operation.value
        XCTAssertNil(image, "Superseded image must not publish or enter the cache")
    }
    func testLibraryKnownUnsafeAndForgedDestinationCannotLoadOrNavigate() async throws {
        let (model,_) = try await model();let source = try post();let entry = try XCTUnwrap(ChatLinkLibrary.entries([source]).first)
        let forged = ChatLinkLibrary.Entry(rawURL:entry.rawURL,destination:URL(string:"https://wrong.test/")!,post:source,preview:entry.preview)
        XCTAssertFalse(model.canBrowseLibraryLink(forged))
        model.posts = [try post(props:#"{"safe_url":false}"#)]
        XCTAssertTrue(model.libraryLinkIsUnsafe(entry))
        var requests = 0;LinkPreviewStub.onRequest = { _,_ in requests += 1 }
        let image = await model.libraryLinkImage(entry);XCTAssertNil(image);XCTAssertEqual(requests,0)
        model.signOutLocally();XCTAssertFalse(model.canBrowseLibraryLink(entry))
    }
    func testLibraryImageSignOutCancelsAndDropsInflightProxyData() async throws {
        let (model,_) = try await model();let source = try post();let entry = try XCTUnwrap(ChatLinkLibrary.entries([source]).first)
        let started = expectation(description:"Library image started"),stopped = expectation(description:"Library image cancelled")
        LinkPreviewStub.stall = true;LinkPreviewStub.onRequest = { _,_ in started.fulfill() };LinkPreviewStub.onStop = { stopped.fulfill() }
        let operation = Task { await model.libraryLinkImage(entry) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally()
        let result = await operation.value;await fulfillment(of:[stopped],timeout:2);XCTAssertNil(result)
    }

}

private final class LinkPreviewStub: URLProtocol {
    static var payload = Data()
    static var onRequest: ((URLRequest, [String: String]) -> Void)?
    static var onStop: (() -> Void)?
    static var stall = false
    static var completeHeld:(()->Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let discovery = request.url!.path.contains("SYNO.API.Info")
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
            }
        }
        var fields = URLComponents(); fields.percentEncodedQuery = String(decoding: body, as: UTF8.self)
        let parameters = Dictionary((fields.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let binary = request.url!.path.contains("SYNO.Chat.Post.File")
        if binary && Self.stall {
            Self.completeHeld = { [weak self] in
                guard let self else { return }
                self.respond(Self.payload,binary:true)
            }
            Self.onRequest?(request,parameters);return
        }
        if !discovery { Self.onRequest?(request, parameters) }
        let data: Data
        if discovery { data = Data(#"{"success":true,"data":{"SYNO.Chat.Post.File":{"path":"entry.cgi","minVersion":1,"maxVersion":2,"requestFormat":"JSON"},"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"},"SYNO.Chat.Admin.Setting":{"path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"}}}"#.utf8) }
        else if binary { data = Self.payload }
        else if request.url!.path.contains("SYNO.Chat.Admin.Setting") { data = Data(#"{"success":true,"data":{"hide_post_url_preview":true}}"#.utf8) }
        else { data = Data(#"{"success":true}"#.utf8) }
        respond(data,binary:binary)
    }
    private func respond(_ data:Data,binary:Bool) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": binary ? "image/png" : "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { if Self.stall { Self.onStop?() } }
}
