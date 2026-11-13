import XCTest
@testable import SynologyChatNative

@MainActor final class ChatHashtagTests: XCTestCase {
    override func tearDown() { HashtagStub.handler = nil; super.tearDown() }
    func testHashtagGrammarUsesVendorUTF16Limit() {
        for tag in ["release-notes","topic_1","Café","👀","123"] { XCTAssertTrue(ChatHashtags.valid(tag),tag) }
        for tag in ["","two words","#topic","x/y","x.y","x|y","x\ny",String(repeating:"👀",count:17)] { XCTAssertFalse(ChatHashtags.valid(tag),tag) }
        XCTAssertTrue(ChatHashtags.valid(String(repeating:"👀",count:16)))
    }
    func testInternalDestinationRejectsForeignOrExtraParameters() {
        let url = ChatHashtags.destination("Café")!
        XCTAssertEqual(ChatHashtags.tag(from:url),"Café")
        for value in ["https://browse?tag=tag","synology-chat-hashtag://browse/path?tag=x","synology-chat-hashtag://browse?tag=x&tag=y","synology-chat-hashtag://name:password@browse?tag=x","synology-chat-hashtag://browse?tag=x&_sid=secret"] {
            XCTAssertNil(ChatHashtags.tag(from:URL(string:value)!))
        }
    }
    func testNativeTagLinksRespectWhitespaceCodeEncryptionAndWebLinks() {
        let value = ChatMessageFormatting.inline("#Release_1, x#not-a-tag `#literal` <https://example.test|#link-label>")
        let tags = value.runs.compactMap(\.link).compactMap(ChatHashtags.tag)
        XCTAssertEqual(tags,["Release_1"])
        XCTAssertEqual(String(value.characters),"#Release_1, x#not-a-tag #literal #link-label")
        XCTAssertTrue(ChatMessageFormatting.inline("#private",hashtagLinks:false).runs.compactMap(\.link).isEmpty)
        XCTAssertTrue(ChatMessageFormatting.inline("#"+String(repeating:"a",count:33)).runs.compactMap(\.link).isEmpty)
    }
    func testCatalogueAndSearchUseDedicatedHashtagArray() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HashtagStub.self]
        var search: [String:String] = [:]
        HashtagStub.handler = { request in
            if request.url!.path.hasSuffix("SYNO.API.Info") {
                let endpoints = Dictionary(uniqueKeysWithValues:["SYNO.Chat.Channel.Hashtag","SYNO.Chat.Post"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"] as [String:Any]) })
                return try! JSONSerialization.data(withJSONObject:["success":true,"data":endpoints])
            }
            if request.url!.path.hasSuffix("SYNO.Chat.Channel.Hashtag") { return Data(#"{"success":true,"data":{"hashtags":["topic","topic","other","bad/tag"]}}"#.utf8) }
            search = Self.fields(request)
            return Data(#"{"success":true,"data":{"search_results":[],"total":0}}"#.utf8)
        }
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        try await api.discover()
        let tags = try await api.channelHashtags(channelID:93); XCTAssertEqual(tags,["other","topic"])
        _ = try await api.searchMessages(query:"",channelID:93,hashtag:"topic")
        XCTAssertEqual(search["hashtag"],#"["topic"]"#);XCTAssertEqual(search["in"],"[93]")
        XCTAssertEqual(search["keyword"],#""""#);XCTAssertEqual(search["method"],"search")
        var filters = ChatSearchFilters(); filters.authorID = 10; filters.mentionID = 6; filters.content = .file; filters.attribute = .star; filters.fileType = "png"
        _ = try await api.searchMessages(query:"test",channelID:93,hashtag:"topic",filters:filters)
        XCTAssertEqual(search["from"],"[10]");XCTAssertEqual(search["mention"],"[6]")
        XCTAssertEqual(search["post_type"],#"["file"]"#);XCTAssertEqual(search["has"],#"["star"]"#)
        XCTAssertEqual(search["file_type"],#"["png"]"#);XCTAssertEqual(search["hashtag"],#"["topic"]"#)
        do { _ = try await api.searchMessages(query:"",channelID:93,hashtag:"bad/tag");XCTFail() } catch { }
    }
    func testEncryptedOrUnknownChannelCannotBrowseCatalogue() {
        let model = NativeChatPreviewModel(restoreNotificationPreference:false)
        model.connected = true
        model.channels = [try! JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Private","type":"private","encrypted":true,"unread":0}"#.utf8))]
        XCTAssertFalse(model.canBrowseHashtags(93));XCTAssertFalse(model.canBrowseHashtags(999))
        model.signOutLocally()
    }
    func testAdditionalTagTransportIsSingleScalarSetDeleteAndRejectsInvalidValues() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HashtagStub.self]
        var calls: [[String:String]] = []
        HashtagStub.handler = { request in
            if request.url!.path.hasSuffix("SYNO.API.Info") { return Data(#"{"success":true,"data":{"SYNO.Chat.Post.Hashtag":{"path":"entry.cgi","minVersion":1,"maxVersion":1,"requestFormat":"JSON"}}}"#.utf8) }
            calls.append(Self.fields(request)); return Data(#"{"success":true}"#.utf8)
        }
        let api = try ChatAPIClient(session: .init(baseURL: URL(string:"https://fixture.invalid")!, sid:"synthetic", synoToken:"synthetic"), network: URLSession(configuration:config))
        try await api.discover()
        try await api.setAdditionalHashtag(postID: 123, hashtag: "topic_1", enabled: true)
        try await api.setAdditionalHashtag(postID: 123, hashtag: "topic_1", enabled: false)
        XCTAssertEqual(calls.map { $0["method"] }, ["set","delete"])
        XCTAssertTrue(calls.allSatisfy { $0["post_id"] == "123" && $0["hashtag"] == #""topic_1""# && $0["version"] == "1" })
        for value in ["", "#topic", "bad/tag", String(repeating:"a",count:33)] {
            do { try await api.setAdditionalHashtag(postID:123, hashtag:value, enabled:true); XCTFail() } catch { }
        }
        do { try await api.setAdditionalHashtag(postID:0, hashtag:"topic", enabled:true); XCTFail() } catch { }
        XCTAssertEqual(calls.count,2)
    }
    func testIndexedAndAdditionalTagMetadataDecodeSeparately() throws {
        let post = try JSONDecoder().decode(ChatPost.self, from: Data(##"{"post_id":1,"channel_id":23,"creator_id":10,"type":"normal","message":"#inline","create_at":1,"hashtags":["inline","added","unknown"],"hashtags_additional":[{"hashtag":"added","user_id":10},{"hashtag":"unknown"}]}"##.utf8))
        let snapshot = ChatPostHashtagSnapshot(post:post, accountGeneration:7)
        XCTAssertEqual(snapshot.indexed,["inline","added","unknown"])
        XCTAssertEqual(snapshot.otherIndexed,["inline"])
        XCTAssertEqual(snapshot.additional.map(\.hashtag),["added","unknown"])
        XCTAssertEqual(snapshot.additional[0].user_id,10); XCTAssertNil(snapshot.additional[1].user_id)
        XCTAssertEqual(post.message,"#inline")
    }

    private static func fields(_ request: URLRequest) -> [String:String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer {stream.close()};var buffer = [UInt8](repeating:0,count:1024)
            while stream.hasBytesAvailable {let n = stream.read(&buffer,maxLength:buffer.count);if n<=0 {break};data.append(contentsOf:buffer.prefix(n))}
        }
        return Dictionary(uniqueKeysWithValues:String(decoding:data,as:UTF8.self).split(separator:"&").map { field in
            let p = field.split(separator:"=",maxSplits:1);return (String(p[0]),String(p[1]).removingPercentEncoding!)
        })
    }
}
private final class HashtagStub: URLProtocol {
    static var handler: ((URLRequest)->Data)?
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        guard let data = Self.handler?(request) else { client?.urlProtocol(self,didFailWithError:URLError(.badServerResponse));return }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
