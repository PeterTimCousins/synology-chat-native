import AppKit
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeImageViewerKeysTests: XCTestCase {
    private let primary: NSEvent.ModifierFlags = [.control,.command]

    func testZoomInAcceptsPlusAndEqualsWithOptionalShift() {
        for value in ["+","="] {
            XCTAssertEqual(NativeImageViewerKeys.action(characters:value,modifiers:primary),.zoomIn)
            XCTAssertEqual(NativeImageViewerKeys.action(characters:value,modifiers:primary.union(.shift)),.zoomIn)
        }
        XCTAssertEqual(NativeImageViewerKeys.action(characters:"-",modifiers:primary),.zoomOut)
        XCTAssertEqual(NativeImageViewerKeys.action(characters:"-",modifiers:primary.union(.shift)),.zoomOut)
    }

    func testFitAndActualSizeDoNotCaptureShiftedNumberCommands() {
        XCTAssertEqual(NativeImageViewerKeys.action(characters:"0",modifiers:primary),.fit)
        XCTAssertEqual(NativeImageViewerKeys.action(characters:"1",modifiers:primary),.actualSize)
        for value in ["0","1",")","!"] {
            XCTAssertNil(NativeImageViewerKeys.action(characters:value,modifiers:primary.union(.shift)))
        }
    }

    func testOrdinaryTypingInterfaceZoomAndAccessibilityZoomAreNotIntercepted() {
        for value in ["+","=","-","0","1"] {
            for flags: NSEvent.ModifierFlags in [[],.shift,.command,.control,.option,[.command,.option],[.command,.option,.control]] {
                XCTAssertNil(NativeImageViewerKeys.action(characters:value,modifiers:flags))
            }
        }
        for value: String? in [nil,"","k","f","_","=="] {
            XCTAssertNil(NativeImageViewerKeys.action(characters:value,modifiers:primary))
        }
        XCTAssertEqual(NativeImageViewerKeys.action(characters:"+",modifiers:primary.union([.capsLock,.numericPad,.function])),.zoomIn)
    }

    func testEveryWindowAndEditingGuardPreventsRouting() {
        func allowed(_ overrides: [Int:Bool] = [:]) -> Bool {
            let defaults = [true,true,true,true,false,false,false]
            let values = defaults.enumerated().map { overrides[$0.offset] ?? $0.element }
            return NativeImageViewerKeys.canHandle(enabled:values[0],applicationActive:values[1],matchingWindow:values[2],windowKey:values[3],coveredBySheet:values[4],editable:values[5],markedText:values[6])
        }
        XCTAssertTrue(allowed())
        for index in 0..<7 { XCTAssertFalse(allowed([index:index >= 4]),"Guard \(index) must pass the event through") }
    }

    func testEditableAndMarkedTextRespondersAreDetected() {
        let text = NSTextView(); text.isEditable = true
        XCTAssertTrue(NativeImageViewerKeys.editingState(text).editable)
        text.isEditable = false
        XCTAssertFalse(NativeImageViewerKeys.editingState(text).editable)
        text.isEditable = true
        text.setMarkedText("compose",selectedRange:NSRange(location:0,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertTrue(NativeImageViewerKeys.editingState(text).markedText)
        let field = NSTextField(); field.isEditable = true
        XCTAssertTrue(NativeImageViewerKeys.editingState(field).editable)
        XCTAssertFalse(NativeImageViewerKeys.editingState(nil).editable)
        XCTAssertFalse(NativeImageViewerKeys.editingState(nil).markedText)
    }

    func testMonitorInstallAndRemovalAreIdempotentAndDoNotHitTest() {
        let view = NativeImageViewerKeysView.KeyView()
        XCTAssertFalse(view.isMonitoring)
        view.install(); XCTAssertTrue(view.isMonitoring)
        view.install(); XCTAssertTrue(view.isMonitoring)
        XCTAssertNil(view.hitTest(.zero))
        view.uninstall(); XCTAssertFalse(view.isMonitoring)
        view.uninstall(); XCTAssertFalse(view.isMonitoring)
    }
}
