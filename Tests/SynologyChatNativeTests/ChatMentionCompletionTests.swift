import XCTest
import AppKit
@testable import SynologyChatNative

final class ChatMentionCompletionTests: XCTestCase {
    private func trigger(_ text: String, caret: Int? = nil) -> ChatMentionCompletion.Trigger? {
        ChatMentionCompletion.trigger(text: text, selection: .init(location: caret ?? text.utf16.count, length: 0))
    }
    func testEmptyAndPartialMentionAtWordBoundary() throws {
        XCTAssertEqual(trigger("@")?.query, "")
        let value = try XCTUnwrap(trigger("Hello @Pe"))
        XCTAssertEqual(value.query, "Pe"); XCTAssertEqual(value.range, NSRange(location: 6, length: 3))
        XCTAssertEqual(trigger("Hello\n@Pe")?.query, "Pe")
    }
    func testEmailWireURLAndEmbeddedTokensDoNotTrigger() {
        for text in ["me@example", "@@Pe", "https://host/@Pe", "@u:6", "Hello @Pe ", "@Pe!", "word@Pe"] { XCTAssertNil(trigger(text), text) }
        XCTAssertNil(trigger("@u:6", caret: 2))
    }
    func testCodeAndMarkdownLabelsStayLiteral() {
        for text in ["`@Pe", "``@Pe", "```\n@Pe", "```swift\n` @Pe", "[Hello @Pe", "[Hello @Pe](https://example.test)"] { XCTAssertNil(trigger(text, caret: text.firstIndex(of: "]").map { text[..<$0].utf16.count }), text) }
        XCTAssertNotNil(trigger("`code` @Pe"))
        XCTAssertNotNil(trigger("``code ` literal`` @Pe"))
        XCTAssertNotNil(trigger("```swift\n`code\n``` @Pe"))
        XCTAssertNotNil(trigger("\\` @Pe"))
    }
    func testSelectionAndInvalidUTF16NeverTrigger() {
        XCTAssertNil(ChatMentionCompletion.trigger(text: "@Pe", selection: .init(location: 1, length: 2)))
        XCTAssertNil(ChatMentionCompletion.trigger(text: "👨‍👩‍👧 @Pe", selection: .init(location: 1, length: 0)))
        XCTAssertNil(trigger("@Pe", caret: NSNotFound))
        XCTAssertNil(trigger("@Pe", caret: -1))
    }
    func testUnicodePrefixAndSuffixArePreserved() throws {
        let source = "👩🏽‍💻 @Пе suffix 🇬🇧"
        let caret = "👩🏽‍💻 @Пе".utf16.count
        let t = try XCTUnwrap(trigger(source, caret: caret))
        let result = try XCTUnwrap(ChatMentionCompletion.insert(userID: 6, trigger: t, text: source, selection: .init(location: caret, length: 0)))
        XCTAssertEqual(result.text, "👩🏽‍💻 @u:6 suffix 🇬🇧")
        XCTAssertEqual(result.selection, NSRange(location: "👩🏽‍💻 @u:6 ".utf16.count, length: 0))
    }
    func testMidTokenCompletionReplacesWholeToken() throws {
        let source = "Hello @Peter tomorrow"
        let caret = "Hello @Pe".utf16.count
        let t = try XCTUnwrap(trigger(source, caret: caret))
        XCTAssertEqual(t.query, "Pe"); XCTAssertEqual(t.range.length, 6)
        let result = ChatMentionCompletion.insert(userID: 6, trigger: t, text: source, selection: .init(location: caret, length: 0))
        XCTAssertEqual(result?.text, "Hello @u:6 tomorrow")
    }
    func testStaleTriggerAndInvalidIdentityCannotEditDraft() throws {
        let t = try XCTUnwrap(trigger("@Pe"))
        XCTAssertNil(ChatMentionCompletion.insert(userID: 6, trigger: t, text: "@Peter", selection: .init(location: 6, length: 0)))
        XCTAssertNil(ChatMentionCompletion.insert(userID: 0, trigger: t, text: "@Pe", selection: .init(location: 3, length: 0)))
        XCTAssertNil(ChatMentionCompletion.insert(userID: 6, trigger: t, text: "@Pe", selection: .init(location: 2, length: 0)))
    }
    func testQueryBoundAndSeparatorInsertion() throws {
        XCTAssertNotNil(trigger("@" + String(repeating: "a", count: 64)))
        XCTAssertNil(trigger("@" + String(repeating: "a", count: 65)))
        let t = try XCTUnwrap(trigger("@Pe"))
        XCTAssertEqual(ChatMentionCompletion.insert(userID: 6, trigger: t, text: "@Pe", selection: .init(location: 3, length: 0))?.text, "@u:6 ")
    }
}

@MainActor final class NativeMentionCompletionKeyTests: XCTestCase {
    private func event(_ code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: code == 36 ? "\r" : "", charactersIgnoringModifiers: code == 36 ? "\r" : "", isARepeat: false, keyCode: code)!
    }
    func testPlainKeysAreConsumedAndCommandKeysAreLeftAlone() {
        let view = NativeComposerText.ComposerTextView(); view.isEditable = true
        var keys: [NativeComposerCompletionKey] = []
        view.onCompletionKey = { keys.append($0); return true }
        for code: UInt16 in [125,126,36,48,53] { view.keyDown(with: event(code)) }
        XCTAssertEqual(keys.count, 5)
        XCTAssertTrue(view.string.isEmpty)
        view.keyDown(with: event(36, flags: .command))
        XCTAssertEqual(keys.count, 5)
    }
    func testReturnFallsThroughWhenNoSuggestionAcceptsIt() {
        let view = NativeComposerText.ComposerTextView(); view.isEditable = true
        view.onCompletionKey = { _ in false }
        XCTAssertFalse(view.completionShortcut(event(36)))
        view.onCompletionKey = nil
        XCTAssertFalse(view.completionShortcut(event(36)))
    }
}
