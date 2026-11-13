import Foundation
import XCTest
@testable import SynologyChatNative

final class ChatMessageApplicationLinkTests: XCTestCase {
    func testStrictLineDestinationsRemainSeparateFromWebURLs() throws {
        for text in ["line://msg/text/Hello%20world", "line://ti/p/synthetic-person", "line://app/123?mode=preview#section"] {
            let url = try XCTUnwrap(ChatMessageLinks.applicationURL(text), text)
            XCTAssertEqual(url.scheme, "line"); XCTAssertEqual(ChatMessageLinks.messageURL(text), url)
            XCTAssertNil(ChatMessageLinks.webURL(text))
        }
        let prefix = "line://msg/text/"
        XCTAssertNotNil(ChatMessageLinks.applicationURL(prefix + String(repeating: "a", count: 8192-prefix.count)))
        XCTAssertNil(ChatMessageLinks.applicationURL(prefix + String(repeating: "a", count: 8193-prefix.count)))
    }

    func testMalformedControlCredentialAndSessionDestinationsAreRejected() {
        for text in ["LINE://msg/text/hello", "Line://msg/text/hello", "line://", "line:///hello", "line://?mode=preview",
                     "line://user@msg/text", "line://user:password@msg/text", "line://msg:443/text", "line://msg:/text",
                     "line://user%40msg/text", "line://msg%3A443/text",
                     "line://msg/text/hello world", "line://msg/\u{00a0}text", "line://msg/\ntext", "line://msg/\rtext", "line://msg/\u{0000}text",
                     "line://msg/text/%0A", "line://msg/text/%0D", "line://msg/text/%00", "line://msg/text/%7F",
                     "line://msg\\text", "line://msg/text/%5C", "line://msg/text/%",
                     "line://msg/text?_sid=secret", "line://msg/text?SynoToken=secret", "line://msg/text?%5Fsid=secret",
                     "line://msg/text?SYNOTOKEN=secret"] {
            XCTAssertNil(ChatMessageLinks.applicationURL(text), text)
            XCTAssertNil(ChatMessageLinks.messageURL(text), text)
        }
    }

    func testRawAndLabelledLineLinksUseTheirExactDestinations() throws {
        let raw = "line://msg/text/hello", labelled = "line://ti/p/synthetic-person"
        let result = ChatMessageLinks.attributed("Café 👀 \(raw) and <\(labelled)|Open LINE profile>")
        XCTAssertEqual(String(result.characters), "Café 👀 \(raw) and Open LINE profile")
        XCTAssertEqual(result.runs.compactMap(\.link), [URL(string: raw)!, URL(string: labelled)!])
        XCTAssertEqual(ChatMessageLinks.renderedDestinations("\(raw) <\(labelled)|Profile>"), Set([URL(string: raw)!, URL(string: labelled)!]))
    }

    func testNoNestedWebDetectionInsideAcceptedOrRejectedLineCandidate() {
        let accepted = "line://msg/text/https://nested.example/path"
        XCTAssertEqual(ChatMessageLinks.attributed(accepted).runs.compactMap(\.link), [URL(string: accepted)!])
        for rejected in ["line://user:password@msg/https://nested.example/path", "LINE://msg/https://nested.example/path",
                         "line://msg:443/https://nested.example/path", "line://msg/text/https://nested.example/?_sid=secret"] {
            XCTAssertTrue(ChatMessageLinks.attributed(rejected).runs.compactMap(\.link).isEmpty, rejected)
        }
        let labelled = ChatMessageLinks.attributed("<line://user@msg/text|https://nested.example/path>")
        XCTAssertTrue(labelled.runs.compactMap(\.link).isEmpty)
    }

    func testInlineAndFencedCodeStayAtomic() {
        let visible = URL(string: "line://ti/p/visible")!
        let text = "line://ti/p/visible `line://ti/p/inline-code`\n```\nline://ti/p/fenced-code\nhttps://code.example/\n```"
        XCTAssertEqual(ChatMessageLinks.renderedDestinations(text), Set([visible]))
        XCTAssertTrue(ChatMessageFormatting.inline("`line://ti/p/code`", hashtagLinks: false).runs.compactMap(\.link).isEmpty)
        XCTAssertTrue(ChatMessageFormatting.inline("`<line://ti/p/code|Code label>`", hashtagLinks: false).runs.compactMap(\.link).isEmpty)
    }

    func testUnsupportedSchemesAndExistingWebBehavior() throws {
        for text in ["mailto:person@example.test", "file:///private/example", "javascript:alert(1)", "myapp://open/item", "tel:1234"] {
            XCTAssertNil(ChatMessageLinks.applicationURL(text)); XCTAssertNil(ChatMessageLinks.messageURL(text))
        }
        let web = "https://example.test/path?q=hello%20world#section"
        XCTAssertEqual(ChatMessageLinks.messageURL(web), ChatMessageLinks.webURL(web))
        XCTAssertNil(ChatMessageLinks.applicationURL(web))
        let result = ChatMessageLinks.attributed("<HTTPS://example.test/page|Read page> and http://other.test/path")
        XCTAssertEqual(String(result.characters), "Read page and http://other.test/path")
        XCTAssertEqual(result.runs.compactMap(\.link).count, 2)
        XCTAssertNil(ChatMessageLinks.messageURL("https://example.test/?SynoToken=secret"))
    }
}
