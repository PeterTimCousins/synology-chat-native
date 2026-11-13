import XCTest
import AppKit
@testable import SynologyChatNative

final class ChatComposerFormattingTests: XCTestCase {
    @MainActor func testUnfocusedComposerCannotConsumeFormattingShortcut() {
        let view = NativeComposerText.ComposerTextView(frame:.zero)
        var called = false
        view.onFormat = { _ in called = true }
        let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:0,context:nil,characters:"b",charactersIgnoringModifiers:"b",isARepeat:false,keyCode:11)!
        _ = view.performKeyEquivalent(with:event)
        XCTAssertFalse(called)
    }
    func testInlineWrapToggleAndNestedEmphasisPreserveSelectedContent() {
        let source = "Hello café 👀 world"
        let selected = (source as NSString).range(of:"café 👀")
        let bold = ChatComposerEdit.format(.bold,text:source,selection:selected)
        XCTAssertEqual(bold.text,"Hello *café 👀* world")
        XCTAssertEqual((bold.text as NSString).substring(with:bold.selection),"café 👀")
        let italic = ChatComposerEdit.format(.italic,text:bold.text,selection:bold.selection)
        XCTAssertEqual(italic.text,"Hello _*café 👀*_ world")
        XCTAssertEqual((italic.text as NSString).substring(with:italic.selection),"café 👀")
        let result = ChatMessageFormatting.inline(italic.text)
        XCTAssertEqual(String(result.characters),source)
        XCTAssertTrue(result.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true && $0.inlinePresentationIntent?.contains(.emphasized) == true })
        let removeItalic = ChatComposerEdit.format(.italic,text:italic.text,selection:italic.selection)
        XCTAssertEqual(removeItalic.text,bold.text)
        XCTAssertEqual(ChatComposerEdit.format(.bold,text:bold.text,selection:bold.selection).text,source)
    }
    func testEmptyInlineSelectionAndWhitespaceAreNotDuplicated() {
        let empty = ChatComposerEdit.format(.bold,text:"",selection:.init(location:0,length:0))
        XCTAssertEqual(empty.text,"**");XCTAssertEqual(empty.selection,.init(location:1,length:0))
        let spaces = ChatComposerEdit.format(.italic,text:"word  next",selection:.init(location:4,length:2))
        XCTAssertEqual(spaces.text,"word  __ next")
        let trim = ChatComposerEdit.format(.strike,text:"a word b",selection:.init(location:1,length:6))
        XCTAssertEqual(trim.text,"a ~word~ b")
    }
    func testListAndQuoteActOnWholeLinesAndMapCursor() {
        let source = "first line\nsecond line\nlast"
        let selected = (source as NSString).range(of:"line\nsecond")
        let list = ChatComposerEdit.format(.bullet,text:source,selection:selected)
        XCTAssertEqual(list.text,"* first line\n* second line\nlast")
        XCTAssertEqual(ChatComposerEdit.format(.bullet,text:list.text,selection:list.selection).text,source)
        let quote = ChatComposerEdit.format(.quote,text:"",selection:.init(location:0,length:0))
        XCTAssertEqual(quote.text,"> ");XCTAssertEqual(quote.selection,.init(location:2,length:0))
        let cursor = ChatComposerEdit.format(.bullet,text:"line",selection:.init(location:2,length:0))
        XCTAssertEqual(cursor.text,"* line");XCTAssertEqual(cursor.selection,.init(location:4,length:0))
    }
    func testCodeBlockRoundTripAndLiteralPayload() {
        let text = "let x = \"https://example.test\""
        let code = ChatComposerEdit.format(.codeBlock,text:text,selection:NSRange(location:0,length:text.utf16.count))
        XCTAssertEqual(code.text,"```\n"+text+"\n```")
        XCTAssertEqual(ChatMessageFormatting.blocks(code.text).first?.kind,.code)
        XCTAssertEqual(ChatComposerEdit.format(.codeBlock,text:code.text,selection:code.selection).text,text)
        let nested = ChatComposerEdit.format(.codeBlock,text:"```existing```",selection:.init(location:0,length:14))
        XCTAssertEqual(nested.text,"```existing```")
    }
    func testMultilineInlineStylesAndInvalidUnicodeRange() {
        let source = "one\n\ntwo"
        let edit = ChatComposerEdit.format(.bold,text:source,selection:NSRange(location:0,length:source.utf16.count))
        XCTAssertEqual(edit.text,"*one*\n\n*two*")
        let invalid = ChatComposerEdit.format(.italic,text:"👀",selection:.init(location:1,length:0))
        XCTAssertEqual(invalid.text,"👀 __")
    }
}
