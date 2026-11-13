import Foundation

/// Presentation only: never merge post identities, action state or read receipts.
/// The caller supplies the calendar used by its visible date labels.
enum NativeTimelineGrouping {
    static func isContinuation(_ post: ChatPost, after previous: ChatPost?, calendar: Calendar) -> Bool {
        guard let previous, previous.id != post.id,
              eligible(previous), eligible(post),
              previous.displayAuthorID == post.displayAuthorID,
              previous.channel_id == post.channel_id,
              threadContext(previous) == threadContext(post) else { return false }
        let interval = post.create_at - previous.create_at
        return interval >= 0 && interval <= 5 * 60 * 1_000 && calendar.isDate(previous.date, inSameDayAs: post.date)
    }

    private static func threadContext(_ post: ChatPost) -> Int64? { post.isReply ? post.thread_id : nil }

    private static func eligible(_ post: ChatPost) -> Bool {
        guard post.id > 0, post.channel_id > 0, post.displayAuthorID > 0,
              post.create_at.isFinite, post.create_at > 0,
              (post.delete_at ?? 0) == 0,
              post.type == "normal" || post.type == "file",
              post.system_props == nil, post.props?.forward == nil,
              post.props?.vote == nil, post.props?.encrypted != true,
              post.props?.attachments?.isEmpty != false,
              post.url_props?.isEmpty != false,
              post.file_props?.is_snippet != true else { return false }
        if post.type == "normal" && post.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if post.type == "file" && post.file_props == nil { return false }
        // Rich quote/code/list blocks retain a fresh author heading so their
        // separate block structure does not appear to belong to the prior post.
        return ChatMessageFormatting.blocks(post.message).allSatisfy { $0.kind == .paragraph }
    }
}
