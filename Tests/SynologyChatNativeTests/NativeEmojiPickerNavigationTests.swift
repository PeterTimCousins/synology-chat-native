import AppKit
import SwiftUI
import XCTest
@testable import SynologyChatNative

final class NativeEmojiPickerNavigationTests: XCTestCase {
    func testVerticalNavigationStartsAtResultEdges() {
        XCTAssertEqual(NativeEmojiPickerNavigation.move(selected: nil, count: 19, command: .down), 0)
        XCTAssertEqual(NativeEmojiPickerNavigation.move(selected: nil, count: 19, command: .up), 18)
        XCTAssertNil(NativeEmojiPickerNavigation.move(selected: nil, count: 19, command: .left))
        XCTAssertNil(NativeEmojiPickerNavigation.move(selected: nil, count: 19, command: .right))
    }
    func testGridMovementAndShortLastRowStayInsideResults() {
        XCTAssertEqual(NativeEmojiPickerNavigation.move(selected: 3, count: 19, command: .down), 11)
        XCTAssertEqual(NativeEmojiPickerNavigation.move(selected: 11, count: 19, command: .down), 18)
        XCTAssertEqual(NativeEmojiPickerNavigation.move(selected: 18, count: 19, command: .down), 18)
        XCTAssertEqual(NativeEmojiPickerNavigation.move(selected: 18, count: 19, command: .up), 10)
        XCTAssertEqual(NativeEmojiPickerNavigation.move(selected: 0, count: 19, command: .up), 0)
        XCTAssertEqual(NativeEmojiPickerNavigation.move(selected: 0, count: 19, command: .left), 0)
        XCTAssertEqual(NativeEmojiPickerNavigation.move(selected: 18, count: 19, command: .right), 18)
        XCTAssertEqual(NativeEmojiPickerNavigation.move(selected: 7, count: 19, command: .right), 8)
    }
    func testEmptyResultsAndStaleSelectionCannotIndexOutsideNewQuery() {
        XCTAssertNil(NativeEmojiPickerNavigation.move(selected: 2, count: 0, command: .down))
        XCTAssertNil(NativeEmojiPickerNavigation.move(selected: 2, count: 3, columns: 0, command: .down))
        XCTAssertNil(NativeEmojiPickerNavigation.submissionIndex(selected: 2, count: 0))
        XCTAssertEqual(NativeEmojiPickerNavigation.move(selected: 45, count: 2, command: .down), 0)
        XCTAssertEqual(NativeEmojiPickerNavigation.move(selected: -1, count: 2, command: .up), 1)
        XCTAssertEqual(NativeEmojiPickerNavigation.submissionIndex(selected: 45, count: 2), 0)
        XCTAssertEqual(NativeEmojiPickerNavigation.submissionIndex(selected: nil, count: 2), 0)
        XCTAssertEqual(NativeEmojiPickerNavigation.submissionIndex(selected: 1, count: 2), 1)
    }
    func testThreeColumnStickerGridUsesItsOwnStrideAndBounds() {
        XCTAssertEqual(NativeEmojiPickerNavigation.move(selected: nil, count: 8, columns: 3, command: .down), 0)
        XCTAssertEqual(NativeEmojiPickerNavigation.move(selected: 1, count: 8, columns: 3, command: .down), 4)
        XCTAssertEqual(NativeEmojiPickerNavigation.move(selected: 4, count: 8, columns: 3, command: .down), 7)
        XCTAssertEqual(NativeEmojiPickerNavigation.move(selected: 7, count: 8, columns: 3, command: .down), 7)
        XCTAssertEqual(NativeEmojiPickerNavigation.move(selected: 7, count: 8, columns: 3, command: .up), 4)
        XCTAssertEqual(NativeEmojiPickerNavigation.move(selected: 2, count: 2, columns: 3, command: .up), 1)
    }
}

@MainActor final class NativeEmojiPickerSearchFieldTests: XCTestCase {
    func testDelegateRoutesOnlyPickerCommandsAndLeavesTabToNativeFocus() {
        var text = "", focused = false, commands: [NativeEmojiPickerNavigation.Command] = []
        let field = NativeEmojiPickerSearchField(text: Binding(get: { text }, set: { text = $0 }),
            focused: Binding(get: { focused }, set: { focused = $0 }), label: "Search reactions") {
                commands.append($0); return true
            }
        let coordinator = field.makeCoordinator(), control = NSSearchField(), editor = NSTextView()
        for selector in [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveRight(_:)),
                         #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveLeft(_:)),
                         #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: selector))
        }
        XCTAssertEqual(commands, [.down, .right, .up, .left, .submit, .cancel])
        XCTAssertFalse(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertFalse(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveWordLeft(_:))))
    }
    func testMarkedCompositionKeepsReturnAndArrowsInFieldEditor() {
        var text = "", focused = false, calls = 0
        let field = NativeEmojiPickerSearchField(text: Binding(get: { text }, set: { text = $0 }),
            focused: Binding(get: { focused }, set: { focused = $0 }), label: "Search emoji") { _ in calls += 1; return true }
        let coordinator = field.makeCoordinator(), control = NSSearchField(), editor = NSTextView()
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)), #selector(NSResponder.cancelOperation(_:))] {
            XCTAssertFalse(coordinator.control(control, textView: editor, doCommandBy: selector))
        }
        XCTAssertEqual(calls, 0)
        control.stringValue = "😀 heart"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: control))
        XCTAssertEqual(text, "😀 heart")
    }
    func testCommandHandlerCanPreserveOrdinaryHorizontalSearchEditing() {
        var text = "heart", focused = false
        let field = NativeEmojiPickerSearchField(text: Binding(get: { text }, set: { text = $0 }),
            focused: Binding(get: { focused }, set: { focused = $0 }), label: "Search emoji") {
                $0 != .left && $0 != .right
            }
        let coordinator = field.makeCoordinator(), control = NSSearchField(), editor = NSTextView()
        XCTAssertFalse(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        XCTAssertFalse(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveRight(_:))))
        XCTAssertTrue(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
    }
}
