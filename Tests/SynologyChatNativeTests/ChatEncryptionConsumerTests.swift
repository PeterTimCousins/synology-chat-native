import XCTest
import AppKit
@testable import SynologyChatNative

@MainActor
final class ChatEncryptionConsumerTests: XCTestCase {
    func testDevelopmentUIFixtureBootstrapsLocallyAndUsesRealUnlockLockConsumers() async throws {
        let f = try fixture()
        let model = try NativeEncryptedUIFixture.makeModel()
        await NativeEncryptedUIFixture.connect(model)
        XCTAssertTrue(model.connected)
        XCTAssertTrue(model.hasEncryptionKeyPair)
        XCTAssertEqual(model.liveStatus, .rejected, "Fixture cannot enable live writes")
        model.selection = 23; model.loadSelection()
        XCTAssertFalse(model.canRead(23))
        XCTAssertThrowsError(try model.unlockEncryption(password: "Incorrect synthetic password"))
        XCTAssertFalse(model.encryptionUnlocked)
        try model.unlockEncryption(password: f.password)
        await model.historyTask?.value
        XCTAssertTrue(model.encryptionUnlocked)
        XCTAssertEqual(model.posts.count, 1)
        XCTAssertEqual(model.messageText(try XCTUnwrap(model.posts.first)), f.message)
        XCTAssertFalse(model.canSend)
        model.lockEncryption()
        XCTAssertFalse(model.canRead(23))
        XCTAssertTrue(model.posts.isEmpty)
        model.signOutLocally()
    }

    private struct Fixture: Decodable {
        let password, publicKey, wrappedPrivateKey, wrappedChannelKey, channelKey: String
        let message, encryptedMessage, filename, encryptedFilename, attachment, encryptedAttachment: String
        var pair: ChatEncryptionKeyPair { .init(public_key: publicKey, private_key_enc: wrappedPrivateKey) }
    }
    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ChatCrypto", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    private func channel(_ f: Fixture, envelope: String? = nil) throws -> ChatChannel {
        let object: [String: Any] = ["channel_id": 23, "name": "Synthetic encrypted", "type": "private", "encrypted": true,
                                    "unread": 0, "channel_key_enc": envelope ?? f.wrappedChannelKey]
        return try JSONDecoder().decode(ChatChannel.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func post(_ f: Fixture) throws -> ChatPost {
        let object: [String: Any] = ["post_id": 100, "channel_id": 23, "creator_id": 20, "message": f.encryptedMessage,
            "type": "file", "create_at": 1000, "thread_id": 0, "file_props": ["name": f.encryptedFilename, "size": 296, "is_image": true]]
        return try JSONDecoder().decode(ChatPost.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testOtherUsersMayPublishOnlyTheirPublicKey() throws {
        let user = try JSONDecoder().decode(ChatUser.self, from: Data(#"{"user_id":20,"nickname":"Synthetic peer","user_props":{"key_pair":{"public_key":"synthetic-public-only"}}}"#.utf8))
        XCTAssertEqual(user.user_props?.key_pair?.public_key, "synthetic-public-only")
        XCTAssertFalse(user.user_props?.key_pair?.isInitialized ?? true)
    }

    func testNativeModelDecryptsPresentationAndEncryptsOutgoingText() throws {
        let f = try fixture()
        let keys = ChatEncryptionSession()
        try keys.unlock(f.pair, password: f.password)
        let model = NativeChatPreviewModel(encryption: keys)
        model.channels = [try channel(f)]; model.selection = 23
        model.connected = true; model.liveStatus = .live
        model.draft = "Synthetic outgoing plaintext"
        XCTAssertTrue(model.canSend)
        XCTAssertEqual(model.messageText(try post(f)), f.message)
        XCTAssertEqual(model.attachmentName(try post(f)), f.filename)
        let wire = try model.wireMessage(model.draft, channelID: 23)
        XCTAssertNotEqual(wire, model.draft)
        XCTAssertEqual(try ChatContentCrypto.decryptMessage(wire, key: ChatContentCrypto.decodeBase64(f.channelKey)), model.draft)
    }

    func testLockRemovesKeysAndEncryptedDraftsAndBlocksPlaintextFallback() throws {
        let f = try fixture()
        let keys = ChatEncryptionSession()
        try keys.unlock(f.pair, password: f.password)
        let model = NativeChatPreviewModel(encryption: keys)
        model.channels = [try channel(f)]; model.selection = 23
        model.connected = true; model.liveStatus = .live
        model.draft = "Synthetic sensitive draft"
        model.beginMessageEditing(owner: UUID())
        model.threadRoot = try post(f); model.replyDraft = "Synthetic sensitive reply"
        model.lockEncryption()
        XCTAssertFalse(keys.isUnlocked)
        XCTAssertFalse(model.isEditingMessage)
        XCTAssertFalse(model.encryptionUnlocked)
        XCTAssertFalse(model.canSend)
        XCTAssertNil(model.drafts[23]); XCTAssertNil(model.threadDrafts[100])
        XCTAssertEqual(model.messageText(try post(f)), "Encrypted message")
        XCTAssertEqual(model.attachmentName(try post(f)), "Encrypted attachment")
        XCTAssertThrowsError(try model.wireMessage("Must never send plainly", channelID: 23))
        XCTAssertThrowsError(try model.wireMessage("Unknown conversation", channelID: 999))
    }

    func testEncryptedThreadDraftUsesRootChannelAcrossSelectionChange() throws {
        let f = try fixture()
        let keys = ChatEncryptionSession(); try keys.unlock(f.pair,password:f.password)
        let model = NativeChatPreviewModel(encryption:keys)
        let ordinary = try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":24,"name":"Ordinary","type":"private","encrypted":false,"unread":0}"#.utf8))
        model.channels = [try channel(f),ordinary]; model.selection = 23
        model.connected = true; model.liveStatus = .live; model.threadRoot = try post(f)
        model.replyDraft = "First encrypted draft"
        XCTAssertTrue(model.canReply); XCTAssertTrue(model.canComposeInThread)
        model.selection = 24
        model.draft = "Ordinary main draft"
        model.replyDraft = "Encrypted draft during navigation"
        XCTAssertFalse(model.canReply); XCTAssertFalse(model.canComposeInThread)
        model.lockEncryption(reload:false)
        XCTAssertNil(model.threadDrafts[100])
        XCTAssertNil(model.threadRoot)
        XCTAssertEqual(model.drafts[24],"Ordinary main draft")
    }

    func testOrdinaryThreadDraftIsNotMisclassifiedBySelectedEncryptedChannel() throws {
        let f = try fixture()
        let keys = ChatEncryptionSession(); try keys.unlock(f.pair,password:f.password)
        let model = NativeChatPreviewModel(encryption:keys)
        let ordinary = try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":24,"name":"Ordinary","type":"private","encrypted":false,"unread":0}"#.utf8))
        let root = try JSONDecoder().decode(ChatPost.self,from:Data(#"{"post_id":200,"channel_id":24,"creator_id":10,"message":"Ordinary root","type":"normal","create_at":1000}"#.utf8))
        model.channels = [try channel(f),ordinary]; model.selection = 23
        model.connected = true; model.liveStatus = .live; model.threadRoot = root
        model.draft = "Encrypted main draft"
        model.replyDraft = "Ordinary reply draft"
        XCTAssertFalse(model.canReply)
        model.lockEncryption(reload:false)
        XCTAssertNil(model.drafts[23])
        XCTAssertEqual(model.threadDrafts[200],"Ordinary reply draft")
        XCTAssertNil(model.threadRoot)
    }

    func testUnknownThreadOwnershipIsClearedConservativelyOnLock() throws {
        let f = try fixture()
        let model = NativeChatPreviewModel()
        model.threadRoot = try post(f)
        model.replyDraft = "Sensitive draft with unavailable channel metadata"
        XCTAssertFalse(model.canComposeInThread)
        model.lockEncryption(reload:false)
        XCTAssertNil(model.threadDrafts[100])
        XCTAssertNil(model.threadRoot)
    }

    func testWrongPasswordOrMismatchedPublicKeyLeavesSessionLocked() throws {
        let f = try fixture()
        let keys = ChatEncryptionSession()
        try keys.unlock(f.pair, password: f.password)
        XCTAssertThrowsError(try keys.unlock(f.pair, password: "Incorrect synthetic password"))
        XCTAssertFalse(keys.isUnlocked)
        let mismatch = ChatEncryptionKeyPair(public_key: Data(repeating: 7, count: 32).base64EncodedString(), private_key_enc: f.wrappedPrivateKey)
        XCTAssertThrowsError(try keys.unlock(mismatch, password: f.password))
        XCTAssertFalse(keys.isUnlocked)
    }

    func testChangedChannelEnvelopeCannotReuseCachedOldKey() throws {
        let f = try fixture()
        let keys = ChatEncryptionSession()
        try keys.unlock(f.pair, password: f.password)
        XCTAssertEqual(try keys.key(for: channel(f)), try ChatContentCrypto.decodeBase64(f.channelKey))
        XCTAssertThrowsError(try keys.key(for: channel(f, envelope: "invalid ciphertext")))
    }

    private func previewAPI() throws -> ChatAPIClient {
        func network() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [EncryptedDownloadStub.self]
            return URLSession(configuration: configuration)
        }
        return try ChatAPIClient(session: .init(baseURL: URL(string: "https://synthetic.test")!, sid: "synthetic", synoToken: "synthetic"),
                                 network: network(), makeAttachmentNetwork: network)
    }

    func testEncryptedImagePreviewAuthenticatesAndLockPreventsCachedPlaintextAccess() async throws {
        let f = try fixture()
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX2cAAAAASUVORK5CYII="))
        let key = try ChatContentCrypto.decodeBase64(f.channelKey)
        EncryptedDownloadStub.payload = try ChatContentCrypto.encryptAttachment(png, key: key)
        defer { EncryptedDownloadStub.payload = Data() }
        let api = try previewAPI()
        try await api.discover()
        let plaintext = try await api.encryptedImageData(postID: 100, key: key)
        XCTAssertEqual(plaintext, png)
        do {
            _ = try await api.encryptedImageData(postID: 100, key: Data(repeating: 0, count: 32))
            XCTFail("Unauthenticated preview must fail")
        } catch ChatCryptoError.authenticationFailed { }
        let keys = ChatEncryptionSession()
        try keys.unlock(f.pair, password: f.password)
        let model = NativeChatPreviewModel(client: api, encryption: keys)
        model.channels = [try channel(f)]
        let attachment = try post(f)
        let image = await model.thumbnail(for: attachment)
        XCTAssertEqual(image?.size, NSSize(width: 1, height: 1))
        model.lockEncryption(reload: false)
        XCTAssertFalse(model.canPreviewThumbnail(attachment))
        let locked = await model.thumbnail(for: attachment)
        XCTAssertNil(locked, "Lock must block both cached and new decrypted previews")
    }

    func testLockCancelsEncryptedImagePreviewAlreadyInFlight() async throws {
        let f = try fixture()
        let started = expectation(description: "Preview download started")
        let stopped = expectation(description: "Preview underlying request cancelled")
        EncryptedDownloadStub.stall = true
        EncryptedDownloadStub.onDownload = { started.fulfill() }
        EncryptedDownloadStub.onStop = { stopped.fulfill() }
        defer { EncryptedDownloadStub.stall = false; EncryptedDownloadStub.onDownload = nil; EncryptedDownloadStub.onStop = nil }
        let api = try previewAPI()
        try await api.discover()
        let keys = ChatEncryptionSession()
        try keys.unlock(f.pair, password: f.password)
        let model = NativeChatPreviewModel(client: api, encryption: keys)
        model.channels = [try channel(f)]
        let attachment = try post(f)
        let task = Task { await model.thumbnail(for: attachment) }
        await fulfillment(of: [started], timeout: 2)
        model.lockEncryption(reload: false)
        let result = await task.value
        XCTAssertNil(result)
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testImagePreviewDownsamplesOversizedImagesAndRejectsNonImages() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4096, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let image = try XCTUnwrap(NativeImagePreview.decode(png))
        XCTAssertLessThanOrEqual(image.size.width, 640)
        XCTAssertLessThanOrEqual(image.size.height, 640)
        XCTAssertNil(NativeImagePreview.decode(Data("Synthetic non-image".utf8)))
    }

    func testSaveDialogCannotStartDownloadAfterEncryptionOrSessionInvalidation() async throws {
        let f = try fixture()
        for invalidation in ["lock", "relock", "envelope", "cancel", "signout"] {
            let keys = ChatEncryptionSession()
            try keys.unlock(f.pair, password: f.password)
            var downloads = 0
            func network() -> URLSession {
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [EncryptedDownloadStub.self]
                return URLSession(configuration: config)
            }
            let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://synthetic.test")!, sid: "synthetic", synoToken: "synthetic"),
                network: network(), makeAttachmentNetwork: { downloads += 1; return network() })
            try await api.discover()
            let model = NativeChatPreviewModel(client: api, encryption: keys)
            model.channels = [try channel(f)]; model.selection = 23
            let target = try post(f)
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            let shown = expectation(description: "Save dialog pending: " + invalidation)
            var resume: CheckedContinuation<URL?, Never>?
            let operation = Task {
                await model.saveAttachment(target, chooseDestination: { _ in
                    await withCheckedContinuation { resume = $0; shown.fulfill() }
                })
            }
            await fulfillment(of: [shown], timeout: 2)
            XCTAssertEqual(model.downloading, [target.id])
            switch invalidation {
            case "lock": model.lockEncryption(reload: false)
            case "relock":
                model.lockEncryption(reload: false)
                try keys.unlock(f.pair, password: f.password)
                XCTAssertTrue(model.canRead(23), "Re-unlocking must not revive the old save intent")
            case "envelope": model.channels = [try channel(f, envelope: "Changed envelope")]
            case "cancel": operation.cancel()
            default: model.signOutLocally()
            }
            resume?.resume(returning: destination)
            await operation.value
            XCTAssertEqual(downloads, 0, invalidation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), invalidation)
            XCTAssertTrue(model.downloading.isEmpty, invalidation)
            model.signOutLocally()
        }
    }

    func testPendingSaveDialogBlocksDuplicateAndCancelReleasesReservation() async throws {
        let f = try fixture()
        let keys = ChatEncryptionSession()
        try keys.unlock(f.pair, password: f.password)
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://synthetic.test")!, sid: "synthetic", synoToken: "synthetic"))
        let model = NativeChatPreviewModel(client: api, encryption: keys)
        model.channels = [try channel(f)]; model.selection = 23
        let target = try post(f)
        let shown = expectation(description: "First dialog pending")
        var resume: CheckedContinuation<URL?, Never>?
        let operation = Task {
            await model.saveAttachment(target, chooseDestination: { _ in
                await withCheckedContinuation { resume = $0; shown.fulfill() }
            })
        }
        await fulfillment(of: [shown], timeout: 2)
        await model.saveAttachment(target, chooseDestination: { _ in XCTFail("Duplicate save dialog"); return nil })
        resume?.resume(returning: nil)
        await operation.value
        XCTAssertTrue(model.downloading.isEmpty)
        var reopened = false
        await model.saveAttachment(target, chooseDestination: { _ in reopened = true; return nil })
        XCTAssertTrue(reopened)
        XCTAssertTrue(model.downloading.isEmpty)
        model.signOutLocally()
    }

    func testNativeCancelDownloadStopsTransferAndKeepsExistingFile() async throws {
        let f = try fixture()
        let keys = ChatEncryptionSession()
        try keys.unlock(f.pair, password: f.password)
        let started = expectation(description: "Native download started")
        let stopped = expectation(description: "Native download stopped")
        EncryptedDownloadStub.stall = true
        EncryptedDownloadStub.onDownload = { started.fulfill() }
        EncryptedDownloadStub.onStop = { stopped.fulfill() }
        defer { EncryptedDownloadStub.stall = false; EncryptedDownloadStub.onDownload = nil; EncryptedDownloadStub.onStop = nil }
        func network() -> URLSession {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [EncryptedDownloadStub.self]
            return URLSession(configuration: config)
        }
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://synthetic.test")!, sid: "synthetic", synoToken: "synthetic"),
                                    network: network(), makeAttachmentNetwork: network)
        try await api.discover()
        let model = NativeChatPreviewModel(client: api, encryption: keys)
        model.channels = [try channel(f)]; model.selection = 23
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let existing = Data("Existing synthetic document".utf8)
        try existing.write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        let target = try post(f)
        let operation = Task { await model.saveAttachment(target, chooseDestination: { _ in destination }) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.downloading, [target.id])
        model.cancelDownload(postID: target.id)
        await operation.value
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertTrue(model.downloading.isEmpty)
        XCTAssertNil(model.error)
        XCTAssertEqual(try Data(contentsOf: destination), existing)
        model.signOutLocally()
    }

    func testCancellingEncryptedDownloadDoesNotReplaceDestination() async throws {
        let f = try fixture()
        let started = expectation(description: "Encrypted download in flight")
        let stopped = expectation(description: "Encrypted download cancelled")
        EncryptedDownloadStub.stall = true
        EncryptedDownloadStub.onDownload = { started.fulfill() }
        EncryptedDownloadStub.onStop = { stopped.fulfill() }
        defer { EncryptedDownloadStub.stall = false; EncryptedDownloadStub.onDownload = nil; EncryptedDownloadStub.onStop = nil }
        func network() -> URLSession {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [EncryptedDownloadStub.self]
            return URLSession(configuration: config)
        }
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://synthetic.test")!, sid: "synthetic", synoToken: "synthetic"),
                                    network: network(), makeAttachmentNetwork: network)
        try await api.discover()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let existing = Data("Existing synthetic file".utf8)
        try existing.write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        let key = try ChatContentCrypto.decodeBase64(f.channelKey)
        let transfer = Task { try await api.saveAttachment(postID: 100, to: destination, decryptionKey: key) }
        await fulfillment(of: [started], timeout: 2)
        transfer.cancel()
        do { try await transfer.value; XCTFail("Cancelled download must not report success") }
        catch is CancellationError { }
        catch { XCTFail("Cancellation must remain distinguishable") }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(try Data(contentsOf: destination), existing)
    }

    func testEncryptedDownloadOpensFixtureAndWrongKeyPreservesExistingDestination() async throws {
        let f = try fixture()
        EncryptedDownloadStub.payload = try ChatContentCrypto.decodeBase64(f.encryptedAttachment)
        defer { EncryptedDownloadStub.payload = Data() }
        func network() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [EncryptedDownloadStub.self]
            return URLSession(configuration: configuration)
        }
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://synthetic.test")!, sid: "synthetic", synoToken: "synthetic"),
                                    network: network(), makeAttachmentNetwork: network)
        try await api.discover()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("synthetic.bin")
        try await api.saveAttachment(postID: 100, to: destination, decryptionKey: ChatContentCrypto.decodeBase64(f.channelKey))
        let expected = try ChatContentCrypto.decodeBase64(f.attachment)
        XCTAssertEqual(try Data(contentsOf: destination), expected)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int, 0o600)
        do { try await api.saveAttachment(postID: 100, to: destination, decryptionKey: Data(repeating: 0, count: 32)); XCTFail("Wrong key must fail") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: destination), expected, "Failed authentication must never replace an existing file")
    }
}

private final class EncryptedDownloadStub: URLProtocol {
    static var payload = Data()
    static var stall = false
    static var onDownload: (() -> Void)?
    static var onStop: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let discovery = request.url!.path.contains("SYNO.API.Info")
        if !discovery && Self.stall { Self.onDownload?(); return }
        let data = discovery ? Data(#"{"success":true,"data":{"SYNO.Chat.Post.File":{"path":"entry.cgi","minVersion":1,"maxVersion":2,"requestFormat":"JSON"}}}"#.utf8) : Self.payload
        let headers = discovery ? ["Content-Type": "application/json"] : ["Content-Type": "application/octet-stream", "Content-Disposition": "attachment; filename=synthetic.bin"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        if !request.url!.path.contains("SYNO.API.Info") && Self.stall { Self.onStop?() }
    }
}
