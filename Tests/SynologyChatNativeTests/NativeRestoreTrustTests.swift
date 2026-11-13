import Foundation
import XCTest
@testable import SynologyChatNative

@MainActor
final class NativeRestoreTrustTests: XCTestCase {
    func testRejectedTLSDuringRestoreClearsPresentationAndPreservesInMemoryAccountForExplicitRetry() async throws {
        // This source replaces only the saved-account lookup. It never touches
        // Keychain and does not claim to verify macOS persistence or a TLS handshake.
        let savedAccount = ChatAccount(session: .init(baseURL: URL(string: "https://restore-trust.invalid")!,
            sid: "synthetic-saved-session", synoToken: "synthetic-saved-token"),
            username: "Synthetic", importedFromOfficialApp: false)
        let ledger = RestoreTrustRequestLedger()
        RestoreTrustFailureProtocol.ledger = ledger
        defer { RestoreTrustFailureProtocol.ledger = nil }
        var lookups = 0
        var clients = 0
        let model = NativeChatPreviewModel(restoreNotificationPreference: false, makeClient: { session in
            clients += 1
            XCTAssertEqual(session.sid, savedAccount.session.sid)
            XCTAssertEqual(session.synoToken, savedAccount.session.synoToken)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RestoreTrustFailureProtocol.self]
            return try ChatAPIClient(session: session, network: URLSession(configuration: configuration))
        })
        // Restore is allowed while disconnected; seed public presentation fields
        // to catch accidental retention of an earlier account's visible snapshot.
        model.channels = [try JSONDecoder().decode(ChatChannel.self, from: Data(#"{"channel_id":93,"name":"Old channel","type":"private","encrypted":false,"unread":0}"#.utf8))]
        model.directory = [try JSONDecoder().decode(ChatUser.self, from: Data(#"{"user_id":10,"username":"old","nickname":"Old account","type":"human"}"#.utf8))]
        model.selection = 93
        model.names = [10: "Old account"]
        model.channelNames = [93: "Old channel"]
        model.accountDisplay = "Old account"

        for attempt in 1...2 {
            await model.restoreSavedSession(loadAccount: {
                lookups += 1
                return savedAccount
            })
            XCTAssertFalse(model.connected)
            XCTAssertFalse(model.connecting)
            XCTAssertFalse(model.restoringSavedSession)
            XCTAssertTrue(model.channels.isEmpty)
            XCTAssertTrue(model.directory.isEmpty)
            XCTAssertTrue(model.posts.isEmpty)
            XCTAssertTrue(model.names.isEmpty)
            XCTAssertTrue(model.channelNames.isEmpty)
            XCTAssertNil(model.selection)
            XCTAssertEqual(model.accountDisplay, "")
            XCTAssertNil(model.notificationVisibleLocation)
            XCTAssertNotNil(model.error)
            XCTAssertEqual(lookups, attempt)
            XCTAssertEqual(clients, attempt)
            // Each explicit restore stops at unauthenticated discovery. Any
            // bootstrap, login, logout or hidden retry produces an extra request.
            let requests = ledger.snapshot()
            XCTAssertEqual(requests.count, attempt)
            for request in requests {
                XCTAssertEqual(request.url?.host, "restore-trust.invalid")
                XCTAssertTrue(request.url?.path.contains("SYNO.API.Info") == true)
                let serialized = (request.url?.absoluteString ?? "")
                    + (String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")
                    + (request.allHTTPHeaderFields ?? [:]).description
                XCTAssertFalse(serialized.contains(savedAccount.session.sid))
                XCTAssertFalse(serialized.contains(savedAccount.session.synoToken))
                XCTAssertFalse(serialized.contains("logout"))
                XCTAssertFalse(serialized.contains("passwd"))
            }
            for _ in 0..<5 { await Task.yield() }
            XCTAssertEqual(ledger.snapshot().count, attempt, "Failure must not queue an automatic retry")
        }
        // The second lookup received the exact same in-memory saved credential;
        // failed connection attempts neither revoke it nor require a new login.
        XCTAssertEqual(savedAccount.session.sid, "synthetic-saved-session")
    }
}

private final class RestoreTrustRequestLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func record(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
    func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

private final class RestoreTrustFailureProtocol: URLProtocol {
    static var ledger: RestoreTrustRequestLedger?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var observed = request
        if observed.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable, bytes.count < 64 * 1024 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            observed.httpBody = bytes
        }
        Self.ledger?.record(observed)
        client?.urlProtocol(self, didFailWithError: URLError(.serverCertificateUntrusted))
    }
    override func stopLoading() { }
}
