import XCTest
@testable import SynologyChatNative

@MainActor final class ChatEmojiPreferencesTests: XCTestCase {
    let first = String(repeating: "a", count: 64)
    let second = String(repeating: "b", count: 64)
    func testExactToneVariantsRemainDistinctAndMoveToFront() throws {
        let p = ChatEmojiPreferences(); p.activate(scope: first)
        let toned = try XCTUnwrap(ChatReactionKind(rawValue: "thumbsup_tone3"))
        p.record(.thumbsUp); p.record(toned); p.record(.heart); p.record(toned)
        XCTAssertEqual(p.recent.map(\.rawValue), [toned.rawValue, ChatReactionKind.heart.rawValue, ChatReactionKind.thumbsUp.rawValue])
        p.setSkinTone(5)
        XCTAssertEqual(p.recent[0], toned)
    }
    func testBoundedQueueKeepsMostRecentlySelected24() {
        let p = ChatEmojiPreferences(); p.activate(scope: first)
        let choices = Array(ChatReactionKind.allCases.prefix(40))
        choices.forEach(p.record)
        XCTAssertEqual(p.recent, Array(choices.reversed().prefix(24)))
    }
    func testUnknownAccountCannotReadOrWriteAndSwitchRestoresOwnState() {
        let p = ChatEmojiPreferences()
        p.record(.heart); p.setSkinTone(4)
        XCTAssertTrue(p.recent.isEmpty); XCTAssertEqual(p.skinTone, 0)
        p.activate(scope: first); p.record(.heart); p.setSkinTone(4)
        p.activate(scope: second); XCTAssertTrue(p.recent.isEmpty); XCTAssertEqual(p.skinTone, 0)
        p.record(.eyes); p.setSkinTone(1)
        p.activate(scope: nil); XCTAssertTrue(p.recent.isEmpty); XCTAssertEqual(p.skinTone, 0)
        p.activate(scope: first); XCTAssertEqual(p.recent, [.heart]); XCTAssertEqual(p.skinTone, 4)
        p.activate(scope: second); XCTAssertEqual(p.recent, [.eyes]); XCTAssertEqual(p.skinTone, 1)
    }
    func testInvalidScopeAndToneAreRejected() {
        let p = ChatEmojiPreferences(); p.activate(scope: "https://example.test/private")
        p.record(.heart); XCTAssertTrue(p.recent.isEmpty)
        p.activate(scope: first); p.setSkinTone(3); p.setSkinTone(-1); p.setSkinTone(6)
        XCTAssertEqual(p.skinTone, 3)
    }
    func testDurableRestoreSanitizesCatalogueAndDeduplicates() throws {
        let suite = "EmojiTests." + UUID().uuidString
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        d.set(Data(#"{"version":1,"recent":["heart","not_a_real_emoji","heart","thumbsup_tone3"],"tone":99}"#.utf8), forKey: ChatEmojiPreferences.key(first))
        let p = ChatEmojiPreferences(defaults: d); p.activate(scope: first)
        XCTAssertEqual(p.recent.map(\.rawValue), ["heart", "thumbsup_tone3"])
        XCTAssertEqual(p.skinTone, 0)
        p.setSkinTone(2); p.record(.eyes)
        let restored = ChatEmojiPreferences(defaults: d); restored.activate(scope: first)
        XCTAssertEqual(restored.recent, p.recent); XCTAssertEqual(restored.skinTone, 2)
    }
    func testCorruptOversizedAndFutureDataDefaultWithoutRewriting() throws {
        let suite = "EmojiTests." + UUID().uuidString
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        for data in [Data("bad".utf8), Data(repeating: 32, count: 4097), Data(#"{"version":2,"recent":["heart"],"tone":2}"#.utf8)] {
            d.set(data, forKey: ChatEmojiPreferences.key(first))
            let p = ChatEmojiPreferences(defaults: d); p.activate(scope: first)
            XCTAssertTrue(p.recent.isEmpty); XCTAssertEqual(p.skinTone, 0)
            XCTAssertEqual(d.data(forKey: ChatEmojiPreferences.key(first)), data)
        }
    }
}
