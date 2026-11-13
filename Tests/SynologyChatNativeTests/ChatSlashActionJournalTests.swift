import Foundation
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatSlashActionJournalTests:XCTestCase {
    private let command = ChatSlashCommand(name:"jitsi",description:"Synthetic integration",usage:"/jitsi",kind:.server(3),endpointFingerprint:nil)
    func testPrivateDurableReceiptContainsNoArgumentsEndpointResponseOrCredentialAndSeparatesAccounts() throws {
        let directory = URL(fileURLWithPath:"/private/tmp").appendingPathComponent("native-slash-journal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let scope = String(repeating:"a",count:64),other = String(repeating:"b",count:64)
        let record = try ChatSlashActionIntent(channelID:93,command:command,message:"/jitsi private synthetic argument")
        XCTAssertEqual(record.id,"b70de644832a3007de138a67acb39ec6dda9bfb57635bc21af609658552ded70")
        let journal = ChatSlashActionJournal(directory:directory)
        XCTAssertTrue(try journal.activate(scope:scope).isEmpty);try journal.remember(record)
        let file = directory.appendingPathComponent(scope + ".json"),stored = try String(contentsOf:file,encoding:.utf8)
        for secret in ["/jitsi","private synthetic argument","Synthetic integration","https://","synthetic-session","Synthetic acknowledgement"] { XCTAssertFalse(stored.contains(secret)) }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:directory.path)[.posixPermissions] as? NSNumber)?.intValue,0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        journal.deactivate()
        let restored = ChatSlashActionJournal(directory:directory)
        XCTAssertEqual(try restored.activate(scope:scope),[record]);XCTAssertTrue(try restored.activate(scope:other).isEmpty)
        XCTAssertEqual(try restored.activate(scope:scope),[record])
    }
    func testReceiptRetirementRequiresExactOperationAndDoesNotRemoveNewerAttempt() throws {
        let journal = ChatSlashActionJournal(),scope = String(repeating:"c",count:64)
        _ = try journal.activate(scope:scope)
        let first = try ChatSlashActionIntent(channelID:93,command:command,message:"/jitsi"),replacement = try ChatSlashActionIntent(channelID:93,command:command,message:"/jitsi")
        try journal.remember(first);try journal.remove(first);try journal.remember(replacement)
        XCTAssertThrowsError(try journal.remove(first))
        XCTAssertEqual(try journal.activate(scope:scope),[replacement])
        XCTAssertThrowsError(try ChatSlashActionIntent(channelID:0,command:command,message:"/jitsi"))
        XCTAssertThrowsError(try ChatSlashActionIntent(channelID:93,command:command,message:"/other"))
        XCTAssertThrowsError(try ChatSlashActionIntent(channelID:93,command:command,message:"/jitsi",createdAt:Date(timeIntervalSince1970:.nan)))
        XCTAssertThrowsError(try ChatSlashActionIntent(channelID:93,command:command,message:"/jitsi",createdAt:Date.distantFuture))
    }
}
