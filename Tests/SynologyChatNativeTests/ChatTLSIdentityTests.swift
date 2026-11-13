import Security
import XCTest
@testable import SynologyChatNative

final class ChatTLSIdentityTests: XCTestCase {
    private let origin = URL(string: "https://203.0.113.10:62443")!
    private func certificate(_ name: String) throws -> SecCertificate {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "der", subdirectory: "Fixtures"))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, try Data(contentsOf: url) as CFData))
    }
    private func trust(anchored: Bool = true, expired: Bool = false) throws -> SecTrust {
        let root = try certificate("RelayTestRoot"), leaf = try certificate("RelayTestLeaf")
        var result: SecTrust?
        let status = SecTrustCreateWithCertificates([leaf, root] as CFArray, SecPolicyCreateSSL(true, "203.0.113.10" as CFString), &result)
        XCTAssertEqual(status, OSStatus(errSecSuccess))
        let trust = try XCTUnwrap(result)
        SecTrustSetNetworkFetchAllowed(trust, false)
        // Test-only anchors are confined to this synthetic trust object. No
        // certificate is installed in Keychain or any production trust store.
        if anchored { SecTrustSetAnchorCertificates(trust, [root] as CFArray); SecTrustSetAnchorCertificatesOnly(trust, true) }
        let date = ISO8601DateFormatter().date(from: expired ? "2040-01-01T00:00:00Z" : "2026-10-17T00:00:00Z")!
        SecTrustSetVerifyDate(trust, date as CFDate)
        return trust
    }
    func testRelayUsesKnownNASNameWithValidChainRatherThanTransportIP() throws {
        let identity = try XCTUnwrap(ChatTLSIdentity(origin: origin, serverName: "nas.synthetic.test"))
        XCTAssertFalse(SecTrustEvaluateWithError(try trust(), nil), "Default IP hostname check must reject this DNS certificate")
        let matchedTrust = try trust()
        let valid = identity.evaluate(matchedTrust, host: "203.0.113.10", port: 62443)
        var failure: CFError?
        _ = SecTrustEvaluateWithError(matchedTrust, &failure)
        XCTAssertTrue(valid, String(describing: failure))
    }
    func testDifferentOriginPortAndDNSNameCannotReuseTheTrustPolicy() throws {
        let identity = try XCTUnwrap(ChatTLSIdentity(origin: origin, serverName: "nas.synthetic.test"))
        XCTAssertFalse(identity.evaluate(try trust(), host: "203.0.113.11", port: 62443))
        XCTAssertFalse(identity.evaluate(try trust(), host: "203.0.113.10", port: 443))
        let wrong = try XCTUnwrap(ChatTLSIdentity(origin: origin, serverName: "other.synthetic.test"))
        XCTAssertFalse(wrong.evaluate(try trust(), host: "203.0.113.10", port: 62443))
    }
    func testUntrustedAndExpiredCertificateChainsRemainRejected() throws {
        let identity = try XCTUnwrap(ChatTLSIdentity(origin: origin, serverName: "nas.synthetic.test"))
        XCTAssertFalse(identity.evaluate(try trust(anchored: false), host: "203.0.113.10", port: 62443))
        XCTAssertFalse(identity.evaluate(try trust(expired: true), host: "203.0.113.10", port: 62443))
    }
    func testMalformedTLSIdentityCannotCreateAClientOrSocketRequest() throws {
        for name in ["", "*.synthetic.test", "https://nas.synthetic.test", "user@nas.synthetic.test", "nas.synthetic.test:443", "203.0.113.10", "nas.test/path"] {
            XCTAssertNil(ChatTLSIdentity(origin: origin, serverName: name))
            let session = ChatSession(baseURL: origin, sid: "s", synoToken: "s", tlsServerName: name)
            XCTAssertThrowsError(try ChatAPIClient(session: session))
            XCTAssertThrowsError(try ChatLiveConnection.request(session: session, version: "test"))
        }
        XCTAssertNil(ChatTLSIdentity(origin: URL(string: "http://203.0.113.10")!, serverName: "nas.synthetic.test"))
    }
    func testSavedRelayIdentityAndAttachmentDelegatePreserveExactOriginAndRedirectDenial() throws {
        let session = ChatSession(baseURL: origin, sid: "s", synoToken: "s", tlsServerName: "nas.synthetic.test")
        let decoded = try JSONDecoder().decode(ChatSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.tlsServerName, "nas.synthetic.test")
        let api = try ChatAPIClient(session: decoded)
        let delegate = api.makeConnectionDelegate()
        XCTAssertTrue(delegate.tlsIdentity?.matches(host: "203.0.113.10", port: 62443) == true)
        XCTAssertFalse(delegate.tlsIdentity?.matches(host: "other.synthetic.test", port: 62443) == true)
        let network = URLSession(configuration: .ephemeral)
        defer { network.invalidateAndCancel() }
        let task = network.dataTask(with: origin)
        delegate.urlSession(network, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil)!,
            newRequest: URLRequest(url: URL(string: "https://other.synthetic.test")!)) { request in XCTAssertNil(request) }
    }
}
