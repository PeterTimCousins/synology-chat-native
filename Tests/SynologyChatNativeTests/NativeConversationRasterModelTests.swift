import AppKit
import XCTest
import UniformTypeIdentifiers
@testable import SynologyChatNative

@MainActor final class NativeConversationRasterModelTests: XCTestCase {
    private func model(thread: Bool) throws -> NativeChatPreviewModel {
        let m = NativeChatPreviewModel(restoreNotificationPreference: false)
        m.channels = [try JSONDecoder().decode(ChatChannel.self, from: Data(#"{"channel_id":93,"name":"Synthetic raster","type":"anonymous","encrypted":false,"unread":0}"#.utf8))]
        m.selection = 93; m.connected = true; m.liveStatus = .live
        m.draft = "Main caption 👀"
        if thread {
            m.threadRoot = try JSONDecoder().decode(ChatPost.self, from: Data(#"{"post_id":1,"channel_id":93,"creator_id":10,"message":"Synthetic root","type":"normal","create_at":1000}"#.utf8))
            m.replyDraft = "Thread caption 👀"
        }
        addTeardownBlock { @MainActor in m.signOutLocally() }
        return m
    }
    private func image(_ type: String = UTType.png.identifier, data: Data = NativeSyntheticClipboardImage.data) -> NSItemProvider {
        let p = NSItemProvider()
        p.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { callback in callback(data,nil); return nil }
        return p
    }
    func testRasterDropsStageMainAndThreadReviewsAndDismissCleansGeneratedFiles() async throws {
        for thread in [false,true] {
            let m = try model(thread: thread)
            XCTAssertTrue(m.receiveConversationFileDrop([image()],inThread: thread))
            await m.composerAttachmentTask?.value
            let batch = try XCTUnwrap(m.attachmentBatch)
            let file = try XCTUnwrap(batch.items.first?.localFile)
            XCTAssertEqual(batch.items.count,1)
            XCTAssertEqual(batch.rootID,thread ? 1 : nil)
            XCTAssertEqual(batch.items.first?.caption,thread ? "Thread caption 👀" : "Main caption 👀")
            XCTAssertEqual(try Data(contentsOf:file),NativeSyntheticClipboardImage.data)
            XCTAssertTrue(file.deletingLastPathComponent().lastPathComponent.hasPrefix("native-chat-paste-"))
            XCTAssertEqual(m.draft,"Main caption 👀"); XCTAssertEqual(m.replyDraft,thread ? "Thread caption 👀" : "")
            XCTAssertFalse(m.sending); XCTAssertFalse(m.preparingComposerAttachment)
            m.dismissAttachmentBatch()
            XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
            XCTAssertEqual(m.draft,"Main caption 👀"); XCTAssertEqual(m.replyDraft,thread ? "Thread caption 👀" : "")
        }
    }
    func testMalformedRasterAfterValidRasterStagesNoPartialBatchAndCanRetry() async throws {
        let m = try model(thread:false)
        XCTAssertTrue(m.receiveConversationFileDrop([image(),image(data:Data("Not an image".utf8))]))
        await m.composerAttachmentTask?.value
        XCTAssertNil(m.attachmentBatch); XCTAssertNotNil(m.error)
        XCTAssertTrue(m.canReceiveConversationFileDrop()); XCTAssertEqual(m.draft,"Main caption 👀")
        XCTAssertTrue(m.receiveConversationFileDrop([image()]))
        await m.composerAttachmentTask?.value
        let file = try XCTUnwrap(m.attachmentBatch?.items.first?.localFile)
        XCTAssertNil(m.error); XCTAssertFalse(m.sending)
        m.signOutLocally()
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
}
