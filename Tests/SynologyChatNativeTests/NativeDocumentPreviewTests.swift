import AppKit
import PDFKit
import AVFoundation
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeDocumentPreviewTests:XCTestCase {
    private func post(_ id:Int64 = 1,name:String = "synthetic.txt",size:Int = 100,channel:Int64 = 93,thread:Int64 = 0) throws -> ChatPost {
        try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:[
            "post_id":id,"channel_id":channel,"creator_id":10,"thread_id":thread,"message":"Synthetic document",
            "create_at":1000,"type":"file","file_props":["name":name,"size":size,"is_image":false]]))
    }
    private func model() async throws -> NativeChatPreviewModel {
        func network()->URLSession { let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [DocumentPreviewStub.self];return URLSession(configuration:config) }
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://synthetic.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:network(),makeAttachmentNetwork:network)
        try await api.discover()
        let model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false)
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0}"#.utf8))]
        model.selection = 93;model.connected = true;model.liveStatus = .live
        addTeardownBlock { @MainActor in model.signOutLocally() }
        return model
    }
    override func tearDown() { DocumentPreviewStub.supportsRanges = false;DocumentPreviewStub.onRequest = nil;DocumentPreviewStub.onStop = nil;DocumentPreviewStub.stall = false;DocumentPreviewStub.attachmentHeader = true;super.tearDown() }
    private func silentAudio() -> Data {
        let wave = NativeSyntheticMedia.wave()
        return Data(wave.prefix(44)) + Data(repeating: 0, count: wave.count - 44)
    }
    func testInlineAudioKeepsReadingVisibleAndExpandsTheSamePlayer() async throws {
        DocumentPreviewStub.payload = silentAudio(); DocumentPreviewStub.supportsRanges = true
        let model = try await model(), target = try post(name: "synthetic.wav", size: DocumentPreviewStub.payload.count)
        model.posts = [target]; model.updateReadingVisibility(active: true, atBottom: true)
        XCTAssertEqual(model.notificationVisibleLocation?.channelID, 93)
        let owner = UUID(); model.openInlineAudio(target, ownerID: owner); await model.documentPreviewTask?.value
        XCTAssertNil(model.documentPreviewError); XCTAssertFalse(model.documentPreviewIsPresented)
        XCTAssertTrue(model.ownsInlineAudio(postID: target.id, ownerID: owner))
        XCTAssertEqual(model.notificationVisibleLocation?.channelID, 93)
        guard case .media(let original) = model.documentPreviewContent else { return XCTFail() }
        original.setVolume(0); let item = original.player.currentItem
        model.expandInlineAudio()
        guard case .media(let expanded) = model.documentPreviewContent else { return XCTFail() }
        XCTAssertTrue(original === expanded); XCTAssertTrue(expanded.player.currentItem === item)
        XCTAssertTrue(model.documentPreviewIsPresented); XCTAssertNil(model.inlineAudioOwnerID)
        XCTAssertNil(model.notificationVisibleLocation); XCTAssertNil(model.documentPreviewTask)
        model.closeDocumentPreview(); XCTAssertNil(original.player.currentItem)
        XCTAssertNil(model.inlineAudioPostID); XCTAssertFalse(model.documentPreviewInlineAudio)
    }
    func testInlineAudioOwnershipAndReplacementIgnoreRetiredCardDisappearance() async throws {
        DocumentPreviewStub.payload = silentAudio(); DocumentPreviewStub.supportsRanges = true
        let model = try await model(), one = try post(1, name: "one.wav", size: DocumentPreviewStub.payload.count)
        let two = try post(2, name: "two.wav", size: DocumentPreviewStub.payload.count)
        let firstOwner = UUID(), nextOwner = UUID(), secondOwner = UUID()
        model.openInlineAudio(one, ownerID: firstOwner); await model.documentPreviewTask?.value
        guard case .media(let first) = model.documentPreviewContent else { return XCTFail() }
        model.openInlineAudio(one, ownerID: nextOwner)
        model.closeInlineAudio(postID: one.id, ownerID: firstOwner)
        XCTAssertNotNil(first.player.currentItem); XCTAssertTrue(model.ownsInlineAudio(postID: one.id, ownerID: nextOwner))
        model.openInlineAudio(two, ownerID: secondOwner); await model.documentPreviewTask?.value
        guard case .media(let second) = model.documentPreviewContent else { return XCTFail() }
        XCTAssertNil(first.player.currentItem)
        model.closeInlineAudio(postID: one.id, ownerID: nextOwner)
        XCTAssertNotNil(second.player.currentItem)
        model.closeInlineAudio(postID: two.id, ownerID: secondOwner)
        XCTAssertNil(second.player.currentItem); XCTAssertNil(model.inlineAudioOwnerID)
    }
    func testInlineAudioRetryPreservesInlineModeAndCardOwner() async throws {
        let bytes = silentAudio(); DocumentPreviewStub.payload = Data("{}".utf8)
        DocumentPreviewStub.supportsRanges = true; DocumentPreviewStub.attachmentHeader = false
        let model = try await model(), target = try post(name: "synthetic.wav", size: bytes.count), owner = UUID()
        model.openInlineAudio(target, ownerID: owner); await model.documentPreviewTask?.value
        XCTAssertNotNil(model.documentPreviewError); XCTAssertFalse(model.documentPreviewIsPresented)
        DocumentPreviewStub.payload = bytes; DocumentPreviewStub.attachmentHeader = true
        model.retryDocumentPreview(); await model.documentPreviewTask?.value
        XCTAssertNil(model.documentPreviewError); XCTAssertFalse(model.documentPreviewIsPresented)
        XCTAssertTrue(model.ownsInlineAudio(postID: target.id, ownerID: owner))
        guard case .media = model.documentPreviewContent else { return XCTFail() }
        model.closeDocumentPreview()
    }
    func testInlineAudioRefusesVideoAndUnreadableChannelBeforeNetwork() async throws {
        let model = try await model(); var requests = 0
        DocumentPreviewStub.onRequest = { _ in requests += 1 }
        model.openInlineAudio(try post(name: "video.mp4"))
        model.openInlineAudio(try post(name: "audio.wav", channel: 94))
        XCTAssertEqual(requests, 0); XCTAssertNil(model.documentPreviewPost); XCTAssertNil(model.inlineAudioOwnerID)
    }
    func testInlineAudioLoadingCancellationPreservesReadingAndDoesNotFallBack() async throws {
        DocumentPreviewStub.payload = silentAudio(); DocumentPreviewStub.supportsRanges = true
        let model = try await model(), target = try post(name: "synthetic.wav", size: DocumentPreviewStub.payload.count), owner = UUID()
        model.posts = [target]; model.updateReadingVisibility(active: true, atBottom: true)
        let started = expectation(description: "Inline range started"), stopped = expectation(description: "Inline range cancelled")
        started.assertForOverFulfill = false; stopped.assertForOverFulfill = false
        let completed = expectation(description: "Inline setup retired")
        DocumentPreviewStub.stall = true
        DocumentPreviewStub.onRequest = { request in XCTAssertNotNil(request.value(forHTTPHeaderField: "Range")); started.fulfill() }
        DocumentPreviewStub.onStop = { stopped.fulfill() }
        model.openInlineAudio(target, ownerID: owner)
        let task = model.documentPreviewTask; Task { await task?.value; completed.fulfill() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(model.notificationVisibleLocation?.channelID, 93)
        model.closeInlineAudio(postID: target.id, ownerID: owner)
        await fulfillment(of: [stopped, completed], timeout: 3)
        XCTAssertEqual(model.notificationVisibleLocation?.channelID, 93)
        XCTAssertNil(model.documentPreviewError); XCTAssertNil(model.inlineAudioOwnerID)
    }
    func testInlineAudioPreservesThreadReadingAndStopsWhenThreadCloses() async throws {
        DocumentPreviewStub.payload = silentAudio(); DocumentPreviewStub.supportsRanges = true
        let model = try await model(), root = try post(50), reply = try post(101, name: "reply.wav", size: DocumentPreviewStub.payload.count, thread: 50)
        model.threadRoot = root; model.replies = [reply]
        model.updateThreadReadingVisibility(active: true, atBottom: true)
        XCTAssertEqual(model.notificationVisibleLocation?.threadID, 50)
        model.openInlineAudio(reply, ownerID: UUID()); await model.documentPreviewTask?.value
        XCTAssertFalse(model.documentPreviewIsPresented); XCTAssertEqual(model.notificationVisibleLocation?.threadID, 50)
        guard case .media(let playback) = model.documentPreviewContent else { return XCTFail() }
        model.closeThread(); XCTAssertNil(playback.player.currentItem); XCTAssertNil(model.inlineAudioPostID)
    }
    func testInlineAudioContextRetirementClearsPlayerAndOwner() async throws {
        for action in 0..<4 {
            DocumentPreviewStub.payload = silentAudio(); DocumentPreviewStub.supportsRanges = true
            let model = try await model(), target = try post(name: "audio.wav", size: DocumentPreviewStub.payload.count)
            model.openInlineAudio(target, ownerID: UUID()); await model.documentPreviewTask?.value
            guard case .media(let playback) = model.documentPreviewContent else { return XCTFail() }
            switch action {
            case 0: model.selection = 94
            case 1: model.channels = []
            case 2: model.lockEncryption(reload: false)
            default: model.signOutLocally()
            }
            XCTAssertNil(playback.player.currentItem); XCTAssertNil(model.inlineAudioOwnerID)
            XCTAssertNil(model.inlineAudioPostID); XCTAssertFalse(model.documentPreviewIsPresented)
        }
    }
    func testTextDecodingPreservesLiteralHTMLUnicodeAndBOMs() throws {
        for encoding in [String.Encoding.utf8,.utf16LittleEndian,.utf16BigEndian] {
            let value = "<script>alert(1)</script> Peter 👋\nsecond line"
            var data = try XCTUnwrap(value.data(using:encoding))
            if encoding == .utf16LittleEndian { data = Data([0xff,0xfe])+data }
            if encoding == .utf16BigEndian { data = Data([0xfe,0xff])+data }
            guard case .text(let decoded) = try NativeDocumentContent.decode(data,kind:.text) else { return XCTFail() }
            XCTAssertEqual(decoded,value)
        }
        guard case .text(let decoded) = try NativeDocumentContent.decode(Data([0xef,0xbb,0xbf])+Data("BOM".utf8),kind:.text) else { return XCTFail() }
        XCTAssertEqual(decoded,"BOM")
    }
    func testBinaryMalformedAndOversizeContentFailsWithoutExtensionGuessing() throws {
        for bytes in [Data([0,1,2]),Data([0xff,0,0xff]),Data(repeating:65,count:NativeDocumentKind.text.limit+1)] {
            XCTAssertThrowsError(try NativeDocumentContent.decode(bytes,kind:.text))
        }
        XCTAssertThrowsError(try NativeDocumentContent.decode(Data("%PDF-invalid".utf8),kind:.pdf))
        XCTAssertNil(NativeDocumentKind.forFilename("payload.exe"));XCTAssertEqual(NativeDocumentKind.forFilename("slides.pptx"),.quickLook)
        XCTAssertEqual(NativeDocumentKind.forFilename("README.TXT"),.text)
    }
    func testPDFDecodingRequiresRealPagesAndKeepsPasswordProtection() throws {
        let document = PDFDocument();document.insert(try XCTUnwrap(PDFPage(image:NSImage(size:NSSize(width:200,height:300),flipped:false) { rect in NSColor.white.setFill();rect.fill();return true })),at:0)
        let data = try XCTUnwrap(document.dataRepresentation())
        guard case .pdf(let decoded) = try NativeDocumentContent.decode(data,kind:.pdf) else { return XCTFail() }
        XCTAssertEqual(decoded.pageCount,1);XCTAssertFalse(decoded.isLocked)
        let encrypted = try XCTUnwrap(document.dataRepresentation(options:[PDFDocumentWriteOption.ownerPasswordOption:"synthetic-owner",PDFDocumentWriteOption.userPasswordOption:"synthetic-reader"]))
        guard case .pdf(let locked) = try NativeDocumentContent.decode(encrypted,kind:.pdf) else { return XCTFail() }
        XCTAssertTrue(locked.isLocked);XCTAssertFalse(locked.unlock(withPassword:"wrong"));XCTAssertTrue(locked.unlock(withPassword:"synthetic-reader"))
    }
    func testAuthenticatedOriginalRouteSuppressesReadingAndRetryRecovers() async throws {
        let model = try await model();let target = try post();model.posts = [target]
        var requestBody = ""
        DocumentPreviewStub.onRequest = { requestBody = String(decoding:$0.httpBody ?? Data(),as:UTF8.self) }
        DocumentPreviewStub.payload = Data([0,1])
        model.updateReadingVisibility(active:true,atBottom:true);XCTAssertNotNil(model.notificationVisibleLocation)
        model.openDocumentPreview(target);await model.documentPreviewTask?.value
        XCTAssertTrue(requestBody.contains("method=get"));XCTAssertTrue(requestBody.contains("post_id=1"));XCTAssertNotNil(model.documentPreviewError);XCTAssertNil(model.notificationVisibleLocation)
        DocumentPreviewStub.payload = Data("Native plain text".utf8)
        model.retryDocumentPreview();await model.documentPreviewTask?.value
        XCTAssertNil(model.documentPreviewError)
        guard case .text(let text) = model.documentPreviewContent else { return XCTFail() };XCTAssertEqual(text,"Native plain text")
        model.closeDocumentPreview();model.updateReadingVisibility(active:true,atBottom:true);XCTAssertNotNil(model.notificationVisibleLocation)
    }
    func testDeclaredSizeAndContextPreventUnnecessaryRequests() async throws {
        let model = try await model();var requests = 0;DocumentPreviewStub.onRequest = { _ in requests += 1 }
        model.openDocumentPreview(try post(name:"large.txt",size:NativeDocumentKind.text.limit+1));await model.documentPreviewTask?.value
        XCTAssertNotNil(model.documentPreviewError);XCTAssertEqual(requests,0);model.closeDocumentPreview()
        model.openDocumentPreview(try post(channel:94));XCTAssertNil(model.documentPreviewPost)
        model.openDocumentPreview(try post(name:"private.exe"));XCTAssertNil(model.documentPreviewPost)
    }
    func testOfficeOriginalUsesAuthenticatedRouteAndCloseRemovesPrivatePreview() async throws {
        let model = try await model(); let target = try post(name:"Fixture.rtf")
        DocumentPreviewStub.payload = Data("{\\rtf1\\ansi Native office document.}".utf8)
        model.openDocumentPreview(target); await model.documentPreviewTask?.value
        XCTAssertNil(model.documentPreviewError)
        guard case .quickLook(let resource) = model.documentPreviewContent else { return XCTFail("Office resource unavailable") }
        let file = resource.file
        XCTAssertEqual(try Data(contentsOf:file),DocumentPreviewStub.payload)
        model.closeDocumentPreview();XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
    func testEncryptedOfficeDocumentsDoNotEnterSystemPreviewCache() async throws {
        let model = try await model()
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Encrypted","type":"anonymous","encrypted":true,"unread":0}"#.utf8))]
        var requests = 0;DocumentPreviewStub.onRequest = { _ in requests += 1 }
        let target = try post(name:"Fixture.docx")
        XCTAssertFalse(model.canPreviewDocument(target));model.openDocumentPreview(target)
        XCTAssertNil(model.documentPreviewPost);XCTAssertEqual(requests,0)
    }
    func testOriginalBytesAreBoundedAuthenticatedAndDecryptedBeforeDecode() async throws {
        func network()->URLSession { let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [DocumentPreviewStub.self];return URLSession(configuration:c) }
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://synthetic.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:network(),makeAttachmentNetwork:network)
        try await api.discover()
        let key = Data(repeating:7,count:32),plain = Data("Encrypted synthetic text".utf8)
        DocumentPreviewStub.payload = try ChatContentCrypto.encryptAttachment(plain,key:key)
        let decrypted = try await api.documentPreviewData(postID:1,maximumBytes:1024,decryptionKey:key)
        XCTAssertEqual(decrypted,plain)
        DocumentPreviewStub.payload = Data(repeating:65,count:100)
        do { _ = try await api.documentPreviewData(postID:1,maximumBytes:99);XCTFail("Oversized original accepted") } catch { }
        DocumentPreviewStub.attachmentHeader = false
        DocumentPreviewStub.payload = Data(#"{"success":false,"error":{"code":119}}"#.utf8)
        do { _ = try await api.documentPreviewData(postID:1,maximumBytes:1024);XCTFail("API error accepted as a document") } catch { }
    }
    #if DEBUG
    func testMediaLeaseRecoveryPreservesLiveInstancesAndForeignFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-media-lease-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:root) }
        let first = NativeMediaTemporaryFiles(root:root,namespace:"preview"),second = NativeMediaTemporaryFiles(root:root,namespace:"preview")
        let live = try first.create(extension:"wav");try Data("active synthetic".utf8).write(to:live)
        second.cleanAbandoned();XCTAssertTrue(FileManager.default.fileExists(atPath:live.path))
        let abandoned = root.appendingPathComponent("native-chat-media-v1-preview-abandoned")
        try FileManager.default.createDirectory(at:abandoned,withIntermediateDirectories:false)
        try Data("SynologyChatNative media cache v1\n".utf8).write(to:abandoned.appendingPathComponent(".lease"))
        try Data("abandoned synthetic".utf8).write(to:abandoned.appendingPathComponent("attachment.wav"))
        let foreign = root.appendingPathComponent("native-chat-media-v1-other-unrelated")
        try FileManager.default.createDirectory(at:foreign,withIntermediateDirectories:false)
        second.cleanAbandoned()
        XCTAssertFalse(FileManager.default.fileExists(atPath:abandoned.path));XCTAssertTrue(FileManager.default.fileExists(atPath:foreign.path));XCTAssertTrue(FileManager.default.fileExists(atPath:live.path))
        first.removeAll();XCTAssertFalse(FileManager.default.fileExists(atPath:live.path));first.removeAll()
    }
    func testMediaTerminationDisposesOpenPlayerWithoutSigningOut() async throws {
        DocumentPreviewStub.payload = NativeSyntheticMedia.wave()
        let model = try await model();model.openDocumentPreview(try post(name:"synthetic.wav",size:DocumentPreviewStub.payload.count));await model.documentPreviewTask?.value
        guard case .media(let playback) = model.documentPreviewContent else { return XCTFail() }
        let file = try XCTUnwrap(playback.file)
        model.prepareForTermination()
        XCTAssertTrue(model.connected);XCTAssertNil(model.documentPreviewContent);XCTAssertNil(playback.player.currentItem);XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
    func testAudioUsesPrivateLocalFileDoesNotAutoplayAndDisposalStopsPlayback() async throws {
        let playback = try await NativeMediaPlayback.load(NativeSyntheticMedia.wave(),kind:.audio,filename:"synthetic.wav")
        let file = try XCTUnwrap(playback.file)
        XCTAssertTrue(file.isFileURL);XCTAssertEqual(file.lastPathComponent,"attachment.wav")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? Int,0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:file.deletingLastPathComponent().path)[.posixPermissions] as? Int,0o700)
        XCTAssertEqual(playback.duration,3,accuracy:0.05);XCTAssertEqual(playback.player.rate,0)
        XCTAssertEqual((playback.player.currentItem?.asset as? AVURLAsset)?.url,file)
        XCTAssertEqual(playback.player.currentItem?.asset.referenceRestrictions,.forbidAll)
        XCTAssertFalse(playback.player.allowsExternalPlayback)
        playback.player.volume = 0;playback.player.play()
        for _ in 0..<100 { if playback.player.currentTime().seconds > 0.05 { break };try await Task.sleep(nanoseconds:20_000_000) }
        XCTAssertGreaterThan(playback.player.currentTime().seconds,0)
        playback.dispose();XCTAssertEqual(playback.player.rate,0);XCTAssertNil(playback.player.currentItem)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path));playback.dispose()
    }
    func testVideoContainsPlayableVideoAndClosingModelRemovesOwnedMedia() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-media-unit-"+UUID().uuidString)
        let files = try await NativeSyntheticMedia.files(in:folder)
        defer { try? FileManager.default.removeItem(at:folder) }
        DocumentPreviewStub.payload = try Data(contentsOf:files[1])
        let model = try await model();let target = try post(name:"synthetic.mp4",size:DocumentPreviewStub.payload.count)
        model.openDocumentPreview(target);await model.documentPreviewTask?.value
        XCTAssertNil(model.documentPreviewError)
        guard case .media(let playback) = model.documentPreviewContent else { return XCTFail() }
        XCTAssertEqual(playback.kind,.video);XCTAssertGreaterThan(playback.duration,2.8)
        let file = try XCTUnwrap(playback.file)
        model.selection = 94
        XCTAssertNil(model.documentPreviewPost);XCTAssertNil(playback.player.currentItem);XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
    func testExplicitPlayActionStartsMediaAfterAuthenticatedLoad() async throws {
        DocumentPreviewStub.payload = NativeSyntheticMedia.wave()
        let model = try await model()
        model.openDocumentPreview(try post(name:"synthetic.wav",size:DocumentPreviewStub.payload.count),playMedia:true)
        await model.documentPreviewTask?.value
        guard case .media(let media) = model.documentPreviewContent else { return XCTFail() }
        media.setVolume(0)
        XCTAssertGreaterThan(media.player.rate,0)
        model.closeDocumentPreview();XCTAssertEqual(media.player.rate,0);XCTAssertNil(media.player.currentItem)
    }
    func testModelStreamsKnownSizeAudioWithOpaqueURLAndNoPlaintextFile() async throws {
        DocumentPreviewStub.payload = NativeSyntheticMedia.wave(); DocumentPreviewStub.supportsRanges = true
        let model = try await model(); var headers: [String?] = []
        DocumentPreviewStub.onRequest = { headers.append($0.value(forHTTPHeaderField: "Range")) }
        model.openDocumentPreview(try post(name: "synthetic.wav", size: DocumentPreviewStub.payload.count))
        await model.documentPreviewTask?.value
        XCTAssertNil(model.documentPreviewError)
        guard case .media(let playback) = model.documentPreviewContent else { return XCTFail("Streaming player unavailable") }
        XCTAssertNil(playback.file); XCTAssertEqual(playback.duration, 3, accuracy: 0.05); XCTAssertEqual(playback.player.rate, 0)
        let asset = try XCTUnwrap(playback.player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(asset.url.scheme, "native-chat-media"); XCTAssertNil(asset.url.query)
        XCTAssertEqual(asset.referenceRestrictions, .forbidAll); XCTAssertFalse(playback.player.allowsExternalPlayback)
        XCTAssertFalse(headers.isEmpty); XCTAssertTrue(headers.allSatisfy { $0?.hasPrefix("bytes=") == true })
        model.closeDocumentPreview(); XCTAssertNil(playback.player.currentItem)
        let count = headers.count
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(headers.count, count)
    }
    func testModelIgnoredRangesFallBackToBoundedPrivateLocalPlayback() async throws {
        DocumentPreviewStub.payload = NativeSyntheticMedia.wave()
        let model = try await model(); var headers: [String?] = []
        DocumentPreviewStub.onRequest = { headers.append($0.value(forHTTPHeaderField: "Range")) }
        model.openDocumentPreview(try post(name: "synthetic.wav", size: DocumentPreviewStub.payload.count))
        await model.documentPreviewTask?.value
        guard case .media(let playback) = model.documentPreviewContent else { return XCTFail("Fallback player unavailable") }
        XCTAssertNotNil(playback.file); XCTAssertTrue(headers.contains { $0 != nil }); XCTAssertTrue(headers.contains { $0 == nil })
        model.closeDocumentPreview()
    }
    func testModelSignOutDuringStreamingSetupCancelsRangeWithoutFallback() async throws {
        DocumentPreviewStub.payload = NativeSyntheticMedia.wave(); DocumentPreviewStub.supportsRanges = true
        let model = try await model()
        let started = expectation(description: "Streaming range started"), stopped = expectation(description: "Streaming range stopped")
        started.assertForOverFulfill = false; stopped.assertForOverFulfill = false
        let completed = expectation(description: "Streaming setup retired")
        DocumentPreviewStub.stall = true
        DocumentPreviewStub.onRequest = { request in XCTAssertNotNil(request.value(forHTTPHeaderField: "Range")); started.fulfill() }
        DocumentPreviewStub.onStop = { stopped.fulfill() }
        model.openDocumentPreview(try post(name: "synthetic.wav", size: DocumentPreviewStub.payload.count))
        let task = model.documentPreviewTask
        Task { await task?.value; completed.fulfill() }
        await fulfillment(of: [started], timeout: 3)
        model.signOutLocally()
        await fulfillment(of: [stopped, completed], timeout: 3)
        XCTAssertNil(model.documentPreviewContent); XCTAssertNil(model.documentPreviewError); XCTAssertNil(model.documentPreviewPost)
    }
    func testMalformedAndWrongTrackMediaCleanTheirTemporaryFiles() async throws {
        func folders()->Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath:FileManager.default.temporaryDirectory.path))?.filter { $0.hasPrefix("native-chat-media-") } ?? []) }
        let before = folders()
        for (bytes,kind,name) in [(Data("not media".utf8),NativeDocumentKind.audio,"bad.mp3"),(NativeSyntheticMedia.wave(),.video,"wrong.mp4")] {
            do { _ = try await NativeMediaPlayback.load(bytes,kind:kind,filename:name);XCTFail("Invalid media accepted") } catch { }
        }
        XCTAssertEqual(folders(),before)
    }
    func testSignOutAndLockClearLoadedAudioAndDeclaredOversizeDoesNotFetch() async throws {
        DocumentPreviewStub.payload = NativeSyntheticMedia.wave()
        for signout in [false,true] {
            let model = try await model();let target = try post(name:"synthetic.wav",size:DocumentPreviewStub.payload.count)
            model.openDocumentPreview(target);await model.documentPreviewTask?.value
            guard case .media(let playback) = model.documentPreviewContent else { return XCTFail() }
            let file = try XCTUnwrap(playback.file)
            if signout { model.signOutLocally() } else { model.lockEncryption(reload:false) }
            XCTAssertNil(model.documentPreviewContent);XCTAssertNil(playback.player.currentItem);XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
        }
        let model = try await model();var requests = 0;DocumentPreviewStub.onRequest = { _ in requests += 1 }
        model.openDocumentPreview(try post(name:"large.mp4",size:NativeDocumentKind.video.limit+1));await model.documentPreviewTask?.value
        XCTAssertEqual(requests,0);XCTAssertNotNil(model.documentPreviewError)
    }
    #endif
    func testClosingSelectionLockRemovalAndSignOutCancelPendingData() async throws {
        for action in 0..<5 {
            let model = try await model();let target = try post()
            let started = expectation(description:"Document request started"),stopped = expectation(description:"Document request cancelled")
            DocumentPreviewStub.stall = true;DocumentPreviewStub.onRequest = { _ in started.fulfill() };DocumentPreviewStub.onStop = { stopped.fulfill() }
            model.openDocumentPreview(target);let task = model.documentPreviewTask
            await fulfillment(of:[started],timeout:2)
            switch action { case 0:model.closeDocumentPreview();case 1:model.selection = 94;case 2:model.lockEncryption(reload:false);case 3:model.channels = [];default:model.signOutLocally() }
            await task?.value;await fulfillment(of:[stopped],timeout:2)
            XCTAssertNil(model.documentPreviewPost);XCTAssertNil(model.documentPreviewContent);XCTAssertNil(model.documentPreviewError)
            DocumentPreviewStub.stall = false
        }
    }
    private func searchChannel(_ id:Int64,overrides:[String:Any] = [:]) throws -> ChatChannel {
        var fields:[String:Any] = ["channel_id":id,"name":"Synthetic research","type":"public","encrypted":false,"is_joined":true,"unread":0]
        fields.merge(overrides,uniquingKeysWith:{ _,new in new });return try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:fields))
    }
    func testSearchTextPreviewUsesOriginalChannelWithoutChangingSelectionOrDraft() async throws {
        DocumentPreviewStub.payload = Data("Synthetic e\u{301} 😀\r\nsearch document\n".utf8)
        let model = try await model(),target = try post(channel:94),owner = UUID();model.channels.append(try searchChannel(94));model.draft = "Keep the unsent draft"
        XCTAssertFalse(model.canPreviewDocument(target));XCTAssertTrue(model.canPreviewSearchDocument(target))
        model.openSearchDocument(target,owner:owner);await model.documentPreviewTask?.value
        guard case .text(let text) = model.documentPreviewContent else { return XCTFail("Search text did not load") }
        XCTAssertEqual(Data(text.utf8),DocumentPreviewStub.payload);XCTAssertEqual(model.searchDocumentOwner,owner);XCTAssertEqual(model.selection,93);XCTAssertEqual(model.draft,"Keep the unsent draft")
        XCTAssertFalse(model.canPreviewDocument(try post(2,channel:94)))
        model.closeDocumentPreview();XCTAssertNil(model.searchDocumentOwner);XCTAssertFalse(model.canPreviewDocument(target))
    }
    func testSearchPDFPreviewDecodesAndSourceJumpSelectsOriginalChannel() async throws {
        DocumentPreviewStub.payload = try NativeSyntheticDocument.data()
        let model = try await model(),target = try post(name:"research.pdf",size:DocumentPreviewStub.payload.count,channel:94,thread:10);model.channels.append(try searchChannel(94))
        model.openSearchDocument(target,owner:UUID());await model.documentPreviewTask?.value
        guard case .pdf(let pdf) = model.documentPreviewContent else { return XCTFail("Search PDF did not load") }
        XCTAssertEqual(pdf.pageCount,2);XCTAssertEqual(model.selection,93)
        XCTAssertTrue(model.jumpFromSearchDocument());XCTAssertEqual(model.selection,94);XCTAssertNil(model.documentPreviewPost);XCTAssertNil(model.searchDocumentOwner)
    }
    func testSearchAudioStreamsPausedAndRevokedChannelStopsPlayer() async throws {
        DocumentPreviewStub.payload = silentAudio();DocumentPreviewStub.supportsRanges = true
        let model = try await model(),target = try post(name:"research.wav",size:DocumentPreviewStub.payload.count,channel:94);model.channels.append(try searchChannel(94))
        model.openSearchDocument(target,owner:UUID());await model.documentPreviewTask?.value
        guard case .media(let playback) = model.documentPreviewContent else { return XCTFail("Search audio did not load") }
        XCTAssertNil(playback.file);XCTAssertEqual(playback.player.rate,0);XCTAssertEqual(model.selection,93);XCTAssertNotNil(model.searchDocumentOwner)
        model.channels = [try searchChannel(93),try searchChannel(94,overrides:["is_closed":true])]
        XCTAssertNil(model.searchDocumentOwner);XCTAssertNil(model.documentPreviewContent);XCTAssertNil(playback.player.currentItem)
    }
    func testSearchVideoFallbackOwnsLocalFileAndSelectionChangeDisposesIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-search-video-"+UUID().uuidString)
        let sources = try await NativeSyntheticMedia.files(in:folder);defer { try? FileManager.default.removeItem(at:folder) }
        DocumentPreviewStub.payload = try Data(contentsOf:sources[1]);DocumentPreviewStub.supportsRanges = false
        let model = try await model(),target = try post(name:"research.mp4",size:DocumentPreviewStub.payload.count,channel:94);model.channels.append(try searchChannel(94))
        model.openSearchDocument(target,owner:UUID());await model.documentPreviewTask?.value
        guard case .media(let playback) = model.documentPreviewContent else { return XCTFail("Search video did not load") }
        let local = try XCTUnwrap(playback.file);XCTAssertEqual(playback.kind,.video);XCTAssertEqual(playback.player.rate,0);XCTAssertTrue(FileManager.default.fileExists(atPath:local.path))
        model.selection = 94
        XCTAssertNil(model.searchDocumentOwner);XCTAssertNil(model.documentPreviewContent);XCTAssertNil(playback.player.currentItem);XCTAssertFalse(FileManager.default.fileExists(atPath:local.path));XCTAssertTrue(FileManager.default.fileExists(atPath:sources[1].path))
    }
    func testSearchDocumentScopeRejectsUnsupportedAndPrivateResultsBeforeFetch() async throws {
        let model = try await model();model.channels.append(try searchChannel(94));var reads = 0;DocumentPreviewStub.onRequest = { _ in reads += 1 }
        let unsupported = try post(name:"research.unknown-extension",channel:94)
        model.openSearchDocument(unsupported,owner:UUID());XCTAssertNil(model.documentPreviewPost)
        let target = try post(channel:94)
        for flags in [["encrypted":true],["is_joined":false],["is_closed":true],["hide_global_at":1000]] as [[String:Any]] {
            model.channels = [try searchChannel(93),try searchChannel(94,overrides:flags)];model.openSearchDocument(target,owner:UUID());XCTAssertNil(model.documentPreviewPost)
        }
        XCTAssertEqual(reads,0);XCTAssertNil(model.searchDocumentOwner)
    }
    func testClosingSearchDocumentCancelsItsReadBeforeNewOwnerPublishes() async throws {
        let model = try await model();model.channels.append(try searchChannel(94))
        let began = expectation(description:"Old search document held"),stopped = expectation(description:"Old search read cancelled")
        DocumentPreviewStub.stall = true;DocumentPreviewStub.onRequest = { _ in began.fulfill() };DocumentPreviewStub.onStop = { stopped.fulfill() }
        model.openSearchDocument(try post(channel:94),owner:UUID());let old = model.documentPreviewTask
        await fulfillment(of:[began],timeout:2);model.closeDocumentPreview();await old?.value;await fulfillment(of:[stopped],timeout:2)
        DocumentPreviewStub.stall = false;DocumentPreviewStub.onRequest = nil;DocumentPreviewStub.onStop = nil;DocumentPreviewStub.payload = Data("New search result".utf8)
        let owner = UUID();model.openSearchDocument(try post(2,channel:94),owner:owner);await model.documentPreviewTask?.value
        guard case .text(let text) = model.documentPreviewContent else { return XCTFail() }
        XCTAssertEqual(text,"New search result");XCTAssertEqual(model.searchDocumentOwner,owner);XCTAssertEqual(model.documentPreviewPost?.id,2);XCTAssertNil(model.documentPreviewError)
    }
    func testOrdinaryPreviewReplacesSearchOwnerWithoutBroadeningOtherSources() async throws {
        DocumentPreviewStub.payload = Data("Synthetic document".utf8)
        let model = try await model(),target = try post(channel:94);model.channels.append(try searchChannel(94))
        model.openSearchDocument(target,owner:UUID());await model.documentPreviewTask?.value
        XCTAssertTrue(model.canPreviewDocument(target));XCTAssertFalse(model.canPreviewDocument(try post(2,channel:94)))
        model.openDocumentPreview(try post(3));await model.documentPreviewTask?.value
        XCTAssertNil(model.searchDocumentOwner);XCTAssertEqual(model.documentPreviewPost?.id,3);XCTAssertFalse(model.canPreviewDocument(target))
        model.openSearchDocument(target,owner:UUID());model.signOutLocally();XCTAssertNil(model.searchDocumentOwner);XCTAssertNil(model.documentPreviewContent)
    }

}

private final class DocumentPreviewStub: URLProtocol {
    static var supportsRanges = false
    static var attachmentHeader = true
    static var payload = Data()
    static var stall = false
    static var onRequest: ((URLRequest) -> Void)?
    static var onStop: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let discovery = request.url!.path.contains("SYNO.API.Info")
        if !discovery {
            var observed = request
            if observed.httpBody == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
                observed.httpBody = bytes
            }
            Self.onRequest?(observed)
            if Self.stall { return }
        }
        var bytes = discovery ? Data(#"{"success":true,"data":{"SYNO.Chat.Post.File":{"path":"entry.cgi","minVersion":1,"maxVersion":2,"requestFormat":"JSON"}}}"#.utf8) : Self.payload
        var headers = discovery ? ["Content-Type": "application/json"] : ["Content-Type": "application/octet-stream", "Content-Disposition": "attachment; filename=synthetic.txt"]
        if !discovery && !Self.attachmentHeader { headers.removeValue(forKey:"Content-Disposition") }
        var status = 200
        if !discovery, Self.supportsRanges, let raw = request.value(forHTTPHeaderField: "Range"), raw.hasPrefix("bytes=") {
            let bounds = raw.dropFirst(6).split(separator: "-")
            guard bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]), start >= 0, end >= start, end < bytes.count else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse));return
            }
            headers["Content-Range"] = "bytes \(start)-\(end)/\(bytes.count)"
            bytes = bytes.subdata(in: start..<(end + 1)); headers["Content-Length"] = String(bytes.count); status = 206
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { if Self.stall { Self.onStop?() } }
}
