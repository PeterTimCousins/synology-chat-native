import XCTest
@testable import SynologyChatNative

final class ChatEncryptedUploadTests: XCTestCase {
    private let caption = "Synthetic caption must be encrypted."
    private let payload = Data("Synthetic encrypted attachment payload. No private data.\n".utf8)
    private func key() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ChatCrypto", withExtension: "json", subdirectory: "Fixtures"))
        let values = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return try ChatContentCrypto.decodeBase64(values["channelKey"] as! String)
    }
    private func source(name: String = "synthetic-secret-name.txt") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(name)
        try payload.write(to: file)
        return file
    }
    private func field(_ name: String, body: Data, boundary: String) throws -> String {
        let header = Data(("name=\"" + name + "\"\r\n\r\n").utf8)
        let start = try XCTUnwrap(body.range(of: header)).upperBound
        let end = try XCTUnwrap(body.range(of: Data(("\r\n--" + boundary).utf8), in: start..<body.count)).lowerBound
        return String(decoding: body[start..<end], as: UTF8.self)
    }
    private func filePart(_ body: Data, boundary: String) throws -> (name: String, bytes: Data) {
        let prefix = Data("name=\"file\"; filename=\"".utf8)
        let start = try XCTUnwrap(body.range(of: prefix)).upperBound
        let end = try XCTUnwrap(body.range(of: Data("\"\r\nContent-Type:".utf8), in: start..<body.count)).lowerBound
        let dataStart = try XCTUnwrap(body.range(of: Data("Content-Type: application/octet-stream\r\n\r\n".utf8))).upperBound
        let tail = Data(("\r\n--" + boundary + "--\r\n").utf8)
        XCTAssertEqual(body.suffix(tail.count), tail)
        return (String(decoding: body[start..<end], as: UTF8.self), Data(body[dataStart..<(body.count-tail.count)]))
    }

    func testMultipartContainsOnlyEncryptedPayloadFilenameAndCaptionWithCorrectReplyRoute() throws {
        let file = try source()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let key = try key(), boundary = "SyntheticEncryptedBoundary"
        let prepared = try ChatMultipartBody.preparePost(file: file, channelID: 23, caption: caption,
            connectionID: "synthetic", threadID: 123, boundary: boundary, limitBytes: 1024, encryptionKey: key)
        defer { NativeSnippetTemporaryFiles.shared.remove(prepared.body) }
        let body = try Data(contentsOf: prepared.body)
        XCTAssertNil(body.range(of: payload))
        XCTAssertNil(body.range(of: Data(file.lastPathComponent.utf8)))
        XCTAssertNil(body.range(of: Data(caption.utf8)))
        let part = try filePart(body, boundary: boundary)
        XCTAssertEqual(part.name, prepared.wireFilename)
        XCTAssertEqual(try ChatContentCrypto.decryptFilename(part.name, key: key), file.lastPathComponent)
        XCTAssertEqual(try ChatContentCrypto.decryptAttachment(part.bytes, key: key), payload)
        XCTAssertEqual(try ChatContentCrypto.decryptMessage(field("message", body: body, boundary: boundary), key: key), caption)
        XCTAssertEqual(try field("thread_id", body: body, boundary: boundary), "123")
        XCTAssertNil(body.range(of: Data("name=\"is_thread\"".utf8)))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: prepared.body.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try Data(contentsOf: file), payload, "The source is never modified")
    }

    func testLongEncryptedFilenameDoesNotBecomeFilesystemPathAndCiphertextUsesFreshNonces() throws {
        let file = try source(name: String(repeating: "a", count: 190) + ".txt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let key = try key()
        let first = try ChatMultipartBody.preparePost(file: file, channelID: 23, caption: caption, connectionID: "s", threadID: 0, boundary: "b", limitBytes: 0, encryptionKey: key)
        defer { try? FileManager.default.removeItem(at: first.body) }
        let second = try ChatMultipartBody.preparePost(file: file, channelID: 23, caption: caption, connectionID: "s", threadID: 0, boundary: "b", limitBytes: 0, encryptionKey: key)
        defer { try? FileManager.default.removeItem(at: second.body) }
        XCTAssertGreaterThan(first.wireFilename.utf8.count, 255)
        XCTAssertEqual(try ChatContentCrypto.decryptFilename(first.wireFilename, key: key), file.lastPathComponent)
        XCTAssertNotEqual(first.wireFilename, second.wireFilename)
        XCTAssertNotEqual(try Data(contentsOf: first.body), try Data(contentsOf: second.body))
    }

    func testWrongKeyAndCiphertextSizeOverheadAreRejectedBeforeUpload() throws {
        let file = try source()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertThrowsError(try ChatMultipartBody.preparePost(file: file, channelID: 23, caption: caption, connectionID: "s",
            threadID: 0, boundary: "b", limitBytes: 0, encryptionKey: Data(repeating: 0, count: 31)))
        XCTAssertThrowsError(try ChatMultipartBody.preparePost(file: file, channelID: 23, caption: caption, connectionID: "s",
            threadID: 0, boundary: "b", limitBytes: Int64(payload.count + 39), encryptionKey: key()))
        XCTAssertEqual(try Data(contentsOf: file), payload)
    }

    func testAPIEncryptsActualMultipartAndValidatesCanonicalEncryptedFilenameWithoutRetry() async throws {
        let file = try source()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()); EncryptedUploadStub.handler = nil }
        let key = try key()
        var uploads = 0
        EncryptedUploadStub.handler = { request in
            if request.url!.path.contains("SYNO.API.Info") {
                return Data(#"{"success":true,"data":{"SYNO.Chat.Admin.Setting":{"path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"},"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"}}}"#.utf8)
            }
            if request.url!.path.contains("SYNO.Chat.Admin.Setting") { return Data(#"{"success":true,"data":{"file_size_limit":1}}"#.utf8) }
            uploads += 1
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; body.append(contentsOf: bytes.prefix(count)) }
            }
            let boundary = request.value(forHTTPHeaderField: "Content-Type")!.components(separatedBy: "boundary=")[1]
            let part = try self.filePart(body, boundary: boundary)
            XCTAssertEqual(try ChatContentCrypto.decryptAttachment(part.bytes, key: key), self.payload)
            XCTAssertEqual(try ChatContentCrypto.decryptFilename(part.name, key: key), file.lastPathComponent)
            let encodedCaption = try self.field("message", body: body, boundary: boundary)
            XCTAssertEqual(try ChatContentCrypto.decryptMessage(encodedCaption, key: key), self.caption)
            let filename = uploads == 1 ? part.name : "incorrect-response-filename"
            return try JSONSerialization.data(withJSONObject: ["success": true, "data": ["post_id": 100, "channel_id": 23,
                "creator_id": 10, "message": encodedCaption, "type": "file", "create_at": 1000, "thread_id": 0, "file_props": ["name": filename]]])
        }
        func network() -> URLSession { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [EncryptedUploadStub.self]; return URLSession(configuration: config) }
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://synthetic.test")!, sid: "s", synoToken: "s"), network: network(), makeAttachmentNetwork: network)
        try await api.discover()
        let result = try await api.uploadAttachment(channelID: 23, file: file, caption: caption, connectionID: "s", encryptionKey: key)
        XCTAssertEqual(try ChatContentCrypto.decryptFilename(result.file_props!.name!, key: key), file.lastPathComponent)
        do { _ = try await api.uploadAttachment(channelID: 23, file: file, caption: caption, connectionID: "s", encryptionKey: key); XCTFail("Mismatched canonical filename must fail") }
        catch let error as ChatTransferError { XCTAssertTrue(error.deliveryNeedsReview,"Accepted upload with an unexpected encrypted filename needs review before retry") }
        XCTAssertEqual(uploads, 2, "Only the two explicit attempts; malformed response must not trigger retry")
    }
}

private final class EncryptedUploadStub: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
