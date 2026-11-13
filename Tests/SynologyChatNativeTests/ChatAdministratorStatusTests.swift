import Foundation
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatAdministratorStatusTests: XCTestCase {
    override func setUp() { super.setUp(); AdministratorStatusProtocol.reset() }
    private func api() async throws -> ChatAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AdministratorStatusProtocol.self]
        let client = try ChatAPIClient(session:.init(baseURL:URL(string:"https://administrator-status.invalid/custom")!,
            sid:"synthetic-sid+&=",synoToken:"synthetic-token?#&"),network:URLSession(configuration:configuration))
        try await client.discover();return client
    }
    func testExactReadOnlyGETPreservesAuthenticatedQueryAndDiscoveredPath() async throws {
        let client = try await api()
        let result = try await client.administratorStatus(expectedUsername:"SyntheticAdmin")
        XCTAssertEqual(result,.init(username:"SyntheticAdmin",isAdministrator:true))
        let request = try XCTUnwrap(AdministratorStatusProtocol.statusRequests.first)
        XCTAssertEqual(AdministratorStatusProtocol.statusRequests.count,1)
        XCTAssertEqual(request.httpMethod,"GET")
        XCTAssertEqual(request.url?.path,"/custom/webapi/desktop-discovered.cgi/SYNO.Core.Desktop.Initdata")
        XCTAssertNil(request.httpBody);XCTAssertNil(request.httpBodyStream)
        XCTAssertNil(request.value(forHTTPHeaderField:"Content-Type"));XCTAssertNil(request.value(forHTTPHeaderField:"Content-Length"))
        let fields = try XCTUnwrap(URLComponents(url:XCTUnwrap(request.url),resolvingAgainstBaseURL:false)?.queryItems)
        XCTAssertEqual(fields.count,5)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues:fields.map { ($0.name,$0.value ?? "") }),[
            "_sid":"synthetic-sid+&=","SynoToken":"synthetic-token?#&","api":"SYNO.Core.Desktop.Initdata","method":"get_user_service","version":"1"])
    }
    func testStrictFalseAdministratorIsKnownNonadministrator() async throws {
        let client = try await api()
        AdministratorStatusProtocol.response = #"{"success":true,"data":{"Session":{"user":"SyntheticAdmin","isLogined":true,"is_admin":false}}}"#
        let result = try await client.administratorStatus(expectedUsername:"SyntheticAdmin")
        XCTAssertEqual(result,.init(username:"SyntheticAdmin",isAdministrator:false))
    }
    func testMissingMalformedWrongPrincipalAndLoggedOutResponsesCannotGrantAdministrator() async throws {
        let client = try await api()
        let sessions: [[String:Any]] = [
            ["user":"OtherAccount","isLogined":true,"is_admin":true],
            ["user":"syntheticadmin","isLogined":true,"is_admin":true],
            ["user":"SyntheticAdmin","isLogined":false,"is_admin":true],
            ["user":"SyntheticAdmin","isLogined":"true","is_admin":true],
            ["user":"SyntheticAdmin","isLogined":1,"is_admin":true],
            ["user":"SyntheticAdmin","isLogined":true,"is_admin":"true"],
            ["user":"SyntheticAdmin","isLogined":true,"is_admin":1],
            ["user":"SyntheticAdmin","isLogined":true],
            ["isLogined":true,"is_admin":true],
            ["user":10,"isLogined":true,"is_admin":true]]
        for session in sessions {
            AdministratorStatusProtocol.response = String(decoding:try JSONSerialization.data(withJSONObject:["success":true,"data":["Session":session]]),as:UTF8.self)
            do { _ = try await client.administratorStatus(expectedUsername:"SyntheticAdmin");XCTFail("Invalid principal/flag granted status") } catch { }
        }
        for response in [#"{"success":true,"data":{}}"#,#"{"success":true,"data":{"Session":null}}"#,#"{"success":false,"error":{"code":119}}"#] {
            AdministratorStatusProtocol.response = response
            do { _ = try await client.administratorStatus(expectedUsername:"SyntheticAdmin");XCTFail() } catch { }
        }
    }
    func testEmptyExpectedPrincipalAndUnsupportedEndpointSendNoStatusRequest() async throws {
        let client = try await api()
        do { _ = try await client.administratorStatus(expectedUsername:"");XCTFail() } catch { }
        XCTAssertTrue(AdministratorStatusProtocol.statusRequests.isEmpty)
        AdministratorStatusProtocol.supported = false
        let unavailable = try await api()
        do { _ = try await unavailable.administratorStatus(expectedUsername:"SyntheticAdmin");XCTFail() }
        catch ChatAPIError.unsupportedAPI { }
        XCTAssertTrue(AdministratorStatusProtocol.statusRequests.isEmpty)
    }
    func testForeignHostsAreInterceptedAndRejectedWithoutNetworkFallback() async throws {
        let configuration = URLSessionConfiguration.ephemeral;configuration.protocolClasses = [AdministratorStatusProtocol.self]
        let network = URLSession(configuration:configuration);defer { network.invalidateAndCancel() }
        do { _ = try await network.data(from:URL(string:"https://outside-fixture.invalid/never")!);XCTFail() }
        catch let error as URLError { XCTAssertEqual(error.code,.unsupportedURL) }
    }
}

private final class AdministratorStatusProtocol: URLProtocol {
    static var supported = true
    static var response = ""
    static var statusRequests: [URLRequest] = []
    static func reset() {
        supported = true;statusRequests = []
        response = #"{"success":true,"data":{"Session":{"user":"SyntheticAdmin","isLogined":true,"is_admin":true}}}"#
    }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.scheme == "https",request.url?.host == "administrator-status.invalid" else {
            client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return
        }
        let data: Data
        if request.url?.lastPathComponent == "SYNO.API.Info" {
            let endpoints: [String:Any] = Self.supported ? ["SYNO.Core.Desktop.Initdata":["path":"desktop-discovered.cgi","minVersion":1,"maxVersion":1,"requestFormat":"JSON"]] : [:]
            data = try! JSONSerialization.data(withJSONObject:["success":true,"data":endpoints])
        } else {
            Self.statusRequests.append(request);data = Data(Self.response.utf8)
        }
        let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
