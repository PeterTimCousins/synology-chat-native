import XCTest
import SwiftUI
@testable import SynologyChatNative

final class ChatMessageFormattingTests: XCTestCase {
    func testVendorBlockGrammarAndLiteralUnclosedFences() {
        let blocks = ChatMessageFormatting.blocks("Hello\n* one\n* two\n> quoted\n```\nlet value = \"https://example.test\"\n```\nDone")
        XCTAssertEqual(blocks.map(\.kind), [.paragraph,.bullet,.bullet,.quote,.code,.paragraph])
        XCTAssertEqual(blocks[4].text, "let value = \"https://example.test\"\n")
        XCTAssertEqual(ChatMessageFormatting.blocks("```not closed").first?.kind, .paragraph)
        XCTAssertEqual(ChatMessageFormatting.blocks(">>>one\ntwo"), [.init(kind:.quote,text:"one\ntwo",children:[.init(kind:.paragraph,text:"one"),.init(kind:.paragraph,text:"two")])])
    }
    func testEmphasisNestingUnicodeAndVendorBoundaries() {
        let value = ChatMessageFormatting.inline("Café 👀 *bold _italic_* ~gone~")
        XCTAssertEqual(String(value.characters), "Café 👀 bold italic gone")
        let italic = value.runs.first { String(value[$0.range].characters) == "italic" }
        XCTAssertTrue(italic?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        XCTAssertTrue(italic?.inlinePresentationIntent?.contains(.emphasized) == true)
        XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
        for text in ["word*bold*", "*bold*.", "* spaced *", "_unclosed", "**CommonMark**"] {
            XCTAssertEqual(String(ChatMessageFormatting.inline(text).characters),text)
        }
    }
    func testCodeAndEscapesDoNotGainLinksStylesOrEmoji() {
        let code = ChatMessageFormatting.inline("`https://example.test *literal* :smile:`")
        XCTAssertEqual(String(code.characters),"https://example.test *literal* :smile:")
        XCTAssertTrue(code.runs.allSatisfy { $0.link == nil && $0.inlinePresentationIntent == .code })
        XCTAssertEqual(String(ChatMessageFormatting.inline(#"\*literal\* \_under\_ \\"#).characters), #"*literal* _under_ \"#)
        XCTAssertEqual(String(ChatMessageFormatting.inline("<script>alert(1)</script>").characters),"<script>alert(1)</script>")
    }
    func testLinksAndEmojiOutsideCodeKeepTheirMeaning() {
        let result = ChatMessageFormatting.inline("*Read this* <https://example.test|Public page> :thumbsup_tone3: https://example.test/:smile:")
        XCTAssertEqual(String(result.characters),"Read this Public page 👍🏽 https://example.test/:smile:")
        XCTAssertEqual(result.runs.compactMap(\.link).count,2)
        XCTAssertEqual(String(ChatMessageFormatting.inline(":not_a_known_emoji:").characters),":not_a_known_emoji:")
    }
    func testMultilineQuoteRetainsListAndCodeBlocksFromVendorChildGrammar() throws {
        // Cached MarkdownParser.blockRules calls parseBlock(quoteblock, true),
        // rather than parseToken: lists and fenced code remain distinct children.
        let source = "Before\n>>>* first\n* _second_\n```\nhttps://example.test *literal* :smile: @u:6 #tag\n```\nAfter"
        let blocks = ChatMessageFormatting.blocks(source)
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .quote])
        let children = try XCTUnwrap(blocks.last?.children)
        XCTAssertEqual(children.map(\.kind), [.bullet, .bullet, .code, .paragraph])
        XCTAssertEqual(children.map(\.text), ["first", "_second_", "https://example.test *literal* :smile: @u:6 #tag\n", "After"])
        XCTAssertTrue(children.allSatisfy { $0.children == nil })
        XCTAssertEqual(String(ChatMessageFormatting.inline(children[1].text).characters), "second")
        XCTAssertTrue(ChatMessageFormatting.inline(children[1].text).runs.contains { $0.inlinePresentationIntent == .emphasized })
    }

    func testMultilineQuoteDoesNotRecursivelyConsumeAnotherTripleMarker() throws {
        let blocks = ChatMessageFormatting.blocks(">>>outer\n>>>inner\n* following")
        let children = try XCTUnwrap(blocks.first?.children)
        XCTAssertEqual(children.map(\.kind), [.paragraph, .quote, .bullet])
        XCTAssertEqual(children.map(\.text), ["outer", ">>inner", "following"])
        XCTAssertTrue(children.allSatisfy { $0.children == nil }, "Vendor nested mode skips quoteblock but still allows ordinary > quotes")
    }

    func testOrdinaryQuoteRemainsInlineAndUnclosedFenceStaysLiteralInsideGroup() throws {
        let single = ChatMessageFormatting.blocks(">* first\n>```literal")
        XCTAssertEqual(single, [.init(kind: .quote, text: "* first"), .init(kind: .quote, text: "```literal")])
        let children = try XCTUnwrap(ChatMessageFormatting.blocks(">>>* first\n```not closed").first?.children)
        XCTAssertEqual(children, [.init(kind: .bullet, text: "first"), .init(kind: .paragraph, text: "```not closed")])
    }

    func testCodeFenceProtectsQuoteMarkersAndQuotedTextKeepsNativeConsumers() throws {
        let code = ChatMessageFormatting.blocks("```\n>>>* literal\n```\nDone")
        XCTAssertEqual(code, [.init(kind: .code, text: ">>>* literal\n"), .init(kind: .paragraph, text: "Done")])
        let children = try XCTUnwrap(ChatMessageFormatting.blocks(">>>* @u:6 #topic\n<https://example.test|Public page>").first?.children)
        XCTAssertEqual(children.map(\.text), ["@u:6 #topic", "<https://example.test|Public page>"])
        let link = ChatMessageFormatting.inline(children[1].text)
        XCTAssertEqual(String(link.characters), "Public page")
        XCTAssertEqual(link.runs.compactMap(\.link), [URL(string: "https://example.test")!])
        // The block parser never rewrites user identifiers or hashtag tokens;
        // the existing inline consumers retain responsibility for both.
        let text = ChatMessageFormatting.inline(children[0].text, mentions: [6: "Peter"], hashtagLinks: false)
        XCTAssertTrue(String(text.characters).contains("Peter"))
        XCTAssertTrue(String(text.characters).contains("#topic"))
    }

}
