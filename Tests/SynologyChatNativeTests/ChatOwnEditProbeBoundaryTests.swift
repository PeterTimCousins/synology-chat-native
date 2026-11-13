#if DEBUG
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatOwnEditProbeBoundaryTests:XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-edit-boundary-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        addTeardownBlock { try FileManager.default.removeItem(at:url) }
        return url
    }
    func testCompetingReceiptCannotBeClaimedOrOverwrittenByFailureHandling() throws {
        let file = try directory().appendingPathComponent("receipt.json")
        // Represents a competing run winning after this run's initial check.
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
        let original = Data(#"{"state":"other_run_dispatching","post_id":120}"#.utf8)
        try original.write(to:file,options:.withoutOverwriting)
        var ledger = ChatOwnEditProbeReceipt(file:file)
        XCTAssertThrowsError(try ledger.claim(["state":"initialized"]))
        XCTAssertFalse(ledger.owned)
        XCTAssertThrowsError(try ledger.save(["state":"stopped_no_retry"]))
        XCTAssertEqual(try Data(contentsOf:file),original)
    }
    func testOwnedReceiptPersistsTransitionsWithoutAllowingSecondClaim() throws {
        let file = try directory().appendingPathComponent("receipt.json")
        var ledger = ChatOwnEditProbeReceipt(file:file)
        try ledger.claim(["state":"initialized"])
        XCTAssertTrue(ledger.owned)
        try ledger.save(["state":"model_edit_dispatching"])
        XCTAssertThrowsError(try ledger.claim(["state":"initialized_again"]))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:String])
        XCTAssertEqual(result["state"],"model_edit_dispatching")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue,0o600)
    }
    func testGuardRejectionHappensBeforeNetworkAndCountsMutationAttempt() async throws {
        let session = URLSessionConfiguration.ephemeral;session.protocolClasses = [EditBoundaryProtocol.self]
        EditBoundaryProtocol.requests = 0
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://edit-boundary.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:session))
        let policy = ChatOwnEditProbePolicy(role:.model)
        api.debugRequestGuard = { try policy.check($0) }
        let request = try api.makeRequest(api:"SYNO.Chat.Post",method:"create",version:5,path:"entry.cgi",parameters:["channel_id":.integer(93),"type":.string("normal"),"message":.string("Synthetic must not dispatch"),"is_thread":.bool(false),"thread_id":.integer(0),"conn_id":.string("")],jsonParameters:true)
        do { let _:ChatJSON = try await api.perform(request);XCTFail("Unarmed mutation passed") } catch {}
        XCTAssertEqual(EditBoundaryProtocol.requests,0)
        XCTAssertEqual(policy.snapshot().createAttempts,1);XCTAssertEqual(policy.snapshot().rejectedCount,1)
    }
    func testOrdinaryClientWithNoGuardRetainsDiscoveryTransport() async throws {
        let session = URLSessionConfiguration.ephemeral;session.protocolClasses = [EditBoundaryProtocol.self]
        EditBoundaryProtocol.requests = 0
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://edit-boundary.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:session))
        XCTAssertNil(api.debugRequestGuard)
        try await api.discover()
        XCTAssertEqual(EditBoundaryProtocol.requests,1)
    }
}
private final class EditBoundaryProtocol:URLProtocol {
    static var requests = 0
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        guard request.url?.host == "edit-boundary.invalid" else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        let data = Data(#"{"success":true,"data":{}}"#.utf8)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
