import AppKit
import SwiftUI

/// Markers retain no message content. The observer reports a single visible
/// post, so reconnect retention does not accumulate a second history cache.
struct NativeTimelineRowMarker:NSViewRepresentable {
    let postID:Int64
    let token:UUID
    func makeNSView(context:Context) -> Marker { let view = Marker();view.postID = postID;view.token = token;return view }
    func updateNSView(_ view:Marker,context:Context) { view.postID = postID;view.token = token }
    final class Marker:NSView {
        var postID:Int64 = 0
        var token = UUID()
        override init(frame:NSRect) { super.init(frame:frame);postsFrameChangedNotifications = true }
        required init?(coder:NSCoder) { super.init(coder:coder);postsFrameChangedNotifications = true }
        override func hitTest(_ point:NSPoint) -> NSView? { nil }
    }
}

struct NativeTimelineViewport:NSViewRepresentable {
#if DEBUG
    static var diagnostic = "No viewport report"
#endif
    let token:UUID
    var changed:(Int64,Bool)->Void
    func makeNSView(context:Context) -> Observer { let view = Observer();view.configure(token:token,changed:changed);return view }
    func updateNSView(_ view:Observer,context:Context) { view.configure(token:token,changed:changed) }
    final class Observer:NSView {
        private var token = UUID()
        private var changed:((Int64,Bool)->Void)?
        private weak var scroll:NSScrollView?
        private weak var document:NSView?
        private var observers:[NSObjectProtocol] = []
        private var scheduled = false
        private var lastID:Int64?
        private var lastBottom:Bool?
        func configure(token:UUID,changed:@escaping(Int64,Bool)->Void) {
            if self.token != token { self.token = token;lastID = nil;lastBottom = nil }
            self.changed = changed;schedule()
        }
        override func hitTest(_ point:NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow();schedule() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview();schedule() }
        override func layout() { super.layout();schedule() }
        private func schedule() {
            guard !scheduled else { return };scheduled = true
            DispatchQueue.main.async { [weak self] in self?.scheduled = false;self?.report() }
        }
        private func report() {
            guard let candidate = enclosingScrollView,let document = candidate.documentView else { return }
            if scroll !== candidate || self.document !== document {
                observers.forEach(NotificationCenter.default.removeObserver);observers = []
                scroll = candidate;self.document = document;lastID = nil;lastBottom = nil
                candidate.contentView.postsBoundsChangedNotifications = true;document.postsFrameChangedNotifications = true
                for (name,object) in [(NSView.boundsDidChangeNotification,candidate.contentView),(NSView.frameDidChangeNotification,document)] {
                    observers.append(NotificationCenter.default.addObserver(forName:name,object:object,queue:.main) { [weak self] _ in self?.schedule() })
                }
                // Lazy rows can move after the clip-view notification without
                // changing the document size. Re-read their settled geometry.
                observers.append(NotificationCenter.default.addObserver(forName:NSView.frameDidChangeNotification,object:nil,queue:.main) { [weak self] notification in
                    guard let self,let marker = notification.object as? NativeTimelineRowMarker.Marker,
                          marker.token == self.token else { return }
                    self.schedule()
                })
            }
            let visible = candidate.documentVisibleRect
            guard visible.height > 0 else { return }
            var first:(id:Int64,position:CGFloat)?
#if DEBUG
            var geometry:[String] = []
#endif
            func visit(_ view:NSView) {
                if let marker = view as? NativeTimelineRowMarker.Marker,marker.token == token {
                    let rect = marker.convert(marker.bounds,to:document)
#if DEBUG
                    geometry.append("\(marker.postID):\(Int(rect.minY))..\(Int(rect.maxY))")
#endif
                    // Ignore a clipped tail at the top edge; restoring that
                    // almost-hidden row would pull the previous message back in.
                    if rect.intersection(visible).height >= min(20,rect.height),rect.height > 0 {
                        let position = document.isFlipped ? rect.minY : -rect.maxY
                        if first == nil || position < first!.position { first = (marker.postID,position) }
                    }
                }
                for child in view.subviews { visit(child) }
            }
            visit(document)
#if DEBUG
            NativeTimelineViewport.diagnostic = "doc \(Int(document.bounds.minY))..\(Int(document.bounds.maxY)); clip \(Int(visible.minY))..\(Int(visible.maxY)); flipped \(document.isFlipped); " + geometry.joined(separator:" ")
#endif
            guard let first else { return }
            let bottom = NativeScrollVisibility.isAtBottom(content:document.bounds,visible:visible,flipped:document.isFlipped)
            if first.id != lastID || bottom != lastBottom {
                lastID = first.id;lastBottom = bottom;changed?(first.id,bottom)
            }
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
