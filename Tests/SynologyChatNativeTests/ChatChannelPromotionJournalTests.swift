import Foundation
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatChannelPromotionJournalTests:XCTestCase {
    private func record() throws -> ChatChannelPromotionIntent {
        let channel = try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":93,"name":"","type":"anonymous","encrypted":false,"is_joined":true,"unread":0}"#.utf8))
        let snapshot = ChatChannelPromotionSnapshot(channel:channel,memberIDs:[6,10],memberNames:[6:"Private person"],accountGeneration:1)
        return try .init(snapshot:snapshot,draft:.init(name:"Private-café",purpose:"Private purpose 👋",mode:.newChannel))
    }
    func testConversionCheckpointIsPrivateFingerprintOnlyAndMatchesCanonicalUnicode() throws {
        let directory = URL(fileURLWithPath:"/private/tmp/native-conversion-record-"+UUID().uuidString),scope = String(repeating:"a",count:64)
        defer { try? FileManager.default.removeItem(at:directory) }
        let original = try record(),known = try original.withTarget(96),journal = ChatChannelPromotionJournal(directory:directory)
        _ = try journal.activate(scope:scope);try journal.remember(original);try journal.replace(original,with:known)
        let file = directory.appendingPathComponent(scope+".json"),data = try Data(contentsOf:file)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]),stored = try XCTUnwrap((envelope["records"] as? [[String:Any]])?.first)
        XCTAssertEqual(Set(stored.keys),Set(["sourceID","mode","memberIDs","detailsFingerprint","operationID","createdAt","targetID"]))
        for text in ["Private-café","Private purpose","Private person","synthetic-session","SynoToken"] { XCTAssertFalse(String(decoding:data,as:UTF8.self).contains(text)) }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        XCTAssertEqual(try ChatChannelPromotionJournal(directory:directory).activate(scope:scope),[known])
        let target:[String:Any] = ["channel_id":96,"name":"Private-cafe\u{301}","purpose":"Private purpose 👋","type":"private","encrypted":false,"is_joined":true,"unread":0]
        let channel = try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:target))
        XCTAssertTrue(known.matches(channel))
        XCTAssertThrowsError(try original.withTarget(1));XCTAssertThrowsError(try original.withTarget(93))
    }
    func testAtomicCheckpointRejectsStaleReplacementAndKeepsLateResultInOriginalScope() throws {
        let directory = URL(fileURLWithPath:"/private/tmp/native-conversion-record-"+UUID().uuidString),a = String(repeating:"a",count:64),b = String(repeating:"b",count:64)
        defer { try? FileManager.default.removeItem(at:directory) }
        let original = try record(),known = try original.withTarget(96),other = try original.withTarget(97),journal = ChatChannelPromotionJournal(directory:directory)
        _ = try journal.activate(scope:a);try journal.remember(original);try journal.replace(original,with:known)
        XCTAssertThrowsError(try journal.replace(original,with:other))
        XCTAssertTrue(try journal.activate(scope:b).isEmpty)
        try journal.replaceInScope(known,with:known,originalScope:a)
        XCTAssertTrue(try journal.activate(scope:b).isEmpty)
        XCTAssertEqual(try journal.activate(scope:a),[known])
    }
}
