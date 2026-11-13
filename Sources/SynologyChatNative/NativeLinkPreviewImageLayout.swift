import Foundation

/// Metadata can reserve the same bounded footprint used after image decoding.
/// Missing/untrusted dimensions do not create a permanent empty image area.
enum NativeLinkPreviewImageLayout {
    static func reservedSize(image:String?,metadata:CGSize?)->CGSize? {
        guard hasImage(image),let metadata else { return nil }
        return fit(metadata)
    }

    static func displaySize(image:String?,metadata:CGSize?,loaded:CGSize)->CGSize? {
        guard hasImage(image) else { return nil }
        if let reserved = reservedSize(image:image,metadata:metadata) { return reserved }
        return fit(loaded)
    }

    /// Fit decoded pixels inside the stable slot without enlarging them when
    /// server metadata has a different size or aspect ratio.
    static func renderedSize(loaded:CGSize,slot:CGSize)->CGSize? {
        guard let bounded = fit(loaded),slot.width.isFinite,slot.height.isFinite,
              slot.width > 0,slot.height > 0 else { return nil }
        let scale = min(1,min(slot.width/bounded.width,slot.height/bounded.height))
        let size = CGSize(width:bounded.width*scale,height:bounded.height*scale)
        guard size.width > 0,size.height > 0 else { return nil }
        return size
    }

    private static func hasImage(_ value:String?)->Bool {
        guard let value,!value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return false }
        return ChatMessageLinks.webURL(value) != nil
    }
    private static func fit(_ source:CGSize)->CGSize? {
        guard source.width.isFinite,source.height.isFinite,source.width > 0,source.height > 0 else { return nil }
        let scale = min(1,min(372/source.width,220/source.height))
        // Clamp floating-point rounding at the existing display caps. Reject
        // aspect-ratio underflow rather than constructing a zero-sized slot.
        let width = min(372,source.width*scale),height = min(220,source.height*scale)
        guard width.isFinite,height.isFinite,width > 0,height > 0 else { return nil }
        return CGSize(width:width,height:height)
    }
}
