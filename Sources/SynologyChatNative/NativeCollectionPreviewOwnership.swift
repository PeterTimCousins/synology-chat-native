import Foundation

@MainActor extension NativeChatPreviewModel {
    /// A collection may refresh, change its query or disappear while another
    /// surface owns a preview. Only release its own captured source records.
    func closeCollectionPreviews(owner:UUID,changed:ChatCollectionChange? = nil) {
        if let changed,changed.accountGeneration != accountGeneration { return }
        func affected(_ post:ChatPost)->Bool {
            guard let changed else { return true }
            return changed.postID == post.id && changed.channelID == post.channel_id
        }
        if searchImageOwner == owner,changed.map({ imageGalleryContainsSource(postID:$0.postID,channelID:$0.channelID) }) ?? true { closeImageViewer() }
        if searchDocumentOwner == owner || collectionDocumentOwner == owner,let post = documentPreviewPost,affected(post) { closeDocumentPreview() }
    }
}
