import XCTest
@testable import SynologyChatNative

final class ChatUploadCancellationTests: XCTestCase {
    func testCancelStopsInFlightUploadWithoutRetry() async throws {
        let started = expectation(description: "Multipart upload in flight")
        let stopped = expectation(description: "Underlying transfer cancelled")
        var uploads = 0
        UploadCancellationStub.onUpload = { uploads += 1; started.fulfill() }
        UploadCancellationStub.onCancel = { stopped.fulfill() }
        defer { UploadCancellationStub.onUpload = nil; UploadCancellationStub.onCancel = nil }
        func network() -> URLSession {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [UploadCancellationStub.self]
            return URLSession(configuration: config)
        }
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://synthetic.test")!, sid: "synthetic", synoToken: "synthetic"),
                                    network: network(), makeAttachmentNetwork: network)
        try await api.discover()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-cancel-" + UUID().uuidString + ".txt")
        try Data("Synthetic upload cancellation fixture. No private data.".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transfer = Task {
            try await api.uploadAttachment(channelID: 23, file: file, caption: "Synthetic unsent caption", connectionID: "synthetic")
        }
        await fulfillment(of: [started], timeout: 2)
        transfer.cancel()
        do { _ = try await transfer.value; XCTFail("Cancelled upload must not report delivery success") }
        catch is CancellationError { }
        catch { XCTFail("Cancellation must remain distinguishable from failed or unknown delivery") }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(uploads, 1, "Cancelling an upload must not retry or create a second post")
    }
}

private final class UploadCancellationStub: URLProtocol {
    static var onUpload: (() -> Void)?
    static var onCancel: (() -> Void)?
    private var isUpload = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let json: String
        if request.url!.path.contains("SYNO.API.Info") {
            json = #"{"success":true,"data":{"SYNO.Chat.Admin.Setting":{"path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"},"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"}}}"#
        } else if request.url!.path.contains("SYNO.Chat.Admin.Setting") {
            json = #"{"success":true,"data":{"file_size_limit":10}}"#
        } else {
            isUpload = true
            Self.onUpload?()
            return // Deliberately keep the request in flight until cancellation.
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { if isUpload { Self.onCancel?() } }
}
