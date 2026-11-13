import XCTest
@testable import SynologyChatNative

final class ChatUploadProgressTests: XCTestCase {
    func testProgressIsMonotonicAndBelongsOnlyToItsUpload() {
        let id = UUID()
        var progress = ChatUploadProgress(id: id)
        XCTAssertNil(progress.fraction)
        XCTAssertEqual(progress.label, "Preparing attachment…")
        progress.update(id: id, sent: 25, total: 100)
        XCTAssertEqual(progress.fraction, 0.25)
        let current = progress
        progress.update(id: UUID(), sent: 90, total: 100)
        progress.update(id: id, sent: 10, total: 100)
        progress.update(id: id, sent: -1, total: 100)
        XCTAssertEqual(progress, current, "Old upload, out-of-order and invalid callbacks cannot repaint progress")
        progress.update(id: id, sent: 100, total: 100)
        XCTAssertEqual(progress.fraction, 1)
    }
    func testUnknownTotalsRemainIndeterminateAndInconsistentTotalsCannotExceedOne() {
        let id = UUID()
        var progress = ChatUploadProgress(id: id)
        progress.update(id: id, sent: 20, total: -1)
        XCTAssertNil(progress.fraction)
        XCTAssertTrue(progress.label.hasPrefix("Uploading "))
        progress.update(id: id, sent: 30, total: 10)
        XCTAssertEqual(progress.total, 30)
        XCTAssertEqual(progress.fraction, 1)
    }
    func testAttachmentDelegateReportsActualTransportByteTotalsAndKeepsTLSScope() throws {
        let record = ProgressRecord()
        let session = ChatSession(baseURL: URL(string: "https://203.0.113.10:62443")!, sid: "s", synoToken: "s", tlsServerName: "nas.synthetic.test")
        let api = try ChatAPIClient(session: session)
        let delegate = api.makeConnectionDelegate(onUploadProgress: { sent, total in record.append(sent, total) })
        XCTAssertTrue(delegate.tlsIdentity?.matches(host: "203.0.113.10", port: 62443) == true)
        let network = URLSession(configuration: .ephemeral)
        defer { network.invalidateAndCancel() }
        let task = network.dataTask(with: session.baseURL)
        delegate.urlSession(network, task: task, didSendBodyData: 25, totalBytesSent: 50, totalBytesExpectedToSend: 100)
        XCTAssertEqual(record.values.map { $0.0 }, [50])
        XCTAssertEqual(record.values.map { $0.1 }, [100])
    }
}
private final class ProgressRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(Int64, Int64)] = []
    var values: [(Int64, Int64)] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ sent: Int64, _ total: Int64) { lock.lock(); defer { lock.unlock() }; stored.append((sent, total)) }
}
