import XCTest
@testable import SynologyChatNative

final class ChatEncryptionOwnerStateTests: XCTestCase {
    private struct Fixture: Decodable { let publicKey, wrappedPrivateKey: String }
    override func setUp() { super.setUp(); OwnerStateProtocol.users = []; OwnerStateProtocol.calls = [] }
    override func tearDown() { OwnerStateProtocol.users = []; OwnerStateProtocol.calls = []; super.tearDown() }
    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ChatCrypto", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    private func api() async throws -> ChatAPIClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [OwnerStateProtocol.self]
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://encryption-owner-fixture.invalid")!, sid: "synthetic", synoToken: "synthetic"), network: URLSession(configuration: configuration))
        try await api.discover(); OwnerStateProtocol.calls = []; return api
    }
    private func owner(_ publicKey: String = "", _ wrappedKey: String = "", id: Int64 = 10) -> [String: Any] {
        ["user_id": id, "user_props": ["key_pair": ["public_key": publicKey, "private_key_enc": wrappedKey]]]
    }
    private func rejected(_ users: [[String: Any]], userID: Int64 = 10, api: ChatAPIClient) async {
        OwnerStateProtocol.users = users
        do { _ = try await api.encryptionOwnerState(userID: userID); XCTFail("Unknown or malformed owner state was accepted") }
        catch { }
    }

    func testExplicitEmptyOwnPairIsUninitializedAndWireUsesOnlyUserListV2() async throws {
        let api = try await api(); OwnerStateProtocol.users = [owner()]
        let state = try await api.encryptionOwnerState(userID: 10)
        XCTAssertEqual(state.userID, 10); XCTAssertFalse(state.isInitialized)
        XCTAssertEqual(state.pair.public_key, ""); XCTAssertEqual(state.pair.private_key_enc, "")
        XCTAssertEqual(OwnerStateProtocol.calls.count, 1)
        let fields = try XCTUnwrap(OwnerStateProtocol.calls.first)
        XCTAssertEqual(fields["api"], "SYNO.Chat.User"); XCTAssertEqual(fields["method"], "list"); XCTAssertEqual(fields["version"], "2")
        for key in ["user_id", "public_key", "private_key_enc", "conn_id"] { XCTAssertNil(fields[key]) }
    }

    func testInitializedOwnerKeepsExactLegacyWrappedStringsWithoutUnlocking() async throws {
        let api = try await api(), f = try fixture(); OwnerStateProtocol.users = [owner(f.publicKey, f.wrappedPrivateKey)]
        let state = try await api.encryptionOwnerState(userID: 10)
        XCTAssertTrue(state.isInitialized); XCTAssertEqual(state.pair.public_key, f.publicKey)
        XCTAssertEqual(state.pair.private_key_enc, f.wrappedPrivateKey)
        XCTAssertTrue(f.wrappedPrivateKey.contains("\r\n"))
    }

    func testMissingNullAndWrongTypeOwnObjectsCannotAuthorizeInitialization() async throws {
        let api = try await api()
        for row: [String: Any] in [
            ["user_id": 10], ["user_id": 10, "user_props": NSNull()], ["user_id": 10, "user_props": []],
            ["user_id": 10, "user_props": [:]], ["user_id": 10, "user_props": ["key_pair": NSNull()]],
            ["user_id": 10, "user_props": ["key_pair": "not an object"]]
        ] { await rejected([row], api: api) }
    }

    func testBothOwnKeyFieldsMustExistAsStringsEvenWhenOtherFieldIsEmpty() async throws {
        let api = try await api()
        let pairs: [[String: Any]] = [[:], ["public_key": ""], ["private_key_enc": ""],
            ["public_key": NSNull(), "private_key_enc": ""], ["public_key": "", "private_key_enc": NSNull()],
            ["public_key": 0, "private_key_enc": ""], ["public_key": "", "private_key_enc": false]]
        for pair in pairs { await rejected([["user_id": 10, "user_props": ["key_pair": pair]]], api: api) }
    }

    func testPublicOnlyPrivateOnlyMalformedAndBoundedWireValuesAreRejected() async throws {
        let api = try await api(), f = try fixture()
        for row in [owner(f.publicKey, ""), owner("", f.wrappedPrivateKey), owner(" ", " "),
                    owner("invalid", f.wrappedPrivateKey), owner(f.publicKey, "invalid"),
                    owner(Data(repeating: 0, count: 31).base64EncodedString(), f.wrappedPrivateKey),
                    owner(Data(repeating: 0, count: 33).base64EncodedString(), f.wrappedPrivateKey),
                    owner(f.publicKey, Data(repeating: 0, count: 83).base64EncodedString()),
                    owner(f.publicKey, Data(repeating: 0, count: 85).base64EncodedString()),
                    owner(String(repeating: " ", count: 257) + f.publicKey, f.wrappedPrivateKey),
                    owner(f.publicKey, String(repeating: " ", count: 1025) + f.wrappedPrivateKey)] {
            await rejected([row], api: api)
        }
    }

    func testMalformedPeerKeysAreIgnoredButAllDirectoryIdentitiesMustBeValidAndUnique() async throws {
        let api = try await api()
        OwnerStateProtocol.users = [owner(), ["user_id": 6, "user_props": ["key_pair": ["public_key": true]]], ["user_id": 7, "user_props": NSNull()]]
        let validOwner = try await api.encryptionOwnerState(userID: 10)
        XCTAssertFalse(validOwner.isInitialized)
        for rows in [[owner(), owner(id: 10)], [owner(), ["user_id": 6], ["user_id": 6]],
                     [owner(), ["user_id": 0]], [owner(), ["user_id": -1]], [owner(), ["user_id": "6"]],
                     [owner(), ["user_id": true]], [owner(), [:]], []] {
            await rejected(rows, api: api)
        }
        await rejected([owner(id: 6)], api: api)
    }

    func testNonpositiveRequestedIdentityRejectsBeforeAnyNetworkRead() async throws {
        let api = try await api()
        for id: Int64 in [0, -1] { await rejected([owner()], userID: id, api: api) }
        XCTAssertTrue(OwnerStateProtocol.calls.isEmpty)
    }

    func testEqualityIncludesExactPairBytesAndVerifiedUserIdentity() async throws {
        let api = try await api(), f = try fixture(); OwnerStateProtocol.users = [owner(f.publicKey, f.wrappedPrivateKey)]
        let first = try await api.encryptionOwnerState(userID: 10)
        let same = try await api.encryptionOwnerState(userID: 10); XCTAssertEqual(first, same)
        OwnerStateProtocol.users = [owner(f.publicKey + "\r\n", f.wrappedPrivateKey)]
        let changedEncoding = try await api.encryptionOwnerState(userID: 10)
        XCTAssertNotEqual(first, changedEncoding)
        OwnerStateProtocol.users = [owner(f.publicKey, f.wrappedPrivateKey, id: 11)]
        let differentOwner = try await api.encryptionOwnerState(userID: 11)
        XCTAssertNotEqual(first, differentOwner)
    }
}

private final class OwnerStateProtocol: URLProtocol {
    static var users: [[String: Any]] = []
    static var calls: [[String: String]] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable && body.count < 16_384 {
                let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
            }
        }
        var parameters = URLComponents(); parameters.percentEncodedQuery = String(decoding: body, as: UTF8.self)
        let items = (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []) + (parameters.queryItems ?? [])
        var fields = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        fields["api"] = fields["api"] ?? request.url!.lastPathComponent
        let data: [String: Any]
        if fields["api"] == "SYNO.API.Info" {
            data = ["SYNO.Chat.User": ["path": "entry.cgi", "minVersion": 2, "maxVersion": 3, "requestFormat": "JSON"]]
        } else { Self.calls.append(fields); data = ["users": Self.users] }
        let bytes = try! JSONSerialization.data(withJSONObject: ["success": true, "data": data])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
