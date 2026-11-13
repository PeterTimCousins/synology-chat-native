import XCTest
@testable import SynologyChatNative

final class ChatAuthenticationTests: XCTestCase {
    func testSavedSessionMatchesQuickConnectAcrossEndpointChanges() {
        func account(_ host: String, sid: String = "synthetic", identity: String = "nas-one") -> ChatAccount {
            ChatAccount(session: .init(baseURL: URL(string: "https://" + host)!, sid: sid, synoToken: "synthetic"),
                        username: "synthetic", importedFromOfficialApp: false,
                        connectionAddress: "SyntheticQC", serverIdentity: identity)
        }
        let saved = account("first.test")
        XCTAssertTrue(ChatAccountKeychain.matchesSession(saved, account("second.test")))
        XCTAssertFalse(ChatAccountKeychain.matchesSession(saved, account("second.test", sid: "other")))
        XCTAssertFalse(ChatAccountKeychain.matchesSession(saved, account("second.test", identity: "other-nas")))
    }

    private func service(handler: @escaping (URLRequest) -> String) -> ChatAuthentication {
        AuthenticationStub.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthenticationStub.self]
        return ChatAuthentication(network: URLSession(configuration: config))
    }
    override func tearDown() { AuthenticationStub.handler = nil; super.tearDown() }

    func testSignInUsesDiscoveredPathKeepsPasswordOutOfURLAndRequestsChatSession() async throws {
        var requests = 0
        let auth = service { request in
            requests += 1
            if requests == 1 {
                return #"{"success":true,"data":{"SYNO.API.Auth":{"path":"auth.cgi","minVersion":1,"maxVersion":7}}}"#
            }
            XCTAssertEqual(request.url!.path, "/proxy/webapi/auth.cgi/SYNO.API.Auth")
            XCTAssertFalse(request.url!.absoluteString.contains("synthetic-password"))
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = String(decoding: bytes, as: UTF8.self)
            let fields = Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { part -> (String, String) in
                let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(pieces[0]).removingPercentEncoding!, String(pieces[1]).removingPercentEncoding!)
            })
            XCTAssertEqual(fields["passwd"], "synthetic-password+&")
            XCTAssertEqual(fields["session"], "chat")
            XCTAssertEqual(fields["otp_code"], "123456")
            XCTAssertEqual(fields["account"], "Synthetic User")
            return #"{"success":true,"data":{"sid":"synthetic-sid","synotoken":"synthetic-token"}}"#
        }
        let account = try await auth.signIn(address: "https://chat.test/proxy/?launchApp=ignored", username: "Synthetic User",
                                            password: "synthetic-password+&", otp: "123456")
        XCTAssertEqual(account.session.sid, "synthetic-sid")
        XCTAssertFalse(account.importedFromOfficialApp)
        XCTAssertEqual(requests, 2)
    }

    func testOTPChallengeDoesNotIssueAutomaticLoginRetry() async throws {
        var requests = 0
        let auth = service { _ in
            requests += 1
            if requests == 1 { return #"{"success":true,"data":{"SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7}}}"# }
            return #"{"success":false,"error":{"code":403}}"#
        }
        do {
            _ = try await auth.signIn(address: "https://chat.test", username: "synthetic", password: "synthetic", otp: "")
            XCTFail("OTP must be requested")
        } catch ChatSignInError.otpRequired { }
        XCTAssertEqual(requests, 2)
    }

    func testRejectsCredentialBearingOrInsecureServerAddresses() {
        for input in ["http://chat.test", "https://user:password@chat.test", "https://quickconnect.to/ID", "", "https://chat.test/login.cgi"] {
            XCTAssertThrowsError(try ChatAuthentication.serverURL(input))
        }
        XCTAssertEqual(try ChatAuthentication.serverURL("chat.test:5001/proxy/").absoluteString, "https://chat.test:5001/proxy/")
    }

    func testLegacyTokenPlaceholderDoesNotCreateUsableAccount() async throws {
        var requests = 0
        let auth = service { _ in
            requests += 1
            if requests == 1 { return #"{"success":true,"data":{"SYNO.API.Auth":{"path":"entry.cgi","minVersion":1,"maxVersion":7}}}"# }
            return #"{"success":true,"data":{"sid":"s","synotoken":"--------"}}"#
        }
        do {
            _ = try await auth.signIn(address: "https://chat.test", username: "synthetic", password: "synthetic", otp: "")
            XCTFail("Missing CSRF token must fail")
        } catch ChatSignInError.response { }
    }
}

private final class AuthenticationStub: URLProtocol {
    static var handler: ((URLRequest) -> String)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(handler(request).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
