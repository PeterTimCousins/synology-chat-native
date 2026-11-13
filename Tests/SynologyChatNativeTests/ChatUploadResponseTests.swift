import XCTest
@testable import SynologyChatNative

final class ChatUploadResponseTests: XCTestCase {
    private func attempt(status: Int, body: String,transportFailure:URLError? = nil) async throws -> (Error?, Int) {
        var uploads = 0
        UploadResponseStub.response = { request in
            if request.url!.path.contains("SYNO.API.Info") {
                return (200, #"{"success":true,"data":{"SYNO.Chat.Admin.Setting":{"path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"},"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"}}}"#)
            }
            if request.url!.path.contains("SYNO.Chat.Admin.Setting") { return (200, #"{"success":true,"data":{"file_size_limit":1}}"#) }
            uploads += 1
            if let transportFailure { throw transportFailure }
            return (status, body)
        }
        defer { UploadResponseStub.response = nil }
        func network() -> URLSession {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [UploadResponseStub.self]
            return URLSession(configuration: config)
        }
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://synthetic.test")!, sid: "s", synoToken: "s"), network: network(), makeAttachmentNetwork: network)
        try await api.discover()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = Data("Synthetic upload response verification.".utf8)
        try source.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        func staging() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("native-chat-upload-") })
        }
        let before = try staging()
        var failure: Error?
        do { _ = try await api.uploadAttachment(channelID: 23, file: file, caption: "Unsent synthetic caption", connectionID: "s") }
        catch { failure = error }
        XCTAssertEqual(try staging(), before, "Failed response must remove this attempt's multipart staging")
        XCTAssertEqual(try Data(contentsOf: file), source, "Failure must preserve the original file")
        return (failure, uploads)
    }
    func testUnconfirmedResponsesWarnBeforeRetryAndNeverAutomaticallyResend() async throws {
        for (status, body) in [(502, "upstream unavailable"), (302, "redirect"), (200, "<html>Sign in</html>"), (200, "{\"success\":true,\"data\":")] {
            let (error, uploads) = try await attempt(status: status, body: body)
            let warning = try XCTUnwrap(error as? ChatTransferError).errorDescription ?? ""
            XCTAssertTrue(try XCTUnwrap(error as? ChatTransferError).deliveryNeedsReview)
            XCTAssertTrue(warning.contains("delivery could not be confirmed"))
            XCTAssertTrue(warning.contains("Check the conversation"))
            XCTAssertEqual(uploads, 1)
        }
    }
    func testExplicitServerRejectionPreservesItsActionableReasonWithoutRetry() async throws {
        for code in [119, 407, 411] {
            let (error, uploads) = try await attempt(status: 200, body: "{\"success\":false,\"error\":{\"code\":\(code)}}")
            guard case ChatAPIError.server(let returned)? = error else { XCTFail("Expected confirmed rejection"); continue }
            XCTAssertEqual(returned, code)
            XCTAssertEqual(uploads, 1)
        }
    }
    func testZeroPostIDCannotConfirmAttachmentDeliveryOrTriggerRetry() async throws {
        let response = #"{"success":true,"data":{"post_id":0,"channel_id":23,"creator_id":10,"message":"Synthetic","type":"file","create_at":1000,"thread_id":0,"file_props":{"name":"synthetic.txt"}}}"#
        let (error, uploads) = try await attempt(status: 200, body: response)
        let warning = try XCTUnwrap(error as? ChatTransferError).errorDescription ?? ""
        XCTAssertTrue(try XCTUnwrap(error as? ChatTransferError).deliveryNeedsReview)
        XCTAssertTrue(warning.contains("Check the conversation"))
        XCTAssertEqual(uploads, 1)
    }
    func testWrongConversationThreadOrTypeRequiresReviewWithoutResending() async throws {
        for fields in ["\"post_id\":7,\"channel_id\":24,\"thread_id\":0,\"type\":\"file\"",
                       "\"post_id\":7,\"channel_id\":23,\"thread_id\":8,\"type\":\"file\"",
                       "\"post_id\":7,\"channel_id\":23,\"thread_id\":0,\"type\":\"normal\""] {
            let body = "{\"success\":true,\"data\":{\(fields),\"creator_id\":10,\"message\":\"Synthetic\",\"create_at\":1000}}"
            let (error,uploads) = try await attempt(status:200,body:body)
            let transfer = try XCTUnwrap(error as? ChatTransferError)
            XCTAssertTrue(transfer.deliveryNeedsReview)
            XCTAssertFalse(transfer.message.localizedCaseInsensitiveContains("confirm"),"This receipt mismatch was missed by the former prose-based check")
            XCTAssertEqual(uploads,1)
        }
    }
    func testDeliveryReviewStateIsIndependentOfPresentationLanguage() {
        XCTAssertTrue(ChatTransferError(message:"Übertragung prüfen",deliveryNeedsReview:true).deliveryNeedsReview)
        XCTAssertFalse(ChatTransferError(message:"Confirm a filename before attaching it").deliveryNeedsReview)
    }
    func testLostUploadResponseRequiresReviewWithoutResending() async throws {
        let (error,uploads) = try await attempt(status:200,body:"",transportFailure:URLError(.networkConnectionLost))
        XCTAssertTrue(try XCTUnwrap(error as? ChatTransferError).deliveryNeedsReview)
        XCTAssertEqual(uploads,1)
    }
}

private final class UploadResponseStub: URLProtocol {
    static var response: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status:Int,text:String
        do {
            guard let result = try Self.response?(request) else { return }
            (status,text) = result
        } catch { client?.urlProtocol(self,didFailWithError:error);return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
