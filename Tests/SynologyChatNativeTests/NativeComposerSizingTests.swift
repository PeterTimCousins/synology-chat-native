import XCTest
import AppKit
import SwiftUI
@testable import SynologyChatNative

final class NativeComposerSizingTests:XCTestCase {
    @MainActor private final class Values {
        var text:String
        var selection:NSRange
        var heights:[CGFloat] = []
        init(_ text:String) { self.text = text;selection = NSRange(location:0,length:0) }
    }
    @MainActor private final class Fixture {
        let values:Values
        let component:NativeComposerText
        let coordinator:NativeComposerText.Coordinator
        let scroll:NativeComposerText.SizingScroll
        let editor:NativeComposerText.ComposerTextView
        let window:NSWindow
        init(_ text:String = "",width:CGFloat = 360,reports:Bool = true,style:NSScroller.Style = .overlay) {
            _ = NSApplication.shared
            let values = Values(text);self.values = values
            let callback:((CGFloat)->Void)? = reports ? { values.heights.append($0) } : nil
            let component = NativeComposerText(text:Binding(get:{ values.text },set:{ values.text = $0 }),
                selection:Binding(get:{ values.selection },set:{ values.selection = $0 }),focused:.constant(false),label:"Synthetic composer",onHeightChanged:callback)
            self.component = component
            let coordinator = component.makeCoordinator();self.coordinator = coordinator
            scroll = component.makeComposerView(coordinator:coordinator)
            editor = scroll.documentView as! NativeComposerText.ComposerTextView
            scroll.scrollerStyle = style
            // A legacy gutter is deliberately present, rather than inferred
            // from whether the current draft happens to overflow.
            scroll.autohidesScrollers = style != .legacy
            window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:width,height:100),styleMask:[],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = scroll
            layout()
        }
        func layout() { scroll.tile();scroll.layoutSubtreeIfNeeded();editor.layoutSubtreeIfNeeded() }
        func resize(_ width:CGFloat) { window.setContentSize(NSSize(width:width,height:100));layout() }
        func setText(_ text:String) { values.text = text;editor.string = text;editor.didChangeText();layout() }
        func measured()->CGFloat? { layout();return NativeComposerMeasuredHeight.height(in:editor,scale:window.backingScaleFactor) }
        func close() { NativeComposerText.dismantleNSView(scroll,coordinator:coordinator);window.contentView = nil;window.close() }
    }
    @MainActor private func drain() async {
        // Drain coalesced native layout callbacks, without a timing threshold.
        for _ in 0..<4 { await withCheckedContinuation { (value:CheckedContinuation<Void,Never>) in DispatchQueue.main.async { value.resume() } } }
    }

    @MainActor func testRealTextKitEmptyOneLineAndMultilineHeights() async throws {
        let fixture = Fixture();defer { fixture.close() }
        let empty = try XCTUnwrap(fixture.measured())
        fixture.setText("One line");let one = try XCTUnwrap(fixture.measured())
        fixture.setText("One line\nSecond line\nThird line\nFourth line")
        let multiple = try XCTUnwrap(fixture.measured())
        XCTAssertGreaterThan(empty,8);XCTAssertEqual(one,empty,accuracy:1)
        XCTAssertGreaterThan(multiple,one*2)
        await drain()
        XCTAssertEqual(fixture.values.heights.last,multiple)
        XCTAssertFalse(fixture.window.isVisible)
    }

    @MainActor func testTrailingNewlineIncludesRealInsertionLine() throws {
        let fixture = Fixture("Hello");defer { fixture.close() }
        let one = try XCTUnwrap(fixture.measured())
        fixture.setText("Hello\n");let two = try XCTUnwrap(fixture.measured())
        fixture.setText("Hello\n\n");let three = try XCTUnwrap(fixture.measured())
        XCTAssertGreaterThan(two,one);XCTAssertGreaterThan(three,two)
    }

    @MainActor func testUnicodeAndWrappingUseTheActualEditorWidth() throws {
        let text = String(repeating:"café 😀 family 👨‍👩‍👧‍👦 words ",count:14)
        let fixture = Fixture(text,width:650);defer { fixture.close() }
        let originalContainerWidth = try XCTUnwrap(fixture.editor.textContainer).containerSize.width
        let wide = try XCTUnwrap(fixture.measured())
        fixture.resize(180)
        let narrow = try XCTUnwrap(fixture.measured())
        XCTAssertLessThan(try XCTUnwrap(fixture.editor.textContainer).containerSize.width,originalContainerWidth)
        XCTAssertGreaterThan(narrow,wide)
        XCTAssertEqual(fixture.editor.string,text)
        let pixels = narrow*fixture.window.backingScaleFactor
        XCTAssertEqual(pixels,pixels.rounded(),accuracy:0.0001)
    }

    @MainActor func testLegacyScrollerUsesItsActualReducedTextContainer() throws {
        // A long unbroken run must wrap at character boundaries. Repeated
        // short words can coincidentally have equal line counts at both widths.
        let text = String(repeating:"W",count:512)
        let overlay = Fixture(text,width:240,style:.overlay),legacy = Fixture(text,width:240,style:.legacy)
        defer { overlay.close();legacy.close() }
        let overlayHeight = try XCTUnwrap(overlay.measured()),legacyHeight = try XCTUnwrap(legacy.measured())
        XCTAssertLessThan(try XCTUnwrap(legacy.editor.textContainer).containerSize.width,try XCTUnwrap(overlay.editor.textContainer).containerSize.width)
        XCTAssertGreaterThan(legacyHeight,overlayHeight)
        XCTAssertEqual(legacy.editor.string,overlay.editor.string)
    }

    @MainActor func testResizeMeasurementPreservesActualEditorSelectionFocusAndUndo() async throws {
        let fixture = Fixture("Original 😀 draft",width:500);defer { fixture.close() }
        fixture.editor.replaceWithUndo("Updated 😀 draft\nSecond line\nThird line")
        fixture.editor.setSelectedRange(NSRange(location:8,length:2))
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.editor))
        let editorID = ObjectIdentifier(fixture.editor),text = fixture.editor.string,selection = fixture.editor.selectedRange()
        let undo = try XCTUnwrap(fixture.editor.undoManager),undoID = ObjectIdentifier(undo)
        let canUndo = undo.canUndo
        fixture.resize(180);await drain()
        XCTAssertEqual(ObjectIdentifier(fixture.scroll.documentView!),editorID)
        XCTAssertEqual(fixture.editor.string,text);XCTAssertEqual(fixture.editor.selectedRange(),selection)
        XCTAssertTrue(fixture.window.firstResponder === fixture.editor)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(fixture.editor.undoManager)),undoID)
        XCTAssertEqual(undo.canUndo,canUndo)
        undo.undo();XCTAssertEqual(fixture.editor.string,"Original 😀 draft")
    }

    @MainActor func testDismantleRejectsQueuedHeightDelivery() async {
        let fixture = Fixture("Synthetic queued report")
        fixture.coordinator.scheduleHeightReport()
        NativeComposerText.dismantleNSView(fixture.scroll,coordinator:fixture.coordinator)
        await drain()
        XCTAssertTrue(fixture.values.heights.isEmpty)
        XCTAssertEqual(fixture.coordinator.heightMeasurementCount,0)
        fixture.close()
    }

    @MainActor func testWindowDetachRejectsQueuedReportAndReattachmentMeasuresAgain() async {
        let fixture = Fixture("Synthetic detached report");defer { fixture.close() }
        fixture.coordinator.scheduleHeightReport();fixture.window.contentView = nil
        await drain();XCTAssertTrue(fixture.values.heights.isEmpty)
        fixture.window.contentView = fixture.scroll;fixture.layout();await drain()
        XCTAssertFalse(fixture.values.heights.isEmpty)
    }

    @MainActor func testDefaultNilCallbackDoesNotMeasureOrChangeNativeEditor() async {
        let fixture = Fixture("Default native editor",reports:false);defer { fixture.close() }
        let id = ObjectIdentifier(fixture.editor),text = fixture.editor.string
        fixture.resize(180);fixture.coordinator.scheduleHeightReport();await drain()
        XCTAssertEqual(fixture.coordinator.heightMeasurementCount,0)
        XCTAssertTrue(fixture.values.heights.isEmpty)
        XCTAssertEqual(ObjectIdentifier(fixture.scroll.documentView!),id);XCTAssertEqual(fixture.editor.string,text)
    }
}
