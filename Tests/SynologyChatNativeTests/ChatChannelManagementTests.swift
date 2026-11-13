import XCTest
@testable import SynologyChatNative

final class ChatChannelManagementTests: XCTestCase {
    private func api() async throws -> ChatAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChannelManagementStub.self]
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://synthetic.test")!, sid: "synthetic", synoToken: "synthetic"),
                                     network: URLSession(configuration: configuration))
        try await api.discover()
        return api
    }
    private func channel(type: String = "private", encrypted: Bool = false, id: Int64 = 123) throws -> ChatChannel {
        try JSONDecoder().decode(ChatChannel.self, from: Data("{\"channel_id\":\(id),\"name\":\"synthetic-channel\",\"type\":\"\(type)\",\"encrypted\":\(encrypted),\"unread\":0}".utf8))
    }
    override func tearDown() { ChannelManagementStub.handler = nil; super.tearDown() }

    func testNamedChannelValidationMatchesRecoveredOfficialConstraints() {
        XCTAssertNil(ChatNamedChannelInput.validationError(name: "Peter-Native-API-test", purpose: ""))
        XCTAssertNil(ChatNamedChannelInput.validationError(name: String(repeating: "a", count: 64), purpose: String(repeating: "a", count: 256)))
        XCTAssertNil(ChatNamedChannelInput.validationError(name: String(repeating: "🙂", count: 32), purpose: ""))
        for name in ["Peter — Native API test", "name\u{00a0}space", String(repeating: "a", count: 65), String(repeating: "🙂", count: 33)] {
            XCTAssertNotNil(ChatNamedChannelInput.validationError(name: name, purpose: ""))
        }
        for scalar in "~!@{}<>`|?#$%^&*()+\\[]'\":;,/=" {
            XCTAssertNotNil(ChatNamedChannelInput.validationError(name: "name\(scalar)name", purpose: ""))
        }
        XCTAssertNotNil(ChatNamedChannelInput.validationError(name: "valid-name", purpose: String(repeating: "a", count: 257)))
    }

    func testPermissionContractDeniesAbsentOrConflictingGrants() async throws {
        ChannelManagementStub.handler = { fields in
            XCTAssertEqual(fields["method"], "acl")
            return #"{"success":true,"data":{"acls":[{"acl_name":"channel_create","allow":true},{"acl_name":"channel_invite","allow":true},{"acl_name":"channel_invite","allow":false}]}}"#
        }
        let api = try await api()
        let permissions = try await api.channelPermissions()
        XCTAssertTrue(permissions.allows("channel_create"))
        XCTAssertFalse(permissions.allows("channel_public"))
        XCTAssertFalse(permissions.allows("channel_invite"))
    }

    @MainActor
    func testNativeCreationRechecksPermissionBeforeAnyWriteAndClearsBusyState() async throws {
        var requests: [String] = []
        ChannelManagementStub.handler = { fields in
            requests.append(fields["method"]!)
            return #"{"success":true,"data":{"acls":[{"acl_name":"channel_create","allow":false}]}}"#
        }
        let api = try await api()
        let model = NativeChatPreviewModel(client: api)
        model.connected = true; model.liveStatus = .live
        do { try await model.createChannel(name: "synthetic-channel", purpose: "", kind: .private); XCTFail("Denied permission must not write") }
        catch is ChatTransferError { }
        XCTAssertEqual(requests, ["acl"])
        XCTAssertFalse(model.channelManagementBusy)
    }

    @MainActor
    func testNativePrivateCreationPublishesCanonicalChannelAndSelection() async throws {
        var requests: [String] = []
        ChannelManagementStub.handler = { fields in
            requests.append(fields["method"]!)
            switch fields["method"] {
            case "acl": return #"{"success":true,"data":{"acls":[{"acl_name":"channel_create","allow":true}]}}"#
            case "create": return #"{"success":true,"data":{"channel_id":123}}"#
            case "join": return #"{"success":true}"#
            case "list": return #"{"success":true,"data":{"channels":[{"channel_id":123,"name":"synthetic-channel","type":"private","encrypted":false,"unread":0}]}}"#
            default: XCTFail("Unexpected operation"); return #"{"success":false,"error":{"code":117}}"#
            }
        }
        let api = try await api()
        let model = NativeChatPreviewModel(client: api)
        model.connected = true; model.liveStatus = .live
        try await model.createChannel(name: "synthetic-channel", purpose: "", kind: .private)
        XCTAssertEqual(model.channels.map(\.id), [123])
        XCTAssertEqual(model.selection, 123)
        XCTAssertFalse(model.channelManagementBusy)
        XCTAssertEqual(requests, ["acl", "create", "join", "list"])
    }

    @MainActor
    func testNativePublicCreationNeedsAdditionalPublicPermission() async throws {
        var requests: [String] = []
        ChannelManagementStub.handler = { fields in
            requests.append(fields["method"]!)
            return #"{"success":true,"data":{"acls":[{"acl_name":"channel_create","allow":true}]}}"#
        }
        let api = try await api()
        let model = NativeChatPreviewModel(client: api)
        model.connected = true; model.liveStatus = .live
        do { try await model.createChannel(name: "synthetic-channel", purpose: "", kind: .public); XCTFail("Must not create a public channel without permission") }
        catch is ChatTransferError { }
        XCTAssertEqual(requests, ["acl"])
        XCTAssertFalse(model.channelManagementBusy)
    }

    func testCreateJoinsAndReadsBackWithoutInvitingAnyone() async throws {
        var operations: [String] = []
        ChannelManagementStub.handler = { fields in
            let operation = fields["method"] ?? ""
            operations.append(operation)
            switch operation {
            case "create":
                XCTAssertEqual(fields["type"], #""private""#)
                XCTAssertEqual(fields["name"], #""synthetic-channel""#)
                XCTAssertEqual(fields["encrypted"], "false")
                XCTAssertNil(fields["user_ids"])
                return #"{"success":true,"data":{"channel_id":123}}"#
            case "join":
                XCTAssertEqual(fields["channel_id"], "123")
                XCTAssertEqual(fields["channel_key_enc"], #""""#)
                return #"{"success":true}"#
            case "list":
                return #"{"success":true,"data":{"channels":[{"channel_id":123,"name":"synthetic-channel","type":"private","encrypted":false,"unread":0}]}}"#
            default: XCTFail("Unexpected operation \(operation)"); return #"{"success":false,"error":{"code":117}}"#
            }
        }
        let api = try await api()
        let result = try await api.createNamedChannel(name: "  synthetic-channel  ", purpose: "Synthetic purpose", kind: .private)
        XCTAssertEqual(result.id, 123)
        XCTAssertEqual(operations, ["create", "join", "list"])
    }

    func testJoinFailureReportsCreatedIDWithoutRetryingOrDeleting() async throws {
        var operations: [String] = []
        ChannelManagementStub.handler = { fields in
            operations.append(fields["method"]!)
            return fields["method"] == "create" ? #"{"success":true,"data":{"channel_id":123}}"# : #"{"success":false,"error":{"code":117}}"#
        }
        let api = try await api()
        do { _ = try await api.createNamedChannel(name: "synthetic-channel", purpose: "", kind: .private); XCTFail("Must report partial creation") }
        catch let error as ChatChannelCreatedError { XCTAssertEqual(error.channelID, 123) }
        XCTAssertEqual(operations, ["create", "join"])
    }

    func testLostCreationResponseReportsUnknownDeliveryWithoutRetry() async throws {
        var creates = 0
        ChannelManagementStub.handler = { fields in
            XCTAssertEqual(fields["method"], "create")
            creates += 1
            throw URLError(.networkConnectionLost)
        }
        let api = try await api()
        do { _ = try await api.createNamedChannel(name: "synthetic-channel", purpose: "", kind: .private); XCTFail("Must not claim failure or success") }
        catch is ChatChannelCreationUnconfirmedError { }
        XCTAssertEqual(creates, 1)
    }

    func testInvalidNameCannotCreateAndServerDenialIsNotRetried() async throws {
        var requests = 0
        ChannelManagementStub.handler = { fields in requests += 1; return #"{"success":false,"error":{"code":117}}"# }
        let api = try await api()
        for name in [" \n", "Synthetic\nchannel"] {
            do { _ = try await api.createNamedChannel(name: name, purpose: "", kind: .private); XCTFail("Invalid name must fail locally") }
            catch is ChatTransferError { }
        }
        XCTAssertEqual(requests, 0)
        do { _ = try await api.createNamedChannel(name: "synthetic-channel", purpose: "", kind: .public); XCTFail("Server denial must propagate") }
        catch ChatAPIError.server(117) { }
        XCTAssertEqual(requests, 1)
    }

    func testLockedEncryptedRemovalUsesOnlyIDsAndDoesNotSendKeyMaterial() async throws {
        var writes = 0
        ChannelManagementStub.handler = { fields in
            writes += 1
            XCTAssertEqual(fields["api"], "SYNO.Chat.Channel.Named")
            XCTAssertEqual(fields["method"], "kick")
            XCTAssertEqual(fields["version"], "1")
            XCTAssertEqual(fields["channel_id"], "123")
            XCTAssertEqual(fields["user_id"], "6")
            XCTAssertNil(fields["channel_key_enc"])
            XCTAssertNil(fields["channel_key_encs"])
            return #"{"success":true}"#
        }
        let api = try await api()
        try await api.removeChannelMember(6, channel: channel(encrypted: true))
        XCTAssertEqual(writes, 1)
    }

    func testRemovalRejectsUnavailablePrivateScopesBeforeDispatch() async throws {
        var writes = 0
        ChannelManagementStub.handler = { _ in writes += 1; return #"{"success":true}"# }
        let api = try await api()
        for flags in [#""is_closed":true"#, #""is_joined":false"#, #""hide_global_at":100"#] {
            let json = "{\"channel_id\":123,\"name\":\"Synthetic\",\"type\":\"private\",\"encrypted\":true,\"unread\":0,\(flags)}"
            let target = try JSONDecoder().decode(ChatChannel.self, from: Data(json.utf8))
            do { try await api.removeChannelMember(6, channel: target); XCTFail("Unavailable scope") }
            catch ChatAPIError.invalidResponse { }
        }
        XCTAssertEqual(writes, 0)
    }

    func testMembershipWireAndEncryptedInvitationOrDirectChannelGuards() async throws {
        var operations: [String] = []
        ChannelManagementStub.handler = { fields in
            XCTAssertEqual(fields["channel_id"], "123")
            operations.append(fields["method"]!)
            if fields["method"] == "invite" {
                XCTAssertEqual(fields["user_ids"], "[6,10]")
                XCTAssertEqual(fields["channel_key_encs"], "[]")
            } else { XCTAssertEqual(fields["method"], "kick"); XCTAssertEqual(fields["user_id"], "6") }
            return #"{"success":true}"#
        }
        let api = try await api()
        try await api.inviteChannelMembers([10, 6], channel: channel())
        try await api.removeChannelMember(6, channel: channel())
        for invalid in [try channel(type: "anonymous"), try channel(encrypted: true)] {
            do { try await api.inviteChannelMembers([6], channel: invalid); XCTFail("Must not send plaintext membership envelopes") }
            catch ChatAPIError.invalidResponse { }
            if invalid.type == "anonymous" {
                do { try await api.removeChannelMember(6, channel: invalid); XCTFail("Unsupported channel must fail before write") }
                catch ChatAPIError.invalidResponse { }
            }
        }
        do { try await api.inviteChannelMembers([6], channel: channel(type: "public", id: 1)); XCTFail("General does not support invitations") }
        catch ChatAPIError.invalidResponse { }
        do { try await api.removeChannelMember(6, channel: channel(type: "public")); XCTFail("Only private channels support removal") }
        catch ChatAPIError.invalidResponse { }
        XCTAssertEqual(operations, ["invite", "kick"])
    }
}

private final class ChannelManagementStub: URLProtocol {
    static var handler: (([String: String]) throws -> String)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let body: String
            if request.url!.path.contains("SYNO.API.Info") {
                body = #"{"success":true,"data":{"SYNO.Chat.Misc":{"path":"entry.cgi","minVersion":1,"maxVersion":1,"requestFormat":"JSON"},"SYNO.Chat.Channel.Named":{"path":"entry.cgi","minVersion":1,"maxVersion":1,"requestFormat":"JSON"},"SYNO.Chat.Channel":{"path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"}}}"#
            } else {
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
                }
                let fields = Dictionary(uniqueKeysWithValues: String(decoding: data, as: UTF8.self).split(separator: "&").map { field -> (String, String) in
                    let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    return (String(pair[0]), String(pair[1]).removingPercentEncoding!)
                })
                body = try Self.handler!(fields)
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
