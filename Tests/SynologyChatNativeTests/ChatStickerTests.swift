import AppKit
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatStickerTests: XCTestCase {
    override func tearDown() { StickerStub.handler = nil; super.tearDown() }
    private func api() async throws -> ChatAPIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StickerStub.self]
        let client = try ChatAPIClient(session: .init(baseURL: URL(string: "https://fixture.invalid/proxy")!, sid: "session", synoToken: "token"), network: URLSession(configuration: config))
        try await client.discover(); return client
    }
    private let css = """
    .syno-chat .sticker-dog_01 {width: 64px;height:64px;background-image:url("images/sticker/1x/dog-s123.png");background-position:0px 0px;}
    .syno-chat .sticker-dog_02 {width:64px;height:64px;background-image:url(images/sticker/1x/dog-s123.png);background-position:0 -64px;}
    """
    func testSpriteManifestAcceptsOnlyBoundedLocalGeometry() {
        let valid = ChatStickerSprite.parse(css)
        XCTAssertEqual(valid["dog_02"], .init(path: "images/sticker/1x/dog-s123.png", x: 0, y: 64, width: 64, height: 64))
        for replacement in ["https://external.invalid/a.png", "images/sticker/1x/../../private.png", "images/sticker/2x/dog-s123.png"] {
            XCTAssertTrue(ChatStickerSprite.parse(css.replacingOccurrences(of: "images/sticker/1x/dog-s123.png", with: replacement)).isEmpty)
        }
        XCTAssertTrue(ChatStickerSprite.parse(css.replacingOccurrences(of: "64px", with: "999999px")).isEmpty)
        XCTAssertFalse(ChatSticker.validName("../../secret")); XCTAssertFalse(ChatSticker.validName(":dog_01:"))
    }
    func testCatalogueAndAssetsUseNASPrefixWithoutCredentialsOnAssetURLs() async throws {
        let css = self.css
        StickerStub.handler = { request in
            if request.url!.path.hasSuffix("SYNO.API.Info") { return Self.info }
            if request.url!.path.hasSuffix("SYNO.Chat.Sticker") { return Self.catalogue }
            XCTAssertEqual(request.url!.path, "/proxy/webman/3rdparty/Chat/style.css")
            XCTAssertNil(request.url!.query); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            return (Data(css.utf8), "text/css")
        }
        let client = try await api()
        let packs = try await client.stickerCatalogue()
        XCTAssertEqual(packs.first?.stickers.count, 2)
        let bytes = try await client.stickerAssetData(path: "style.css")
        XCTAssertEqual(ChatStickerSprite.parse(String(decoding: bytes, as: UTF8.self)).count, 2)
        do { _ = try await client.stickerAssetData(path: "https://external.invalid/a.png"); XCTFail() } catch { }
    }
    func testNativeSpriteCroppingSharedFetchAndAccountReset() async throws {
        let css = self.css; let png = Self.sprite(); var requests = 0
        StickerStub.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("SYNO.API.Info") { return Self.info }
            if path.hasSuffix("SYNO.Chat.Sticker") { return Self.catalogue }
            if path.hasSuffix("style.css") { return (Data(css.utf8), "text/css") }
            requests += 1; return (png, "image/png")
        }
        let client = try await api(); let assets = NativeStickerAssets(); assets.attach(client)
        async let first = assets.image("dog_01")
        async let second = assets.image("dog_02")
        let (one, two) = await (first, second)
        XCTAssertEqual(one?.size, NSSize(width: 64, height: 64)); XCTAssertEqual(two?.size, NSSize(width: 64, height: 64))
        XCTAssertEqual(requests, 1)
        let top = NSBitmapImageRep(data: one!.tiffRepresentation!)!.colorAt(x: 30, y: 30)!.usingColorSpace(.deviceRGB)!
        let bottom = NSBitmapImageRep(data: two!.tiffRepresentation!)!.colorAt(x: 30, y: 30)!.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(top.redComponent, 0.9); XCTAssertGreaterThan(bottom.blueComponent, 0.9)
        assets.attach(nil); XCTAssertTrue(assets.packs.isEmpty)
        let resetImage = await assets.image("dog_01")
        XCTAssertNil(resetImage)
    }
    func testStickerWireTypesAndReactionNames() async throws {
        var writes: [[String: String]] = []
        StickerStub.handler = { request in
            if request.url!.path.hasSuffix("SYNO.API.Info") { return Self.info }
            let fields = Self.fields(request); writes.append(fields)
            if request.url!.path.hasSuffix("SYNO.Chat.Post.Reaction") { return (Data(#"{"success":true}"#.utf8), "application/json") }
            return (Data(#"{"success":true,"data":{"post_id":123,"channel_id":93,"creator_id":10,"type":"sticker","message":":dog_01:","create_at":1000}}"#.utf8), "application/json")
        }
        let client = try await api()
        _ = try await client.sendSticker(channelID: 93, name: "dog_01", wireText: ":dog_01:", connectionID: "live")
        do { try await client.setReaction(postID: 123, stickerName: "dog_02", enabled: true); XCTFail("Official reactions accept emoji only") } catch { }
        try await client.setReaction(postID: 123, stickerName: "thumbsup", enabled: true)
        try await client.setReaction(postID: 123, stickerName: "thumbsup", enabled: false)
        XCTAssertEqual(writes[0]["type"], #""sticker""#); XCTAssertEqual(writes[0]["message"], #"":dog_01:""#)
        XCTAssertEqual(writes[1]["sticker_name"], #""thumbsup""#); XCTAssertEqual(writes[2]["method"], "delete")
    }
    private static var info: (Data, String) {
        let endpoints = Dictionary(uniqueKeysWithValues: ["SYNO.Chat.Sticker", "SYNO.Chat.Post", "SYNO.Chat.Post.Reaction"].map { ($0, ["path":"entry.cgi", "minVersion":1,"maxVersion":8,"requestFormat":"JSON"] as [String:Any]) })
        return (try! JSONSerialization.data(withJSONObject: ["success":true,"data":endpoints]), "application/json")
    }
    private static var catalogue: (Data, String) { (Data(#"{"success":true,"data":{"categories":[{"category_id":9,"name":"dog","stickers":[{"name":"dog_01","sticker_id":1,"keywords":[]},{"name":"dog_02","sticker_id":2,"keywords":[]}]}]}}"#.utf8), "application/json") }
    private static func sprite() -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:64,pixelsHigh:128,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        for y in 0..<128 { for x in 0..<64 {
            let offset = y * bitmap.bytesPerRow + x * 4
            bitmap.bitmapData![offset] = y < 64 ? 255 : 0
            bitmap.bitmapData![offset + 1] = 0
            bitmap.bitmapData![offset + 2] = y < 64 ? 0 : 255
            bitmap.bitmapData![offset + 3] = 255
        } }
        return bitmap.representation(using:.png,properties:[:])!
    }
    private static func fields(_ request: URLRequest) -> [String:String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:1024)
            while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; data.append(contentsOf:buffer.prefix(n)) }
        }
        return Dictionary(uniqueKeysWithValues: String(decoding:data,as:UTF8.self).split(separator:"&").map { field in
            let pair = field.split(separator:"=",maxSplits:1); return (String(pair[0]),String(pair[1]).removingPercentEncoding!)
        })
    }
}
private final class StickerStub: URLProtocol {
    static var handler: ((URLRequest) -> (Data, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let result = Self.handler?(request) else { client?.urlProtocol(self,didFailWithError:URLError(.badServerResponse)); return }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":result.1])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:result.0);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
