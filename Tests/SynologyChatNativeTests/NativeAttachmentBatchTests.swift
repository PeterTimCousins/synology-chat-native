import XCTest
@testable import SynologyChatNative

@MainActor final class NativeAttachmentBatchTests:XCTestCase {
    private func batch(_ names:[String] = ["a.txt","b.txt","c.txt"],caption:String = "Synthetic first caption") -> NativeAttachmentBatch {
        NativeAttachmentBatch(files:names.map { URL(fileURLWithPath:"/private/tmp/"+$0) },caption:caption,channelID:93,channelTitle:"Peter",rootID:nil,encrypted:false,keyEnvelope:nil)
    }
    private func post(_ id:Int) throws -> ChatPost {
        try JSONDecoder().decode(ChatPost.self,from:Data("{\"post_id\":\(id),\"channel_id\":93,\"creator_id\":10,\"message\":\"Synthetic\",\"type\":\"file\",\"create_at\":1000}".utf8))
    }
    func testModelStagingSuspendsTextSendAndVisibilityAndClearsOnContextChanges() throws {
        let model = NativeChatPreviewModel(restoreNotificationPreference:false)
        let channel = try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0}"#.utf8))
        model.channels = [channel];model.selection = 93;model.connected = true;model.liveStatus = .live;model.draft = "Synthetic caption"
        model.posts = [try post(1)]
        model.updateReadingVisibility(active:true,atBottom:true);XCTAssertNotNil(model.notificationVisibleLocation);XCTAssertTrue(model.canSend)
        let files = [URL(fileURLWithPath:"/private/tmp/synthetic.txt")]
        model.stageAttachments(files);XCTAssertNotNil(model.attachmentBatch);XCTAssertFalse(model.canSend);XCTAssertNil(model.notificationVisibleLocation)
        model.selection = 94;XCTAssertNil(model.attachmentBatch);XCTAssertEqual(model.drafts[93],"Synthetic caption")
        model.selection = 93;model.threadRoot = try post(1);model.replyDraft = "Synthetic reply"
        model.stageAttachments(files,inThread:true);XCTAssertEqual(model.attachmentBatch?.rootID,1);XCTAssertFalse(model.canReply)
        model.closeThread();XCTAssertNil(model.attachmentBatch)
        model.stageAttachments(files)
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"Locked","type":"private","encrypted":true,"unread":0}"#.utf8))]
        XCTAssertNil(model.attachmentBatch)
        model.channels = [channel];model.stageAttachments(files);XCTAssertNotNil(model.attachmentBatch)
        model.signOutLocally();XCTAssertNil(model.attachmentBatch);XCTAssertFalse(model.uploading)
    }

    func testReviewDeduplicatesAddsRemovesAndKeepsIndependentCaptions() {
        let batch = batch(["a.txt","a.txt","b.txt"])
        XCTAssertEqual(batch.items.count,2);XCTAssertEqual(batch.items.map(\.caption),["Synthetic first caption",""])
        let original = batch.originalCaptionItemID
        batch.caption(batch.items[1].id,text:"Second caption")
        XCTAssertFalse(batch.append([URL(fileURLWithPath:"/private/tmp/b.txt"),URL(fileURLWithPath:"/private/tmp/c.txt"),URL(string:"https://example.invalid/private")!]))
        XCTAssertEqual(batch.items.count,2)
        XCTAssertTrue(batch.append([URL(fileURLWithPath:"/private/tmp/b.txt"),URL(fileURLWithPath:"/private/tmp/c.txt")]))
        XCTAssertEqual(batch.items.count,3);XCTAssertEqual(batch.items[1].caption,"Second caption")
        batch.remove(batch.items[0].id);XCTAssertEqual(batch.items.count,2);XCTAssertEqual(batch.originalCaptionItemID,original)
        XCTAssertTrue(batch.canSend)
    }
    func testCaptionLimitBlocksWholeBatchUntilCorrected() {
        let batch = batch();let id = batch.items[1].id
        batch.caption(id,text:String(repeating:"😀",count:1001));XCTAssertFalse(batch.canSend)
        batch.caption(id,text:"Fixed");XCTAssertTrue(batch.canSend)
        for item in batch.items { batch.remove(item.id) };XCTAssertFalse(batch.canSend)
    }
    func testSequentialReceiptsPreserveOrderAndDoNotRepeatFirstCaption() async throws {
        let batch = batch();var names:[String] = [];var captions:[String] = [];var receipts:[Int64] = []
        batch.caption(batch.items[1].id,text:"Synthetic second caption")
        await batch.run(canContinue:{ true },send:{ item in
            XCTAssertTrue(batch.sending)
            let count = batch.items.count;batch.remove(item.id);batch.caption(item.id,text:"Must not mutate active batch")
            XCTAssertEqual(batch.items.count,count)
            names.append(item.displayName);captions.append(item.caption)
            return try self.post(names.count)
        },received:{ post,_ in receipts.append(post.id) })
        XCTAssertEqual(names,["a.txt","b.txt","c.txt"]);XCTAssertEqual(captions,["Synthetic first caption","Synthetic second caption",""])
        XCTAssertEqual(receipts,[1,2,3]);XCTAssertTrue(batch.finished);XCTAssertEqual(batch.sentCount,3);XCTAssertFalse(batch.sending)
    }
    func testFailureStopsQueueAndContinueNeverRetriesConfirmedOrAmbiguousFiles() async throws {
        let batch = batch();var attempts:[String] = []
        await batch.run(canContinue:{ true },send:{ item in
            attempts.append(item.displayName)
            if attempts.count == 2 { throw ChatTransferError(message:"Synthetic unknown delivery") }
            return try self.post(1)
        },received:{ _,_ in })
        XCTAssertEqual(attempts,["a.txt","b.txt"]);XCTAssertEqual(batch.sentCount,1);XCTAssertEqual(batch.unconfirmedCount,1);XCTAssertEqual(batch.queuedCount,1)
        await batch.run(canContinue:{ true },send:{ item in attempts.append(item.displayName);return try self.post(3) },received:{ _,_ in })
        XCTAssertEqual(attempts,["a.txt","b.txt","c.txt"]);XCTAssertEqual(batch.sentCount,2);XCTAssertEqual(batch.unconfirmedCount,1);XCTAssertFalse(batch.finished);XCTAssertFalse(batch.canSend)
    }
    func testCancellationKeepsUnattemptedFilesAndDoesNotStartNextUpload() async throws {
        let batch = batch();var pending:CheckedContinuation<ChatPost,Error>?
        var attempts = 0
        let task = Task { await batch.run(canContinue:{ true },send:{ _ in attempts += 1;return try await withCheckedThrowingContinuation { pending = $0 } },received:{ _,_ in }) }
        while pending == nil { await Task.yield() }
        task.cancel();pending?.resume(throwing:CancellationError());await task.value
        XCTAssertEqual(attempts,1);XCTAssertEqual(batch.unconfirmedCount,1);XCTAssertEqual(batch.queuedCount,2);XCTAssertFalse(batch.sending)
    }
    func testDestinationOrSessionInvalidationPreventsAnyFurtherQueuedUpload() async throws {
        let batch = batch();var valid = true;var receipts = 0
        await batch.run(canContinue:{ valid },send:{ _ in valid = false;return try self.post(1) },received:{ _,_ in receipts += 1 })
        XCTAssertEqual(receipts,1);XCTAssertEqual(batch.sentCount,1);XCTAssertEqual(batch.queuedCount,2)
    }
    func testConfirmedReceiptSurvivesCancellationRaceButNextFileDoesNotStart() async throws {
        let batch = batch();var pending:CheckedContinuation<ChatPost,Error>?
        var receipts:[Int64] = []
        let task = Task { await batch.run(canContinue:{ true },send:{ _ in try await withCheckedThrowingContinuation { pending = $0 } },received:{ post,_ in receipts.append(post.id) }) }
        while pending == nil { await Task.yield() }
        task.cancel();pending?.resume(returning:try post(1));await task.value
        XCTAssertEqual(receipts,[1]);XCTAssertEqual(batch.sentCount,1);XCTAssertEqual(batch.queuedCount,2)
    }
}
