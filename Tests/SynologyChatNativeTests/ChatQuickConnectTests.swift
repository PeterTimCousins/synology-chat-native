import XCTest
@testable import SynologyChatNative

final class ChatQuickConnectTests: XCTestCase {
    private let identity = "900150983cd24fb0d6963f7d28e17f72" // Synology legacy MD5 checksum for synthetic server ID "abc".
    private let discovery = #"{"errno":0,"server":{"serverID":"abc","ddns":"nas.example.test"},"service":{"port":443,"ext_port":443}}"#
    private func network(_ handler: @escaping (URLRequest) throws -> String) -> URLSession {
        QuickConnectStub.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.protocolClasses = [QuickConnectStub.self]
        return URLSession(configuration: config)
    }
    override func tearDown() { QuickConnectStub.handler = nil; super.tearDown() }

    func testIDsAndPublicURLsResolveWithoutUsingTheirHTTPTransport() throws {
        for address in ["ExampleID", "https://QuickConnect.to/ExampleID", "http://QuickConnect.to/ExampleID/", " quickconnect.to/ExampleID "] {
            let parsed = try XCTUnwrap(ChatQuickConnectAddress.parse(address))
            XCTAssertEqual(parsed.id, "ExampleID")
            XCTAssertEqual(parsed.discoveryHost, "global.quickconnect.to")
        }
        XCTAssertEqual(try ChatQuickConnectAddress.parse("https://exampleid.quickconnect.cn")?.discoveryHost, "global.quickconnect.cn")
        XCTAssertNil(try ChatQuickConnectAddress.parse("https://nas.example.test:5001"))
        XCTAssertNil(try ChatQuickConnectAddress.parse("localhost"))
        for address in ["ftp://quickconnect.to/ExampleID", "https://user:pass@quickconnect.to/ExampleID", "https://quickconnect.to:443/ExampleID",
                        "https://quickconnect.to/ExampleID/extra", "https://nested.exampleid.quickconnect.to", "https://quickconnect.to/"] {
            XCTAssertThrowsError(try ChatQuickConnectAddress.parse(address))
        }
    }

    func testLoginOnlyFollowsMatchingNASIdentityAndNeverSendsCredentialsToDiscovery() async throws {
        let requests = QuickConnectRequests()
        let network = network { [discovery, identity] request in
            let body = requests.record(request)
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.url!.absoluteString.contains("synthetic-password"))
            if request.url?.host == "global.quickconnect.to" {
                XCTAssertFalse(body.contains("passwd")); XCTAssertFalse(body.contains("_sid"))
                return discovery
            }
            if request.url!.path.contains("pingpong.cgi") {
                XCTAssertFalse(request.url!.query?.contains("_sid") == true)
                return "{\"success\":true,\"ezid\":\"\(identity)\"}"
            }
            if request.url!.path.contains("SYNO.API.Info") {
                return #"{"success":true,"data":{"SYNO.API.Auth":{"path":"auth.cgi","minVersion":1,"maxVersion":7}}}"#
            }
            XCTAssertEqual(request.url?.host, "nas.example.test")
            XCTAssertTrue(body.contains("passwd=synthetic-password"))
            return #"{"success":true,"data":{"sid":"synthetic-sid","synotoken":"synthetic-token"}}"#
        }
        let account = try await ChatAuthentication(network: network).signIn(address: "http://QuickConnect.to/ExampleID",
            username: "synthetic", password: "synthetic-password", otp: "")
        XCTAssertEqual(account.connectionAddress, "ExampleID")
        XCTAssertEqual(account.serverIdentity, identity)
        XCTAssertEqual(account.session.baseURL.host, "nas.example.test")
        XCTAssertEqual(requests.hosts, ["global.quickconnect.to", "nas.example.test", "nas.example.test", "nas.example.test"])
    }

    func testMismatchedCandidateCannotReceiveAuthDiscoveryOrLogin() async throws {
        let requests = QuickConnectRequests()
        let network = network { [discovery] request in
            _ = requests.record(request)
            if request.url?.host == "global.quickconnect.to" { return discovery }
            XCTAssertTrue(request.url!.path.contains("pingpong.cgi"))
            return #"{"success":true,"ezid":"different-nas"}"#
        }
        do {
            _ = try await ChatAuthentication(network: network).signIn(address: "ExampleID", username: "synthetic", password: "synthetic-password", otp: "")
            XCTFail("Mismatched NAS must reject login")
        } catch ChatQuickConnectError.trustedConnection { }
        XCTAssertEqual(requests.hosts.count, 3, "Direct failure may request relay metadata, never auth")
    }

    func testSavedIdentityChangeIsRejectedBeforeContactingAnyCandidate() async throws {
        let requests = QuickConnectRequests()
        let network = network { [discovery] request in _ = requests.record(request); return discovery }
        defer { network.invalidateAndCancel() }
        do {
            _ = try await ChatServerResolver(network: network).resolveServer("ExampleID", expectedIdentity: "previous-nas")
            XCTFail("Changed saved identity must fail closed")
        } catch ChatQuickConnectError.trustedConnection { }
        XCTAssertEqual(requests.hosts, ["global.quickconnect.to"])
    }

    func testUntrustedCandidateConnectionCannotReceiveCredentials() async throws {
        let requests = QuickConnectRequests()
        let network = network { [discovery] request in
            _ = requests.record(request)
            if request.url?.host == "global.quickconnect.to" { return discovery }
            throw URLError(.serverCertificateUntrusted)
        }
        defer { network.invalidateAndCancel() }
        do {
            _ = try await ChatServerResolver(network: network).resolve("ExampleID")
            XCTFail("Untrusted TLS must not be bypassed")
        } catch ChatQuickConnectError.trustedConnection { }
        XCTAssertEqual(requests.hosts.count, 3, "Relay metadata fallback carries no credentials")
    }

    func testRegionalDiscoverySkipsNonSynologyControlHost() async throws {
        let requests = QuickConnectRequests()
        let network = network { [discovery, identity] request in
            _ = requests.record(request)
            switch request.url?.host {
            case "global.quickconnect.to": return #"{"errno":1,"sites":["attacker.example.test","us.quickconnect.to"]}"#
            case "us.quickconnect.to": return discovery
            case "nas.example.test": return "{\"success\":true,\"ezid\":\"\(identity)\"}"
            default: XCTFail("Unapproved control host"); throw URLError(.badURL)
            }
        }
        defer { network.invalidateAndCancel() }
        let result = try await ChatServerResolver(network: network).resolve("ExampleID")
        XCTAssertEqual(result.host, "nas.example.test")
        XCTAssertEqual(requests.hosts, ["global.quickconnect.to", "us.quickconnect.to", "nas.example.test"])
    }

    func testCandidatesRejectEmbeddedURLsAndCredentialsAndDeduplicate() throws {
        let info = try JSONDecoder().decode(ChatQuickConnectInfo.self, from: Data(#"{"errno":0,"server":{"serverID":"abc","ddns":"nas.example.test","fqdn":"nas.example.test","external":{"ip":"user@evil.test"}},"service":{"port":443},"smartdns":{"host":"https://evil.test/path","lan":["bad host"]}}"#.utf8))
        let candidates = ChatServerResolver.candidates(info)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.scheme, "https")
        XCTAssertEqual(candidates.first?.host, "nas.example.test")
    }

    func testOlderSavedDirectAccountStillDecodesWithoutQuickConnectFields() throws {
        let data = Data(#"{"session":{"baseURL":"https://nas.example.test","sid":"synthetic-sid","synoToken":"synthetic-token"},"username":"synthetic","importedFromOfficialApp":false}"#.utf8)
        let account = try JSONDecoder().decode(ChatAccount.self, from: data)
        XCTAssertNil(account.connectionAddress)
        XCTAssertNil(account.serverIdentity)
        XCTAssertNil(account.session.tlsServerName)
        XCTAssertFalse(account.importedFromOfficialApp)
    }

    func testRelayFallbackValidatesNASBeforeLoginAndCarriesTLSIdentity() async throws {
        let requests = QuickConnectRequests()
        let network = network { [discovery, identity] request in
            let body = requests.record(request)
            if request.url?.host == "global.quickconnect.to" {
                XCTAssertFalse(body.contains("passwd")); XCTAssertFalse(body.contains("_sid"))
                if body.contains("request_tunnel") { return #"{"errno":0,"server":{"serverID":"abc"},"service":{"port":443,"relay_ip":"203.0.113.10","relay_port":62443}}"# }
                return discovery
            }
            if request.url?.host == "nas.example.test" {
                XCTAssertTrue(request.url!.path.contains("pingpong.cgi")); return #"{"success":true,"ezid":"wrong"}"#
            }
            XCTAssertEqual(request.url?.host, "203.0.113.10")
            if request.url!.path.contains("pingpong.cgi") {
                XCTAssertFalse(body.contains("passwd")); XCTAssertFalse(request.url?.query?.contains("_sid") == true)
                return "{\"success\":true,\"ezid\":\"\(identity)\"}"
            }
            if request.url!.path.contains("SYNO.API.Info") { return #"{"success":true,"data":{"SYNO.API.Auth":{"path":"auth.cgi","minVersion":1,"maxVersion":7}}}"# }
            XCTAssertTrue(body.contains("passwd=synthetic-password"))
            return #"{"success":true,"data":{"sid":"s","synotoken":"s"}}"#
        }
        let account = try await ChatAuthentication(network: network).signIn(address: "ExampleID", username: "synthetic", password: "synthetic-password", otp: "")
        XCTAssertEqual(account.session.tlsServerName, "nas.example.test")
        XCTAssertEqual(account.serverIdentity, identity)
        XCTAssertEqual(account.session.baseURL.absoluteString, "https://203.0.113.10:62443")
        XCTAssertEqual(requests.hosts.filter { $0 == "203.0.113.10" }.count, 3)
    }

    func testInvalidOrDifferentNASRelayMetadataCannotContactRelay() async throws {
        let tunnels = [
            #"{"errno":0,"server":{"serverID":"different"},"service":{"port":443,"relay_ip":"203.0.113.10","relay_port":62443}}"#,
            #"{"errno":0,"server":{"serverID":"abc"},"service":{"port":443,"relay_ip":"https://bad.test","relay_port":62443}}"#,
            #"{"errno":0,"server":{"serverID":"abc"},"service":{"port":443,"relay_ip":"203.0.113.10","relay_port":0}}"#
        ]
        for tunnel in tunnels {
            let requests = QuickConnectRequests()
            let network = network { [discovery] request in
                let body = requests.record(request)
                XCTAssertEqual(request.url?.host, "global.quickconnect.to")
                return body.contains("request_tunnel") ? tunnel : discovery
            }
            defer { network.invalidateAndCancel() }
            do { _ = try await ChatServerResolver(network: network).resolveServer("ExampleID", relayOnly: true); XCTFail("Invalid relay must be rejected") }
            catch ChatQuickConnectError.trustedConnection { }
            XCTAssertEqual(requests.hosts.count, 2)
        }
    }

    func testRelayNASMismatchCannotReceiveLoginOrAuthDiscovery() async throws {
        let requests = QuickConnectRequests()
        let network = network { [discovery] request in
            let body = requests.record(request)
            if request.url?.host == "global.quickconnect.to" {
                return body.contains("request_tunnel") ? #"{"errno":0,"server":{"serverID":"abc"},"service":{"port":443,"relay_ip":"203.0.113.10","relay_port":62443}}"# : discovery
            }
            XCTAssertTrue(request.url!.path.contains("pingpong.cgi"))
            XCTAssertFalse(body.contains("passwd"))
            return #"{"success":true,"ezid":"wrong-nas"}"#
        }
        do { _ = try await ChatAuthentication(network: network).signIn(address: "ExampleID", username: "synthetic", password: "synthetic-password", otp: ""); XCTFail("Wrong NAS must fail") }
        catch ChatQuickConnectError.trustedConnection { }
        XCTAssertEqual(requests.hosts.count, 4)
    }
}

private final class QuickConnectRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var hosts: [String] { lock.lock(); defer { lock.unlock() }; return values }
    func record(_ request: URLRequest) -> String {
        lock.lock(); values.append(request.url?.host ?? ""); lock.unlock()
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
private final class QuickConnectStub: URLProtocol {
    static var handler: ((URLRequest) throws -> String)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let response = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
