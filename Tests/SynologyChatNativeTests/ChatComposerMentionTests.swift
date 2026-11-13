import XCTest
import SwiftUI
import AppKit
@testable import SynologyChatNative

final class ChatComposerMentionTests: XCTestCase {
    @MainActor func testNativeComposerUndoRedoAndIsolation() {
        let view = NativeComposerText.ComposerTextView(frame: NSRect(x:0,y:0,width:400,height:80))
        view.allowsUndo = true
        view.undoManager?.groupsByEvent = false
        view.string = "before middle after"
        view.setSelectedRange(NSRange(location:7,length:6))
        view.undoManager?.beginUndoGrouping()
        view.replaceWithUndo("before @u:6 after")
        view.undoManager?.endUndoGrouping()
        XCTAssertTrue(view.undoManager?.canUndo == true)
        view.undo(nil)
        XCTAssertEqual(view.string,"before middle after")
        XCTAssertEqual(view.selectedRange(),NSRange(location:7,length:6))
        view.redo(nil)
        XCTAssertEqual(view.string,"before @u:6 after")
        let other = NativeComposerText.ComposerTextView(frame:.zero)
        XCTAssertFalse(other.undoManager?.canUndo == true)
    }
    func testSelectedUnicodeIsReplacedAndCaretUsesUTF16() {
        let text = "Hi 👨‍👩‍👧‍👦 friend"
        let selected = (text as NSString).range(of: "👨‍👩‍👧‍👦")
        let edit = ChatComposerEdit.insert("@u:6", into: text, selection: selected, separated: true)
        XCTAssertEqual(edit.text,"Hi @u:6 friend")
        XCTAssertEqual(edit.selection,NSRange(location:8,length:0))
        let emoji = ChatComposerEdit.insert("👍🏽", into: "AB", selection:.init(location:1,length:0))
        XCTAssertEqual(emoji.text,"A👍🏽B");XCTAssertEqual(emoji.selection.location,5)
    }
    func testMentionBoundariesAndStaleSelectionFallback() {
        let edit = ChatComposerEdit.insert("@u:6", into:"prefixsuffix",selection:.init(location:6,length:0),separated:true)
        XCTAssertEqual(edit.text,"prefix @u:6 suffix")
        XCTAssertEqual(ChatComposerEdit.insert("😄",into:"draft",selection:.init(location:NSNotFound,length:0)).text,"draft😄")
        XCTAssertEqual(ChatComposerEdit.insert("x",into:"👀",selection:.init(location:1,length:0)).text,"👀x")
        XCTAssertEqual(ChatComposerEdit.insert("@u:6",into:"",selection:.init(location:0,length:0),separated:true).text,"@u:6 ")
    }
    func testMentionNamesUnicodeAndUnknownUsersRemainLegible() {
        let value = ChatMessageFormatting.inline("Hi @u:6 and @u:10; @u:999",mentions:[6:"peter",10:"Café 👀"])
        XCTAssertEqual(String(value.characters),"Hi @peter and @Café 👀; @u:999")
        XCTAssertEqual(String(ChatMessageFormatting.inline("mail@u:6",mentions:[6:"Peter"]).characters),"mail@u:6")
    }
    func testCodeAndWebLinksDoNotBecomeMentions() {
        let names: [Int64:String] = [6:"Peter"]
        XCTAssertEqual(String(ChatMessageFormatting.inline("`@u:6 @here`",mentions:names).characters),"@u:6 @here")
        let code = ChatMessageFormatting.blocks("```@u:6 @channel```")
        XCTAssertEqual(code.first?.kind,.code);XCTAssertEqual(code.first?.text,"@u:6 @channel")
        let linked = ChatMessageFormatting.inline("<https://example.test|@u:6>",mentions:names)
        XCTAssertEqual(String(linked.characters),"@u:6");XCTAssertNotNil(linked.runs.first?.link)
        XCTAssertEqual(String(ChatMessageFormatting.inline("@channel @here",mentions:names).characters),"@channel @here")
        XCTAssertTrue(ChatMessageFormatting.inline("@here",mentions:names).runs.contains { $0.backgroundColor != nil })
    }
}
