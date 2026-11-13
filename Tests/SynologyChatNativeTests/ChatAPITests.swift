import XCTest
@testable import SynologyChatNative

final class ChatAPITests: XCTestCase {
    private func client() throws -> ChatAPIClient {
        try ChatAPIClient(session: ChatSession(baseURL: URL(string: "https://chat.example.test/proxy/?launchApp=ignored#channel")!,
                                              sid: "test+sid&=", synoToken: "test/token?&"))
    }

    func testConversationInitiationUsesAllMembersAndRejectsUnexpectedChannel() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatResponseStub.self]
        var creates = 0
        var returnedType = "anonymous"
        ChatResponseStub.handler = { request in
            if request.url!.path.contains("SYNO.API.Info") {
                return Data(#"{"success":true,"data":{"SYNO.Chat.Channel.Anonymous":{"path":"entry.cgi","minVersion":1,"maxVersion":2,"requestFormat":"JSON"}}}"#.utf8)
            }
            creates += 1
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = String(decoding: data, as: UTF8.self)
            let fields = Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { field -> (String, String) in
                let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(pair[0]), String(pair[1]).removingPercentEncoding!)
            })
            XCTAssertEqual(fields["user_ids"], "[6,10]")
            XCTAssertNil(fields["encrypted"])
            XCTAssertEqual(fields["channel_key_encs"], "[]")
            return Data("{\"success\":true,\"data\":{\"channel_id\":93,\"name\":\"\",\"type\":\"\(returnedType)\",\"encrypted\":false,\"unread\":0}}".utf8)
        }
        defer { ChatResponseStub.handler = nil }
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://synthetic.test")!, sid: "s", synoToken: "t"), network: URLSession(configuration: config))
        try await api.discover()
        let channel = try await api.initiateConversation(userIDs: [10, 6])
        XCTAssertEqual(channel.id, 93)
        returnedType = "public"
        do { _ = try await api.initiateConversation(userIDs: [10, 6]); XCTFail("Unexpected channel type must fail") }
        catch ChatAPIError.invalidResponse { }
        do { _ = try await api.initiateConversation(userIDs: [10, 10]); XCTFail("Duplicate members must fail before request") }
        catch ChatAPIError.invalidResponse { }
        XCTAssertEqual(creates, 2, "No implicit retries or requests with duplicate members")
    }

    func testConversationPickerExcludesBotsGuestsDisabledAndDeletedAccounts() throws {
        func user(_ extra: String) throws -> ChatUser {
            try JSONDecoder().decode(ChatUser.self, from: Data(("{\"user_id\":1,\"nickname\":\"Synthetic\"," + extra + "}").utf8))
        }
        XCTAssertTrue(try user(#""type":"human","human_type":"dsm","is_disabled":false,"delete_at":0"#).canStartConversation)
        for fields in [#""type":"bot","human_type":"dsm""#, #""type":"human","human_type":"guest""#,
                       #""type":"human","human_type":"dsm","is_disabled":true"#,
                       #""type":"human","human_type":"dsm","delete_at":123"#, #""type":"unknown""#] {
            XCTAssertFalse(try user(fields).canStartConversation)
        }
    }

    func testTextCreationUsesOfficialNormalTypeAndRejectsMalformedSuccess() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatResponseStub.self]
        var returnedType = "normal"
        var creates = 0
        ChatResponseStub.handler = { request in
            if request.url!.path.contains("SYNO.API.Info") {
                return Data(#"{"success":true,"data":{"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"}}}"#.utf8)
            }
            creates += 1
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = String(decoding: data, as: UTF8.self)
            let fields = Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { field -> (String, String) in
                let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(parts[0]), String(parts[1]).removingPercentEncoding!)
            })
            XCTAssertEqual(fields["type"], #""normal""#)
            XCTAssertEqual(fields["is_thread"], "false")
            return Data("""
            {"success":true,"data":{"post_id":123,"channel_id":23,"creator_id":10,"message":"Synthetic fixture","type":"\(returnedType)","create_at":1000,"thread_id":0}}
            """.utf8)
        }
        defer { ChatResponseStub.handler = nil }
        let api = try ChatAPIClient(session: ChatSession(baseURL: URL(string: "https://chat.example.test")!, sid: "s", synoToken: "t"),
                                   network: URLSession(configuration: configuration))
        try await api.discover()
        let sent = try await api.sendText(channelID: 23, text: "Synthetic fixture", connectionID: "test")
        XCTAssertEqual(sent.type, "normal")
        returnedType = "system"
        do {
            _ = try await api.sendText(channelID: 23, text: "Synthetic fixture", connectionID: "test")
            XCTFail("Malformed system post must never be reported as a successful text send")
        } catch ChatAPIError.invalidResponse { }
        XCTAssertEqual(creates, 2, "Unexpected responses must not cause an automatic resend")
    }

    func testExpiredSessionEnvelopeBecomesActionableError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatResponseStub.self]
        let network = URLSession(configuration: configuration)
        ChatResponseStub.handler = { request in
            if request.url!.path.contains("SYNO.API.Info") {
                return Data(#"{"success":true,"data":{"SYNO.Chat.User":{"path":"entry.cgi","minVersion":1,"maxVersion":3,"requestFormat":"JSON"}}}"#.utf8)
            }
            return Data(#"{"success":false,"error":{"code":119}}"#.utf8)
        }
        defer { ChatResponseStub.handler = nil }
        let api = try ChatAPIClient(session: ChatSession(baseURL: URL(string: "https://chat.example.test")!, sid: "s", synoToken: "t"), network: network)
        try await api.discover()
        do {
            _ = try await api.users()
            XCTFail("Expired session must fail")
        } catch ChatAPIError.server(let code) { XCTAssertEqual(code, 119) }
    }

    func testTextSendRejectsUnexpectedReplyRouteOrInvalidReceiptWithoutRetry() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatResponseStub.self]
        var requestedRoot: Int64 = 42
        var returnedRoot: Int64? = 0
        var returnedID: Int64 = 123
        var writes = 0
        ChatResponseStub.handler = { request in
            if request.url!.path.contains("SYNO.API.Info") { return Data(#"{"success":true,"data":{"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"}}}"#.utf8) }
            writes += 1
            let thread = returnedRoot.map { ",\"thread_id\":\($0)" } ?? ""
            return Data("{\"success\":true,\"data\":{\"post_id\":\(returnedID),\"channel_id\":23,\"creator_id\":10,\"message\":\"Synthetic\",\"type\":\"normal\",\"create_at\":1000\(thread)}}".utf8)
        }
        defer { ChatResponseStub.handler = nil }
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://synthetic.test")!, sid: "s", synoToken: "s"), network: URLSession(configuration: config))
        try await api.discover()
        for (sentRoot, responseRoot, responseID): (Int64, Int64?, Int64) in [(42, 0, 123), (42, nil, 123), (42, 43, 123), (0, 42, 123), (0, 0, 0), (42, 42, -1), (42, 42, 42)] {
            requestedRoot = sentRoot; returnedRoot = responseRoot; returnedID = responseID
            do { _ = try await api.sendText(channelID: 23, text: "Synthetic", connectionID: "s", threadID: requestedRoot); XCTFail("Unexpected route/receipt must be unconfirmed") }
            catch ChatAPIError.invalidResponse { }
        }
        XCTAssertEqual(writes, 7, "Exactly the explicit attempts; no automatic resend")
    }

    func testTextSendAcceptsExactReplyRouteAndOlderMainReceiptWithoutThreadField() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatResponseStub.self]
        var root: Int64?
        ChatResponseStub.handler = { request in
            if request.url!.path.contains("SYNO.API.Info") { return Data(#"{"success":true,"data":{"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"}}}"#.utf8) }
            let thread = root.map { ",\"thread_id\":\($0)" } ?? ""
            return Data("{\"success\":true,\"data\":{\"post_id\":123,\"channel_id\":23,\"creator_id\":10,\"message\":\"Synthetic\",\"type\":\"normal\",\"create_at\":1000\(thread)}}".utf8)
        }
        defer { ChatResponseStub.handler = nil }
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://synthetic.test")!, sid: "s", synoToken: "s"), network: URLSession(configuration: config))
        try await api.discover()
        let main = try await api.sendText(channelID: 23, text: "Synthetic", connectionID: "s")
        XCTAssertNil(main.thread_id)
        root = 42
        let reply = try await api.sendText(channelID: 23, text: "Synthetic", connectionID: "s", threadID: 42)
        XCTAssertEqual(reply.thread_id, 42)
    }

    func testNotificationPreferencesUseNestedServerContractAndLogoutUsesPlainAuthFields() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatResponseStub.self]
        ChatResponseStub.handler = { request in
            if request.url!.path.contains("SYNO.API.Info") {
                return Data(#"{"success":true,"data":{"SYNO.Chat.User.Preference":{"path":"entry.cgi","minVersion":1,"maxVersion":4,"requestFormat":"JSON"},"SYNO.API.Auth":{"path":"auth.cgi","minVersion":1,"maxVersion":7}}}"#.utf8)
            }
            if request.url!.path.contains("SYNO.Chat.User.Preference") {
                return Data(#"{"success":true,"data":{"preferences":{"notification_showmessage":false,"notification_browser_active":true,"notification_mute":true}}}"#.utf8)
            }
            XCTAssertEqual(request.url!.path, "/webapi/auth.cgi/SYNO.API.Auth")
            XCTAssertTrue(request.url!.query!.contains("_sid=s"))
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
            }
            XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "api=SYNO.API.Auth&method=logout&session=chat&version=1")
            return Data(#"{"success":true}"#.utf8)
        }
        defer { ChatResponseStub.handler = nil }
        let api = try ChatAPIClient(session: ChatSession(baseURL: URL(string: "https://chat.example.test")!, sid: "s", synoToken: "t"),
                                   network: URLSession(configuration: configuration))
        try await api.discover()
        let prefs = try await api.notificationPreferences()
        XCTAssertEqual(prefs.notification_showmessage, false)
        XCTAssertEqual(prefs.notification_mute, true)
        XCTAssertEqual(prefs.notification_browser_active, true)
        try await api.revokeSession()
    }

    func testUnsupportedVersionFailsBeforeAuthenticatedRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatResponseStub.self]
        var requests = 0
        ChatResponseStub.handler = { _ in
            requests += 1
            return Data(#"{"success":true,"data":{"SYNO.Chat.Channel":{"path":"entry.cgi","minVersion":1,"maxVersion":4,"requestFormat":"JSON"}}}"#.utf8)
        }
        defer { ChatResponseStub.handler = nil }
        let api = try ChatAPIClient(session: ChatSession(baseURL: URL(string: "https://chat.example.test")!, sid: "s", synoToken: "t"),
                                   network: URLSession(configuration: configuration))
        try await api.discover()
        do {
            _ = try await api.channels()
            XCTFail("Version 5 must not be sent to a version 4 server")
        } catch ChatAPIError.unsupportedAPI { }
        XCTAssertEqual(requests, 1)
    }

    func testReactionUsesCanonicalNameWithoutMessageShorthandAndSupportsRemoval() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatResponseStub.self]
        var methods: [String] = []
        ChatResponseStub.handler = { request in
            if request.url!.path.contains("SYNO.API.Info") {
                return Data(#"{"success":true,"data":{"SYNO.Chat.Post.Reaction":{"path":"entry.cgi","minVersion":1,"maxVersion":1,"requestFormat":"JSON"}}}"#.utf8)
            }
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
            }
            let fields = Dictionary(uniqueKeysWithValues: String(decoding: bytes, as: UTF8.self).split(separator: "&").map { field -> (String, String) in
                let pair = field.split(separator: "=", maxSplits: 1)
                return (String(pair[0]), String(pair[1]).removingPercentEncoding!)
            })
            XCTAssertEqual(fields["sticker_name"], #""thumbsup""#)
            XCTAssertEqual(fields["post_id"], "123")
            methods.append(fields["method"]!)
            return Data(#"{"success":true}"#.utf8)
        }
        defer { ChatResponseStub.handler = nil }
        let api = try ChatAPIClient(session: ChatSession(baseURL: URL(string: "https://chat.example.test")!, sid: "s", synoToken: "t"),
                                   network: URLSession(configuration: configuration))
        try await api.discover()
        try await api.setReaction(postID: 123, sticker: .thumbsUp, enabled: true)
        try await api.setReaction(postID: 123, sticker: .thumbsUp, enabled: false)
        XCTAssertEqual(methods, ["set", "delete"])
        XCTAssertNil(ChatReactionKind(rawValue: ":thumbsup:"))
    }

    func testAuthenticatedRoutingPreservesProxyAndEscapesTokens() throws {
        let request = try client().makeRequest(api: "SYNO.Chat.Channel", method: "list", version: 5, path: "entry.cgi",
                                               parameters: ["is_joined": .bool(true)], jsonParameters: true)
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.path, "/proxy/webapi/entry.cgi/SYNO.Chat.Channel")
        XCTAssertNil(components.fragment)
        let query = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(query, ["_sid": "test+sid&=", "SynoToken": "test/token?&"])
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(String(decoding: request.httpBody!, as: UTF8.self),
                       "api=SYNO.Chat.Channel&is_joined=true&method=list&version=5")
    }

    func testJSONParametersRetainQuotesAndSpecialCharacters() throws {
        let request = try client().makeRequest(api: "SYNO.Chat.Post", method: "list", version: 5, path: "entry.cgi",
                                              parameters: ["message": .string("a+b & café\n")], jsonParameters: true)
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        let fields = body.split(separator: "&").map { $0.split(separator: "=", maxSplits: 1) }
        let value = fields.first { $0[0] == "message" }![1].removingPercentEncoding!
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(value.utf8)), "a+b & café\n")
    }

    func testDiscoveryDoesNotSendSessionOrJSONQuoteQuery() throws {
        let request = try client().makeRequest(api: "SYNO.API.Info", method: "query", version: 1, path: "query.cgi",
                                              parameters: ["query": .string("all")], jsonParameters: false, authenticated: false)
        XCTAssertNil(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.query)
        XCTAssertTrue(String(decoding: request.httpBody!, as: UTF8.self).contains("query=all"))
    }

    func testRejectsInsecureServerAndDiscoveredPathTraversal() throws {
        XCTAssertThrowsError(try ChatAPIClient(session: ChatSession(baseURL: URL(string: "http://chat.test")!, sid: "s", synoToken: "t")))
        for path in ["../entry.cgi", "https://evil.test/entry.cgi", "entry.cgi?leak=1", "entry.cgi#x"] {
            XCTAssertThrowsError(try client().makeRequest(api: "SYNO.Chat.User", method: "list", version: 2, path: path,
                                                         parameters: [:], jsonParameters: true))
        }
    }

    func testCallerCannotReplaceRoutingOrSessionFields() throws {
        for key in ["api", "method", "version", "_sid", "SynoToken"] {
            XCTAssertThrowsError(try client().makeRequest(api: "SYNO.Chat.User", method: "list", version: 2, path: "entry.cgi",
                                                         parameters: [key: .string("override")], jsonParameters: true))
        }
    }

    func testPostIdentifiersDoNotLoseIntegerPrecision() throws {
        let json = """
        {"posts":[{"post_id":9007199254740993,"channel_id":23,"creator_id":10,"message":"Synthetic fixture","type":"normal","create_at":1792143000000,"delete_at":0,"ignored_future_field":true}]}
        """
        let posts = try JSONDecoder().decode(PostList.self, from: Data(json.utf8)).posts
        XCTAssertEqual(posts[0].id, 9_007_199_254_740_993)
        XCTAssertEqual(posts[0].date.timeIntervalSince1970, 1_792_143_000)
    }

    func testBuiltInChannelNamesAreClientSideDefaults() throws {
        let json = #"{"channels":[{"channel_id":1,"name":"","type":"public","encrypted":false,"unread":0},{"channel_id":2,"name":"","type":"public","encrypted":false,"unread":0},{"channel_id":3,"name":"","type":"synobot","encrypted":false,"unread":0}]}"#
        let channels = try JSONDecoder().decode(ChannelList.self, from: Data(json.utf8)).channels
        XCTAssertEqual(channels.compactMap(\.defaultTitle), ["General", "Random", "My Space"])
    }

    func testDockBadgeUsesMentionsForNamedChannelsAndAllUnreadForDMsPlusSubscribedThreads() throws {
        let data = Data(#"{"channels":[{"channel_id":1,"name":"General","type":"public","encrypted":false,"unread":20,"unread_mention":2,"unread_thread":{"111":3}},{"channel_id":2,"name":"","type":"anonymous","encrypted":false,"unread":4,"unread_mention":1,"unread_thread":{"222":2}},{"channel_id":3,"name":"Secret","type":"private","encrypted":true,"unread":7,"unread_thread":{"333":1}},{"channel_id":4,"name":"Bot","type":"chatbot","encrypted":false,"unread":2}]}"#.utf8)
        let channels = try JSONDecoder().decode(ChannelList.self, from: data).channels
        XCTAssertEqual(channels.map(\.badgeUnreadCount), [5, 6, 8, 2])
        let malformedCounts = Data(#"{"channel_id":5,"name":"","type":"anonymous","encrypted":false,"unread":-10,"unread_thread":{"a":-1,"b":9223372036854775807,"c":9223372036854775807}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ChatChannel.self, from: malformedCounts).badgeUnreadCount, 9999)
    }

    func testBotUserMayOmitDSMUsername() throws {
        let users = try JSONDecoder().decode(UserList.self, from: Data(#"{"users":[{"user_id":42,"nickname":"Synthetic Bot"}]}"#.utf8)).users
        XCTAssertNil(users[0].username)
        XCTAssertEqual(users[0].displayName, "Synthetic Bot")
    }

    func testInvalidSessionImportDoesNotExposePayload() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "{\"type\":\"session\",\"data\":\"invalid-session-secret\"}\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try OfficialChatSessionLoader.load(from: file)) { error in
            XCTAssertFalse(error.localizedDescription.contains("invalid-session-secret"))
        }
    }
}

private final class ChatResponseStub: URLProtocol {
    static var handler: ((URLRequest) -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: handler(request))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
