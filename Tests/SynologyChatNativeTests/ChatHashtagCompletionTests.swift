import XCTest
@testable import SynologyChatNative

final class ChatHashtagCompletionTests: XCTestCase {
    private func trigger(_ value: String, caret: Int? = nil) -> ChatMentionCompletion.Trigger? {
        ChatMentionCompletion.trigger(text: value, selection: .init(location: caret ?? value.utf16.count, length: 0), marker: "#")
    }
    func testEmptyPartialAndUnicodeTagsUseActualHashtagGrammar() {
        XCTAssertEqual(trigger("#")?.query, "")
        for tag in ["release-notes", "topic_1", "Café", "👀", "123"] { XCTAssertEqual(trigger("Hello #" + tag)?.query, tag) }
        for value in ["word#topic", "https://host/#topic", "##topic", "#topic.part", "#topic/path", "#two words", "#tag "] { XCTAssertNil(trigger(value), value) }
    }
    func testUTF16LimitMatchesBackendInsteadOfMentionQueryLimit() {
        XCTAssertNotNil(trigger("#" + String(repeating: "a", count: 32)))
        XCTAssertNil(trigger("#" + String(repeating: "a", count: 33)))
        XCTAssertNotNil(trigger("#" + String(repeating: "👀", count: 16)))
        XCTAssertNil(trigger("#" + String(repeating: "👀", count: 17)))
    }
    func testCodeAndLinkLabelsNeverSuggestTags() {
        for value in ["`#topic", "``#topic", "```swift\n` #topic", "[a #topic"] { XCTAssertNil(trigger(value), value) }
        XCTAssertNotNil(trigger("```swift\n` literal\n``` #topic"))
    }
    func testReplacementPreservesUnicodeAndSuffixAtMidTokenCaret() throws {
        let source = "👩🏽‍💻 before #NativeParity suffix 🇬🇧"
        let caret = "👩🏽‍💻 before #Nat".utf16.count
        let t = try XCTUnwrap(trigger(source, caret: caret))
        XCTAssertEqual(t.query, "Nat")
        let edit = try XCTUnwrap(ChatMentionCompletion.insert(hashtag: "NativeParity20261016", trigger: t, text: source, selection: .init(location: caret, length: 0)))
        XCTAssertEqual(edit.text, "👩🏽‍💻 before #NativeParity20261016 suffix 🇬🇧")
        XCTAssertEqual(edit.selection.location, "👩🏽‍💻 before #NativeParity20261016 ".utf16.count)
    }
    func testInvalidTagsStaleQueriesAndSelectedRangesCannotBeInserted() throws {
        let t = try XCTUnwrap(trigger("#Nat"))
        for invalid in ["", "bad/tag", "#tag", String(repeating: "x", count: 33)] {
            XCTAssertNil(ChatMentionCompletion.insert(hashtag: invalid, trigger: t, text: "#Nat", selection: .init(location: 4, length: 0)))
        }
        XCTAssertNil(ChatMentionCompletion.insert(hashtag: "Native", trigger: t, text: "#Other", selection: .init(location: 6, length: 0)))
        XCTAssertNil(ChatMentionCompletion.trigger(text: "#Nat", selection: .init(location: 1, length: 3), marker: "#"))
    }
    func testSwitchingMarkerInvalidatesOldTriggerEvenWithIdenticalQuery() throws {
        let member = try XCTUnwrap(ChatMentionCompletion.trigger(text: "@Nat", selection: .init(location: 4, length: 0)))
        let tag = try XCTUnwrap(trigger("#Nat"))
        XCTAssertNotEqual(member, tag)
        XCTAssertNil(ChatMentionCompletion.insert(hashtag: "Native", trigger: member, text: "#Nat", selection: .init(location: 4, length: 0)))
        XCTAssertNil(ChatMentionCompletion.insert(userID: 6, trigger: tag, text: "@Nat", selection: .init(location: 4, length: 0)))
        XCTAssertNil(ChatMentionCompletion.trigger(text: "$Nat", selection: .init(location: 4, length: 0), marker: "$"))
    }
}
