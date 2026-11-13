import Foundation

extension ChatChannel {
    var canJoinUnencryptedPublic:Bool { id > 0 && type == "public" && !encrypted && is_joined == false && is_closed != true && (hide_global_at ?? 0) == 0 }
    var canLeaveNamed:Bool { id > 1 && ["public","private"].contains(type) && is_joined == true && is_closed != true && (hide_global_at ?? 0) == 0 }
}

struct ChatChannelMembershipFailure:LocalizedError {
    let uncertain:Bool
    let message:String
    var errorDescription:String? { message }
}

/// A browser-only snapshot. Never insert these posts into the active timeline or membership.
struct ChatChannelPreviewSnapshot {
    let channel:ChatChannel
    let posts:[ChatPost]
    let accountGeneration:Int
}

struct ChatChannelPreviewContent {
    static func stickerName(_ post:ChatPost) -> String? {
        guard post.type == "sticker",(post.delete_at ?? 0) == 0 else { return nil }
        let text = post.message.trimmingCharacters(in:.whitespacesAndNewlines)
        guard text.hasPrefix(":"),text.hasSuffix(":"),text.count > 2 else { return nil }
        let name = String(text.dropFirst().dropLast())
        return ChatSticker.validName(name) ? name : nil
    }
    static func poll(_ post:ChatPost) -> ChatPoll? {
        guard post.type == "vote",(post.delete_at ?? 0) == 0,let poll = post.props?.vote,poll.state != "delete" else { return nil }
        return try? poll.replacingChoices(poll.choices)
    }
}

enum ChatPreviewLinkSource { case message,card(Int) }
struct ChatPreviewLinkReview:Identifiable {
    let id = UUID()
    let snapshot:ChatChannelPreviewSnapshot
    let postID:Int64
    let destination:URL
    let source:ChatPreviewLinkSource
    let requiresConfirmation:Bool
    var flaggedByServer = false
}
enum ChatPreviewLinkOpenResult { case opened,confirmation(ChatPreviewLinkReview) }

extension ChatChannelPreviewContent {
    static func messageDestinations(_ post:ChatPost) -> Set<URL> {
        guard post.type != "system",(post.delete_at ?? 0) == 0,post.props?.encrypted != true else { return [] }
        return ChatMessageLinks.renderedDestinations(post.message)
    }
    static func containsDestination(_ destination:URL,in post:ChatPost,source:ChatPreviewLinkSource,hideCards:Bool) -> Bool {
        switch source {
        case .message:return messageDestinations(post).contains(destination)
        case .card(let index):return ChatLinkPreviewPolicy.cards(in:post,hidden:hideCards).contains { $0.index == index && $0.preview.url.flatMap(ChatMessageLinks.webURL) == destination }
        }
    }
}
