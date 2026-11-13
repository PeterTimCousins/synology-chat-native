import XCTest
@testable import SynologyChatNative

final class ChatBoundedPreviewTransferTests: XCTestCase {
    private func load(limit: Int = 8) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedPreviewStub.self]
        let transfer = ChatBoundedPreviewTransfer(maximumBytes: limit, tlsIdentity: nil)
        let task = Task { try await transfer.load(URLRequest(url: URL(string: "https://synthetic.invalid/preview")!), configuration: configuration) }
        let watchdog = Task { try await Task.sleep(nanoseconds: 3_000_000_000); task.cancel() }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    override func tearDown() {
        BoundedPreviewStub.length = nil
        BoundedPreviewStub.attachmentHeader = true
        BoundedPreviewStub.chunks = []
        BoundedPreviewStub.completes = true
        BoundedPreviewStub.started = nil
        BoundedPreviewStub.stopped = nil
        super.tearDown()
    }

    func testUnknownLengthAtExactLimitSucceeds() async throws {
        BoundedPreviewStub.chunks = [Data("1234".utf8), Data("5678".utf8)]
        let data = try await load()
        XCTAssertEqual(data, Data("12345678".utf8))
    }

    func testUnknownLengthOverflowCancelsBeforeServerFinishes() async {
        let stopped = expectation(description: "Network cancelled without response completion")
        BoundedPreviewStub.stopped = { stopped.fulfill() }
        BoundedPreviewStub.completes = false
        BoundedPreviewStub.chunks = [Data("12345678".utf8), Data("9".utf8)]
        do { _ = try await load(); XCTFail("Overflow accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("too large")) }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testOversizeHeaderRejectsBeforeBodyCompletion() async {
        BoundedPreviewStub.length = "1000000"
        BoundedPreviewStub.chunks = [Data("x".utf8)]
        BoundedPreviewStub.completes = false
        do { _ = try await load(); XCTFail("Oversize header accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("too large")) }
    }

    func testMissingAttachmentHeaderRejectsWithoutBodyCompletion() async {
        BoundedPreviewStub.attachmentHeader = false
        BoundedPreviewStub.completes = false
        BoundedPreviewStub.chunks = [Data("x".utf8)]
        do { _ = try await load(); XCTFail("API envelope accepted") }
        catch { guard case ChatAPIError.invalidResponse = error else { return XCTFail("Unexpected error: \(error)") } }
    }

    func testCancellationStopsStalledTransfer() async {
        let started = expectation(description: "Request started")
        let stopped = expectation(description: "Request stopped")
        BoundedPreviewStub.started = { started.fulfill() }
        BoundedPreviewStub.stopped = { stopped.fulfill() }
        BoundedPreviewStub.completes = false
        let task = Task { try await load() }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 2)
    }
}

private final class BoundedPreviewStub: URLProtocol {
    static var length: String?
    static var attachmentHeader = true
    static var chunks: [Data] = []
    static var completes = true
    static var started: (() -> Void)?
    static var stopped: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var headers = ["Content-Type": "application/octet-stream", "Content-Disposition": "attachment; filename=synthetic.txt"]
        if !Self.attachmentHeader { headers.removeValue(forKey: "Content-Disposition") }
        if let length = Self.length { headers["Content-Length"] = length }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        for chunk in Self.chunks { client?.urlProtocol(self, didLoad: chunk) }
        Self.started?()
        if Self.completes { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.stopped?() }
}
