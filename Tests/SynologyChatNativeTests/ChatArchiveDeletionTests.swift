import XCTest
@testable import SynologyChatNative

@MainActor final class ChatArchiveDeletionTests: XCTestCase {
    private let scope = String(repeating: "a", count: 64)
    private let otherScope = String(repeating: "b", count: 64)
    private func archive(id: Int64 = 26, encrypted: Bool = false, kind: String = "private", reason: String = "channel_archived", end: Int64 = 200) throws -> ChatArchive {
        let object: [String: Any] = ["archive_id": id, "post_start": 1000, "post_end": 2000,
            "post_id_start": 100, "post_id_end": end, "props": ["reason": reason, "trigger_user_id": 10,
                "channel": ["channel_id": 97, "name": "Synthetic test", "type": kind, "encrypted": encrypted, "unread": 0]]]
        return try JSONDecoder().decode(ChatArchive.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func manager(directory: URL? = nil) -> ChatArchiveDeletionCoordinator {
        let value = ChatArchiveDeletionCoordinator(journal: .init(directory: directory))
        value.activate(scope: scope, ownerID: 10); return value
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("archive-deletion-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func prepare(_ value: ChatArchiveDeletionCoordinator, _ item: ChatArchive) async throws -> ChatArchiveDeletionPreparation {
        try await value.prepare(archive: item, kind: ChatArchiveKind(rawValue: item.props.channel.type)!, name: "Synthetic test", accountGeneration: 4, load: { _, _ in [item] }, checkCurrent: {})
    }
    func testReviewedEncryptedArchiveDeletesOnlyAfterFreshReadAndCanonicalAbsence() async throws {
        let value = manager(), item = try archive(encrypted: true), prep = try await prepare(value, item)
        XCTAssertFalse(item.isReadable); XCTAssertEqual(prep.accountGeneration, 4)
        var reads = 0, writes = 0
        try await value.delete(prep, load: { kind, name in
            XCTAssertEqual(kind, .private); XCTAssertEqual(name, "Synthetic test")
            reads += 1; return reads == 1 ? [item] : []
        }, dispatch: { id in
            XCTAssertEqual(id, 26); XCTAssertEqual(value.pending.count, 1); writes += 1
        }, checkCurrent: {})
        XCTAssertEqual(reads, 2); XCTAssertEqual(writes, 1); XCTAssertTrue(value.pending.isEmpty); XCTAssertFalse(value.busy)
    }
    func testChangedBoundaryOrReasonAndMissingArchiveCannotDispatch() async throws {
        let item = try archive()
        for list in [[try archive(end: 201)], [try archive(reason: "channel_closed")], []] {
            let value = manager(), prep = try await prepare(value, item); var writes = 0
            do { try await value.delete(prep, load: { _, _ in list }, dispatch: { _ in writes += 1 }, checkCurrent: {}); XCTFail() } catch { }
            XCTAssertEqual(writes, 0); XCTAssertTrue(value.pending.isEmpty)
        }
    }
    func testMalformedDuplicateOrWrongCategoryListCannotAuthorizeAbsence() async throws {
        let item = try archive(), value = manager(), prep = try await prepare(value, item)
        do { try await value.delete(prep, load: { _, _ in [item] }, dispatch: { _ in throw URLError(.timedOut) }, checkCurrent: {}); XCTFail() } catch { }
        let record = try XCTUnwrap(value.pending.first)
        for list in [[item, item], [try archive(id: -1)], [try archive(kind: "public")]] {
            do { _ = try await value.checkOutcome(record, load: { _, _ in list }, checkCurrent: {}); XCTFail() } catch { }
            XCTAssertEqual(value.pending, [record])
        }
    }
    func testLostResponseSurvivesRelaunchAndReadOnlyRecoveryNeverReplays() async throws {
        let directory = try folder(), value = manager(directory: directory), item = try archive(), prep = try await prepare(value, item)
        var writes = 0
        do { try await value.delete(prep, load: { _, _ in [item] }, dispatch: { _ in writes += 1; throw URLError(.networkConnectionLost) }, checkCurrent: {}); XCTFail() } catch { }
        let restarted = manager(directory: directory), record = try XCTUnwrap(restarted.pending.first)
        let present = try await restarted.checkOutcome(record, load: { _, _ in [item] }, checkCurrent: {})
        XCTAssertFalse(present); XCTAssertEqual(restarted.pending, [record])
        let absent = try await restarted.checkOutcome(record, load: { _, _ in [] }, checkCurrent: {})
        XCTAssertTrue(absent); XCTAssertTrue(manager(directory: directory).pending.isEmpty); XCTAssertEqual(writes, 1)
    }
    func testAcknowledgementAloneOrReadbackErrorKeepsReceipt() async throws {
        for failure in [false, true] {
            let value = manager(), item = try archive(), prep = try await prepare(value, item); var reads = 0
            do {
                try await value.delete(prep, load: { _, _ in
                    reads += 1; if reads == 2 && failure { throw ChatAPIError.server(105) }; return [item]
                }, dispatch: { _ in }, checkCurrent: {})
                XCTFail()
            } catch { }
            XCTAssertEqual(value.pending.count, 1, "A readback rejection is not a dispatch rejection")
        }
    }
    func testExplicitDispatchServerRejectionReleasesReceiptButUnknownFailuresDoNot() async throws {
        let failures: [Error] = [ChatAPIError.server(105), ChatAPIError.http(403), ChatAPIError.invalidResponse, CancellationError()]
        for (index, error) in failures.enumerated() {
            let value = manager(), item = try archive(), prep = try await prepare(value, item)
            do { try await value.delete(prep, load: { _, _ in [item] }, dispatch: { _ in throw error }, checkCurrent: {}); XCTFail() }
            catch { if index == 0 { guard case .server(105) = error as? ChatAPIError else { return XCTFail("Original refusal lost") } } }
            XCTAssertEqual(value.pending.isEmpty, index == 0)
        }
    }
    func testPredispatchCancellationRemovesReceiptOnOriginalScope() async throws {
        let directory = try folder(), value = manager(directory: directory), item = try archive(), prep = try await prepare(value, item)
        var checks = 0, writes = 0
        do {
            try await value.delete(prep, load: { _, _ in [item] }, dispatch: { _ in writes += 1 }, checkCurrent: {
                checks += 1
                if checks == 3 { value.activate(scope: self.otherScope, ownerID: 11); throw CancellationError() }
            }); XCTFail()
        } catch { }
        XCTAssertEqual(writes, 0); XCTAssertTrue(value.pending.isEmpty)
        XCTAssertTrue(manager(directory: directory).pending.isEmpty, "Original scope's known-undispatched record must be removed")
    }
    func testOldPreparationCannotCrossAccountOrActivationRevision() async throws {
        for owner in [Int64(10), 11] {
            let value = manager(), item = try archive(), prep = try await prepare(value, item); var writes = 0
            value.activate(scope: owner == 10 ? scope : otherScope, ownerID: owner)
            do { try await value.delete(prep, load: { _, _ in [item] }, dispatch: { _ in writes += 1 }, checkCurrent: {}); XCTFail() } catch { }
            XCTAssertEqual(writes, 0)
        }
    }
    func testRetirementAfterDispatchPreservesOriginalReceiptWithoutPublishingToNewAccount() async throws {
        let directory = try folder(), value = manager(directory: directory), item = try archive(), prep = try await prepare(value, item)
        do {
            try await value.delete(prep, load: { _, _ in [item] }, dispatch: { _ in value.activate(scope: self.otherScope, ownerID: 11) }, checkCurrent: {})
            XCTFail()
        } catch { }
        XCTAssertTrue(value.pending.isEmpty); XCTAssertFalse(value.busy)
        XCTAssertEqual(manager(directory: directory).pending.count, 1)
    }
    func testConcurrentProcessReceiptBlocksDuplicateDeleteAndHasPrivateBoundedMetadata() async throws {
        let directory = try folder(), one = manager(directory: directory), two = manager(directory: directory), item = try archive()
        let p1 = try await prepare(one, item), p2 = try await prepare(two, item); var writes = 0
        do { try await one.delete(p1, load: { _, _ in [item] }, dispatch: { _ in writes += 1; throw URLError(.timedOut) }, checkCurrent: {}); XCTFail() } catch { }
        do { try await two.delete(p2, load: { _, _ in [item] }, dispatch: { _ in writes += 1 }, checkCurrent: {}); XCTFail() } catch { }
        XCTAssertEqual(writes, 1)
        let file = directory.appendingPathComponent(scope + ".json"), data = try Data(contentsOf: file)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("channel_key")); XCTAssertFalse(text.contains("post_start"))
        XCTAssertTrue(text.contains("fingerprint")); XCTAssertLessThan(data.count, 4096)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testInvalidIdentityAndRecoveryOwnerCannotAuthorizeDeletion() async throws {
        let item = try archive(), value = manager()
        do { _ = try await value.prepare(archive: item, kind: .public, name: "Synthetic test", accountGeneration: 4, load: { _, _ in [item] }, checkCurrent: {}); XCTFail() } catch { }
        let directory = try folder(), journal = ChatArchiveDeletionJournal(directory: directory)
        _ = try journal.activate(scope: scope)
        try journal.remember(.init(archive: item, kind: .private, name: "Synthetic test", ownerID: 11))
        let wrongOwner = manager(directory: directory)
        XCTAssertNotNil(wrongOwner.recoveryError); XCTAssertTrue(wrongOwner.pending.isEmpty)
    }
    func testReadOnlyCheckRetiredDuringAwaitCannotClearOriginalReceipt() async throws {
        let directory = try folder(), value = manager(directory: directory), item = try archive(), prep = try await prepare(value, item)
        do { try await value.delete(prep, load: { _, _ in [item] }, dispatch: { _ in throw URLError(.timedOut) }, checkCurrent: {}); XCTFail() } catch { }
        let record = try XCTUnwrap(value.pending.first)
        do { _ = try await value.checkOutcome(record, load: { _, _ in value.deactivate(); return [] }, checkCurrent: {}); XCTFail() } catch { }
        XCTAssertEqual(manager(directory: directory).pending, [record])
    }
    func testDeleteWireUsesOnlyArchiveIDAtV1AndRejectsInvalidIDsWithoutNetwork() async throws {
        ArchiveDeletionProtocol.calls = []
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ArchiveDeletionProtocol.self]
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://archive-delete-fixture.invalid")!, sid: "synthetic", synoToken: "synthetic"), network: URLSession(configuration: configuration))
        try await api.discover(); ArchiveDeletionProtocol.calls = []
        for id in [Int64(0), -1] { do { try await api.deleteArchive(id: id); XCTFail() } catch { } }
        XCTAssertTrue(ArchiveDeletionProtocol.calls.isEmpty)
        try await api.deleteArchive(id: 26)
        let fields = try XCTUnwrap(ArchiveDeletionProtocol.calls.last)
        XCTAssertEqual(fields["api"], "SYNO.Chat.Archive"); XCTAssertEqual(fields["method"], "delete")
        XCTAssertEqual(fields["version"], "1"); XCTAssertEqual(fields["archive_id"], "26")
        XCTAssertNil(fields["channel_id"]); XCTAssertNil(fields["type"]); XCTAssertNil(fields["channel_name"])
    }
}

private final class ArchiveDeletionProtocol: URLProtocol {
    static var calls: [[String: String]] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "archive-delete-fixture.invalid" else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable && data.count < 16_384 {
                let count = stream.read(&bytes, maxLength: min(bytes.count, 16_384 - data.count))
                if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count))
            }
        }
        var form = URLComponents(); form.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        let items = (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []) + (form.queryItems ?? [])
        var fields = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        let api = fields["api"] ?? request.url!.lastPathComponent; fields["api"] = api
        let response: [String: Any]
        if api == "SYNO.API.Info" {
            response = ["success": true, "data": ["SYNO.Chat.Archive": ["path": "entry.cgi", "minVersion": 1, "maxVersion": 1, "requestFormat": "JSON"]]]
        } else { Self.calls.append(fields); response = ["success": true] }
        let bytes = try! JSONSerialization.data(withJSONObject: response)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
