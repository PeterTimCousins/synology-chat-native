import AppKit
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeTimelineViewportTests:XCTestCase {
    private final class Document:NSView { override var isFlipped:Bool { true } }
    private func tick() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    private func host(token:UUID,changed:@escaping(Int64,Bool)->Void)->(NSWindow,NSScrollView,NativeTimelineViewport.Observer,[NativeTimelineRowMarker.Marker]) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:320,height:240),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:320,height:240))
        let document = Document(frame:NSRect(x:0,y:0,width:320,height:800))
        window.contentView = scroll;scroll.documentView = document
        let markers = (0..<10).map { index in
            let marker = NativeTimelineRowMarker.Marker(frame:NSRect(x:0,y:index*80,width:320,height:80))
            marker.postID = Int64(100+index);marker.token = token;document.addSubview(marker);return marker
        }
        let observer = NativeTimelineViewport.Observer(frame:document.bounds)
        observer.configure(token:token,changed:changed);document.addSubview(observer)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible)
        addTeardownBlock { @MainActor in observer.removeFromSuperview();window.contentView = nil;window.close() }
        return (window,scroll,observer,markers)
    }
    func testActualViewportReportsFirstVisiblePostAndBottomAfterScrolling() async {
        var reports:[(Int64,Bool)] = []
        let (window,scroll,_,_) = host(token:UUID()) { reports.append(($0,$1)) }
        await tick();await tick()
        XCTAssertEqual(reports.last?.0,100);XCTAssertEqual(reports.last?.1,false)
        scroll.contentView.scroll(to:NSPoint(x:0,y:238));scroll.reflectScrolledClipView(scroll.contentView)
        await tick();await tick()
        XCTAssertEqual(reports.last?.0,103,"A two-point tail of the previous row must not become the reading anchor")
        scroll.contentView.scroll(to:NSPoint(x:0,y:240));scroll.reflectScrolledClipView(scroll.contentView)
        await tick();await tick()
        XCTAssertEqual(reports.last?.0,103);XCTAssertEqual(reports.last?.1,false)
        scroll.contentView.scroll(to:NSPoint(x:0,y:560));scroll.reflectScrolledClipView(scroll.contentView)
        await tick();await tick()
        XCTAssertEqual(reports.last?.0,107);XCTAssertEqual(reports.last?.1,true)
        XCTAssertFalse(window.isVisible)
    }
    func testReplacedReaderIgnoresOldMarkersAndDetachedObserverCannotPublish() async {
        var oldReports:[Int64] = [],newReports:[Int64] = []
        let (_,scroll,observer,markers) = host(token:UUID()) { id,_ in oldReports.append(id) }
        let replacement = UUID()
        observer.configure(token:replacement) { id,_ in newReports.append(id) }
        await tick();await tick()
        XCTAssertTrue(oldReports.isEmpty);XCTAssertTrue(newReports.isEmpty)
        markers[0].token = replacement
        observer.configure(token:replacement) { id,_ in newReports.append(id) }
        await tick();await tick()
        XCTAssertEqual(newReports,[100])
        observer.removeFromSuperview()
        scroll.contentView.scroll(to:NSPoint(x:0,y:320));scroll.reflectScrolledClipView(scroll.contentView)
        await tick();await tick()
        XCTAssertEqual(newReports,[100]);XCTAssertTrue(oldReports.isEmpty)
    }
    func testRowRelayoutUpdatesAnchorWithoutScrollingOrDocumentResize() async {
        var reports:[Int64] = []
        let (_,scroll,_,markers) = host(token:UUID()) { id,_ in reports.append(id) }
        scroll.contentView.scroll(to:NSPoint(x:0,y:240))
        await tick();await tick()
        XCTAssertEqual(reports.last,103)
        // SwiftUI can settle lazy-row geometry after the scroll notification.
        markers[2].setFrameOrigin(NSPoint(x:0,y:240))
        markers[3].setFrameOrigin(NSPoint(x:0,y:320))
        await tick();await tick()
        XCTAssertEqual(reports.last,102)
    }
}
