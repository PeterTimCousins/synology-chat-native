import XCTest
import AppKit
@testable import SynologyChatNative

final class NativeScrollVisibilityTests: XCTestCase {
    @MainActor
    private func fixture()->(NSScrollView,FlippedSyntheticDocument,NativeScrollVisibility.Observer) {
        let scroll = NSScrollView(frame:CGRect(x:0,y:0,width:600,height:500))
        let document = FlippedSyntheticDocument(frame:CGRect(x:0,y:0,width:600,height:2000))
        scroll.documentView = document;scroll.tile()
        let observer = NativeScrollVisibility.Observer(frame:.zero);document.addSubview(observer)
        scroll.contentView.scroll(to:CGPoint(x:0,y:document.bounds.maxY-scroll.documentVisibleRect.height))
        return (scroll,document,observer)
    }
    @MainActor
    private func resizeWithoutFollowing(_ scroll:NSScrollView,height:CGFloat) {
        let y = scroll.documentVisibleRect.minY
        scroll.setFrameSize(CGSize(width:scroll.frame.width,height:height));scroll.tile()
        scroll.contentView.scroll(to:CGPoint(x:0,y:y))
    }

    #if DEBUG
    @MainActor
    func testResizeDiagnosticsAreBoundedJSONSafeAndDoNotReadClock() {
        let (scroll,document,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var now:TimeInterval = 100,clockReads = 0,requests = 0
        observer.monotonicNow = { clockReads += 1;return now }
        observer.configure(readerContext:.init(account:1,channelID:Int64.max,threadID:nil),keepLatestAfterResize:{ _ in
            requests += 1
            scroll.contentView.scroll(to:CGPoint(x:0,y:document.bounds.maxY-scroll.documentVisibleRect.height))
        }) { _ in }
        observer.updateViewport()
        for index in 0..<40 {
            now += 1
            resizeWithoutFollowing(scroll,height:index.isMultiple(of:2) ? 250 : 400)
            observer.updateViewport()
        }
        XCTAssertEqual(requests,40)
        XCTAssertEqual(observer.debugResizeCallbackCount,requests)
        XCTAssertEqual(observer.debugResizeEvents.count,32)
        let readsBeforeSnapshot = clockReads
        let state = observer.debugResizeState
        XCTAssertEqual(clockReads,readsBeforeSnapshot,"Reading diagnostics must not advance the injected clock")
        XCTAssertEqual(clockReads,41,"Tracing must reuse the single clock observation per update")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(state))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject:state))
        XCTAssertTrue(observer.debugResizeEvents.contains { $0["event"] as? String == "request" })
    }

    @MainActor
    func testResizeDiagnosticsSanitizeNonfiniteClockWithoutChangingCancellation() {
        let (scroll,document,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var now:TimeInterval = 100,clockReads = 0,requests = 0
        observer.monotonicNow = { clockReads += 1;return now }
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil),keepLatestAfterResize:{ _ in requests += 1 }) { _ in }
        observer.updateViewport();resizeWithoutFollowing(scroll,height:250);observer.updateViewport()
        now = .nan
        document.setFrameSize(CGSize(width:600,height:2200));observer.updateViewport()
        XCTAssertEqual(requests,1)
        let state = observer.debugResizeState
        XCTAssertEqual(clockReads,3)
        XCTAssertTrue(state["now"] is NSNull)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(state))
        let expiry = observer.debugResizeEvents.last { $0["event"] as? String == "expired" }
        XCTAssertEqual(expiry?["reason"] as? String,"nonfinite_clock")
        XCTAssertTrue(expiry?["now"] is NSNull)
    }
    #endif

    @MainActor
    func testDeferredResizePermitAcceptsCurrentIntentAndRejectsStaleExecution() {
        for invalidation in ["manual-clip","live-scroll","context","loading","document","detach","window","callback","expiry","nonfinite"] {
            let (scroll,document,observer) = fixture()
            defer { observer.configure(readerContext:nil) { _ in } }
            let window:NSWindow? = invalidation == "window" ? NSWindow(contentRect:scroll.frame,styleMask:.borderless,backing:.buffered,defer:false) : nil
            window?.contentView = scroll
            defer { window?.contentView = nil }
            var now:TimeInterval = 100
            var permit:(() -> Bool)?
            let context = NativeScrollVisibility.ReaderContext(account:1,channelID:93,threadID:nil)
            observer.monotonicNow = { now }
            observer.configure(readerContext:context,keepLatestAfterResize:{ permit = $0 }) { _ in }
            observer.updateViewport();resizeWithoutFollowing(scroll,height:250);observer.updateViewport()
            XCTAssertEqual(permit?(),true,invalidation)
            switch invalidation {
            case "manual-clip": scroll.contentView.scroll(to:CGPoint(x:0,y:200))
            case "live-scroll": NotificationCenter.default.post(name:NSScrollView.willStartLiveScrollNotification,object:scroll)
            case "context": observer.configure(readerContext:.init(account:2,channelID:93,threadID:nil),keepLatestAfterResize:{ _ in }) { _ in }
            case "loading": observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil,isLoading:true),keepLatestAfterResize:{ _ in }) { _ in }
            case "document": scroll.documentView = FlippedSyntheticDocument(frame:document.frame)
            case "detach": observer.removeFromSuperview()
            case "window": window?.contentView = NSView()
            case "callback": observer.configure(readerContext:context) { _ in }
            case "expiry": now += 0.350
            default: now = .nan
            }
            XCTAssertEqual(permit?(),false,invalidation)
        }
    }

    @MainActor
    func testSmallBottomInsetAdjustmentRetainsPendingResizeAndDeferredPermit() {
        let (scroll,document,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var permits:[() -> Bool] = []
        observer.monotonicNow = { 100 }
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil),keepLatestAfterResize:{
            permits.append($0)
            scroll.contentView.scroll(to:CGPoint(x:0,y:document.bounds.maxY-scroll.documentVisibleRect.height))
        }) { _ in }
        observer.updateViewport();resizeWithoutFollowing(scroll,height:250);observer.updateViewport()
        XCTAssertEqual(permits.count,1)
        scroll.contentView.scroll(to:CGPoint(x:0,y:scroll.documentVisibleRect.minY-21))
        XCTAssertTrue(permits[0](),"An inset adjustment inside the established bottom tolerance is still at bottom")
        observer.updateViewport()
        document.setFrameSize(CGSize(width:600,height:2100));observer.updateViewport()
        XCTAssertEqual(permits.count,2,"A small still-at-bottom correction must not cancel the bounded refinement intent")
        XCTAssertTrue(permits[1]())
    }

    @MainActor
    func testDeferredResizePermitCannotCrossIntentReplacement() {
        let (scroll,document,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var now:TimeInterval = 100
        var permits:[() -> Bool] = []
        observer.monotonicNow = { now }
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil),keepLatestAfterResize:{ permits.append($0) }) { _ in }
        observer.updateViewport();resizeWithoutFollowing(scroll,height:250);observer.updateViewport()
        XCTAssertEqual(permits.count,1);XCTAssertTrue(permits[0]())
        now += 1
        scroll.contentView.scroll(to:CGPoint(x:0,y:document.bounds.maxY-scroll.documentVisibleRect.height))
        observer.updateViewport()
        resizeWithoutFollowing(scroll,height:300);observer.updateViewport()
        XCTAssertEqual(permits.count,2)
        XCTAssertFalse(permits[0]());XCTAssertTrue(permits[1]())
    }

    @MainActor
    func testFinalBudgetedDeferredRequestStillHasValidPermit() {
        let (scroll,document,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var permits:[() -> Bool] = []
        observer.monotonicNow = { 100 }
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil),keepLatestAfterResize:{ permits.append($0) }) { _ in }
        observer.updateViewport();resizeWithoutFollowing(scroll,height:250);observer.updateViewport()
        for index in 1..<8 {
            document.setFrameSize(CGSize(width:600,height:CGFloat(2000+index*10)));observer.updateViewport()
        }
        XCTAssertEqual(permits.count,8)
        XCTAssertTrue(permits.last?() == true,"Consuming the final request must not invalidate its deferred execution")
    }

    @MainActor
    func testPendingResizeContinuesOnLateHeightAndViewportRefinementWithoutFabricatedBottom() {
        let (scroll,document,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var now:TimeInterval = 100,requests = 0,reports:[Bool] = []
        observer.monotonicNow = { now }
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil),keepLatestAfterResize:{ _ in requests += 1 }) { reports.append($0) }
        observer.updateViewport();resizeWithoutFollowing(scroll,height:250);observer.updateViewport()
        XCTAssertEqual(requests,1);XCTAssertEqual(reports,[true,false])
        now += 0.1;document.setFrameSize(CGSize(width:600,height:2200));observer.updateViewport()
        XCTAssertEqual(requests,2,"Late lazy document-height refinement retains this resize's latest intent")
        now += 0.1;resizeWithoutFollowing(scroll,height:300);observer.updateViewport()
        XCTAssertEqual(requests,3,"Another viewport resize can continue the pending intent even while actual bottom is false")
        XCTAssertEqual(reports,[true,false]);XCTAssertLessThan(scroll.documentVisibleRect.maxY,document.bounds.maxY-30)
    }

    @MainActor
    func testPendingResizeSurvivesImmediateBottomUntilLateDocumentHeightDrift() {
        let (scroll,document,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var now:TimeInterval = 100,requests = 0,reports:[Bool] = []
        observer.monotonicNow = { now }
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil),keepLatestAfterResize:{ _ in
            requests += 1;scroll.contentView.scroll(to:CGPoint(x:0,y:document.bounds.maxY-scroll.documentVisibleRect.height))
        }) { reports.append($0) }
        observer.updateViewport();resizeWithoutFollowing(scroll,height:250);observer.updateViewport()
        XCTAssertEqual(requests,1);XCTAssertEqual(reports,[true])
        now += 0.2;document.setFrameSize(CGSize(width:600,height:2300));observer.updateViewport()
        XCTAssertEqual(requests,2);XCTAssertEqual(reports,[true])
        XCTAssertTrue(NativeScrollVisibility.isAtBottom(content:document.bounds,visible:scroll.documentVisibleRect,flipped:true))
    }

    @MainActor
    func testDelegateCausedDocumentRefinementGetsOneBoundedNextPass() {
        let (scroll,document,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var requests = 0,reports:[Bool] = []
        observer.monotonicNow = { 100 }
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil),keepLatestAfterResize:{ _ in
            requests += 1
            if requests == 1 { document.setFrameSize(CGSize(width:600,height:2100)) }
            else { scroll.contentView.scroll(to:CGPoint(x:0,y:document.bounds.maxY-scroll.documentVisibleRect.height)) }
        }) { reports.append($0) }
        observer.updateViewport();resizeWithoutFollowing(scroll,height:250);observer.updateViewport()
        XCTAssertEqual(requests,1);XCTAssertEqual(reports,[true,false])
        observer.updateViewport()
        XCTAssertEqual(requests,2);XCTAssertEqual(reports,[true,false,true])
        observer.updateViewport();XCTAssertEqual(requests,2,"Unchanged geometry must not cause a no-op retry loop")
    }

    @MainActor
    func testRefinementsCannotExtendPendingResizeDeadline() {
        let (scroll,document,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var now:TimeInterval = 100,requests = 0
        observer.monotonicNow = { now }
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil),keepLatestAfterResize:{ _ in requests += 1 }) { _ in }
        observer.updateViewport();resizeWithoutFollowing(scroll,height:250);observer.updateViewport()
        now += 0.2;document.setFrameSize(CGSize(width:600,height:2100));observer.updateViewport()
        XCTAssertEqual(requests,2)
        now += 0.151;document.setFrameSize(CGSize(width:600,height:2200));observer.updateViewport()
        XCTAssertEqual(requests,2,"Deadline is fixed from the original resize, not renewed by a document refinement")
        resizeWithoutFollowing(scroll,height:300);observer.updateViewport();XCTAssertEqual(requests,2)
    }

    @MainActor
    func testPendingResizeHasEightRequestBudgetEvenWhenBottomKeepsReturningTrue() {
        let (scroll,document,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var now:TimeInterval = 100,requests = 0
        observer.monotonicNow = { now }
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil),keepLatestAfterResize:{ _ in
            requests += 1;scroll.contentView.scroll(to:CGPoint(x:0,y:document.bounds.maxY-scroll.documentVisibleRect.height))
        }) { _ in }
        observer.updateViewport();resizeWithoutFollowing(scroll,height:250);observer.updateViewport()
        for index in 1...12 {
            now += 0.01;document.setFrameSize(CGSize(width:CGFloat(600+index%2),height:CGFloat(2000+index*50)));observer.updateViewport()
        }
        XCTAssertEqual(requests,8,"Width changes and successful scrolls cannot refill this intent's bounded budget")
    }

    @MainActor
    func testModernAndLegacyUserScrollNotificationsCancelPendingResize() {
        for notification in [NSScrollView.willStartLiveScrollNotification,NSScrollView.didLiveScrollNotification] {
            let (scroll,document,observer) = fixture()
            defer { observer.configure(readerContext:nil) { _ in } }
            var requests = 0
            observer.monotonicNow = { 100 }
            observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil),keepLatestAfterResize:{ _ in requests += 1 }) { _ in }
            observer.updateViewport();resizeWithoutFollowing(scroll,height:250);observer.updateViewport();XCTAssertEqual(requests,1)
            NotificationCenter.default.post(name:notification,object:scroll)
            document.setFrameSize(CGSize(width:600,height:2300));observer.updateViewport()
            resizeWithoutFollowing(scroll,height:300);observer.updateViewport()
            XCTAssertEqual(requests,1,"Real user scrolling must retire the old resize intent")
            NotificationCenter.default.post(name:NSScrollView.didEndLiveScrollNotification,object:scroll)
            observer.updateViewport()
        }
    }

    @MainActor
    func testDirectManualClipMovementCancelsPendingResizeBeforeLaterRefinement() {
        let (scroll,document,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var requests = 0
        observer.monotonicNow = { 100 }
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil),keepLatestAfterResize:{ _ in
            requests += 1;scroll.contentView.scroll(to:CGPoint(x:0,y:document.bounds.maxY-scroll.documentVisibleRect.height))
        }) { _ in }
        observer.updateViewport();resizeWithoutFollowing(scroll,height:250);observer.updateViewport()
        XCTAssertEqual(requests,1)
        // No live-scroll notification: keyboard/page actions can move the clip
        // directly. The bounds observation must still cancel resize following.
        scroll.contentView.scroll(to:CGPoint(x:0,y:200));observer.updateViewport()
        document.setFrameSize(CGSize(width:600,height:2300));observer.updateViewport()
        XCTAssertEqual(requests,1);XCTAssertEqual(scroll.documentVisibleRect.minY,200,accuracy:0.001)
    }

    @MainActor
    func testLoadingAndCallbackRemovalCancelPendingResize() {
        let (scroll,document,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var requests = 0
        observer.monotonicNow = { 100 }
        let context = NativeScrollVisibility.ReaderContext(account:1,channelID:93,threadID:nil)
        observer.configure(readerContext:context,keepLatestAfterResize:{ _ in requests += 1 }) { _ in }
        observer.updateViewport();resizeWithoutFollowing(scroll,height:250);observer.updateViewport()
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil,isLoading:true),keepLatestAfterResize:{ _ in requests += 1 }) { _ in }
        observer.updateViewport();document.setFrameSize(CGSize(width:610,height:2200));observer.updateViewport()
        resizeWithoutFollowing(scroll,height:300);observer.updateViewport();XCTAssertEqual(requests,1)
        observer.configure(readerContext:context,keepLatestAfterResize:{ _ in requests += 1 }) { _ in };observer.updateViewport()
        document.setFrameSize(CGSize(width:610,height:2300));observer.updateViewport();XCTAssertEqual(requests,1)
        scroll.contentView.scroll(to:CGPoint(x:0,y:document.bounds.maxY-scroll.documentVisibleRect.height));observer.updateViewport()
        resizeWithoutFollowing(scroll,height:250);observer.updateViewport();XCTAssertEqual(requests,2)
        observer.configure(readerContext:context) { _ in }
        let before = scroll.documentVisibleRect
        document.setFrameSize(CGSize(width:610,height:2500));observer.updateViewport()
        XCTAssertEqual(scroll.documentVisibleRect,before,"Plain fallback consumers must not inherit a removed delegate's pending height-refinement intent")
        XCTAssertEqual(requests,2)
    }

    @MainActor
    func testDocumentReplacementCancelsPendingResize() {
        let (scroll,_,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var requests = 0
        observer.monotonicNow = { 100 }
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil),keepLatestAfterResize:{ _ in requests += 1 }) { _ in }
        observer.updateViewport();resizeWithoutFollowing(scroll,height:250);observer.updateViewport();XCTAssertEqual(requests,1)
        let replacement = FlippedSyntheticDocument(frame:CGRect(x:0,y:0,width:600,height:2500))
        scroll.documentView = replacement;replacement.addSubview(observer);scroll.contentView.scroll(to:CGPoint(x:0,y:200))
        observer.updateViewport();replacement.setFrameSize(CGSize(width:600,height:2700));observer.updateViewport()
        XCTAssertEqual(requests,1);XCTAssertLessThan(scroll.documentVisibleRect.minY,500)
    }

    @MainActor
    func testNonfiniteClockCancelsPendingResizeWithoutFollowing() {
        let (scroll,document,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var now:TimeInterval = 100,requests = 0
        observer.monotonicNow = { now }
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil),keepLatestAfterResize:{ _ in requests += 1 }) { _ in }
        observer.updateViewport();resizeWithoutFollowing(scroll,height:250);observer.updateViewport()
        now = .nan;document.setFrameSize(CGSize(width:600,height:2300));observer.updateViewport()
        XCTAssertEqual(requests,1)
    }

    @MainActor
    func testResizeDelegateRunsSynchronouslyWithoutDirectClipMovementOrFabricatedBottom() {
        let (scroll,document,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var requests = 0,reports:[Bool] = []
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil),keepLatestAfterResize:{ _ in requests += 1 }) { reports.append($0) }
        observer.updateViewport();XCTAssertEqual(reports,[true]);XCTAssertEqual(requests,0)
        let oldY = scroll.documentVisibleRect.minY
        scroll.setFrameSize(CGSize(width:600,height:250));scroll.tile()
        scroll.contentView.scroll(to:CGPoint(x:0,y:oldY))
        let before = scroll.documentVisibleRect
        XCTAssertFalse(NativeScrollVisibility.isAtBottom(content:document.bounds,visible:before,flipped:true))
        observer.updateViewport()
        XCTAssertEqual(requests,1,"The delegate must run before updateViewport returns")
        XCTAssertEqual(scroll.documentVisibleRect,before,"A delegated lazy-stack resize must not also move the AppKit clip directly")
        XCTAssertEqual(reports,[true,false],"A delegate request alone is not proof that the viewport reached the bottom")
        observer.updateViewport();XCTAssertEqual(requests,1)
    }

    @MainActor
    func testResizeDelegateCanMoveToBottomAndActualGeometryDeterminesReport() {
        let (scroll,document,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var requests = 0,reports:[Bool] = []
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil),keepLatestAfterResize:{ _ in
            requests += 1
            scroll.contentView.scroll(to:CGPoint(x:0,y:document.bounds.maxY-scroll.documentVisibleRect.height))
        }) { reports.append($0) }
        observer.updateViewport()
        let oldY = scroll.documentVisibleRect.minY
        scroll.setFrameSize(CGSize(width:600,height:250));scroll.tile()
        scroll.contentView.scroll(to:CGPoint(x:0,y:oldY))
        observer.updateViewport()
        XCTAssertEqual(requests,1)
        XCTAssertTrue(NativeScrollVisibility.isAtBottom(content:document.bounds,visible:scroll.documentVisibleRect,flipped:true))
        XCTAssertEqual(reports,[true],"Unchanged viewport truth needs no duplicate report")
    }

    @MainActor
    func testResizeDelegateDoesNotFollowReaderAfterManualScrollBack() {
        let (scroll,_,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var requests = 0,reports:[Bool] = []
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil),keepLatestAfterResize:{ _ in requests += 1 }) { reports.append($0) }
        observer.updateViewport()
        scroll.contentView.scroll(to:CGPoint(x:0,y:200));observer.updateViewport()
        scroll.setFrameSize(CGSize(width:500,height:350));scroll.tile()
        observer.updateViewport()
        XCTAssertEqual(requests,0)
        XCTAssertEqual(reports,[true,false])
        XCTAssertLessThan(scroll.documentVisibleRect.minY,500)
    }

    @MainActor
    func testHistoryHeightChangeAloneDoesNotInvokeResizeDelegate() {
        let (scroll,document,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var requests = 0,reports:[Bool] = []
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil),keepLatestAfterResize:{ _ in requests += 1 }) { reports.append($0) }
        observer.updateViewport();let before = scroll.documentVisibleRect
        document.setFrameSize(CGSize(width:600,height:3000))
        observer.updateViewport()
        XCTAssertEqual(requests,0)
        XCTAssertEqual(scroll.documentVisibleRect,before)
        XCTAssertEqual(reports,[true,false])
    }

    @MainActor
    func testAccountChannelThreadAndViewportTokenRebindClearOldLatestIntent() {
        let originalToken = UUID()
        let contexts:[NativeScrollVisibility.ReaderContext] = [
            .init(account:2,channelID:93,threadID:11,viewportToken:originalToken),
            .init(account:1,channelID:94,threadID:11,viewportToken:originalToken),
            .init(account:1,channelID:93,threadID:12,viewportToken:originalToken),
            .init(account:1,channelID:93,threadID:11,viewportToken:UUID())]
        for next in contexts {
            let (scroll,_,observer) = fixture()
            defer { observer.configure(readerContext:nil) { _ in } }
            var requests = 0,reports:[Bool] = []
            observer.configure(readerContext:.init(account:1,channelID:93,threadID:11,viewportToken:originalToken),keepLatestAfterResize:{ _ in requests += 1 }) { reports.append($0) }
            observer.updateViewport()
            scroll.contentView.scroll(to:CGPoint(x:0,y:200));scroll.setFrameSize(CGSize(width:500,height:350));scroll.tile()
            let before = scroll.documentVisibleRect
            observer.configure(readerContext:next,keepLatestAfterResize:{ _ in requests += 1 }) { reports.append($0) }
            observer.updateViewport()
            XCTAssertEqual(requests,0)
            XCTAssertEqual(scroll.documentVisibleRect,before)
            XCTAssertEqual(reports,[true,false])
        }
    }

    @MainActor
    func testSynchronousDelegateRebindCannotPublishOldGeometryToNewReader() {
        let (scroll,_,observer) = fixture()
        defer { observer.configure(readerContext:nil) { _ in } }
        var requests = 0,oldReports:[Bool] = [],newReports:[Bool] = []
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil),keepLatestAfterResize:{ _ in
            requests += 1
            observer.configure(readerContext:.init(account:1,channelID:94,threadID:nil)) { newReports.append($0) }
        }) { oldReports.append($0) }
        observer.updateViewport();let oldY = scroll.documentVisibleRect.minY
        scroll.setFrameSize(CGSize(width:600,height:250));scroll.tile();scroll.contentView.scroll(to:CGPoint(x:0,y:oldY))
        observer.updateViewport()
        XCTAssertEqual(requests,1);XCTAssertEqual(oldReports,[true]);XCTAssertTrue(newReports.isEmpty)
        observer.updateViewport()
        XCTAssertEqual(newReports,[false],"The rebound context gets its own fresh geometry report")
    }

    @MainActor
    func testReboundReaderContextReceivesCurrentBottomWithoutGeometryChange() {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        let document = FlippedSyntheticDocument(frame: CGRect(x: 0, y: 0, width: 600, height: 2000))
        scroll.documentView = document
        scroll.tile()
        let observer = NativeScrollVisibility.Observer(frame: .zero)
        document.addSubview(observer)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.bounds.maxY - scroll.documentVisibleRect.height))
        var firstReports: [Bool] = []
        observer.configure(readerContext:.init(account:1,channelID:93,threadID:nil)) { firstReports.append($0) }
        observer.updateViewport()
        XCTAssertEqual(firstReports, [true])
        let originalViewport = scroll.documentVisibleRect

        // NativeChatPreview resets atBottom when its selected conversation
        // changes. SwiftUI can retain this same scroll/document/observer and
        // rebind the callback while the newly selected content also fits here.
        var nextContextAtBottom = false
        var reboundReports: [Bool] = []
        observer.configure(readerContext:.init(account:1,channelID:94,threadID:nil)) { nextContextAtBottom = $0; reboundReports.append($0) }
        observer.updateViewport()

        XCTAssertEqual(scroll.documentVisibleRect, originalViewport)
        XCTAssertTrue(NativeScrollVisibility.isAtBottom(content: document.bounds, visible: scroll.documentVisibleRect, flipped: true))
        XCTAssertTrue(nextContextAtBottom, "A new reader context must not remain false merely because cached viewport truth stayed true")
        XCTAssertEqual(reboundReports, [true], "Rebinding must publish the current viewport before any manual scroll")
    }

    @MainActor
    func testNewAccountAndThreadRepublishWithoutPullingNewReaderToOldBottom() {
        let scroll = NSScrollView(frame:CGRect(x:0,y:0,width:600,height:500))
        let document = FlippedSyntheticDocument(frame:CGRect(x:0,y:0,width:600,height:2000))
        scroll.documentView = document;scroll.tile()
        let observer = NativeScrollVisibility.Observer(frame:.zero);document.addSubview(observer)
        let original = NativeScrollVisibility.ReaderContext(account:1,channelID:93,threadID:11)
        scroll.contentView.scroll(to:CGPoint(x:0,y:1500))
        var reports:[Bool] = []
        observer.configure(readerContext:original) { reports.append($0) };observer.updateViewport()
        XCTAssertEqual(reports,[true])
        observer.configure(readerContext:original) { reports.append($0) };observer.updateViewport()
        XCTAssertEqual(reports,[true],"An unchanged reader and viewport need no repeated report")
        // A new account takes over this reused document at a different position
        // while its viewport also resizes; old bottom intent must not pull it down.
        scroll.contentView.scroll(to:CGPoint(x:0,y:200));scroll.setFrameSize(CGSize(width:600,height:400));scroll.tile()
        observer.configure(readerContext:.init(account:2,channelID:93,threadID:11)) { reports.append($0) };observer.updateViewport()
        XCTAssertLessThan(scroll.documentVisibleRect.minY,500)
        XCTAssertEqual(reports,[true,false])
        observer.configure(readerContext:.init(account:2,channelID:93,threadID:12)) { reports.append($0) };observer.updateViewport()
        XCTAssertEqual(reports,[true,false,false],"A different root receives the unchanged current position")
        XCTAssertLessThan(scroll.documentVisibleRect.minY,500)
    }

    @MainActor
    func testRealScrollViewResizeKeepsBottomButRespectsManualScrollBack() {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        let document = FlippedSyntheticDocument(frame: CGRect(x: 0, y: 0, width: 600, height: 2000))
        scroll.documentView = document
        scroll.tile()
        let observer = NativeScrollVisibility.Observer(frame: .zero)
        document.addSubview(observer)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.bounds.maxY - scroll.documentVisibleRect.height))
        observer.updateViewport()
        scroll.setFrameSize(CGSize(width: 600, height: 250)); scroll.tile()
        observer.updateViewport()
        XCTAssertTrue(NativeScrollVisibility.isAtBottom(content: document.bounds, visible: scroll.documentVisibleRect, flipped: true))
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 200))
        observer.updateViewport()
        scroll.setFrameSize(CGSize(width: 600, height: 400)); scroll.tile()
        observer.updateViewport()
        XCTAssertFalse(NativeScrollVisibility.isAtBottom(content: document.bounds, visible: scroll.documentVisibleRect, flipped: true))
        XCTAssertLessThan(scroll.documentVisibleRect.minY, 500)
    }

    func testFlippedDocumentRequiresLatestEndOfRealViewport() {
        let content = CGRect(x: 0, y: 0, width: 600, height: 2000)
        XCTAssertFalse(NativeScrollVisibility.isAtBottom(content: content, visible: CGRect(x: 0, y: 1000, width: 600, height: 500), flipped: true))
        XCTAssertTrue(NativeScrollVisibility.isAtBottom(content: content, visible: CGRect(x: 0, y: 1500, width: 600, height: 500), flipped: true))
    }
    func testUnflippedDocumentUsesOppositeEdge() {
        let content = CGRect(x: 0, y: 0, width: 600, height: 2000)
        XCTAssertFalse(NativeScrollVisibility.isAtBottom(content: content, visible: CGRect(x: 0, y: 1000, width: 600, height: 500), flipped: false))
        XCTAssertTrue(NativeScrollVisibility.isAtBottom(content: content, visible: CGRect(x: 0, y: 0, width: 600, height: 500), flipped: false))
    }
    func testShortDocumentsAreVisibleButUnlaidOutViewportIsNot() {
        let content = CGRect(x: 0, y: 0, width: 600, height: 100)
        XCTAssertTrue(NativeScrollVisibility.isAtBottom(content: content, visible: CGRect(x: 0, y: 0, width: 600, height: 500), flipped: true))
        XCTAssertFalse(NativeScrollVisibility.isAtBottom(content: content, visible: .zero, flipped: true))
    }
}

private final class FlippedSyntheticDocument: NSView {
    override var isFlipped: Bool { true }
}
