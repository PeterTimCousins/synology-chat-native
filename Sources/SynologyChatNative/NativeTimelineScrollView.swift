import AppKit

final class NativeTimelineScrollView:NSScrollView {
    var input:(()->Void)?
    /// Optional ownership around size mutation. The main-only table leaves
    /// this nil; virtual readers use it to distinguish native clamping from input.
    var viewportResize:((Bool)->Void)?
    private var viewportResizeDepth = 0
    private func beginViewportResize(_ changes:Bool) {
        guard changes else { return }
        if viewportResizeDepth == 0 { viewportResize?(true) }
        viewportResizeDepth += 1
    }
    private func endViewportResize(_ changes:Bool) {
        guard changes else { return }
        viewportResizeDepth -= 1
        if viewportResizeDepth == 0 { viewportResize?(false) }
    }
    override var frame:NSRect {
        get { super.frame }
        set {
            let changes = super.frame.size != newValue.size
            beginViewportResize(changes);super.frame = newValue;endViewportResize(changes)
        }
    }
    override func setFrameSize(_ newSize:NSSize) {
        let changes = frame.size != newSize
        beginViewportResize(changes);super.setFrameSize(newSize);endViewportResize(changes)
    }
    override var acceptsFirstResponder:Bool { true }
    override func scrollWheel(with event:NSEvent) { input?();super.scrollWheel(with:event) }
    override func keyDown(with event:NSEvent) {
        if handleNavigation(event) { return }
        super.keyDown(with:event)
    }
    /// The table has no selected rows. Its default selection-based key
    /// handling cannot page this reader, so own vertical reading commands.
    /// Editing and modified shortcuts continue through their responder.
    @discardableResult func handleNavigation(_ event:NSEvent)->Bool {
        guard event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty,
              let document = documentView else { return false }
        let visible = documentVisibleRect,content = document.bounds
        let line = max(1,verticalLineScroll),page = max(line,visible.height-verticalPageScroll)
        let minimum = content.minY,maximum = max(minimum,content.maxY-visible.height)
        let target:CGFloat
        switch event.keyCode {
        case 115:target = minimum
        case 119:target = maximum
        case 116:target = visible.minY-page
        case 121:target = visible.minY+page
        case 126:target = visible.minY-line
        case 125:target = visible.minY+line
        default:return false
        }
        input?()
        contentView.scroll(to:NSPoint(x:visible.minX,y:min(maximum,max(minimum,target))))
        reflectScrolledClipView(contentView)
        return true
    }
}
