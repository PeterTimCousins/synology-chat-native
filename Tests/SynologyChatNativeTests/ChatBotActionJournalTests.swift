import Foundation
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatBotActionJournalTests: XCTestCase {
    private func post(card: [String: Any]? = nil, id: Int64 = 700, channel: Int64 = 93,
                      creator: Int64 = 16, thread: Int64? = nil, message: String = "Synthetic surrounding message") throws -> ChatPost {
        let attachment = card ?? ["text":"Private synthetic card text","callback_id":"synthetic-secret-callback",
            "actions":[["type":"button","text":"Private button label","name":"synthetic-action-name","value":"synthetic-secret-value"]]]
        var fields: [String: Any] = ["post_id":id,"channel_id":channel,"creator_id":creator,"message":message,
                                   "type":"normal","create_at":1000,"props":["attachments":[attachment]]]
        if let thread { fields["thread_id"] = thread }
        return try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:fields))
    }
    private func intent(_ post: ChatPost) throws -> ChatBotActionIntent {
        try .init(post:post,selection:.init(attachmentIndex:0,actionIndex:0,attachment:XCTUnwrap(post.props?.attachments?.first)))
    }
    private func folder() throws -> URL {
        let folder = URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("native-bot-action-journal-test-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:folder) }
        return folder
    }
    func testDiskRestoreAccountIsolationAndPrivateReceiptContainsNoCallbackOrCardBody() throws {
        let directory = try folder(),scopeA = String(repeating:"a",count:64),scopeB = String(repeating:"b",count:64)
        let record = try intent(post()),journal = ChatBotActionJournal(directory:directory)
        XCTAssertTrue(try journal.activate(scope:scopeA).isEmpty)
        try journal.remember(record)
        let file = directory.appendingPathComponent(scopeA + ".json")
        let stored = try String(contentsOf:file,encoding:.utf8)
        for secret in ["Private synthetic card text","synthetic-secret-callback","Private button label","synthetic-action-name","synthetic-secret-value","Synthetic surrounding message"] {
            XCTAssertFalse(stored.contains(secret))
        }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:directory.path)[.posixPermissions] as? NSNumber)?.intValue,0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        journal.deactivate()
        let restored = ChatBotActionJournal(directory:directory)
        XCTAssertEqual(try restored.activate(scope:scopeA),[record])
        XCTAssertTrue(try restored.activate(scope:scopeB).isEmpty)
        XCTAssertEqual(try restored.activate(scope:scopeA),[record])
    }
    func testStableSortedFingerprintTracksExactCardAndPostIdentityButNotSurroundingText() throws {
        let original = try post(),record = try intent(original)
        let reordered: [String:Any] = ["actions":[["value":"synthetic-secret-value","name":"synthetic-action-name","text":"Private button label","type":"button"]],
                                      "callback_id":"synthetic-secret-callback","text":"Private synthetic card text"]
        XCTAssertEqual(try intent(post(card:reordered)).attachmentFingerprint,record.attachmentFingerprint)
        XCTAssertTrue(record.matches(try post(card:reordered,message:"Changed unrelated surrounding text")))
        var changed = reordered;changed["callback_id"] = "changed"
        XCTAssertFalse(record.matches(try post(card:changed)))
        changed = reordered;changed["text"] = "changed card"
        XCTAssertFalse(record.matches(try post(card:changed)))
        XCTAssertFalse(record.matches(try post(id:701)))
        XCTAssertFalse(record.matches(try post(channel:94)))
        XCTAssertFalse(record.matches(try post(creator:17)))
        XCTAssertFalse(record.matches(try post(thread:100)))
        XCTAssertTrue(record.matches(try post(thread:0)))
        XCTAssertTrue(record.matches(try post(thread:700)), "A self-referencing root normalizes to the same root identity")
    }
    func testPendingPerPostCannotDuplicateAndOldOperationCannotRemoveNewReceipt() throws {
        let journal = ChatBotActionJournal(directory:try folder()),scope = String(repeating:"c",count:64)
        _ = try journal.activate(scope:scope)
        let first = try intent(post()),second = try intent(post())
        XCTAssertNotEqual(first.operationID,second.operationID)
        try journal.remember(first)
        XCTAssertThrowsError(try journal.remember(second))
        try journal.remove(first);try journal.remember(second)
        XCTAssertThrowsError(try journal.remove(first))
        XCTAssertEqual(try journal.activate(scope:scope),[second])
    }
    func testInvalidSelectionAndNormalizedThreadIdentityAreValidated() throws {
        let original = try post(),card = try XCTUnwrap(original.props?.attachments?.first)
        for selection in [ChatBotActionSelection(attachmentIndex:1,actionIndex:0,attachment:card),
                          ChatBotActionSelection(attachmentIndex:0,actionIndex:1,attachment:card),
                          ChatBotActionSelection(attachmentIndex:0,actionIndex:0,attachment:.object([:]))] {
            XCTAssertThrowsError(try ChatBotActionIntent(post:original,selection:selection))
        }
        for invalid in try [post(id:0),post(channel:0),post(creator:0),post(thread:-1)] {
            XCTAssertThrowsError(try intent(invalid))
        }
        let reply = try post(thread:100),record = try intent(reply)
        XCTAssertEqual(record.threadID,100);XCTAssertTrue(record.matches(reply))
        XCTAssertEqual(try intent(post(thread:700)).threadID,0)
    }
    func testMalformedDiskRecordsAreRejectedInsteadOfRestored() throws {
        let directory = try folder(),scope = String(repeating:"d",count:64),record = try intent(post())
        let journal = ChatBotActionJournal(directory:directory);_ = try journal.activate(scope:scope);try journal.remember(record)
        let file = directory.appendingPathComponent(scope + ".json"),valid = try Data(contentsOf:file)
        for (key,value) in [("postID",0 as Any),("threadID",-1 as Any),("attachmentIndex",100 as Any),
                            ("actionIndex",-1 as Any),("attachmentFingerprint","not-a-hash" as Any),("operationID","not-a-uuid" as Any)] {
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with:valid) as? [String:Any])
            var records = try XCTUnwrap(envelope["records"] as? [[String:Any]])
            records[0][key] = value;envelope["records"] = records
            try JSONSerialization.data(withJSONObject:envelope).write(to:file)
            XCTAssertThrowsError(try ChatBotActionJournal(directory:directory).activate(scope:scope),key)
        }
    }
}
