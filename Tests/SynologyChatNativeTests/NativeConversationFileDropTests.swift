import AppKit
import UniformTypeIdentifiers
import SwiftUI
import XCTest
@testable import SynologyChatNative

private final class DroppedFileGate:@unchecked Sendable {
    private let lock = NSLock()
    private var callback:((Data?,Error?)->Void)?
    var started:Bool { lock.lock();defer{lock.unlock()};return callback != nil }
    func start(_ completion:@escaping(Data?,Error?)->Void)->Progress {
        lock.lock();callback = completion;lock.unlock();return Progress(totalUnitCount:1)
    }
    func finish(_ data:Data) {
        lock.lock();let callback = callback;self.callback = nil;lock.unlock();callback?(data,nil)
    }
}

@MainActor final class NativeConversationFileDropTests:XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-file-drop-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        addTeardownBlock{try? FileManager.default.removeItem(at:url)};return url
    }
    private func file(_ name:String = "Synthetic file.txt") throws -> URL {
        let url = try folder().appendingPathComponent(name);try Data("Synthetic file drop content".utf8).write(to:url);return url
    }
    private func provider(_ url:URL)->NSItemProvider { NSItemProvider(object:url as NSURL) }
    private func dataProvider(_ data:Data)->NSItemProvider {
        let p = NSItemProvider();p.registerDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier,visibility:.all) { callback in callback(data,nil);return nil };return p
    }
    private func held()->(NSItemProvider,DroppedFileGate) {
        let gate = DroppedFileGate(),p = NSItemProvider()
        p.registerDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier,visibility:.all) { callback in gate.start(callback) };return(p,gate)
    }
    private func wait(_ gate:DroppedFileGate) async throws {
        for _ in 0..<100 where !gate.started { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertTrue(gate.started)
    }
    private func model() throws -> NativeChatPreviewModel {
        let m = NativeChatPreviewModel(restoreNotificationPreference:false)
        m.channels = try [93,94].map{try JSONDecoder().decode(ChatChannel.self,from:Data("{\"channel_id\":\($0),\"name\":\"Synthetic\",\"type\":\"anonymous\",\"encrypted\":false,\"unread\":0}".utf8))}
        m.selection = 93;m.connected = true;m.liveStatus = .live;m.draft = "Main draft stays"
        addTeardownBlock{@MainActor in m.signOutLocally()};return m
    }
    private func root() throws -> ChatPost { try JSONDecoder().decode(ChatPost.self,from:Data(#"{"post_id":1,"channel_id":93,"creator_id":10,"message":"Synthetic root","type":"normal","create_at":1000}"#.utf8)) }
    private func pasteboard(_ references:[String])->NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        let items = references.map { text in let item = NSPasteboardItem();item.setString(text,forType:.fileURL);return item }
        board.writeObjects(items);addTeardownBlock { board.releaseGlobally() };return board
    }
    func testNativeHostingDestinationStagesCompleteThreadBatchWithoutSending() async throws {
        let m = try model(),a = try file(),b = try file("Second.txt")
        m.threadRoot = try root();m.replyDraft = "Native thread caption"
        let container = NativeConversationDropContainer(content:AnyView(Text("Synthetic viewport")))
        container.frame = CGRect(x:0,y:0,width:400,height:300);container.layout()
        container.canReceive = { m.canReceiveConversationFileDrop(inThread:true) }
        container.receive = { m.receiveConversationFileDrop($0,inThread:true) }
        let drag = SyntheticFileDraggingInfo(pasteboard([a.absoluteString,b.absoluteString,a.absoluteString]))
        XCTAssertTrue(container.registeredDraggedTypes.contains(.fileURL))
        XCTAssertTrue(container.host.registeredDraggedTypes.contains(.fileURL))
        XCTAssertEqual(container.host.frame,container.bounds.insetBy(dx:2,dy:2))
        XCTAssertEqual(container.host.draggingEntered(drag),.copy)
        XCTAssertTrue(container.host.prepareForDragOperation(drag))
        XCTAssertTrue(container.host.performDragOperation(drag))
        await m.composerAttachmentTask?.value
        XCTAssertEqual(m.attachmentBatch?.items.compactMap(\.localFile),[a,b])
        XCTAssertEqual(m.attachmentBatch?.rootID,1)
        XCTAssertEqual(m.attachmentBatch?.items.map(\.caption),["Native thread caption",""])
        XCTAssertEqual(m.draft,"Main draft stays");XCTAssertFalse(m.sending)
        XCTAssertEqual(container.host.draggingUpdated(drag),[])
        container.host.concludeDragOperation(drag);XCTAssertEqual(container.layer?.borderWidth,0)
    }
    func testNativeDestinationRechecksEligibilityBeforePerformAndRejectsMoveOnly() throws {
        let a = try file(),drag = SyntheticFileDraggingInfo(pasteboard([a.absoluteString]))
        let container = NativeConversationDropContainer(content:AnyView(Text("Synthetic viewport")))
        var allowed = true,received = false
        container.canReceive = { allowed };container.receive = { _ in received = true;return true }
        XCTAssertEqual(container.host.draggingEntered(drag),.copy)
        allowed = false
        XCTAssertFalse(container.host.prepareForDragOperation(drag));XCTAssertFalse(container.host.performDragOperation(drag));XCTAssertFalse(received)
        allowed = true;drag.draggingSourceOperationMask = .move
        XCTAssertEqual(container.host.draggingEntered(drag),[]);XCTAssertFalse(container.host.performDragOperation(drag));XCTAssertFalse(received)
        XCTAssertEqual(container.layer?.borderWidth,0)
    }
    func testNativePasteboardNeverFiltersInvalidReferenceFromOtherwiseValidBatch() async throws {
        let a = try file()
        for invalid in ["https://synthetic.invalid/file.txt","not a file URL","file://remote.invalid/tmp/fixture.txt"] {
            let board = pasteboard([a.absoluteString,invalid])
            let providers = try XCTUnwrap(NativeConversationFileDropReader.providers(from:board))
            XCTAssertEqual(providers.count,2)
            do { _ = try await NativeConversationFileDropReader.read(providers);XCTFail("Invalid batch accepted") } catch { }
        }
    }
    func testNativePasteboardRejectsMixedTypesAndBoundsWithoutPartialExtraction() throws {
        let a = try file(),board = pasteboard([a.absoluteString]),text = NSPasteboardItem()
        text.setString("Synthetic plain text",forType:.string)
        board.writeObjects([text])
        XCTAssertFalse(NativeConversationFileDropReader.hasFileReferences(board))
        XCTAssertNil(NativeConversationFileDropReader.providers(from:board))
        for references in [Array(repeating:a.absoluteString,count:101),[a.absoluteString,String(repeating:"x",count:16_385)],[a.absoluteString,""]] {
            XCTAssertNil(NativeConversationFileDropReader.providers(from:pasteboard(references)))
        }
    }
    func testNativeHoverDoesNotReadLazyPasteboardData() throws {
        let a = try file(),board = NSPasteboard.withUniqueName(),item = NSPasteboardItem()
        addTeardownBlock { board.releaseGlobally() }
        let source = SyntheticLazyFileReference(a.absoluteString)
        XCTAssertTrue(item.setDataProvider(source,forTypes:[.fileURL]));XCTAssertTrue(board.writeObjects([item]))
        let container = NativeConversationDropContainer(content:AnyView(Text("Synthetic viewport")))
        container.canReceive = { true };container.receive = { $0.count == 1 }
        let drag = SyntheticFileDraggingInfo(board)
        XCTAssertEqual(container.host.draggingEntered(drag),.copy)
        XCTAssertEqual(container.host.draggingUpdated(drag),.copy)
        XCTAssertTrue(container.host.prepareForDragOperation(drag));XCTAssertEqual(source.reads,0)
        XCTAssertTrue(container.host.performDragOperation(drag));XCTAssertEqual(source.reads,1)
        container.host.draggingExited(drag);XCTAssertEqual(container.layer?.borderWidth,0)
    }
    func testSuccessfulTransferProgressIsNeverMarkedCancelled() async throws {
        for synchronousCallback in [true,false] {
            let request = NativeFileDropRequest(),progress = Progress(totalUnitCount:1),bytes = Data("Synthetic file reference".utf8)
            let result:Data = try await withCheckedThrowingContinuation { continuation in
                XCTAssertTrue(request.install(continuation))
                if synchronousCallback { request.finish(.success(bytes));request.setProgress(progress) }
                else { request.setProgress(progress);request.finish(.success(bytes)) }
            }
            XCTAssertEqual(result,bytes);XCTAssertFalse(progress.isCancelled)
        }
    }
    func testCancellationBeforeAndAfterProviderInstallationCancelsProgress() async {
        for cancelledBeforeInstall in [true,false] {
            let request = NativeFileDropRequest(),progress = Progress(totalUnitCount:1)
            if cancelledBeforeInstall { request.finish(.failure(CancellationError())) }
            do {
                let _:Data = try await withCheckedThrowingContinuation { continuation in
                    let installed = request.install(continuation);request.setProgress(progress)
                    if installed { request.finish(.failure(CancellationError())) }
                }
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(progress.isCancelled)
            request.finish(.success(Data())) // An uncooperative late callback stays ignored.
        }
    }
    func testRealURLProvidersPreserveOrderUnicodeAndDeduplicate() async throws {
        let a = try file("😀 a%20 #.txt"),b = try file("Second.txt")
        let files = try await NativeConversationFileDropReader.read([provider(a),provider(b),provider(a)])
        XCTAssertEqual(files,[a,b])
    }
    func testMissingFolderSymlinkAndRemoteFilesAreRejectedAsAWhole() async throws {
        let a = try file(),dir = try folder(),link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:a)
        for bad in [dir,link,dir.appendingPathComponent("missing.txt"),URL(string:"https://synthetic.invalid/file.txt")!] {
            do { _ = try await NativeConversationFileDropReader.read([provider(a),dataProvider(Data(bad.absoluteString.utf8))]);XCTFail("Invalid file accepted") } catch { }
        }
    }
    func testBoundsAndMalformedRepresentationsFailBeforeStaging() async throws {
        let a = try file(),p = provider(a)
        let cases:[[NSItemProvider]] = [[],Array(repeating:p,count:101),[NSItemProvider(object:"Text only" as NSString)],[dataProvider(Data(repeating:65,count:16385))],[dataProvider(Data("file:///tmp/a\0.txt".utf8))],[dataProvider(Data("file://remote.invalid/tmp/a.txt".utf8))]]
        for providers in cases { do { _ = try await NativeConversationFileDropReader.read(providers);XCTFail("Invalid drop accepted") } catch { } }
    }
    func testStalledProviderTimesOutAndLateCompletionDoesNotResumeTwice() async throws {
        let (p,gate) = held(),file = try file()
        do { _ = try await NativeConversationFileDropReader.read([p],timeoutNanoseconds:50_000_000);XCTFail("Expected timeout") } catch { XCTAssertTrue((error as? ChatTransferError)?.message.contains("too long") == true) }
        gate.finish(Data(file.absoluteString.utf8));await Task.yield()
    }
    func testCancellationDoesNotWaitForProviderCompletion() async throws {
        let (p,gate) = held(),file = try file()
        let task = Task { try await NativeConversationFileDropReader.read([p]) }
        try await wait(gate);task.cancel()
        do { _ = try await task.value;XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        gate.finish(Data(file.absoluteString.utf8));await Task.yield()
    }
    func testMainDropStagesOnlyReviewAndKeepsCaptionAndOrder() async throws {
        let m = try model(),a = try file(),b = try file("Second.txt")
        XCTAssertTrue(m.receiveConversationFileDrop([provider(a),provider(b),provider(a)]))
        await m.composerAttachmentTask?.value
        XCTAssertEqual(m.attachmentBatch?.items.compactMap(\.localFile),[a,b]);XCTAssertEqual(m.attachmentBatch?.items.map(\.caption),["Main draft stays",""])
        XCTAssertEqual(m.draft,"Main draft stays");XCTAssertFalse(m.sending);XCTAssertFalse(m.preparingComposerAttachment)
    }
    func testThreadDropUsesReplyCaptionWithoutTouchingMainDraft() async throws {
        let m = try model(),file = try file();m.threadRoot = try root();m.replyDraft = "Thread draft stays"
        XCTAssertTrue(m.receiveConversationFileDrop([provider(file)],inThread:true));await m.composerAttachmentTask?.value
        XCTAssertEqual(m.attachmentBatch?.rootID,1);XCTAssertEqual(m.attachmentBatch?.originalCaption,"Thread draft stays");XCTAssertEqual(m.draft,"Main draft stays");XCTAssertEqual(m.replyDraft,"Thread draft stays")
    }
    func testChangingConversationCancelsHeldDropAndLateFilesAreDiscarded() async throws {
        let m = try model(),file = try file(),(p,gate) = held()
        XCTAssertTrue(m.receiveConversationFileDrop([p]));let task = try XCTUnwrap(m.composerAttachmentTask);try await wait(gate)
        m.selection = 94;m.selection = 93;await task.value;gate.finish(Data(file.absoluteString.utf8));await Task.yield()
        XCTAssertNil(m.attachmentBatch);XCTAssertFalse(m.preparingComposerAttachment);XCTAssertNil(m.error)
    }
    func testAccountDisconnectCancelsHeldDropWithoutPublishingIntoNewAccount() async throws {
        let m = try model(),file = try file(),(p,gate) = held()
        XCTAssertTrue(m.receiveConversationFileDrop([p]));let task = try XCTUnwrap(m.composerAttachmentTask);try await wait(gate)
        let previousChannels = m.channels;m.signOutLocally();m.channels = previousChannels;m.connected = true;m.liveStatus = .live;m.selection = 93;m.draft = "New account draft"
        await task.value;gate.finish(Data(file.absoluteString.utf8));await Task.yield()
        XCTAssertNil(m.attachmentBatch);XCTAssertFalse(m.preparingComposerAttachment);XCTAssertNil(m.error);XCTAssertEqual(m.draft,"New account draft")
    }
    func testClosingThreadDiscardsHeldDrop() async throws {
        let m = try model(),file = try file(),(p,gate) = held();m.threadRoot = try root();m.replyDraft = "Thread draft"
        XCTAssertTrue(m.receiveConversationFileDrop([p],inThread:true));let task = try XCTUnwrap(m.composerAttachmentTask);try await wait(gate)
        m.closeThread();await task.value;gate.finish(Data(file.absoluteString.utf8));await Task.yield()
        XCTAssertNil(m.attachmentBatch);XCTAssertEqual(m.draft,"Main draft stays")
    }
    func testOverlappingDropAndInactiveEditingDestinationsAreRejected() async throws {
        let m = try model(),file = try file(),(p,gate) = held()
        XCTAssertTrue(m.receiveConversationFileDrop([p]));let task = try XCTUnwrap(m.composerAttachmentTask);try await wait(gate)
        XCTAssertFalse(m.receiveConversationFileDrop([provider(file)]));gate.finish(Data(file.absoluteString.utf8));await task.value
        XCTAssertFalse(m.canReceiveConversationFileDrop());m.dismissAttachmentBatch()
        let owner = UUID();m.beginMessageEditing(owner:owner);XCTAssertFalse(m.receiveConversationFileDrop([provider(file)]));m.endMessageEditing(owner:owner)
        m.sending = true;XCTAssertFalse(m.canReceiveConversationFileDrop());m.sending = false
        m.connected = false;XCTAssertFalse(m.canReceiveConversationFileDrop())
    }
    func testFailedBatchDoesNotStageValidPrefixOrConsumeDraft() async throws {
        let m = try model(),a = try file(),missing = try folder().appendingPathComponent("missing.txt")
        XCTAssertTrue(m.receiveConversationFileDrop([provider(a),dataProvider(Data(missing.absoluteString.utf8))]));await m.composerAttachmentTask?.value
        XCTAssertNil(m.attachmentBatch);XCTAssertEqual(m.draft,"Main draft stays");XCTAssertNotNil(m.error);XCTAssertTrue(m.canReceiveConversationFileDrop())
    }
    func testLostReadAccessAndChangedEncryptionEnvelopeCancelHeldDrops() async throws {
        for loseAccess in [true,false] {
            let m = try model(),file = try file(),(p,gate) = held()
            XCTAssertTrue(m.receiveConversationFileDrop([p]));let task = try XCTUnwrap(m.composerAttachmentTask);try await wait(gate)
            if loseAccess { m.channels = [] }
            else { m.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Synthetic","type":"anonymous","encrypted":false,"channel_key_enc":"replacement-envelope","unread":0}"#.utf8))] }
            await task.value;gate.finish(Data(file.absoluteString.utf8));await Task.yield()
            XCTAssertNil(m.attachmentBatch);XCTAssertFalse(m.preparingComposerAttachment)
        }
    }
    func testAChangedThreadRootCannotReceiveThePreviousDrop() async throws {
        let m = try model(),file = try file(),(p,gate) = held();m.threadRoot = try root()
        XCTAssertTrue(m.receiveConversationFileDrop([p],inThread:true));let task = try XCTUnwrap(m.composerAttachmentTask);try await wait(gate)
        m.threadRoot = try JSONDecoder().decode(ChatPost.self,from:Data(#"{"post_id":2,"channel_id":93,"creator_id":10,"message":"Another synthetic root","type":"normal","create_at":1000}"#.utf8))
        gate.finish(Data(file.absoluteString.utf8));await task.value
        XCTAssertNil(m.attachmentBatch);XCTAssertEqual(m.threadRoot?.id,2)
    }
    func testExplicitCancelAllowsNewDropAndOldCompletionCannotReplaceIt() async throws {
        let m = try model(),oldFile = try file("Old.txt"),newFile = try file("New.txt"),(p,gate) = held()
        m.error = "Previous drop failed"
        XCTAssertTrue(m.receiveConversationFileDrop([p]));XCTAssertNil(m.error);let oldTask = try XCTUnwrap(m.composerAttachmentTask);try await wait(gate)
        m.cancelAttachmentPreparation();XCTAssertFalse(m.preparingComposerAttachment);await oldTask.value
        XCTAssertTrue(m.receiveConversationFileDrop([provider(newFile)]));await m.composerAttachmentTask?.value
        gate.finish(Data(oldFile.absoluteString.utf8));await Task.yield()
        XCTAssertEqual(m.attachmentBatch?.items.compactMap(\.localFile),[newFile]);XCTAssertEqual(m.draft,"Main draft stays");XCTAssertNil(m.error)
    }
    func testDestinationThatStartsSendingDuringLoadCannotReceiveFiles() async throws {
        let m = try model(),file = try file(),(p,gate) = held()
        XCTAssertTrue(m.receiveConversationFileDrop([p]));let task = try XCTUnwrap(m.composerAttachmentTask);try await wait(gate)
        m.sending = true;gate.finish(Data(file.absoluteString.utf8));await task.value
        XCTAssertNil(m.attachmentBatch);XCTAssertFalse(m.preparingComposerAttachment)
    }
}

@MainActor final class SyntheticFileDraggingInfo:NSObject,NSDraggingInfo {
    let draggingPasteboard:NSPasteboard
    var draggingDestinationWindow:NSWindow? { nil }
    var draggingSourceOperationMask:NSDragOperation = .copy
    var draggingLocation:NSPoint { .zero }
    var draggedImageLocation:NSPoint { .zero }
    nonisolated var draggedImage:NSImage? { nil }
    var draggingSource:Any? { nil }
    var draggingSequenceNumber:Int { 1 }
    var draggingFormation:NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight:NSSpringLoadingHighlight { .none }
    init(_ pasteboard:NSPasteboard) { draggingPasteboard = pasteboard }
    func slideDraggedImage(to screenPoint:NSPoint) { }
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination:URL)->[String]? { nil }
    func resetSpringLoading() { }
    func enumerateDraggingItems(options enumOpts:NSDraggingItemEnumerationOptions,for view:NSView?,classes classArray:[AnyClass],searchOptions:[NSPasteboard.ReadingOptionKey:Any],using block:(NSDraggingItem,Int,UnsafeMutablePointer<ObjCBool>)->Void) { }
}

private final class SyntheticLazyFileReference:NSObject,NSPasteboardItemDataProvider {
    let reference:String
    var reads = 0
    init(_ reference:String) { self.reference = reference }
    func pasteboard(_ pasteboard:NSPasteboard?,item:NSPasteboardItem,provideDataForType type:NSPasteboard.PasteboardType) {
        reads += 1;item.setString(reference,forType:type)
    }
}
