import AppKit
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeTextDocumentLayoutTests:XCTestCase {
    func testReenablingWrapShrinksExpandedDocumentAndReturnsToStartOfLine() {
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:480,height:320))
        scroll.hasVerticalScroller = true
        let view = NSTextView(frame:scroll.contentView.bounds)
        view.font = .monospacedSystemFont(ofSize:13,weight:.regular)
        view.textContainerInset = NSSize(width:20,height:20)
        view.isVerticallyResizable = true
        view.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        view.string = String(repeating:"Long synthetic line ",count:80)
        scroll.documentView = view
        NativeTextDocumentView.updateLayout(of:scroll,wrap:true)
        let wrappedWidth = view.frame.width
        NativeTextDocumentView.updateLayout(of:scroll,wrap:false)
        XCTAssertGreaterThan(view.frame.width,wrappedWidth*2)
        scroll.contentView.scroll(to:NSPoint(x:500,y:0))
        XCTAssertGreaterThan(scroll.contentView.bounds.minX,0)
        NativeTextDocumentView.updateLayout(of:scroll,wrap:true)
        XCTAssertEqual(view.frame.width,scroll.contentSize.width,accuracy:1)
        XCTAssertEqual(scroll.contentView.bounds.minX,0,accuracy:0.1)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertTrue(view.textContainer?.widthTracksTextView == true)
        view.layoutManager?.ensureLayout(for:view.textContainer!)
        let used = view.layoutManager!.usedRect(for:view.textContainer!)
        XCTAssertLessThanOrEqual(used.width,scroll.contentSize.width)
        XCTAssertGreaterThan(used.height,view.font!.pointSize*2)
        XCTAssertEqual(view.string,String(repeating:"Long synthetic line ",count:80))
    }
}
