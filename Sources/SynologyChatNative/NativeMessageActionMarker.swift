#if DEBUG
import AppKit
import SwiftUI

/// Passive geometry for isolated action-routing checks. Never intercepts input.
struct NativeMessageActionMarker:NSViewRepresentable {
    let postID:Int64
    let kind:String
    func makeNSView(context:Context)->Marker { Marker(postID:postID,kind:kind) }
    func updateNSView(_ view:Marker,context:Context) { view.postID = postID;view.kind = kind }
    final class Marker:NSView {
        var postID:Int64
        var kind:String
        init(postID:Int64,kind:String) { self.postID = postID;self.kind = kind;super.init(frame:.zero) }
        required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point:NSPoint)->NSView? { nil }
    }
}
#endif
