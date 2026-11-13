import AppKit
import SwiftUI
import XCTest
@testable import SynologyChatNative

final class ChatSearchCompletionTests: XCTestCase {
    private let users = [ChatSearchEntity(id:10,label:"Peter Cousins",aliases:["Peter Cousins"])]
    func testCaretTokenReplacementPreservesUnicodePrefixAndTrailingFilters() throws {
        let text = "😀 Native has:fi before:2026-10-31",range = (text as NSString).range(of:"has:fi")
        let caret = NSRange(location:range.location+5,length:0),trigger = try XCTUnwrap(ChatSearchCompletion.trigger(text:text,selection:caret))
        XCTAssertEqual(trigger.prefix,"has:f");XCTAssertEqual(trigger.range,range)
        let choice = try XCTUnwrap(ChatSearchQuery.suggestions(token:trigger.prefix,users:[],channels:[]).first)
        let result = try XCTUnwrap(ChatSearchCompletion.applying(choice,trigger:trigger,text:text,selection:caret))
        XCTAssertEqual(result.text,"😀 Native has:file before:2026-10-31")
        XCTAssertEqual(result.selection.location,"😀 Native has:file ".utf16.count)
    }
    func testCaretSelectsEarlierOperatorInsteadOfFinalQueryToken() throws {
        let text = "from:Pe has:file",caret = NSRange(location:7,length:0)
        let trigger = try XCTUnwrap(ChatSearchCompletion.trigger(text:text,selection:caret))
        XCTAssertEqual(trigger.prefix,"from:Pe")
        let choice = try XCTUnwrap(ChatSearchQuery.suggestions(token:trigger.prefix,users:users,channels:[]).first)
        let result = try XCTUnwrap(ChatSearchCompletion.applying(choice,trigger:trigger,text:text,selection:caret))
        XCTAssertEqual(result.text,"from:\"Peter Cousins\" has:file")
    }
    func testSelectionsSplitGraphemesAndQuotedLiteralsDoNotComplete() {
        for (text,range) in [("has:fi",NSRange(location:0,length:6)),("😀 has:fi",NSRange(location:1,length:0)),("e\u{301} has:fi",NSRange(location:1,length:0)),("\"has:fi\"",NSRange(location:8,length:0))] {
            XCTAssertNil(ChatSearchCompletion.trigger(text:text,selection:range))
        }
    }
    func testStaleSelectionSourceAndTrailingTextCannotApplyCapturedChoice() throws {
        let text = "has:fi words",caret = NSRange(location:6,length:0)
        let trigger = try XCTUnwrap(ChatSearchCompletion.trigger(text:text,selection:caret)),choice = try XCTUnwrap(ChatSearchQuery.suggestions(token:trigger.prefix,users:[],channels:[]).first)
        XCTAssertNil(ChatSearchCompletion.applying(choice,trigger:trigger,text:text,selection:NSRange(location:5,length:0)))
        XCTAssertNil(ChatSearchCompletion.applying(choice,trigger:trigger,text:"has:fi other",selection:caret))
        XCTAssertNil(ChatSearchCompletion.applying(choice,trigger:trigger,text:"has:fi",selection:caret))
    }
    func testModifierCompletionLeavesCaretAfterColonForValueEntry() throws {
        let text = "fil rest",caret = NSRange(location:3,length:0),trigger = try XCTUnwrap(ChatSearchCompletion.trigger(text:text,selection:caret))
        let choice = try XCTUnwrap(ChatSearchQuery.suggestions(token:trigger.prefix,users:[],channels:[]).first)
        let result = try XCTUnwrap(ChatSearchCompletion.applying(choice,trigger:trigger,text:text,selection:caret))
        XCTAssertEqual(result.text,"filetype: rest");XCTAssertEqual(result.selection.location,9)
        XCTAssertEqual(ChatComposerEdit.insert("pdf",into:result.text,selection:result.selection).text,"filetype:pdf rest")
    }
    func testQuotedSpacedNameCompletionReplacesCompleteQuotedTokenAtCaret() throws {
        let text = "from:\"Peter C\" has:file",caret = NSRange(location:13,length:0)
        let trigger = try XCTUnwrap(ChatSearchCompletion.trigger(text:text,selection:caret))
        let matches = ChatSearchQuery.suggestions(token:trigger.prefix,users:users,channels:[])
        XCTAssertEqual(matches.count,1)
        let result = try XCTUnwrap(ChatSearchCompletion.applying(matches[0],trigger:trigger,text:text,selection:caret))
        XCTAssertEqual(result.text,"from:\"Peter Cousins\" has:file")
    }
    func testGeneralEntityCompletionReplacesMiddleWordAndPreservesOtherFilters() throws {
        let text = "has:file Peter before:2026-10-31",caret = NSRange(location:14,length:0)
        let trigger = try XCTUnwrap(ChatSearchCompletion.trigger(text:text,selection:caret))
        XCTAssertEqual(trigger.prefix,"Peter")
        let choice = try XCTUnwrap(ChatSearchQuery.suggestions(token:trigger.prefix,users:users,channels:[]).first)
        let changed = try XCTUnwrap(ChatSearchCompletion.applying(choice,trigger:trigger,text:text,selection:caret))
        XCTAssertEqual(changed.text,"has:file from:\"Peter Cousins\" before:2026-10-31")
        XCTAssertEqual(changed.selection.location,"has:file from:\"Peter Cousins\" ".utf16.count)
    }
    func testDateTriggersUseDedicatedChooserAndUnknownURLsDoNotSuggestModifiers() throws {
        for value in ["before:","after:"] {
            let trigger = try XCTUnwrap(ChatSearchCompletion.trigger(text:value,selection:NSRange(location:value.utf16.count,length:0)))
            XCTAssertEqual(trigger.prefix,value);XCTAssertTrue(ChatSearchQuery.suggestions(token:value,users:[],channels:[]).isEmpty)
        }
        XCTAssertTrue(ChatSearchQuery.suggestions(token:"https://example.test/has:fi",users:[],channels:[]).isEmpty)
    }
}

@MainActor final class NativeSearchFieldKeyTests:XCTestCase {
    func testDelegateRoutesCompletionKeysAndLeavesUnrelatedMovementToFieldEditor() {
        var text = "has:fi",selection = NSRange(location:6,length:0),focused = true,keys:[NativeSearchFieldCommand] = []
        let field = NativeSearchTextField(text:Binding(get:{text},set:{text=$0}),selection:Binding(get:{selection},set:{selection=$0}),focused:Binding(get:{focused},set:{focused=$0}),placeholder:"Search") { keys.append($0);return true }
        let coordinator = field.makeCoordinator(),editor = NSTextView(),control = NSSearchField()
        for selector in [#selector(NSResponder.moveDown(_:)),#selector(NSResponder.moveUp(_:)),#selector(NSResponder.insertTab(_:)),#selector(NSResponder.insertNewline(_:)),#selector(NSResponder.cancelOperation(_:))] {
            XCTAssertTrue(coordinator.control(control,textView:editor,doCommandBy:selector))
        }
        XCTAssertEqual(keys,[.next,.previous,.tab,.submit,.cancel]);XCTAssertFalse(coordinator.control(control,textView:editor,doCommandBy:#selector(NSResponder.moveLeft(_:))))
    }
    func testMarkedTextOwnsReturnAndTextBindingTracksUTF16SelectionFallback() {
        var text = "",selection = NSRange(location:0,length:0),focused = false,calls = 0
        let field = NativeSearchTextField(text:Binding(get:{text},set:{text=$0}),selection:Binding(get:{selection},set:{selection=$0}),focused:Binding(get:{focused},set:{focused=$0}),placeholder:"Search") { _ in calls += 1;return true }
        let coordinator = field.makeCoordinator(),control = NSSearchField(),editor = NSTextView()
        editor.setMarkedText("かな",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertTrue(editor.hasMarkedText());XCTAssertFalse(coordinator.control(control,textView:editor,doCommandBy:#selector(NSResponder.insertNewline(_:))));XCTAssertEqual(calls,0)
        control.stringValue = "😀 has:fi";coordinator.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:control))
        XCTAssertEqual(text,"😀 has:fi");XCTAssertEqual(selection.location,text.utf16.count)
    }
}
