import AppKit
import ImageIO
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeComposerAttachmentTests:XCTestCase {
    private func pasteboard() -> NSPasteboard {
        let value = NSPasteboard(name:.init("native-attachment-test-"+UUID().uuidString))
        addTeardownBlock { value.clearContents() };return value
    }
    private func bitmap(_ format:NSBitmapImageRep.FileType = .png) throws -> Data {
        let value = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:3,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        value.bitmapData?.initialize(repeating:120,count:value.bytesPerRow*value.pixelsHigh)
        return try XCTUnwrap(value.representation(using:format,properties:[:]))
    }
    private func files(_ names:[String],on board:NSPasteboard) {
        board.clearContents()
        board.writeObjects(names.map { name in
            let item = NSPasteboardItem();item.setString(URL(fileURLWithPath:"/private/tmp/"+name).absoluteString,forType:.fileURL)
            item.setString("Do not insert file paths into text",forType:.string);return item
        })
    }
    private func model() throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference:false)
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0}"#.utf8))]
        model.selection = 93;model.connected = true;model.liveStatus = .live;model.draft = "Synthetic image caption"
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    private func root() throws -> ChatPost {
        try JSONDecoder().decode(ChatPost.self,from:Data(#"{"post_id":1,"channel_id":93,"creator_id":10,"message":"Synthetic root","type":"normal","create_at":1000}"#.utf8))
    }
    func testScreenshotStagesPrivateReviewAndDoesNotChangeDraft() async throws {
        let m = try model(),data = try bitmap();let draft = m.draft
        m.captureScreenshot(capture:{data});await m.composerAttachmentTask?.value
        let batch = try XCTUnwrap(m.attachmentBatch),file = try XCTUnwrap(batch.items.first?.localFile)
        XCTAssertEqual(file.lastPathComponent,"Screenshot.png");XCTAssertEqual(try Data(contentsOf:file),data);XCTAssertEqual(batch.originalCaption,draft);XCTAssertEqual(m.draft,draft);XCTAssertFalse(m.capturingScreenshot)
        XCTAssertEqual(try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile,true)
        m.dismissAttachmentBatch();XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
    func testScreenshotThreadReviewKeepsMainDraftAndRoot() async throws {
        let m = try model(),data = try bitmap();m.threadRoot = try root();m.replyDraft = "Thread screenshot caption"
        m.captureScreenshot(inThread:true,capture:{data});await m.composerAttachmentTask?.value
        XCTAssertEqual(m.attachmentBatch?.rootID,1);XCTAssertEqual(m.attachmentBatch?.originalCaption,"Thread screenshot caption");XCTAssertEqual(m.draft,"Synthetic image caption")
    }
    func testCancelledSelectionAndFailedCaptureSendNothing() async throws {
        let m = try model();m.captureScreenshot(capture:{nil});await m.composerAttachmentTask?.value
        XCTAssertNil(m.attachmentBatch);XCTAssertNil(m.error);XCTAssertFalse(m.preparingComposerAttachment);XCTAssertEqual(m.draft,"Synthetic image caption")
        m.captureScreenshot(capture:{throw ChatTransferError(message:"Synthetic capture error")});await m.composerAttachmentTask?.value
        XCTAssertNil(m.attachmentBatch);XCTAssertEqual(m.error,"Synthetic capture error");XCTAssertFalse(m.capturingScreenshot)
    }
    func testScreenshotCancelDestinationSignoutAndThreadClosePreventLateStaging() async throws {
        for change in 0..<4 {
            let m = try model(),data = try bitmap(),gate = ScreenshotCaptureTestGate(),started = expectation(description:"Capture started")
            if change == 3 {m.threadRoot = try root()}
            m.captureScreenshot(inThread:change == 3,capture:{started.fulfill();return try await gate.capture()})
            let running = m.composerAttachmentTask;await fulfillment(of:[started],timeout:2)
            XCTAssertTrue(m.capturingScreenshot)
            switch change {case 0:m.cancelScreenshotCapture();case 1:m.selection = 94;case 2:m.signOutLocally();default:m.closeThread()}
            await gate.finish(data);await running?.value
            XCTAssertNil(m.attachmentBatch);XCTAssertFalse(m.preparingComposerAttachment);XCTAssertFalse(m.capturingScreenshot)
        }
    }
    func testMalformedScreenshotRejectedBeforeAttachmentReview() async throws {
        let m = try model();m.captureScreenshot(capture:{Data("invalid image".utf8)});await m.composerAttachmentTask?.value
        XCTAssertNil(m.attachmentBatch);XCTAssertNotNil(m.error);XCTAssertFalse(m.capturingScreenshot)
        XCTAssertThrowsError(try NativeComposerAttachmentReader.writeImage(try bitmap(),format:"png",basename:"../escape"))
    }
    func testScreenshotCopyIsByteEqualAndDoesNotUploadOrRemoveReview() async throws {
        let m = try model(),data = try bitmap();m.captureScreenshot(capture:{data});await m.composerAttachmentTask?.value
        let batch = try XCTUnwrap(m.attachmentBatch),item = try XCTUnwrap(batch.items.first),source = try XCTUnwrap(item.localFile)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png");defer {try? FileManager.default.removeItem(at:destination)}
        let saved = try await m.saveScreenshotCopy(itemID:item.id,chooseDestination:{_ in destination})
        XCTAssertTrue(saved);XCTAssertEqual(try Data(contentsOf:destination),data);XCTAssertTrue(FileManager.default.fileExists(atPath:source.path));XCTAssertEqual(batch.items.first?.state,.queued);XCTAssertEqual(batch.sentCount,0)
        m.dismissAttachmentBatch();XCTAssertFalse(FileManager.default.fileExists(atPath:source.path));XCTAssertEqual(try Data(contentsOf:destination),data)
    }
    func testScreenshotSaveCancelAndChangedReviewPreserveDestination() async throws {
        for change in 0..<3 {
            let m = try model(),data = try bitmap();m.captureScreenshot(capture:{data});await m.composerAttachmentTask?.value
            let item = try XCTUnwrap(m.attachmentBatch?.items.first),destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png"),original = Data("keep existing destination".utf8)
            try original.write(to:destination);defer {try? FileManager.default.removeItem(at:destination)}
            do {
                let saved = try await m.saveScreenshotCopy(itemID:item.id,chooseDestination:{_ in
                    if change == 0 {return nil};if change == 1 {m.selection = 94} else {m.dismissAttachmentBatch()};return destination
                });XCTAssertFalse(saved);XCTAssertEqual(change,0)
            } catch is CancellationError {XCTAssertNotEqual(change,0)}
            XCTAssertEqual(try Data(contentsOf:destination),original)
        }
    }
    func testScreenshotCopyAtomicallyReplacesRegularFileAndRejectsLinksOrSelf() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false);defer {try? FileManager.default.removeItem(at:folder)}
        let source = folder.appendingPathComponent("source.png"),destination = folder.appendingPathComponent("copy.png"),link = folder.appendingPathComponent("link.png"),data = try bitmap()
        try data.write(to:source);try Data("old".utf8).write(to:destination)
        let staged = try NativeScreenshotCopy.stage(source,to:destination);try NativeScreenshotCopy.commit(staged,to:destination);XCTAssertEqual(try Data(contentsOf:destination),data)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:destination)
        XCTAssertThrowsError(try NativeScreenshotCopy.stage(source,to:link));XCTAssertEqual(try Data(contentsOf:destination),data)
        XCTAssertThrowsError(try NativeScreenshotCopy.stage(source,to:source));XCTAssertEqual(try Data(contentsOf:source),data)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:folder.path).contains {$0.hasPrefix(".native-chat-screenshot-save-")})
    }
    func testFileReferencesTakePriorityOverTextAndKeepMultipleFiles() {
        let board = pasteboard();files(["a.txt","b.txt"],on:board)
        XCTAssertTrue(NativeComposerAttachmentReader.hasAttachment(board))
        guard case .files(let urls) = NativeComposerAttachmentReader.read(board) else { return XCTFail("Files were not recognized") }
        XCTAssertEqual(urls.map(\.lastPathComponent),["a.txt","b.txt"])
    }
    func testOrdinaryTextAndWebURLsStayTextAndPromisesDoNotBecomePaths() {
        let board = pasteboard();board.setString("https://example.invalid/ordinary text",forType:.string)
        XCTAssertFalse(NativeComposerAttachmentReader.hasAttachment(board))
        guard case .none = NativeComposerAttachmentReader.read(board) else { return XCTFail("Text was captured as an attachment") }
        board.clearContents();board.setString("public.png",forType:NativeComposerAttachmentReader.promiseTypes[0])
        guard case .invalid = NativeComposerAttachmentReader.read(board) else { return XCTFail("Unsupported promise accepted") }
        board.clearContents();board.setString("https://example.invalid/private",forType:.fileURL)
        guard case .invalid = NativeComposerAttachmentReader.read(board) else { return XCTFail("Remote file URL accepted") }
    }
    func testPNGIsPreservedByteForByteWithPrivateTemporaryPermissionsAndCleanup() throws {
        let data = try bitmap();let board = pasteboard();board.setData(data,forType:.png)
        guard case .image(let extracted,let format) = NativeComposerAttachmentReader.read(board) else { return XCTFail("PNG not recognized") }
        XCTAssertEqual(extracted,data);XCTAssertEqual(format,"png")
        let file = try NativeComposerAttachmentReader.writeImage(extracted,format:format)
        XCTAssertEqual(try Data(contentsOf:file),data)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue,0o700)
        NativeComposerAttachmentReader.removeImage(file);XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
    func testTIFFConvertsToPNGWithoutChangingPixelDimensionsAndMalformedDataFails() throws {
        let file = try NativeComposerAttachmentReader.writeImage(bitmap(.tiff),format:"tiff")
        defer { NativeComposerAttachmentReader.removeImage(file) }
        XCTAssertEqual(file.pathExtension,"png")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(Data(contentsOf:file) as CFData,nil))
        let values = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])
        XCTAssertEqual((values[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,3)
        XCTAssertEqual((values[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,2)
        XCTAssertThrowsError(try NativeComposerAttachmentReader.writeImage(Data("Not an image".utf8),format:"png"))
        XCTAssertThrowsError(try NativeComposerAttachmentReader.writeImage(bitmap(.tiff),format:"png"))
    }
    func testActualComposerConsumerDoesNotInsertPathsOrChangeTextSelection() {
        let board = pasteboard();files(["a.txt","b.txt"],on:board)
        let view = NativeComposerText.ComposerTextView(frame:NSRect(x:0,y:0,width:300,height:80))
        view.isEditable = true;view.string = "Keep this draft 👀";view.setSelectedRange(NSRange(location:5,length:4))
        var received:[URL] = []
        view.onAttachmentInput = { if case .files(let urls) = $0 { received = urls } }
        XCTAssertEqual(view.attachmentDragOperation(board),.copy)
        XCTAssertTrue(view.consumeAttachment(board));XCTAssertEqual(received.count,2)
        XCTAssertEqual(view.string,"Keep this draft 👀");XCTAssertEqual(view.selectedRange(),NSRange(location:5,length:4))
        view.isEditable = false;XCTAssertEqual(view.attachmentDragOperation(board),[])
        view.isEditable = true;view.onAttachmentInput = nil;XCTAssertEqual(view.attachmentDragOperation(board),[])
        let text = pasteboard();text.setString("Plain text",forType:.string);XCTAssertFalse(view.consumeAttachment(text))
    }
    func testActualComposerDropRechecksCopyAndEditingStateAtRelease() throws {
        let board = pasteboard()
        let view = NativeComposerText.ComposerTextView(frame:NSRect(x:0,y:0,width:300,height:80))
        view.isEditable = true;view.string = "Retain this caption 👀"
        view.setSelectedRange(NSRange(location:7,length:4))
        let drag = SyntheticFileDraggingInfo(board)
        var deliveries = 0
        let receive: (NativeComposerAttachmentInput)->Void = { _ in deliveries += 1 }
        // Exercise both existing local files and an image without a file URL.
        for image in [false,true] {
            board.clearContents()
            if image { board.setData(try bitmap(),forType:.png) }
            else { files(["Synthetic.txt"],on:board) }
            view.onAttachmentInput = receive;view.isEditable = true
            drag.draggingSourceOperationMask = .copy
            XCTAssertEqual(view.draggingEntered(drag),.copy)
            XCTAssertTrue(view.prepareForDragOperation(drag))
            let before = deliveries
            drag.draggingSourceOperationMask = .move
            XCTAssertFalse(view.performDragOperation(drag))
            drag.draggingSourceOperationMask = .copy;view.isEditable = false
            XCTAssertFalse(view.performDragOperation(drag))
            view.isEditable = true;view.onAttachmentInput = nil
            XCTAssertFalse(view.performDragOperation(drag))
            XCTAssertEqual(deliveries,before)
            view.onAttachmentInput = receive
            XCTAssertTrue(view.performDragOperation(drag))
            XCTAssertEqual(deliveries,before+1)
            XCTAssertEqual(view.string,"Retain this caption 👀")
            XCTAssertEqual(view.selectedRange(),NSRange(location:7,length:4))
        }
    }
    func testModelFileIngestionStagesReviewWithoutSendingOrDeletingSourceFile() throws {
        let model = try model()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("native-user-source-test-"+UUID().uuidString+".txt")
        try Data("Synthetic source".utf8).write(to:file);defer { try? FileManager.default.removeItem(at:file) }
        model.receiveComposerAttachment(.files([file]))
        XCTAssertEqual(model.attachmentBatch?.items.first?.localFile,file);XCTAssertFalse(model.canSend);XCTAssertFalse(model.uploading)
        model.dismissAttachmentBatch();XCTAssertTrue(FileManager.default.fileExists(atPath:file.path));XCTAssertEqual(model.draft,"Synthetic image caption")
    }
    func testActualComposerConsumesAllRasterItemsWithoutChangingDraftOrSelection() async throws {
        let board = pasteboard(), png = try bitmap(), tiff = try bitmap(.tiff)
        let first = NSPasteboardItem(); first.setData(png, forType: .png)
        let second = NSPasteboardItem(); second.setData(tiff, forType: .tiff)
        XCTAssertTrue(board.writeObjects([first, second]))
        let model = try model()
        let view = NativeComposerText.ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        view.isEditable = true; view.string = model.draft
        let selection = NSRange(location: 3, length: 5); view.setSelectedRange(selection)
        view.onAttachmentInput = { model.receiveComposerAttachment($0) }
        XCTAssertTrue(view.consumeAttachment(board))
        await model.composerAttachmentTask?.value
        let items = try XCTUnwrap(model.attachmentBatch).items
        XCTAssertEqual(items.count, 2, "Every clipboard image must reach the review")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(items.first?.localFile)), png)
        XCTAssertEqual(view.string, "Synthetic image caption"); XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertEqual(model.draft, "Synthetic image caption"); XCTAssertFalse(model.uploading)
        let generated = items.compactMap(\.localFile)
        model.dismissAttachmentBatch()
        XCTAssertTrue(generated.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
    func testMixedClipboardItemsKeepOrderAndPreferSavedFileRepresentation() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("native-paste-source-" + UUID().uuidString + ".txt")
        try Data("Synthetic local source".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let board = pasteboard(), png = try bitmap()
        let first = NSPasteboardItem(); first.setData(png, forType: .png)
        let second = NSPasteboardItem(); second.setString(source.absoluteString, forType: .fileURL)
        second.setData(Data("Invalid alternate raster must not be used".utf8), forType: .png)
        let third = NSPasteboardItem(); third.setData(try bitmap(.tiff), forType: .tiff)
        XCTAssertTrue(board.writeObjects([first, second, third]))
        let m = try model(); m.threadRoot = try root(); m.replyDraft = "Reply caption 🌍  "
        m.receiveComposerAttachment(NativeComposerAttachmentReader.read(board), inThread: true)
        await m.composerAttachmentTask?.value
        let batch = try XCTUnwrap(m.attachmentBatch)
        XCTAssertEqual(batch.items.count, 3); XCTAssertEqual(batch.rootID, 1)
        XCTAssertEqual(batch.items[1].localFile, source)
        XCTAssertEqual(batch.items.map(\.caption), ["Reply caption 🌍  ", "", ""])
        XCTAssertEqual(m.replyDraft, "Reply caption 🌍  "); XCTAssertEqual(m.draft, "Synthetic image caption")
        let generated = batch.items.compactMap(\.localFile).filter { $0 != source }
        XCTAssertEqual(generated.count, 2)
        m.closeThread()
        XCTAssertTrue(generated.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testRasterPasteRejectsUnsupportedSiblingAndCompleteSelectionOverflow() throws {
        let png = try bitmap()
        for overflow in [false, true] {
            let board = pasteboard()
            var items: [NSPasteboardItem] = []
            for _ in 0..<(overflow ? 101 : 1) {
                let item = NSPasteboardItem(); item.setData(png, forType: .png); items.append(item)
            }
            if !overflow { let item = NSPasteboardItem(); item.setString("Keep whole selection", forType: .string); items.append(item) }
            XCTAssertTrue(board.writeObjects(items))
            guard case .invalid = NativeComposerAttachmentReader.read(board) else { return XCTFail("Partial clipboard selection accepted") }
        }
    }
    func testFailedRasterPreparationRemovesEarlierGeneratedImages() throws {
        let folder = FileManager.default.temporaryDirectory
        func generatedFolders() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("native-chat-paste-") })
        }
        let before = try generatedFolders()
        XCTAssertThrowsError(try NativeComposerAttachmentReader.prepare([.image(try bitmap(), "png"), .image(Data("Malformed second raster".utf8), "png")]))
        XCTAssertEqual(try generatedFolders(), before)
    }
    func testMultiRasterAppendOverflowPreservesExistingReviewAndCleansGeneratedFiles() async throws {
        let m = try model(), folder = FileManager.default.temporaryDirectory
        let existing = (0..<99).map { folder.appendingPathComponent("synthetic-existing-\($0).txt") }
        m.stageAttachments(existing)
        let batch = try XCTUnwrap(m.attachmentBatch), ids = batch.items.map(\.id)
        batch.caption(batch.items[0].id, text: "Keep edited caption")
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("native-chat-paste-") })
        let png = try bitmap()
        m.receiveComposerAttachment(.items([.image(png,"png"),.image(png,"png")]))
        await m.composerAttachmentTask?.value
        XCTAssertEqual(m.attachmentBatch?.id, batch.id); XCTAssertEqual(batch.items.map(\.id), ids)
        XCTAssertEqual(batch.items[0].caption, "Keep edited caption"); XCTAssertNotNil(m.error)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("native-chat-paste-") }), before)
        m.receiveComposerAttachment(.items([.image(png,"png")]))
        await m.composerAttachmentTask?.value
        XCTAssertEqual(batch.items.count, 100); XCTAssertNil(m.error)
        let generated = try XCTUnwrap(batch.items.last?.localFile)
        m.dismissAttachmentBatch(); XCTAssertFalse(FileManager.default.fileExists(atPath: generated.path))
    }
    func testModelImageIngestionReviewsAndDeletesOnlyGeneratedFileOnClose() async throws {
        let model = try model();let data = try bitmap()
        model.receiveComposerAttachment(.image(data,"png"));XCTAssertTrue(model.preparingComposerAttachment);XCTAssertFalse(model.canSend)
        await model.composerAttachmentTask?.value
        let file = try XCTUnwrap(model.attachmentBatch?.items.first?.localFile)
        XCTAssertEqual(try Data(contentsOf:file),data);XCTAssertFalse(model.preparingComposerAttachment);XCTAssertFalse(model.uploading)
        model.dismissAttachmentBatch();XCTAssertFalse(FileManager.default.fileExists(atPath:file.path));XCTAssertEqual(model.draft,"Synthetic image caption")
    }
    func testThreadImageRoutesToRootAndCleanupFollowsThreadClosure() async throws {
        let model = try model();model.threadRoot = try root();model.replyDraft = "Synthetic thread caption"
        model.receiveComposerAttachment(.image(try bitmap(),"png"),inThread:true)
        await model.composerAttachmentTask?.value
        XCTAssertEqual(model.attachmentBatch?.rootID,1)
        let file = try XCTUnwrap(model.attachmentBatch?.items.first?.localFile)
        model.closeThread();XCTAssertNil(model.attachmentBatch);XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
    func testDestinationChangeAndSignOutPreventLateImageStaging() async throws {
        for signOut in [false,true] {
            let model = try model();model.receiveComposerAttachment(.image(try bitmap(),"png"))
            let task = model.composerAttachmentTask
            if signOut { model.signOutLocally() } else { model.selection = 94 }
            await task?.value
            XCTAssertNil(model.attachmentBatch);XCTAssertFalse(model.preparingComposerAttachment);XCTAssertNil(model.error)
        }
    }
}

private actor ScreenshotCaptureTestGate {
    private var continuation:CheckedContinuation<Data?,Error>?
    private var pending:Data?
    func capture() async throws->Data? {if let pending {return pending};return try await withCheckedThrowingContinuation {continuation = $0}}
    func finish(_ data:Data) {if let continuation {self.continuation = nil;continuation.resume(returning:data)} else {pending = data}}
}
