import XCTest
@testable import SynologyChatNative

final class ChatSearchQueryTests: XCTestCase {
    private let users = [ChatSearchEntity(id:10,label:"Peter Cousins",aliases:["peter.cousins","Peter Cousins","Peter"]),.init(id:6,label:"Peter",aliases:["costwise","Peter"])]
    private let channels = [ChatSearchEntity(id:93,label:"Peter conversation",aliases:["Peter conversation","Costwise"]),.init(id:96,label:"Self test",aliases:["Self test"])]
    private var london:Calendar { var c = Calendar(identifier:.gregorian);c.timeZone = TimeZone(identifier:"Europe/London")!;return c }
    private func parse(_ query:String,base:ChatSearchFilters = .init()) throws -> ChatSearchQuery { try .parse(query,base:base,users:users,channels:channels,calendar:london) }
    private func fields(_ value:ChatSearchQuery) throws -> [String:Any] { try JSONSerialization.jsonObject(with:JSONEncoder().encode(value.filters.parameters(calendar:london))) as! [String:Any] }
    func testFullOperatorQueryMapsMultiValuesToOfficialArraysAndRemainingKeyword() throws {
        let result = try parse("Native text from:u:10 from:costwise in:@c:93 in:\"Self test\" has:file has:vote has:bookmark has:url filetype:GIF filetype:png @u:6 #NativeParity20261016 #Second")
        let p = try fields(result)
        XCTAssertEqual(result.keyword,"Native text");XCTAssertEqual(p["from"] as? [Int],[10,6]);XCTAssertEqual(p["in"] as? [Int],[93,96])
        XCTAssertEqual(p["post_type"] as? [String],["file","vote"]);XCTAssertEqual(p["has"] as? [String],["star","url"])
        XCTAssertEqual(p["file_type"] as? [String],["gif","png"]);XCTAssertEqual(p["mention"] as? [Int],[6]);XCTAssertEqual(p["hashtag"] as? [String],["NativeParity20261016","Second"])
    }
    func testPanelAndTextFiltersMergeWithoutLosingSingleSelectionsOrDuplicatingValues() throws {
        var base = ChatSearchFilters();base.authorID = 10;base.mentionID = 6;base.content = .file;base.attribute = .pin;base.fileType = "GIF"
        let p = try fields(parse("from:u:6 from:u:10 @u:6 has:file has:reaction filetype:gif",base:base))
        XCTAssertEqual(p["from"] as? [Int],[10,6]);XCTAssertEqual(p["mention"] as? [Int],[6]);XCTAssertEqual(p["post_type"] as? [String],["file"])
        XCTAssertEqual(p["has"] as? [String],["pin","reaction"]);XCTAssertEqual(p["file_type"] as? [String],["gif"])
    }
    func testIdentityResolutionRejectsAmbiguityUnavailableIDsAndFixedScopeExpansion() throws {
        XCTAssertThrowsError(try parse("from:Peter"));XCTAssertEqual(try fields(parse("from:\"Peter Cousins\""))["from"] as? [Int],[10])
        for query in ["from:u:999","in:@c:999","@u:999","from:u:9223372036854775808"] { XCTAssertThrowsError(try parse(query)) }
        XCTAssertThrowsError(try ChatSearchQuery.parse("in:@c:96",users:users,channels:channels,fixedChannelID:93))
        XCTAssertNoThrow(try ChatSearchQuery.parse("in:@c:93",users:users,channels:channels,fixedChannelID:93))
    }
    func testQuotedOperatorsAndOrdinaryURLsRemainLiteralKeywords() throws {
        let query = #""has:file" "from:Peter" someone@example.test https://example.test/from:peter has:pin"#
        let result = try parse(query)
        XCTAssertEqual(result.keyword,#""has:file" "from:Peter" someone@example.test https://example.test/from:peter"#)
        XCTAssertEqual(try fields(result)["has"] as? [String],["pin"])
        XCTAssertThrowsError(try parse(#"from:"Unfinished"#))
    }
    func testDateValidationLastOccurrenceAndLocalDSTBoundaries() throws {
        let result = try parse("after:2026-01-01 after:2026/3/29 before:2026-03-29")
        let p = try fields(result),first = try XCTUnwrap(p["after"] as? Int64),last = try XCTUnwrap(p["before"] as? Int64)
        XCTAssertEqual(last-first,23*60*60*1000-1000)
        for bad in ["2026-02-29","1900-02-29","2026--03-29","2026-+3-29","2026-003-29","999-01-01","3000-01-01"] { XCTAssertThrowsError(try parse("after:"+bad)) }
        XCTAssertNoThrow(try parse("after:2000-02-29"));XCTAssertThrowsError(try parse("after:2026-10-21 before:2026-10-20"))
    }
    func testSuggestionsKeepFriendlyUniqueNamesAndReplaceOnlyFinalFragment() throws {
        let choices = ChatSearchQuery.suggestions("Native has:fi",users:users,channels:channels)
        XCTAssertEqual(choices.map(\.label),["has:file"]);XCTAssertEqual(ChatSearchQuery.applying(choices[0],to:"Native has:fi"),"Native has:file ")
        let authors = ChatSearchQuery.suggestions("from:Peter",users:users,channels:channels)
        XCTAssertEqual(authors.count,2)
        for item in authors { XCTAssertFalse(item.replacement.contains("u:"));XCTAssertNoThrow(try parse(item.replacement)) }
        XCTAssertEqual(ChatSearchQuery.suggestions("from: ",users:users,channels:channels).count,8)
    }
    func testInvalidRecognizedOperatorsAreNotSilentlySentAsBroadKeywordSearches() {
        for query in ["has:everything","filetype:.pdf","filetype:","from:","#","@",String(repeating:"a",count:4097)] { XCTAssertThrowsError(try parse(query)) }
        var base = ChatSearchFilters();base.channelIDs = [0];XCTAssertThrowsError(try base.parameters())
    }
    func testLegacyKeywordAndEmptyFilterBehaviorAreRetained() throws {
        let result = try parse("plain   text")
        XCTAssertEqual(result.keyword,"plain text");XCTAssertTrue(result.filters.isEmpty);XCTAssertTrue(try fields(result).isEmpty)
        XCTAssertFalse(try parse("in:Costwise").filters.isEmpty)
    }
    func testGeneralTextSuggestsAuthorsAndConversationsAsTypedFilters() throws {
        let choices = ChatSearchQuery.suggestions(token:"Pe",users:users,channels:channels)
        XCTAssertEqual(choices.map(\.id),["from:u:10","from:u:6","in:@c:93","filetype:"])
        for item in choices { if item.replacement.hasSuffix(":") { XCTAssertThrowsError(try parse(item.replacement)) } else { let parsed = try parse(item.replacement);XCTAssertTrue(parsed.keyword.isEmpty);XCTAssertFalse(parsed.filters.isEmpty) } }
        XCTAssertTrue(try parse("Pe").filters.isEmpty) // Unselected Return keeps the actual keyword.
    }
    func testGeneralMenuIncludesMatchingModifiersAfterEntityChoices() {
        let choices = ChatSearchQuery.suggestions(token:"in",users:[.init(id:10,label:"Indigo",aliases:["Indigo"])],channels:[.init(id:93,label:"Indigo room",aliases:["Indigo room"])])
        XCTAssertEqual(choices.map(\.id),["from:u:10","in:@c:93","in:"])
        XCTAssertEqual(choices.last?.replacement,"in:")
    }
    func testBotCanBeAuthorButIsExcludedFromMentionSuggestions() throws {
        let bot = ChatSearchEntity(id:1,label:"System bot",aliases:["system"],canMention:false)
        XCTAssertTrue(ChatSearchQuery.suggestions(token:"@sys",users:[bot],channels:[]).isEmpty)
        XCTAssertEqual(ChatSearchQuery.suggestions(token:"sys",users:[bot],channels:[]).map(\.id),["from:u:1"])
        XCTAssertEqual(ChatSearchQuery.suggestions(token:"from:sys",users:[bot],channels:[]).map(\.id),["from:u:1"])
    }
    func testFileTypesHashtagsLiteralsAndUnknownOperatorsDoNotInventSuggestions() {
        for token in ["#","#Peter","filetype:","filetype:Pe","https://Peter","unknown:Peter","someone@Peter","\"Peter"] {
            XCTAssertTrue(ChatSearchQuery.suggestions(token:token,users:users,channels:channels).isEmpty,token)
        }
    }
    func testGeneralGroupsExposeBeyondSixAndDuplicateAliasesProduceOneChoice() {
        let many = (1...20).map{ChatSearchEntity(id:Int64($0),label:"Peter",aliases:["Peter","Peter"])}
        let choices = ChatSearchQuery.suggestions(token:"Peter",users:many,channels:many)
        XCTAssertEqual(choices.count,40);XCTAssertEqual(Set(choices.map(\.id)).count,40)
        XCTAssertEqual(choices.first?.replacement,"from:u:1");XCTAssertEqual(choices.last?.replacement,"in:@c:20")
    }
    func testTransportCombinesOperatorArraysWithFixedHashtagWithoutLeakingOperatorsIntoKeyword() async throws {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [SearchQueryProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://synthetic.test")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        defer { SearchQueryProtocol.fields = nil }
        try await api.discover();let parsed = try parse("Native in:@c:93 from:u:10 has:file #Second")
        _ = try await api.searchMessages(query:parsed.keyword,channelID:96,offset:25,hashtag:"Fixed",filters:parsed.filters)
        let p = try XCTUnwrap(SearchQueryProtocol.fields)
        func decoded<T:Decodable>(_ key:String,_ type:T.Type) throws -> T { try JSONDecoder().decode(type,from:Data(try XCTUnwrap(p[key]).utf8)) }
        XCTAssertEqual(try decoded("keyword",String.self),"Native");XCTAssertEqual(try decoded("in",[Int].self),[93])
        XCTAssertEqual(try decoded("hashtag",[String].self),["Second","Fixed"]);XCTAssertEqual(try decoded("from",[Int].self),[10])
        XCTAssertEqual(p["version"],"5");XCTAssertEqual(p["offset"],"25");XCTAssertEqual(p["limit"],"25")
    }
}

private final class SearchQueryProtocol: URLProtocol {
    static var fields:[String:String]?
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body:String
        if request.url!.lastPathComponent == "SYNO.API.Info" { body = #"{"success":true,"data":{"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"}}}"# }
        else {
            var data = request.httpBody ?? Data()
            if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer{stream.close()};var buffer = [UInt8](repeating:0,count:4096);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n<=0{break};data.append(contentsOf:buffer.prefix(n)) } }
            var parts = URLComponents();parts.percentEncodedQuery = String(decoding:data,as:UTF8.self)
            Self.fields = Dictionary((parts.queryItems ?? []).map{($0.name,$0.value ?? "")},uniquingKeysWith:{$1})
            body = #"{"success":true,"data":{"search_results":[],"total":0}}"#
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(body.utf8));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
