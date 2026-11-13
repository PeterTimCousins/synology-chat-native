import XCTest
@testable import SynologyChatNative

final class ChatMediaRangeReadTests: XCTestCase {
    private var configuration: URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [MediaRangeStub.self]; return value
    }
    private var request: URLRequest { URLRequest(url: URL(string: "https://media-range-fixture.invalid/file")!) }
    override func setUp() { super.setUp(); MediaRangeStub.reset() }
    override func tearDown() { MediaRangeStub.reset(); super.tearDown() }
    private func range() throws -> ChatMediaByteRange { try .init(offset: 4, length: 8, total: 20) }
    private func load(_ transfer: ChatMediaRangeRead? = nil) async throws -> Data {
        let transfer = try transfer ?? ChatMediaRangeRead(range: range(), tlsIdentity: nil)
        let task = Task { try await transfer.load(request, configuration: configuration) }
        let watchdog = Task { try await Task.sleep(nanoseconds: 3_000_000_000); task.cancel() }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    func testRangeClipsEndAndRejectsOverflowNegativeOrExcessiveRequests() throws {
        let last = try ChatMediaByteRange(offset: 19, length: 1024 * 1024, total: 20)
        XCTAssertEqual(last.end, 19); XCTAssertEqual(last.expectedCount, 1); XCTAssertEqual(last.header, "bytes=19-19")
        let max = try ChatMediaByteRange(offset: 128 * 1024 * 1024 - 1, length: 1024 * 1024, total: 128 * 1024 * 1024)
        XCTAssertEqual(max.expectedCount, 1)
        for (offset, length, total) in [(Int64(-1), 8, Int64(20)), (20, 8, 20), (0, 0, 20), (0, -1, 20),
            (0, 1024 * 1024 + 1, 20), (0, 1, 0), (0, 1, -1), (0, 1, 128 * 1024 * 1024 + 1), (Int64.max, Int.max, Int64.max)] {
            XCTAssertThrowsError(try ChatMediaByteRange(offset: offset, length: length, total: total))
        }
    }
    func testUnknownLengthExactChunksAndRequestHeaders() async throws {
        MediaRangeStub.chunks = [Data("1234".utf8), Data("5678".utf8)]
        let bytes = try await load()
        XCTAssertEqual(bytes, Data("12345678".utf8))
        XCTAssertEqual(MediaRangeStub.requestRange, "bytes=4-11")
        XCTAssertEqual(MediaRangeStub.requestEncoding, "identity")
    }
    func testClippedFinalRangeAcceptsOnlyItsExactContentRangeAndLength() async throws {
        let transfer = ChatMediaRangeRead(range: try .init(offset: 19, length: 8, total: 20), tlsIdentity: nil)
        MediaRangeStub.headers["Content-Range"] = "bytes 19-19/20"
        MediaRangeStub.headers["Content-Length"] = "1"; MediaRangeStub.chunks = [Data([1])]
        let bytes = try await load(transfer); XCTAssertEqual(bytes, Data([1]))
        XCTAssertEqual(MediaRangeStub.requestRange, "bytes=19-19")
    }
    func testWrongMalformedOverflowOrUnknownTotalContentRangesAreRejected() async throws {
        let invalid = ["bytes 4-11/21", "bytes 3-10/20", "bytes 4-12/20", "bytes 4-11/*", "bytes */20",
            "bytes 4-11/9223372036854775808", "bytes 4-18446744073709551616/20", "bytes 04-11/20", "Bytes 4-11/20",
            "bytes 4-11/20, bytes 4-11/20", "bytes 4-11/20 trailing", "bytes -1-11/20"]
        for header in invalid {
            MediaRangeStub.headers["Content-Range"] = header
            do { _ = try await load(); XCTFail("Invalid range accepted") }
            catch { XCTAssertEqual(error as? ChatMediaRangeReadError, .invalidResponse) }
        }
    }
    func testWrongOrMalformedDeclaredLengthRejectsBeforeStalledBodyCompletes() async {
        MediaRangeStub.completes = false; MediaRangeStub.chunks = [Data([1])]
        for length in ["9", "7", "-1", "18446744073709551616", "8,8"] {
            MediaRangeStub.headers["Content-Length"] = length
            do { _ = try await load(); XCTFail("Invalid declared length accepted") }
            catch { XCTAssertEqual(error as? ChatMediaRangeReadError, .invalidResponse) }
        }
    }
    func testMissingAttachmentOrInlineOrEncodedEnvelopeNeverAccepted() async {
        for variant in 0..<4 {
            MediaRangeStub.reset()
            switch variant {
            case 0: MediaRangeStub.headers.removeValue(forKey: "Content-Disposition")
            case 1: MediaRangeStub.headers["Content-Disposition"] = "inline; filename=test.mp4"
            case 2: MediaRangeStub.headers["Content-Disposition"] = "attachment-malformed"
            default: MediaRangeStub.headers["Content-Encoding"] = "gzip"
            }
            do { _ = try await load(); XCTFail("Nonattachment or compressed body accepted") }
            catch { XCTAssertEqual(error as? ChatMediaRangeReadError, .invalidResponse) }
        }
    }
    func testTruncatedAndOverlongBodiesNeverReturnPartialData() async {
        for chunks in [[Data("1234567".utf8)], [Data("1234".utf8), Data("56789".utf8)]] {
            MediaRangeStub.chunks = chunks
            do { _ = try await load(); XCTFail("Incorrect actual length accepted") }
            catch { XCTAssertEqual(error as? ChatMediaRangeReadError, .invalidResponse) }
        }
    }
    func testOversizeActualDataCancelsWithoutWaitingForServerEOF() async {
        let stopped = expectation(description: "Oversize read cancelled")
        MediaRangeStub.stopped = { stopped.fulfill() }; MediaRangeStub.completes = false
        MediaRangeStub.chunks = [Data("12345678".utf8), Data("x".utf8)]
        do { _ = try await load(); XCTFail() }
        catch { XCTAssertEqual(error as? ChatMediaRangeReadError, .invalidResponse) }
        await fulfillment(of: [stopped], timeout: 2)
    }
    func testFull200ResponseIsUnsupportedWithoutWaitingForBodyEOF() async {
        let stopped = expectation(description: "Full download refused")
        MediaRangeStub.status = 200; MediaRangeStub.completes = false
        MediaRangeStub.chunks = [Data("x".utf8)]; MediaRangeStub.stopped = { stopped.fulfill() }
        do { _ = try await load(); XCTFail() }
        catch { XCTAssertEqual(error as? ChatMediaRangeReadError, .unsupported) }
        await fulfillment(of: [stopped], timeout: 2)
    }
    func testFull200APIErrorIsNotEvidenceThatFileRangesAreUnsupported() async {
        MediaRangeStub.status = 200
        MediaRangeStub.headers = ["Content-Type": "application/json"]
        MediaRangeStub.chunks = [Data(#"{"success":false,"error":{"code":119}}"#.utf8)]
        do { _ = try await load(); XCTFail("API error classified as file range support") }
        catch { XCTAssertEqual(error as? ChatMediaRangeReadError, .invalidResponse) }
    }
    func testOtherStatusCodesAreInvalidRatherThanRangeUnsupported() async {
        for status in [302, 401, 404, 416, 500] {
            MediaRangeStub.status = status
            do { _ = try await load(); XCTFail() }
            catch { XCTAssertEqual(error as? ChatMediaRangeReadError, .invalidResponse) }
        }
    }
    func testCancellationStopsStalledReadAndRetiresSingleUseReader() async throws {
        let started = expectation(description: "Read started"), stopped = expectation(description: "Read stopped")
        MediaRangeStub.started = { started.fulfill() }; MediaRangeStub.stopped = { stopped.fulfill() }
        MediaRangeStub.completes = false; MediaRangeStub.chunks = [Data([1])]
        let transfer = ChatMediaRangeRead(range: try range(), tlsIdentity: nil)
        let task = Task { try await load(transfer) }
        await fulfillment(of: [started], timeout: 2); task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 2)
        do { _ = try await load(transfer); XCTFail() } catch { XCTAssertEqual(error as? ChatMediaRangeReadError, .alreadyUsed) }
    }
    func testPrecancelledReadDoesNotStartRequestAndSuccessfulReaderCannotBeReused() async throws {
        let transfer = ChatMediaRangeRead(range: try range(), tlsIdentity: nil)
        let task = Task { () throws -> Data in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transfer.load(request, configuration: configuration)
        }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(MediaRangeStub.starts, 0)
        let successful = ChatMediaRangeRead(range: try range(), tlsIdentity: nil)
        _ = try await load(successful)
        do { _ = try await load(successful); XCTFail() } catch { XCTAssertEqual(error as? ChatMediaRangeReadError, .alreadyUsed) }
        XCTAssertEqual(MediaRangeStub.starts, 1)
    }
    func testCancelledSecondCallerCannotCancelAnActiveFirstRead() async throws {
        let started = expectation(description: "First read started"), stopped = expectation(description: "First read stopped")
        MediaRangeStub.started = { started.fulfill() }; MediaRangeStub.stopped = { stopped.fulfill() }
        MediaRangeStub.completes = false; MediaRangeStub.chunks = [Data([1])]
        let transfer = ChatMediaRangeRead(range: try range(), tlsIdentity: nil)
        let first = Task { try await load(transfer) }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { () throws -> Data in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transfer.load(request, configuration: configuration)
        }
        do { _ = try await second.value; XCTFail() } catch { XCTAssertEqual(error as? ChatMediaRangeReadError, .alreadyUsed) }
        XCTAssertEqual(MediaRangeStub.starts, 1)
        first.cancel()
        do { _ = try await first.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 2)
    }
    func testRedirectRefusalAndTLSIdentityAreInherited() throws {
        let identity = try XCTUnwrap(ChatTLSIdentity(origin: URL(string: "https://media-range-fixture.invalid")!, serverName: "nas.example.invalid"))
        let transfer = ChatMediaRangeRead(range: try range(), tlsIdentity: identity)
        XCTAssertEqual(transfer.tlsIdentity?.serverName, identity.serverName)
        let session = URLSession(configuration: .ephemeral), task = session.dataTask(with: request)
        defer { session.invalidateAndCancel() }
        let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://other.invalid"]))
        var called = false
        transfer.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://other.invalid")!)) { forwarded in
            called = true; XCTAssertNil(forwarded)
        }
        XCTAssertTrue(called)
    }
}

private final class MediaRangeStub: URLProtocol {
    static var headers = baseHeaders
    static let baseHeaders = ["Content-Type": "video/mp4", "Content-Disposition": "attachment; filename=synthetic.mp4", "Content-Range": "bytes 4-11/20"]
    static var status = 206
    static var chunks = [Data("12345678".utf8)]
    static var completes = true
    static var started: (() -> Void)?
    static var stopped: (() -> Void)?
    static var requestRange: String?
    static var requestEncoding: String?
    static var starts = 0
    static func reset() {
        headers = baseHeaders; status = 206; chunks = [Data("12345678".utf8)]; completes = true
        started = nil; stopped = nil; requestRange = nil; requestEncoding = nil; starts = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var onStop: (() -> Void)?
    override func startLoading() {
        onStop = Self.stopped
        guard request.url?.host == "media-range-fixture.invalid" else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        Self.starts += 1; Self.requestRange = request.value(forHTTPHeaderField: "Range")
        Self.requestEncoding = request.value(forHTTPHeaderField: "Accept-Encoding")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: Self.headers)!, cacheStoragePolicy: .notAllowed)
        // A real media Content-Type plus a first chunk makes URLSession deliver
        // the response promptly even for a deliberately stalled fixture stream.
        for chunk in Self.chunks { client?.urlProtocol(self, didLoad: chunk) }
        Self.started?()
        if Self.completes { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { onStop?() }
}
