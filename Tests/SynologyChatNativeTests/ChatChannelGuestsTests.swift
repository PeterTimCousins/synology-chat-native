import XCTest
@testable import SynologyChatNative

@MainActor final class ChatChannelGuestsTests: XCTestCase {
    override func setUp() { super.setUp(); GuestsProtocol.reset() }
    override func tearDown() { GuestsProtocol.held = nil; GuestsProtocol.observer = nil; super.tearDown() }
    private func api() async throws -> ChatAPIClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GuestsProtocol.self]
        let client = try ChatAPIClient(session: .init(baseURL: URL(string: "https://guests-fixture.invalid")!, sid: "synthetic", synoToken: "synthetic"), network: URLSession(configuration: configuration))
        try await client.discover(); return client
    }
    private func model() async throws -> NativeChatPreviewModel {
        let value = NativeChatPreviewModel(client: try await api(), restoreNotificationPreference: false)
        value.connected = true; value.liveStatus = .live; value.selection = 96
        addTeardownBlock { @MainActor in value.signOutLocally() }; return value
    }
    func testReadOnlyWireUsesGuestListV1AndPreservesServerOrderAndExpirySeconds() async throws {
        let model = try await model(); let snapshot = try await model.loadChannelGuests(channelID: 96)
        XCTAssertTrue(snapshot.policy.allow_guest); XCTAssertEqual(snapshot.guests.map(\.id), [9, 4])
        XCTAssertEqual(snapshot.guests[0].statusLabel, "Awaiting registration")
        XCTAssertEqual(snapshot.guests[1].statusLabel, "Registered")
        XCTAssertNil(snapshot.guests[0].expiration)
        XCTAssertEqual(snapshot.guests[1].expiration?.timeIntervalSince1970, 1_900_000_000)
        XCTAssertEqual(GuestsProtocol.calls.map { $0.0 }, ["SYNO.Chat.Misc", "SYNO.Chat.Channel", "SYNO.Chat.Admin.Setting", "SYNO.Chat.Channel.GuestUser"])
        let list = try XCTUnwrap(GuestsProtocol.calls.last)
        XCTAssertEqual(list.1["method"], "list"); XCTAssertEqual(list.1["version"], "1"); XCTAssertEqual(list.1["channel_id"], "96")
        XCTAssertNil(list.1["email"]); XCTAssertNil(list.1["guest_id"]); XCTAssertNil(list.1["expire_at"])
        XCTAssertEqual(GuestsProtocol.writes, 0)
    }
    func testDisabledGuestPolicyStillShowsExistingRegistrationsAndNeverSendsInvite() async throws {
        GuestsProtocol.policy = ["allow_guest": false]
        let snapshot = try await model().loadChannelGuests(channelID: 96)
        XCTAssertFalse(snapshot.policy.allow_guest); XCTAssertEqual(snapshot.guests.count, 2); XCTAssertEqual(GuestsProtocol.writes, 0)
    }
    func testFreshACLRevocationOrConflictingACLStopsBeforeGuestInventory() async throws {
        let model = try await model()
        for entries in [[], [["acl_name": "guest_manage", "allow": false]], [["acl_name": "guest_manage", "allow": true], ["acl_name": "guest_manage", "allow": false]]] as [[[String: Any]]] {
            GuestsProtocol.acls = entries; GuestsProtocol.calls = []
            do { _ = try await model.loadChannelGuests(channelID: 96); XCTFail("Permissionless list accepted") } catch { }
            XCTAssertEqual(GuestsProtocol.calls.map { $0.0 }, ["SYNO.Chat.Misc"])
        }
    }
    func testUnavailablePublicEncryptedClosedOrUnjoinedChannelsStopBeforePolicyAndList() async throws {
        let model = try await model()
        for patch: [String: Any] in [["type": "public"], ["type": "one_on_one"], ["encrypted": true], ["is_closed": true], ["is_joined": false], ["hide_global_at": 1]] {
            GuestsProtocol.channel = GuestsProtocol.initial.merging(patch, uniquingKeysWith: { _, new in new }); GuestsProtocol.calls = []
            do { _ = try await model.loadChannelGuests(channelID: 96); XCTFail("Unavailable channel listed") } catch { }
            XCTAssertFalse(GuestsProtocol.calls.contains { $0.0 == "SYNO.Chat.Channel.GuestUser" || $0.0 == "SYNO.Chat.Admin.Setting" })
        }
    }
    func testUnknownOrMalformedPolicyDoesNotGuessGuestAvailability() async throws {
        let model = try await model()
        for policy: [String: Any] in [[:], ["allow_guest": "true"], ["allow_guest": 1]] {
            GuestsProtocol.policy = policy; GuestsProtocol.calls = []
            do { _ = try await model.loadChannelGuests(channelID: 96); XCTFail("Unknown policy accepted") } catch { }
            XCTAssertFalse(GuestsProtocol.calls.contains { $0.0 == "SYNO.Chat.Channel.GuestUser" })
        }
    }
    func testMalformedDuplicateOrInvalidGuestInventoryIsRejectedAsAWhole() async throws {
        let client = try await api(); let original = GuestsProtocol.guests
        for guests in [original + [original[0]], [original[0].merging(["guest_id": 0], uniquingKeysWith: { _, new in new })], [original[0].merging(["expire_at": -1], uniquingKeysWith: { _, new in new })], [original[0].merging(["user_id": -1], uniquingKeysWith: { _, new in new })], [original[0].merging(["email": ""], uniquingKeysWith: { _, new in new })]] {
            GuestsProtocol.guests = guests
            do { _ = try await client.channelGuests(channelID: 96); XCTFail("Malformed guests accepted") } catch { }
        }
        GuestsProtocol.guests = []; let empty = try await client.channelGuests(channelID: 96); XCTAssertTrue(empty.isEmpty)
        let before = GuestsProtocol.calls.count
        do { _ = try await client.channelGuests(channelID: 1); XCTFail("System channel accepted") } catch { }
        XCTAssertEqual(GuestsProtocol.calls.count, before)
    }
    func testLogoutWhilePolicyLoadsCannotDispatchGuestListOrPublishSnapshot() async throws {
        let model = try await model(); GuestsProtocol.holdPolicy = true
        let started = expectation(description: "Policy held"); GuestsProtocol.observer = { if $0 == "SYNO.Chat.Admin.Setting" { started.fulfill() } }
        let task = Task { try await model.loadChannelGuests(channelID: 96) }
        await fulfillment(of: [started], timeout: 2); model.signOutLocally()
        GuestsProtocol.held?.finish(["success": true, "data": ["allow_guest": true]])
        do { _ = try await task.value; XCTFail("Old-account guest inventory published") } catch is CancellationError { }
        XCTAssertFalse(GuestsProtocol.calls.contains { $0.0 == "SYNO.Chat.Channel.GuestUser" }); XCTAssertEqual(GuestsProtocol.writes, 0)
    }
    func testUnknownStatusIsNeutralAndDoesNotInferPendingInvitation() throws {
        let data = try JSONSerialization.data(withJSONObject: ["guest_id": 5, "expire_at": 0, "status": "future-status", "user_id": 0, "email": "synthetic@example.invalid"])
        let value = try JSONDecoder().decode(ChatChannelGuest.self, from: data)
        XCTAssertEqual(value.statusLabel, "Registration status unavailable")
    }
    func testExactGuestWriteMethodsAndFieldsNeverArchiveOrChangeOrdinaryMembers() async throws {
        let api = try await api(), model = try await model(), snapshot = try await model.loadChannelGuests(channelID: 96)
        let guest = snapshot.guests[0]
        for change in [ChatGuestChange.invite(email: "NEW@example.invalid", expireAt: 0, language: "enu"), .expiry(guest, expireAt: 1_900_000_000), .remove(guest), .resend(guest)] {
            try await api.applyGuestAction(ChatGuestActionRecord(change: change, snapshot: snapshot))
        }
        let writes = GuestsProtocol.calls.filter { !["list", "get", "acl"].contains($0.1["method"] ?? "") }
        XCTAssertEqual(writes.map { $0.1["method"]! }, ["register", "set", "kick", "resend_email"])
        for write in writes {
            XCTAssertEqual(write.0, "SYNO.Chat.Channel.GuestUser"); XCTAssertEqual(write.1["version"], "1"); XCTAssertEqual(write.1["channel_id"], "96")
            XCTAssertNil(write.1["user_ids"]); XCTAssertNil(write.1["archive"]); XCTAssertNil(write.1["type"])
        }
        XCTAssertEqual(writes[0].1["email"], #""new@example.invalid""#); XCTAssertEqual(writes[0].1["language"], #""enu""#)
        XCTAssertEqual(writes[0].1["expire_at"], "0"); XCTAssertNil(writes[0].1["guest_id"])
        XCTAssertEqual(writes[1].1["guest_id"], "9"); XCTAssertEqual(writes[1].1["expire_at"], "1900000000")
        for write in writes.dropFirst() { XCTAssertNil(write.1["email"]); XCTAssertNil(write.1["language"]) }
        XCTAssertNil(writes[2].1["expire_at"]); XCTAssertNil(writes[3].1["expire_at"])
    }
    func testNativeMutationRefreshesACLAndBlocksRevokedAccessBeforeDispatch() async throws {
        let model = try await model(); model.guestManagement.activate(scope: String(repeating: "a", count: 64))
        let snapshot = try await model.loadChannelGuests(channelID: 96)
        GuestsProtocol.acls = [["acl_name": "guest_manage", "allow": false]]
        do { _ = try await model.changeChannelGuest(.remove(snapshot.guests[0]), original: snapshot); XCTFail("Revoked permission changed guest") } catch { }
        XCTAssertEqual(GuestsProtocol.writes, 0); XCTAssertTrue(model.guestManagement.pending.isEmpty)
    }
}

private final class GuestsProtocol: URLProtocol {
    static let initial: [String: Any] = ["channel_id": 96, "name": "Synthetic-private", "type": "private", "encrypted": false, "is_joined": true, "unread": 0]
    static var channel = initial
    static var acls: [[String: Any]] = []
    static var policy: [String: Any] = [:]
    static var guests: [[String: Any]] = []
    static var calls: [(String, [String: String])] = []
    static var writes = 0
    static var holdPolicy = false
    static var held: GuestsProtocol?
    static var observer: ((String) -> Void)?
    static func reset() {
        channel = initial; acls = [["acl_name": "guest_manage", "allow": true]]; policy = ["allow_guest": true]
        guests = [["guest_id": 9, "expire_at": 0, "status": "uninvited", "user_id": 0, "email": "pending@example.invalid"], ["guest_id": 4, "expire_at": 1_900_000_000, "status": "registered", "user_id": 42, "email": "registered@example.invalid"]]
        calls = []; writes = 0; holdPolicy = false; held = nil; observer = nil
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let api = request.url!.lastPathComponent
        if api == "SYNO.API.Info" || request.url!.path.contains("query.cgi") {
            let names = ["SYNO.Chat.Misc", "SYNO.Chat.Channel", "SYNO.Chat.Admin.Setting", "SYNO.Chat.Channel.GuestUser"]
            finish(["success": true, "data": Dictionary(uniqueKeysWithValues: names.map { ($0, ["path": "entry.cgi", "minVersion": 1, "maxVersion": 8, "requestFormat": "JSON"] as [String: Any]) })]); return
        }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable && data.count < 16_384 { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        }
        var components = URLComponents(); components.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        let fields = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
        Self.calls.append((api, fields))
        if !["list", "get", "acl"].contains(fields["method"] ?? "") {
            Self.writes += 1
            if api == "SYNO.Chat.Channel.GuestUser", ["register", "set", "kick", "resend_email"].contains(fields["method"] ?? "") { finish(["success": true]); return }
            finish(["success": false, "error": ["code": 400]]); return
        }
        if api == "SYNO.Chat.Admin.Setting", Self.holdPolicy { Self.held = self; Self.observer?(api); return }
        Self.observer?(api)
        switch api {
        case "SYNO.Chat.Misc": finish(["success": true, "data": ["acls": Self.acls]])
        case "SYNO.Chat.Channel": finish(["success": true, "data": ["channels": [Self.channel]]])
        case "SYNO.Chat.Admin.Setting": finish(["success": true, "data": Self.policy])
        case "SYNO.Chat.Channel.GuestUser": finish(["success": true, "data": ["guests": Self.guests]])
        default: finish(["success": false, "error": ["code": 400]])
        }
    }
    func finish(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
