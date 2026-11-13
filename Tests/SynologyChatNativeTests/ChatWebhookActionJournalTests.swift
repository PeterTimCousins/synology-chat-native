import Foundation
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatWebhookActionJournalTests:XCTestCase {
    private let fingerprint = String(repeating:"a",count:64)
    private let scope = String(repeating:"b",count:64)
    private func folder()->URL {
        let value = URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("native-webhook-action-journal-test-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:value) };return value
    }
    func testValidationRejectsInvalidIDsFingerprintsAndUnsupportedCheckpointChanges() throws {
        for operation in ChatWebhookActionIntent.Operation.allCases {
            for id in [Int64(-1),0,1] {
                XCTAssertThrowsError(try ChatWebhookActionIntent(operation:operation,kind:.incoming,webhookID:id,previousTokenFingerprint:operation == .rotate ? fingerprint : nil))
            }
        }
        for operation in [ChatWebhookActionIntent.Operation.edit,.remove,.rotate] {
            XCTAssertThrowsError(try ChatWebhookActionIntent(operation:operation,kind:.incoming))
        }
        for operation in [ChatWebhookActionIntent.Operation.create,.edit,.remove] {
            XCTAssertThrowsError(try ChatWebhookActionIntent(operation:operation,kind:.incoming,webhookID:50,previousTokenFingerprint:fingerprint))
        }
        for bad in ["",String(repeating:"a",count:63),String(repeating:"a",count:65),String(repeating:"A",count:64),String(repeating:"g",count:64)] {
            XCTAssertThrowsError(try ChatWebhookActionIntent(operation:.rotate,kind:.outgoing,webhookID:50,previousTokenFingerprint:bad))
        }
        let create = try ChatWebhookActionIntent(operation:.create,kind:.incoming)
        XCTAssertThrowsError(try create.withCreatedID(1))
        let checkpoint = try create.withCreatedID(50)
        XCTAssertThrowsError(try checkpoint.withCreatedID(51))
        XCTAssertThrowsError(try ChatWebhookActionIntent(operation:.edit,kind:.incoming,webhookID:50).withCreatedID(50))
        XCTAssertNoThrow(try ChatWebhookActionIntent(operation:.rotate,kind:.outgoing,webhookID:50,previousTokenFingerprint:fingerprint))
    }
    func testCreateCheckpointKeepsStableIdentityNonceAndReopensInItsAccount() throws {
        let directory = folder(),journal = ChatWebhookActionJournal(directory:directory)
        let first = try ChatWebhookActionIntent(operation:.create,kind:.incoming),checkpoint = try first.withCreatedID(50)
        XCTAssertEqual(first.id,"create:incoming");XCTAssertEqual(checkpoint.id,first.id)
        XCTAssertEqual(checkpoint.operationID,first.operationID);XCTAssertEqual(checkpoint.webhookID,50)
        _ = try journal.activate(scope:scope);try journal.remember(first);try journal.replace(first,with:checkpoint)
        journal.deactivate()
        let reopened = ChatWebhookActionJournal(directory:directory)
        XCTAssertEqual(try reopened.activate(scope:scope),[checkpoint])
        XCTAssertTrue(try reopened.activate(scope:String(repeating:"c",count:64)).isEmpty)
        XCTAssertEqual(try reopened.activate(scope:scope),[checkpoint])
    }
    func testReceiptIsPrivateAndPersistsOnlyIdentityAndFingerprint() throws {
        let directory = folder(),journal = ChatWebhookActionJournal(directory:directory)
        let token = ChatWebhookSecret("synthetic-private-webhook-token")
        let record = try ChatWebhookActionIntent(operation:.rotate,kind:.outgoing,webhookID:50,previousTokenFingerprint:token.fingerprint)
        _ = try journal.activate(scope:scope);try journal.remember(record)
        let file = directory.appendingPathComponent(scope+".json"),data = try Data(contentsOf:file)
        let text = String(decoding:data,as:UTF8.self)
        XCTAssertFalse(text.contains(token.reveal()));XCTAssertFalse(text.contains("callback"));XCTAssertFalse(text.contains("https://"))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        let stored = try XCTUnwrap((envelope["records"] as? [[String:Any]])?.first)
        XCTAssertEqual(Set(stored.keys),["operation","kind","webhookID","previousTokenFingerprint","operationID"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:directory.path)[.posixPermissions] as? NSNumber)?.intValue,0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
    func testCrossOperationAndCreateCheckpointResourceCollisionsAreRejected() throws {
        let directory = folder(),journal = ChatWebhookActionJournal(directory:directory);_ = try journal.activate(scope:scope)
        let create = try ChatWebhookActionIntent(operation:.create,kind:.incoming).withCreatedID(50)
        try journal.remember(create)
        for operation in [ChatWebhookActionIntent.Operation.edit,.rotate,.remove] {
            let other = try ChatWebhookActionIntent(operation:operation,kind:.outgoing,webhookID:50,previousTokenFingerprint:operation == .rotate ? fingerprint : nil)
            XCTAssertTrue(create.conflicts(with:other));XCTAssertTrue(other.conflicts(with:create))
            XCTAssertThrowsError(try journal.remember(other))
        }
        XCTAssertThrowsError(try journal.remember(ChatWebhookActionIntent(operation:.create,kind:.incoming)))
        let outgoing = try ChatWebhookActionIntent(operation:.create,kind:.outgoing)
        try journal.remember(outgoing)
        XCTAssertThrowsError(try journal.replace(outgoing,with:outgoing.withCreatedID(50)))
        let reopened = ChatWebhookActionJournal(directory:directory)
        XCTAssertEqual(try reopened.activate(scope:scope),[create,outgoing])
    }
    func testCheckpointCollisionWithPreexistingResourceAndStaleCleanupCannotEraseNewAttempt() throws {
        let journal = ChatWebhookActionJournal(directory:folder());_ = try journal.activate(scope:scope)
        let old = try ChatWebhookActionIntent(operation:.edit,kind:.incoming,webhookID:50)
        try journal.remember(old);try journal.remove(old)
        let newer = try ChatWebhookActionIntent(operation:.edit,kind:.incoming,webhookID:50)
        XCTAssertNotEqual(old.operationID,newer.operationID)
        try journal.remember(newer)
        XCTAssertThrowsError(try journal.remove(old))
        let create = try ChatWebhookActionIntent(operation:.create,kind:.outgoing)
        try journal.remember(create)
        XCTAssertThrowsError(try journal.replace(create,with:create.withCreatedID(50)))
        XCTAssertEqual(try journal.activate(scope:scope),[newer,create])
    }
    func testCorruptAndConflictingDiskRecordsFailClosedWithoutDroppingReceipts() throws {
        let directory = folder(),journal = ChatWebhookActionJournal(directory:directory)
        let record = try ChatWebhookActionIntent(operation:.create,kind:.incoming).withCreatedID(50)
        _ = try journal.activate(scope:scope);try journal.remember(record)
        let file = directory.appendingPathComponent(scope+".json"),valid = try Data(contentsOf:file)
        for (field,value) in [("webhookID",1 as Any),("operation","unknown" as Any),("kind","unknown" as Any),("operationID","invalid" as Any)] {
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with:valid) as? [String:Any])
            var rows = try XCTUnwrap(envelope["records"] as? [[String:Any]])
            rows[0][field] = value;envelope["records"] = rows
            let damaged = try JSONSerialization.data(withJSONObject:envelope);try damaged.write(to:file)
            XCTAssertThrowsError(try ChatWebhookActionJournal(directory:directory).activate(scope:scope),field)
            XCTAssertEqual(try Data(contentsOf:file),damaged)
        }
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with:valid) as? [String:Any])
        let collision = try ChatWebhookActionIntent(operation:.remove,kind:.outgoing,webhookID:50)
        let second = try JSONSerialization.jsonObject(with:JSONEncoder().encode(collision))
        var rows = try XCTUnwrap(envelope["records"] as? [Any]);rows.append(second);envelope["records"] = rows
        let damaged = try JSONSerialization.data(withJSONObject:envelope);try damaged.write(to:file)
        XCTAssertThrowsError(try ChatWebhookActionJournal(directory:directory).activate(scope:scope))
        XCTAssertEqual(try Data(contentsOf:file),damaged)
    }
}
