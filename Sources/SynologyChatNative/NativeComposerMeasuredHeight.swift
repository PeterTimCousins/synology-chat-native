import AppKit

/// Reads the live editor's TextKit layout. This never changes its document,
/// selection, text container width, focus, or undo history.
@MainActor enum NativeComposerMeasuredHeight {
    static func height(in view:NSTextView,scale:CGFloat)->CGFloat? {
        guard scale.isFinite,scale > 0,view.bounds.width.isFinite,view.bounds.width > 0,
              let container = view.textContainer,let layout = view.layoutManager,
              container.containerSize.width.isFinite,container.containerSize.width > 0 else { return nil }
        layout.ensureLayout(for:container)
        var bottom = layout.usedRect(for:container).maxY
        if layout.extraLineFragmentTextContainer === container { bottom = max(bottom,layout.extraLineFragmentRect.maxY) }
        if view.string.isEmpty { bottom = max(bottom,layout.defaultLineHeight(for:view.font ?? .systemFont(ofSize:14))) }
        let height = bottom+2*view.textContainerInset.height
        guard height.isFinite,height > 0 else { return nil }
        return ceil(height*scale)/scale
    }
}
