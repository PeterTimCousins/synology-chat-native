import AppKit
import SwiftUI

/// Use the actual AppKit viewport. SwiftUI's lazy-stack preference geometry can
/// stop updating when macOS reuses the scroll document during history changes.
struct NativeScrollVisibility: NSViewRepresentable {
    struct ReaderContext: Equatable {
        let account: Int
        let channelID: Int64?
        let threadID: Int64?
        let viewportToken: UUID?
        let isLoading: Bool
        init(account:Int,channelID:Int64?,threadID:Int64?,viewportToken:UUID? = nil,isLoading:Bool = false) {
            self.account = account;self.channelID = channelID;self.threadID = threadID;self.viewportToken = viewportToken;self.isLoading = isLoading
        }
    }
    var readerContext: ReaderContext? = nil
    var keepLatestAfterResize: ((@escaping () -> Bool) -> Void)? = nil
    var changed: (Bool) -> Void
    static func isAtBottom(content: CGRect, visible: CGRect, flipped: Bool) -> Bool {
        guard content.height.isFinite, visible.height.isFinite, visible.minY.isFinite,
              content.height >= 0, visible.height > 0 else { return false }
        if content.height <= visible.height { return true }
        return flipped ? visible.maxY >= content.maxY - 30 : visible.minY <= content.minY + 30
    }
    func makeNSView(context: Context) -> Observer {
        let view = Observer(); view.configure(readerContext: readerContext, keepLatestAfterResize:keepLatestAfterResize, changed: changed); return view
    }
    func updateNSView(_ view: Observer, context: Context) { view.configure(readerContext: readerContext, keepLatestAfterResize:keepLatestAfterResize, changed: changed) }

    final class Observer: NSView {
        var changed: ((Bool) -> Void)?
        private weak var scroll: NSScrollView?
        private weak var document: NSView?
        private var tokens: [NSObjectProtocol] = []
        private var lastValue: Bool?
        private var lastVisibleSize: CGSize?
        private var lastVisibleOrigin: CGPoint?
        private var lastDocumentSize: CGSize?
        private var readerContext: ReaderContext?
        private var keepLatestAfterResize: ((@escaping () -> Bool) -> Void)?
        var monotonicNow: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        private struct ResizeIntent {
            let id = UUID()
            let deadline:TimeInterval
            var requestsRemaining:Int
        }
        private var pendingResize:ResizeIntent?
        private var userScrolling = false
        #if DEBUG
        private(set) var debugResizeEvents:[[String:Any]] = []
        private(set) var debugResizeCallbackCount = 0
        private var debugLastNow:TimeInterval?
        var debugResizeState:[String:Any] {
            var state = debugState()
            state["events"] = debugResizeEvents
            return state
        }
        private func debugNumber(_ value:Double?)->Any {
            guard let value,value.isFinite else { return NSNull() };return value
        }
        private func debugState()->[String:Any] {
            var state:[String:Any] = ["now":debugNumber(debugLastNow),"now_source":"last_observed_update",
                "deadline":debugNumber(pendingResize?.deadline),"remaining":pendingResize.map { $0.requestsRemaining as Any } ?? NSNull(),
                "last_value_before":lastValue.map { $0 as Any } ?? NSNull(),"callback_total":debugResizeCallbackCount,
                "has_callback":keepLatestAfterResize != nil,"user_scrolling":userScrolling]
            if let context = readerContext {
                state["reader_context"] = ["account":context.account,"channel_id":context.channelID.map { String($0) as Any } ?? NSNull(),
                    "thread_id":context.threadID.map { String($0) as Any } ?? NSNull(),"viewport_token":context.viewportToken.map { $0.uuidString as Any } ?? NSNull(),"is_loading":context.isLoading]
            } else { state["reader_context"] = NSNull() }
            if let origin = lastVisibleOrigin { state["cached_origin"] = ["x":debugNumber(Double(origin.x)),"y":debugNumber(Double(origin.y))] }
            if let size = lastVisibleSize { state["cached_visible_size"] = ["width":debugNumber(Double(size.width)),"height":debugNumber(Double(size.height))] }
            if let size = lastDocumentSize { state["cached_document_size"] = ["width":debugNumber(Double(size.width)),"height":debugNumber(Double(size.height))] }
            return state
        }
        private func debugTrace(_ event:String,reason:String? = nil,now:TimeInterval? = nil,resized:Bool? = nil,refined:Bool? = nil,
                                visible:CGRect? = nil,documentSize:CGSize? = nil,actualValue:Bool? = nil) {
            var entry = debugState();entry["event"] = event
            if let reason { entry["reason"] = reason }
            if let now { entry["now"] = debugNumber(now);entry["now_source"] = "current_observation" }
            entry["resized"] = resized.map { $0 as Any } ?? NSNull()
            entry["refined"] = refined.map { $0 as Any } ?? NSNull()
            if let visible {
                entry["observed_origin"] = ["x":debugNumber(Double(visible.minX)),"y":debugNumber(Double(visible.minY))]
                entry["observed_visible_size"] = ["width":debugNumber(Double(visible.width)),"height":debugNumber(Double(visible.height))]
            }
            if let size = documentSize { entry["observed_document_size"] = ["width":debugNumber(Double(size.width)),"height":debugNumber(Double(size.height))] }
            if let actualValue { entry["actual_value"] = actualValue }
            debugResizeEvents.append(entry)
            if debugResizeEvents.count > 32 { debugResizeEvents.removeFirst(debugResizeEvents.count-32) }
        }
        #endif
        func configure(readerContext: ReaderContext?,keepLatestAfterResize:((@escaping () -> Bool) -> Void)? = nil,changed: @escaping (Bool) -> Void) {
            #if DEBUG
            let hadCallback = self.keepLatestAfterResize != nil
            #endif
            self.changed = changed
            self.keepLatestAfterResize = keepLatestAfterResize
            if keepLatestAfterResize == nil {
                #if DEBUG
                if pendingResize != nil || hadCallback { debugTrace("cancel",reason:"callback_removed") }
                #endif
                pendingResize = nil;lastVisibleOrigin = nil
            }
            if readerContext != self.readerContext {
                #if DEBUG
                let loadingChanged = self.readerContext != nil && readerContext != nil && self.readerContext?.isLoading != readerContext?.isLoading
                debugTrace("cancel",reason:loadingChanged ? "loading_state_changed" : "reader_context_changed")
                #endif
                self.readerContext = readerContext
                // SwiftUI may reuse the same AppKit document for a new reader.
                // Its reset state needs a fresh report even if geometry is equal.
                lastValue = nil; lastVisibleSize = nil; lastVisibleOrigin = nil;lastDocumentSize = nil;pendingResize = nil
            }
            scheduleUpdate()
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleUpdate() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleUpdate() }
        override func layout() { super.layout(); scheduleUpdate() }
        func scheduleUpdate() { DispatchQueue.main.async { [weak self] in self?.updateViewport() } }
        private func userScroll(started:Bool = false,ended:Bool = false) {
            #if DEBUG
            debugTrace("cancel",reason:started ? "live_scroll_started" : ended ? "live_scroll_ended" : "live_scroll_moved")
            #endif
            if started { userScrolling = true }
            if ended { userScrolling = false }
            pendingResize = nil
            lastValue = nil;lastVisibleSize = nil;lastVisibleOrigin = nil;lastDocumentSize = nil
            scheduleUpdate()
        }
        func updateViewport() {
            guard let candidate = enclosingScrollView else {
                #if DEBUG
                if pendingResize != nil || lastValue != nil { debugTrace("cancel",reason:"detached") }
                #endif
                pendingResize = nil;lastValue = nil;lastVisibleSize = nil;lastVisibleOrigin = nil;lastDocumentSize = nil;userScrolling = false
                return
            }
            if candidate !== scroll || candidate.documentView !== document {
                #if DEBUG
                if pendingResize != nil || lastValue != nil { debugTrace("cancel",reason:candidate !== scroll ? "scroll_replaced" : "document_replaced") }
                #endif
                if candidate !== scroll { userScrolling = false }
                tokens.forEach(NotificationCenter.default.removeObserver); tokens = []
                scroll = candidate; document = candidate.documentView
                lastValue = nil; lastVisibleSize = nil;lastVisibleOrigin = nil;lastDocumentSize = nil;pendingResize = nil
                candidate.contentView.postsBoundsChangedNotifications = true
                document?.postsFrameChangedNotifications = true
                for (name, object) in [(NSView.boundsDidChangeNotification, candidate.contentView),
                                       (NSView.frameDidChangeNotification, candidate.documentView)] {
                    guard let object else { continue }
                    tokens.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                        self?.scheduleUpdate()
                    })
                }
                tokens.append(NotificationCenter.default.addObserver(forName:NSScrollView.willStartLiveScrollNotification,object:candidate,queue:.main) { [weak self] _ in self?.userScroll(started:true) })
                tokens.append(NotificationCenter.default.addObserver(forName:NSScrollView.didLiveScrollNotification,object:candidate,queue:.main) { [weak self] _ in self?.userScroll() })
                tokens.append(NotificationCenter.default.addObserver(forName:NSScrollView.didEndLiveScrollNotification,object:candidate,queue:.main) { [weak self] _ in self?.userScroll(ended:true) })
            }
            guard let document = candidate.documentView else { return }
            let expectedContext = readerContext
            var visible = candidate.documentVisibleRect
            let observedVisibleSize = visible.size,observedDocumentSize = document.bounds.size
            let now = monotonicNow()
            #if DEBUG
            debugLastNow = now
            #endif
            if !now.isFinite || pendingResize.map({ now >= $0.deadline }) == true {
                #if DEBUG
                if pendingResize != nil { debugTrace("expired",reason:now.isFinite ? "deadline" : "nonfinite_clock",now:now,visible:visible,documentSize:observedDocumentSize) }
                #endif
                pendingResize = nil
            }
            let resized = lastVisibleSize.map { $0 != visible.size || lastDocumentSize?.width != document.bounds.width } ?? false
            let refined = lastDocumentSize.map { $0 != document.bounds.size } ?? false
            #if DEBUG
            if resized || (refined && pendingResize != nil) { debugTrace("viewport_change",reason:resized ? "viewport_or_width" : "document_refinement",now:now,resized:resized,refined:refined,visible:visible,documentSize:observedDocumentSize) }
            #endif
            if pendingResize != nil,!resized,!refined,let origin = lastVisibleOrigin {
                let movedAway = document.isFlipped ? visible.minY < origin.y : visible.minY > origin.y
                // Keyboard/page actions and direct clip movement need not emit
                // a live-scroll notification. Never steal that manual position.
                if movedAway && !NativeScrollVisibility.isAtBottom(content:document.bounds,visible:visible,flipped:document.isFlipped) {
                    #if DEBUG
                    debugTrace("cancel",reason:"manual_origin_away",now:now,resized:resized,refined:refined,visible:visible,documentSize:observedDocumentSize)
                    #endif
                    pendingResize = nil
                }
            }
            let mayFollow = !userScrolling && readerContext?.isLoading != true && visible.minY.isFinite && visible.height.isFinite && document.bounds.height.isFinite && visible.height > 0 && document.bounds.height > visible.height
            let initialResize = mayFollow && lastValue == true && resized
            var requested = false,requestedAnchor = false
            if let keepLatestAfterResize {
                if initialResize,pendingResize == nil,now.isFinite,(now+0.350).isFinite {
                    pendingResize = ResizeIntent(deadline:now+0.350,requestsRemaining:8)
                    #if DEBUG
                    debugTrace("start",now:now,resized:resized,refined:refined,visible:visible,documentSize:observedDocumentSize)
                    #endif
                }
                if mayFollow,let intent = pendingResize,intent.requestsRemaining > 0,resized || refined {
                    // Lazy layout may refine its height after the first ID scroll.
                    // Continue only this bounded resize intent, without claiming
                    // that a request itself put the actual viewport at the bottom.
                    pendingResize?.requestsRemaining -= 1
                    #if DEBUG
                    debugResizeCallbackCount += 1
                    debugTrace("request",reason:"view_id_callback",now:now,resized:resized,refined:refined,visible:visible,documentSize:observedDocumentSize)
                    if pendingResize?.requestsRemaining == 0 { debugTrace("budget_exhausted",now:now,resized:resized,refined:refined,visible:visible,documentSize:observedDocumentSize) }
                    #endif
                    let expectedWindow = window.map(ObjectIdentifier.init)
                    keepLatestAfterResize { [weak self,weak candidate,weak document] in
                        guard let self,let candidate,let document,
                              self.pendingResize?.id == intent.id,self.readerContext == expectedContext,
                              self.scroll === candidate,self.document === document,
                              self.enclosingScrollView === candidate,candidate.documentView === document,
                              self.window.map(ObjectIdentifier.init) == expectedWindow,
                              self.keepLatestAfterResize != nil,!self.userScrolling,self.readerContext?.isLoading != true else { return false }
                        // The caller may defer the view-ID scroll until SwiftUI's
                        // anchor preferences settle. Revalidate its original finite
                        // intent at execution time, including manual clip movement.
                        let current = candidate.documentVisibleRect
                        if let origin = self.lastVisibleOrigin,
                           self.lastVisibleSize == current.size,self.lastDocumentSize == document.bounds.size {
                            let movedAway = document.isFlipped ? current.minY < origin.y : current.minY > origin.y
                            if movedAway && !NativeScrollVisibility.isAtBottom(content:document.bounds,visible:current,flipped:document.isFlipped) { return false }
                        }
                        let executionNow = self.monotonicNow()
                        return executionNow.isFinite && executionNow < intent.deadline
                    };requested = true;requestedAnchor = true
                }
            } else if initialResize {
                #if DEBUG
                debugTrace("request",reason:"direct_clip_fallback",now:now,resized:resized,refined:refined,visible:visible,documentSize:observedDocumentSize)
                #endif
                // A window resize changes the viewport and may reflow the document.
                // Preserve the user's latest-message position, but never pull someone
                // back down merely because they scrolled or older history loaded.
                let y = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - visible.height) : document.bounds.minY
                candidate.contentView.scroll(to: CGPoint(x: visible.minX, y: y))
                candidate.reflectScrolledClipView(candidate.contentView);requested = true
            }
            if requested {
                // The synchronous callback can replace the reader/document. Its
                // new configuration must receive its own fresh geometry report.
                guard readerContext == expectedContext,scroll === candidate,
                      enclosingScrollView === candidate,candidate.documentView === document else {
                    #if DEBUG
                    debugTrace("cancel",reason:"callback_rebound",now:now,resized:resized,refined:refined)
                    #endif
                    return
                }
                visible = candidate.documentVisibleRect
            }
            // Do not consume a new lazy-layout size produced by the delegate
            // itself; its queued frame notification needs one bounded next pass.
            let preserveRefinement = requestedAnchor && keepLatestAfterResize != nil
            lastVisibleSize = preserveRefinement ? observedVisibleSize : visible.size
            lastVisibleOrigin = visible.origin
            lastDocumentSize = preserveRefinement ? observedDocumentSize : document.bounds.size
            let value = NativeScrollVisibility.isAtBottom(content: document.bounds, visible: visible, flipped: document.isFlipped)
            if value != lastValue {
                #if DEBUG
                debugTrace("viewport_change",reason:"bottom_truth_changed",now:now,resized:resized,refined:refined,visible:visible,documentSize:observedDocumentSize,actualValue:value)
                #endif
                lastValue = value; changed?(value)
            }
        }
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}
