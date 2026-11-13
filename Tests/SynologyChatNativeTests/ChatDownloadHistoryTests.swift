import XCTest
@testable import SynologyChatNative

@MainActor final class ChatDownloadHistoryTests: XCTestCase {
    override func setUp() { super.setUp(); HistoryDownloadStub.reset() }
    private func directory() throws -> URL { let u = FileManager.default.temporaryDirectory.appendingPathComponent("native-download-tests-" + UUID().uuidString); try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); addTeardownBlock { try? FileManager.default.removeItem(at: u) }; return u }
    private func channel(encrypted: Bool = false, envelope: String? = nil) throws -> ChatChannel {
        var object: [String: Any] = ["channel_id":93,"name":"Peter","type":"anonymous","encrypted":encrypted,"unread":0]
        if let envelope { object["channel_key_enc"] = envelope }
        return try JSONDecoder().decode(ChatChannel.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func post(_ id: Int64 = 100, name: String = "synthetic.txt") throws -> ChatPost { try JSONDecoder().decode(ChatPost.self, from: JSONSerialization.data(withJSONObject: ["post_id":id,"channel_id":93,"creator_id":10,"message":"Synthetic attachment","type":"file","create_at":1000,"file_props":["name":name,"size":HistoryDownloadStub.payload.count,"is_image":false]])) }
    private func model(keys: ChatEncryptionSession? = nil) async throws -> NativeChatPreviewModel {
        func network() -> URLSession { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [HistoryDownloadStub.self]; return URLSession(configuration: c) }
        let api = try ChatAPIClient(session: .init(baseURL: URL(string:"https://download-history.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:network(),makeAttachmentNetwork:network)
        try await api.discover()
        let model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false,encryption:keys)
        model.connected = true; model.liveStatus = .live; model.channels = [try channel()]; model.selection = 93
        addTeardownBlock { @MainActor in model.signOutLocally() }; return model
    }
    func testSuccessfulSaveRecordsBytesPrivateFileAndRememberedLocation() async throws {
        let model = try await model(), destination = try directory().appendingPathComponent("saved.txt")
        await model.saveAttachment(try post(), chooseDestination: { _ in destination })
        let record = try XCTUnwrap(model.downloadHistory.first)
        XCTAssertEqual(record.filename,"saved.txt"); XCTAssertEqual(record.state,.saved); XCTAssertEqual(record.received,Int64(HistoryDownloadStub.payload.count)); XCTAssertEqual(record.fileBytes,Int64(HistoryDownloadStub.payload.count)); XCTAssertEqual(record.destination,destination)
        XCTAssertEqual(try Data(contentsOf:destination),HistoryDownloadStub.payload)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:destination.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        XCTAssertEqual(model.downloadPreferences.lastFolder?.path,destination.deletingLastPathComponent().path); XCTAssertTrue(model.downloading.isEmpty)
    }
    func testRemoteOrCredentialBearingDestinationsAreRejectedBeforeTransfer() async throws {
        let model = try await model()
        for raw in ["https://elsewhere.invalid/file", "file://elsewhere.invalid/tmp/file", "file:///tmp/file?token=secret"] {
            await model.saveAttachment(try post(), chooseDestination: { _ in URL(string: raw) })
        }
        XCTAssertEqual(HistoryDownloadStub.downloads, 0); XCTAssertTrue(model.downloadHistory.allSatisfy { $0.state == .cancelled })
    }
    func testSavePanelCancellationLeavesReceiptWithoutRequestOrFile() async throws {
        let model = try await model()
        await model.saveAttachment(try post(),chooseDestination:{_ in nil})
        XCTAssertEqual(model.downloadHistory.first?.state,.cancelled); XCTAssertEqual(HistoryDownloadStub.downloads,0); XCTAssertTrue(model.downloading.isEmpty)
    }
    func testCancellingPendingLocationPreventsTransferAfterLateSelection() async throws {
        let model = try await model(), destination = try directory().appendingPathComponent("keep.txt"), shown = expectation(description:"Location pending")
        let original = Data("Keep existing".utf8); try original.write(to:destination)
        var resume: CheckedContinuation<URL?,Never>?
        let operation = Task { await model.saveAttachment(try post(),chooseDestination:{_ in await withCheckedContinuation { resume = $0; shown.fulfill() }}) }
        await fulfillment(of:[shown],timeout:2); model.cancelDownload(postID:100); resume?.resume(returning:destination); try await operation.value
        XCTAssertEqual(model.downloadHistory.first?.state,.cancelled); XCTAssertEqual(HistoryDownloadStub.downloads,0); XCTAssertEqual(try Data(contentsOf:destination),original)
    }
    func testDuplicateSaveDoesNotOpenAnotherPanelOrCreateReceipt() async throws {
        let model = try await model(), shown = expectation(description:"Location pending")
        var resume: CheckedContinuation<URL?,Never>?
        let operation = Task { await model.saveAttachment(try post(),chooseDestination:{_ in await withCheckedContinuation { resume = $0; shown.fulfill() }}) }
        await fulfillment(of:[shown],timeout:2)
        await model.saveAttachment(try post(),chooseDestination:{_ in XCTFail("Duplicate chooser");return nil})
        XCTAssertEqual(model.downloadHistory.count,1);resume?.resume(returning:nil);try await operation.value
    }
    func testOnlyOneLocationChooserCanBeActiveAcrossDifferentPosts() async throws {
        let model = try await model(), shown = expectation(description:"Location pending")
        var resume: CheckedContinuation<URL?,Never>?
        let operation = Task { await model.saveAttachment(try post(),chooseDestination:{_ in await withCheckedContinuation { resume = $0; shown.fulfill() }}) }
        await fulfillment(of:[shown],timeout:2)
        await model.saveAttachment(try post(101),chooseDestination:{_ in XCTFail("Second modal chooser");return nil})
        XCTAssertEqual(model.downloadHistory.count,1);resume?.resume(returning:nil);try await operation.value
    }
    func testCancelActiveDownloadRetainsExistingFileAndTerminalReceipt() async throws {
        let model = try await model(), destination = try directory().appendingPathComponent("keep.txt"), started = expectation(description:"Transfer held")
        let original = Data("Existing contents".utf8);try original.write(to:destination)
        HistoryDownloadStub.stall = true;HistoryDownloadStub.onStart = {started.fulfill()}
        let operation = Task {await model.saveAttachment(try post(),chooseDestination:{_ in destination})}
        await fulfillment(of:[started],timeout:2);model.cancelDownload(postID:100);try await operation.value
        XCTAssertEqual(model.downloadHistory.first?.state,.cancelled);XCTAssertEqual(try Data(contentsOf:destination),original);XCTAssertTrue(model.downloading.isEmpty);XCTAssertNil(model.error)
    }
    func testParentTaskCancellationStopsTransfer() async throws {
        let model = try await model(), destination = try directory().appendingPathComponent("cancel.txt"), started = expectation(description:"Transfer held")
        HistoryDownloadStub.stall = true;HistoryDownloadStub.onStart = {started.fulfill()}
        let operation = Task {await model.saveAttachment(try post(),chooseDestination:{_ in destination})}
        await fulfillment(of:[started],timeout:2);operation.cancel();try await operation.value
        XCTAssertEqual(model.downloadHistory.first?.state,.cancelled);XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
    }
    func testRevokedChannelBeforeCommitCannotReplaceExistingDestination() async throws {
        let model = try await model(), destination = try directory().appendingPathComponent("keep.txt"), started = expectation(description:"Transfer held")
        let original = Data("Preserve important file".utf8);try original.write(to:destination)
        HistoryDownloadStub.stall = true;HistoryDownloadStub.onStart = {started.fulfill()}
        let operation = Task {await model.saveAttachment(try post(),chooseDestination:{_ in destination})}
        await fulfillment(of:[started],timeout:2);model.channels = [];HistoryDownloadStub.release();try await operation.value
        XCTAssertEqual(model.downloadHistory.first?.state,.cancelled);XCTAssertEqual(try Data(contentsOf:destination),original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:destination.deletingLastPathComponent().path).filter{$0.hasPrefix(".native-chat-")}.isEmpty)
    }
    func testChangedEnvelopeBeforeCommitCannotReplaceExistingDestination() async throws {
        let model = try await model(), destination = try directory().appendingPathComponent("keep.txt"), started = expectation(description:"Transfer held")
        let original = Data("Keep old".utf8);try original.write(to:destination)
        HistoryDownloadStub.stall = true;HistoryDownloadStub.onStart = {started.fulfill()}
        let operation = Task {await model.saveAttachment(try post(),chooseDestination:{_ in destination})}
        await fulfillment(of:[started],timeout:2);model.channels = [try channel(envelope:"new-envelope")];HistoryDownloadStub.release();try await operation.value
        XCTAssertEqual(model.downloadHistory.first?.state,.cancelled);XCTAssertEqual(try Data(contentsOf:destination),original)
    }
    func testSignOutCancelsDownloadAndClearsAccountHistory() async throws {
        let model = try await model(), destination = try directory().appendingPathComponent("keep.txt"), started = expectation(description:"Transfer held")
        let original = Data("Keep old".utf8);try original.write(to:destination)
        HistoryDownloadStub.stall = true;HistoryDownloadStub.onStart = {started.fulfill()}
        let operation = Task {await model.saveAttachment(try post(),chooseDestination:{_ in destination})}
        await fulfillment(of:[started],timeout:2);model.signOutLocally();try await operation.value
        XCTAssertTrue(model.downloadHistory.isEmpty);XCTAssertTrue(model.downloading.isEmpty);XCTAssertEqual(try Data(contentsOf:destination),original)
    }
    func testFailureAndExplicitRetryHaveSeparateReceipts() async throws {
        let model = try await model(), destination = try directory().appendingPathComponent("retry.txt")
        let original = Data("Keep old".utf8);try original.write(to:destination);HistoryDownloadStub.disposition = false
        await model.saveAttachment(try post(),chooseDestination:{_ in destination})
        let failed = try XCTUnwrap(model.downloadHistory.first);XCTAssertEqual(failed.state,.failed);XCTAssertEqual(try Data(contentsOf:destination),original)
        HistoryDownloadStub.disposition = true
        await model.retryDownload(failed.id,chooseDestination:{_ in destination})
        XCTAssertEqual(model.downloadHistory.count,2);XCTAssertEqual(failed.state,.failed);XCTAssertEqual(model.downloadHistory.first?.state,.saved);XCTAssertNotEqual(model.downloadHistory.first?.id,failed.id);XCTAssertEqual(try Data(contentsOf:destination),HistoryDownloadStub.payload)
    }
    func testClearingHistoryDoesNotDeleteSavedFileOrCancelActiveTransfer() async throws {
        let model = try await model(), folder = try directory(), saved = folder.appendingPathComponent("saved.txt"), pending = folder.appendingPathComponent("pending.txt")
        await model.saveAttachment(try post(),chooseDestination:{_ in saved})
        let started = expectation(description:"Transfer held");HistoryDownloadStub.stall = true;HistoryDownloadStub.onStart = {started.fulfill()}
        let operation = Task {await model.saveAttachment(try post(101),chooseDestination:{_ in pending})}
        await fulfillment(of:[started],timeout:2);model.clearDownloadHistory()
        XCTAssertEqual(model.downloadHistory.count,1);XCTAssertEqual(model.downloadHistory.first?.state,.transferring);XCTAssertTrue(FileManager.default.fileExists(atPath:saved.path))
        model.clearDownloadHistory(cancelActive:true);try await operation.value
        XCTAssertTrue(model.downloadHistory.isEmpty);XCTAssertTrue(FileManager.default.fileExists(atPath:saved.path));XCTAssertFalse(FileManager.default.fileExists(atPath:pending.path))
    }
    func testOpenRequiresSavedExistingRegularFileAndClearRemovesOpenAuthority() async throws {
        let model = try await model(), destination = try directory().appendingPathComponent("saved.txt")
        await model.saveAttachment(try post(),chooseDestination:{_ in destination});let record = try XCTUnwrap(model.downloadHistory.first)
        var opened:[URL] = []
        await model.openDownload(record.id,opener:{opened.append($0);return true},confirmOpening:{_ in .open});XCTAssertEqual(opened,[destination])
        try FileManager.default.removeItem(at:destination);await model.refreshDownloadFiles();XCTAssertFalse(record.available)
        await model.openDownload(record.id,opener:{_ in XCTFail("Missing file opened");return true})
        try HistoryDownloadStub.payload.write(to:destination);await model.refreshDownloadFiles();XCTAssertTrue(record.available)
        model.clearDownloadHistory();await model.openDownload(record.id,opener:{_ in XCTFail("Cleared receipt opened");return true});XCTAssertTrue(FileManager.default.fileExists(atPath:destination.path))
    }
    func testChangedFileToSymlinkIsNotOpened() async throws {
        let model = try await model(), folder = try directory(), destination = folder.appendingPathComponent("saved.txt"), other = folder.appendingPathComponent("other.txt")
        await model.saveAttachment(try post(),chooseDestination:{_ in destination});let record = try XCTUnwrap(model.downloadHistory.first)
        try Data("Other file".utf8).write(to:other);try FileManager.default.removeItem(at:destination);try FileManager.default.createSymbolicLink(at:destination,withDestinationURL:other)
        await model.openDownload(record.id,opener:{_ in XCTFail("Replaced symlink opened");return true});XCTAssertFalse(record.available)
    }
    func testSavedDownloadReviewSeparatesCancelRevealAndOpen() async throws {
        let model = try await model(), destination = try directory().appendingPathComponent("review.txt")
        await model.saveAttachment(try post(), chooseDestination: { _ in destination })
        let record = try XCTUnwrap(model.downloadHistory.first)
        var opened: [URL] = [], revealed: [URL] = [], prompts = 0
        await model.openDownload(record.id, opener: { opened.append($0);return true }, confirmOpening: { _ in prompts += 1;return .cancel }, revealer: { revealed.append($0) })
        XCTAssertEqual(prompts, 1); XCTAssertTrue(opened.isEmpty); XCTAssertTrue(revealed.isEmpty)
        await model.openDownload(record.id, opener: { opened.append($0);return true }, confirmOpening: { _ in prompts += 1;return .reveal }, revealer: { revealed.append($0) })
        XCTAssertEqual(revealed, [destination]); XCTAssertTrue(opened.isEmpty)
        await model.openDownload(record.id, reveal: true, confirmOpening: { _ in XCTFail("Reveal asked for Open approval");return .open }, revealer: { revealed.append($0) })
        XCTAssertEqual(prompts, 2); XCTAssertEqual(revealed.count, 2)
        await model.openDownload(record.id, opener: { opened.append($0);return true }, confirmOpening: { _ in prompts += 1;return .open })
        XCTAssertEqual(opened, [destination]); XCTAssertEqual(record.state, .saved)
        XCTAssertEqual(try Data(contentsOf: destination), HistoryDownloadStub.payload)
    }
    func testRetiredDownloadReviewCannotOpenAfterSignOutClearLockOrDestinationChange() async throws {
        for action in 0..<4 {
            let model = try await model(), folder = try directory(), destination = folder.appendingPathComponent("saved.txt")
            let other = folder.appendingPathComponent("other.txt");try Data("Other local file".utf8).write(to: other)
            await model.saveAttachment(try post(), chooseDestination: { _ in destination })
            let record = try XCTUnwrap(model.downloadHistory.first), started = expectation(description: "Review pending")
            var reply: CheckedContinuation<ChatSavedFileOpening.Decision, Never>?, opens = 0
            let operation = Task { await model.openDownload(record.id, opener: { _ in opens += 1;return true }, confirmOpening: { _ in
                await withCheckedContinuation { reply = $0;started.fulfill() }
            }) }
            await fulfillment(of: [started], timeout: 3)
            switch action {
            case 0: model.signOutLocally()
            case 1: model.clearDownloadHistory()
            case 2: model.lockEncryption(reload: false)
            default: record.destination = other
            }
            reply?.resume(returning: .open);await operation.value
            XCTAssertEqual(opens, 0);XCTAssertFalse(model.savedFileOpening.busy)
            XCTAssertEqual(try Data(contentsOf: destination), HistoryDownloadStub.payload)
            XCTAssertEqual(try Data(contentsOf: other), Data("Other local file".utf8))
        }
    }
    func testChangedFileDuringModelReviewIsKeptButNotOpened() async throws {
        let model = try await model(), destination = try directory().appendingPathComponent("edited.txt")
        await model.saveAttachment(try post(), chooseDestination: { _ in destination })
        let record = try XCTUnwrap(model.downloadHistory.first); var opens = 0
        await model.openDownload(record.id, opener: { _ in opens += 1;return true }, confirmOpening: { _ in
            try? Data("User edited this file".utf8).write(to: destination, options: .atomic)
            return .open
        })
        XCTAssertEqual(opens, 0);XCTAssertNotNil(record.failure)
        XCTAssertEqual(record.state, .saved);XCTAssertEqual(try Data(contentsOf: destination), Data("User edited this file".utf8))
    }
    func testSaveAndOpenReviewsOnlyCompletedReleasedDownload() async throws {
        let model = try await model(), destination = try directory().appendingPathComponent("complete.txt")
        var prompts = 0, opens = 0
        await model.saveAttachment(try post(), chooseDestination: { _ in destination }, openAfterSaving: { url in
            XCTAssertEqual(url, destination);opens += 1;return true
        }, confirmOpening: { review in
            prompts += 1;XCTAssertEqual(review.localURL, destination)
            XCTAssertEqual(model.downloadHistory.first?.state, .saved);XCTAssertFalse(model.downloading.contains(100))
            XCTAssertEqual(try? Data(contentsOf: destination), HistoryDownloadStub.payload)
            return .open
        })
        XCTAssertEqual(prompts, 1);XCTAssertEqual(opens, 1);XCTAssertEqual(model.downloadHistory.first?.state, .saved)
    }
    func testSavedAttachmentHelperRequiresCompletedMatchingReceiptAndAccount() async throws {
        let model = try await model(), destination = try directory().appendingPathComponent("archive-like.txt")
        try Data("Not a download yet".utf8).write(to: destination)
        var prompts = 0, opens = 0
        let confirm: (ChatSavedFileOpening.Review) async -> ChatSavedFileOpening.Decision = { _ in prompts += 1;return .open }
        let open: (URL) -> Bool = { _ in opens += 1;return true }
        await model.openSavedAttachment(at: destination, postID: 100, expectedAccount: model.accountGeneration, opener: open, confirmOpening: confirm)
        XCTAssertEqual(prompts, 0);XCTAssertEqual(opens, 0)
        await model.saveAttachment(try post(), chooseDestination: { _ in destination })
        await model.openSavedAttachment(at: destination, postID: 101, expectedAccount: model.accountGeneration, opener: open, confirmOpening: confirm)
        await model.openSavedAttachment(at: destination, postID: 100, expectedAccount: model.accountGeneration + 1, opener: open, confirmOpening: confirm)
        XCTAssertEqual(prompts, 0);XCTAssertEqual(opens, 0)
        await model.openSavedAttachment(at: destination, postID: 100, expectedAccount: model.accountGeneration, opener: open, confirmOpening: confirm)
        XCTAssertEqual(prompts, 1);XCTAssertEqual(opens, 1)
    }
    func testConcurrentModelOpensKeepOneReviewWhileDirectRevealStillWorks() async throws {
        let model = try await model(), folder = try directory(), firstFile = folder.appendingPathComponent("one.txt"), secondFile = folder.appendingPathComponent("two.txt")
        await model.saveAttachment(try post(100), chooseDestination: { _ in firstFile })
        await model.saveAttachment(try post(101), chooseDestination: { _ in secondFile })
        let records = model.downloadHistory
        let started = expectation(description: "One review started")
        var replies: [CheckedContinuation<ChatSavedFileOpening.Decision, Never>] = [], prompts = 0, opens = 0, reveals = 0
        let confirm: (ChatSavedFileOpening.Review) async -> ChatSavedFileOpening.Decision = { _ in
            prompts += 1
            return await withCheckedContinuation { replies.append($0);if replies.count == 1 { started.fulfill() } }
        }
        let first = Task { await model.openDownload(records[0].id, opener: { _ in opens += 1;return true }, confirmOpening: confirm) }
        let second = Task { await model.openDownload(records[1].id, opener: { _ in opens += 1;return true }, confirmOpening: confirm) }
        await fulfillment(of: [started], timeout: 3);try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(prompts, 1);XCTAssertTrue(model.savedFileOpening.busy)
        await model.openDownload(records[1].id, reveal: true, confirmOpening: { _ in XCTFail("Reveal prompted");return .cancel }, revealer: { _ in reveals += 1 })
        XCTAssertEqual(reveals, 1);XCTAssertTrue(model.savedFileOpening.busy)
        replies.forEach { $0.resume(returning: .open) }
        await first.value;await second.value
        XCTAssertEqual(prompts, 1);XCTAssertEqual(opens, 1);XCTAssertFalse(model.savedFileOpening.busy)
    }
    func testOpenPromptDefaultsReturnToRevealAndEscapeToCancel() {
        let alert = NativeSavedFileOpenPrompt.makeAlert(.init(localURL: URL(fileURLWithPath: "/synthetic/fixture.txt"), displayName: "fixture.txt"))
        XCTAssertEqual(alert.buttons.map(\.title), ["Show in Folder", "Open", "Cancel"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r");XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
        XCTAssertEqual(alert.buttons[2].keyEquivalent, "\u{1b}")
    }
    func testLateCancelAfterCommitDoesNotRelabelSuccessfulSave() async throws {
        let model = try await model(), destination = try directory().appendingPathComponent("saved.txt")
        await model.saveAttachment(try post(),chooseDestination:{_ in destination});model.cancelDownload(postID:100)
        XCTAssertEqual(model.downloadHistory.first?.state,.saved);XCTAssertEqual(try Data(contentsOf:destination),HistoryDownloadStub.payload)
    }
    func testDirectoryDestinationIsNeverReplaced() async throws {
        let model = try await model(), folder = try directory(), contents = folder.appendingPathComponent("keep.txt")
        try Data("Keep folder contents".utf8).write(to: contents)
        let slashless = try XCTUnwrap(URL(string: folder.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        await model.saveAttachment(try post(), chooseDestination: { _ in slashless })
        XCTAssertNotEqual(model.downloadHistory.first?.state, .saved)
        XCTAssertEqual(try Data(contentsOf: contents), Data("Keep folder contents".utf8))
    }
    func testEmptyFileSaveIsSuccessfulAndRecordsZeroBytes() async throws {
        HistoryDownloadStub.payload = Data();let model = try await model(), destination = try directory().appendingPathComponent("empty.txt")
        await model.saveAttachment(try post(),chooseDestination:{_ in destination})
        XCTAssertEqual(model.downloadHistory.first?.state,.saved);XCTAssertEqual(model.downloadHistory.first?.fileBytes,0);XCTAssertEqual(try Data(contentsOf:destination),Data())
    }
    func testProgressIsMonotonicThrottledAndCannotRepaintTerminalReceipt() {
        let box = ProgressValues(), relay = ChatDownloadProgressRelay {box.append($0,$1)}
        relay.update(received:100,expected:1000,now:0);relay.update(received:101,expected:1000,now:0.05);relay.update(received:90,expected:1000,now:1);relay.update(received:200,expected:1000,now:0.2);relay.update(received:1000,expected:1000,now:0.21)
        XCTAssertEqual(box.values.map{$0.0},[100,200,1000]);XCTAssertEqual(relay.snapshot().received,1000)
        let record = ChatDownloadRecord(id:UUID(),postID:100,channelID:93,filename:"x",encrypted:false,startedAt:Date());record.state = .transferring
        record.progress(received:100,expected:1000);record.progress(received:50,expected:500);XCTAssertEqual(record.received,100)
        record.state = .cancelled;record.progress(received:1000,expected:1000);XCTAssertEqual(record.received,100)
    }
    func testProgressDelegateRetainsRedirectAndTLSIdentityPolicy() throws {
        let identity = try XCTUnwrap(ChatTLSIdentity(origin:URL(string:"https://192.0.2.1:5001")!,serverName:"nas.example.test")), box = ProgressValues()
        let delegate = NoChatRedirects(tlsIdentity:identity,onDownloadProgress:{box.append($0,$1)})
        let network = URLSession(configuration:.ephemeral), task = network.downloadTask(with:URL(string:"https://download-history.invalid/never-started")!);defer{network.invalidateAndCancel()}
        delegate.urlSession(network,downloadTask:task,didWriteData:100,totalBytesWritten:100,totalBytesExpectedToWrite:200)
        XCTAssertEqual(box.values.first?.0,100);XCTAssertEqual(delegate.tlsIdentity?.serverName,"nas.example.test")
        var redirected:URLRequest? = URLRequest(url:URL(string:"https://elsewhere.invalid")!)
        delegate.urlSession(network,task:task,willPerformHTTPRedirection:HTTPURLResponse(url:task.originalRequest!.url!,statusCode:302,httpVersion:nil,headerFields:[:])!,newRequest:redirected!){redirected = $0};XCTAssertNil(redirected)
    }
    func testFolderPreferencePersistsOnlyLocalPathAndResetRestoresDefault() throws {
        let name = "native-download-preference-tests-"+UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:name));defer{defaults.removePersistentDomain(forName:name)}
        let folder = try directory(), preferences = ChatDownloadPreferences(defaults:defaults)
        XCTAssertNil(preferences.lastFolder); XCTAssertEqual(preferences.initialFolder,FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask).first);preferences.chooseFolder(folder)
        XCTAssertEqual(ChatDownloadPreferences(defaults:defaults).lastFolder?.path,folder.path)
        preferences.chooseFolder(URL(string:"https://not-a-folder.invalid/?token=secret")!);XCTAssertEqual(preferences.lastFolder?.path,folder.path)
        preferences.reset();XCTAssertNil(ChatDownloadPreferences(defaults:defaults).lastFolder);XCTAssertEqual(preferences.initialFolder,FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask).first);XCTAssertNil(defaults.object(forKey:ChatDownloadPreferences.folderKey))
    }
    func testEncryptedHistoryIsRedactedAndCannotOpenWhileLocked() async throws {
        struct Fixture:Decodable{let password,publicKey,wrappedPrivateKey,wrappedChannelKey,encryptedAttachment,attachment,filename,encryptedFilename:String}
        let url = try XCTUnwrap(Bundle.module.url(forResource:"ChatCrypto",withExtension:"json",subdirectory:"Fixtures")),f = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:url)),keys = ChatEncryptionSession()
        try keys.unlock(.init(public_key:f.publicKey,private_key_enc:f.wrappedPrivateKey),password:f.password)
        HistoryDownloadStub.payload = try ChatContentCrypto.decodeBase64(f.encryptedAttachment)
        let model = try await model(keys:keys);model.channels = [try channel(encrypted:true,envelope:f.wrappedChannelKey)]
        let destination = try directory().appendingPathComponent("decrypted.bin")
        await model.saveAttachment(try post(name:f.encryptedFilename),chooseDestination:{_ in destination})
        let record = try XCTUnwrap(model.downloadHistory.first);XCTAssertEqual(record.state,.saved);XCTAssertEqual(try Data(contentsOf:destination),try ChatContentCrypto.decodeBase64(f.attachment))
        XCTAssertEqual(model.downloadName(record),"decrypted.bin");model.lockEncryption()
        XCTAssertEqual(model.downloadName(record),"Encrypted attachment");XCTAssertFalse(model.canUseSavedDownload(record))
        await model.openDownload(record.id,opener:{_ in XCTFail("Locked download opened");return true})
    }
}
private final class ProgressValues:@unchecked Sendable {
    private let lock = NSLock();private var stored:[(Int64,Int64)] = []
    func append(_ a:Int64,_ b:Int64){lock.lock();stored.append((a,b));lock.unlock()}
    var values:[(Int64,Int64)]{lock.lock();defer{lock.unlock()};return stored}
}
private final class HistoryDownloadStub:URLProtocol,@unchecked Sendable {
    static var payload = Data(),disposition = true,stall = false,downloads = 0
    static var onStart:(()->Void)?,held:HistoryDownloadStub?
    static func reset(){payload = Data("Synthetic file. No private data.\n".utf8);disposition = true;stall = false;downloads = 0;onStart = nil;held = nil}
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
        guard request.url?.host == "download-history.invalid" else{client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return}
        if request.url!.lastPathComponent == "SYNO.API.Info"{finish(Data(#"{"success":true,"data":{"SYNO.Chat.Post.File":{"path":"entry.cgi","minVersion":1,"maxVersion":2,"requestFormat":"JSON"}}}"#.utf8),headers:["Content-Type":"application/json"]);return}
        Self.downloads += 1
        if Self.stall{Self.held = self;Self.onStart?();return};sendFile()
    }
    static func release(){if let held{Self.held = nil;held.sendFile()}}
    func sendFile(){var headers = ["Content-Type":"application/octet-stream","Content-Length":String(Self.payload.count)];if Self.disposition{headers["Content-Disposition"] = "attachment; filename=synthetic.txt"};finish(Self.payload,headers:headers)}
    private func finish(_ data:Data,headers:[String:String]){client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:headers)!,cacheStoragePolicy:.notAllowed);if !data.isEmpty{client?.urlProtocol(self,didLoad:data)};client?.urlProtocolDidFinishLoading(self)}
    override func stopLoading(){if Self.held === self{Self.held = nil}}
}
