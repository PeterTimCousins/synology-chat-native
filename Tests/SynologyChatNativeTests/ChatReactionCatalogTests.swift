import XCTest
@testable import SynologyChatNative

final class ChatReactionCatalogTests: XCTestCase {
    func testFullCatalogIdentifiersAndUnicodeSequences() {
        XCTAssertEqual(ChatReactionKind.allCases.count, 1784)
        XCTAssertEqual(Set(ChatReactionKind.allCases.map(\.rawValue)).count, 1784)
        XCTAssertEqual(Set(ChatReactionKind.allCases.map(\.category)), Set(ChatReactionKind.categories))
        for value in ChatReactionKind.allCases {
            XCTAssertEqual(ChatReactionKind(rawValue: value.rawValue), value)
            XCTAssertFalse(value.emoji.isEmpty)
            XCTAssertTrue((0...5).contains(value.skinTone))
        }
        XCTAssertEqual(ChatReactionKind(rawValue: "thumbsup_tone3")?.emoji, "👍🏽")
        XCTAssertEqual(ChatReactionKind(rawValue: "flag_gb")?.emoji, "🇬🇧")
        XCTAssertNil(ChatReactionKind(rawValue: ":thumbsup:"))
        XCTAssertNil(ChatReactionKind(rawValue: "unrecognized_sticker"))
    }
    func testCategoryToneAndSearchAreDistinct() {
        let base = ChatReactionKind.matching(query: "", category: "people", skinTone: 0)
        XCTAssertTrue(base.allSatisfy { $0.category == "people" && $0.skinTone == 0 })
        let medium = ChatReactionKind.matching(query: "", category: "people", skinTone: 3)
        XCTAssertTrue(medium.contains { $0.rawValue == "thumbsup_tone3" })
        XCTAssertFalse(medium.contains { $0.rawValue == "thumbsup" || $0.skinTone == 2 })
        // Search spans categories and tones even when a different browse category is selected.
        XCTAssertEqual(ChatReactionKind.matching(query: ":flag_gb:", category: "people", skinTone: 0).map(\.rawValue), ["flag_gb"])
        XCTAssertEqual(ChatReactionKind.matching(query: "thumbsup tone3", category: "food", skinTone: 0).map(\.rawValue), ["thumbsup_tone3"])
        XCTAssertEqual(ChatReactionKind.matching(query: "United Kingdom", category: nil, skinTone: 0).map(\.rawValue), ["flag_gb"])
        XCTAssertTrue(ChatReactionKind.matching(query: "no_such_emoji", category: nil, skinTone: 0).isEmpty)
    }
}
