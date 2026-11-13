import Foundation

enum ChatImageHistoryDirection { case around, older, newer }

struct ChatLibraryImagePage {
    let posts: [ChatPost]
    let hasMore: Bool
    let cursor: Int
}

/// Anchor-inclusive image-only Post/list pages, as used by PhotoViewer.Message.
struct ChatImageHistoryPage {
    let posts: [ChatPost]
    let hasOlder: Bool
    let hasNewer: Bool
    init(posts: [ChatPost], channelID: Int64, anchorID: Int64, threadID: Int64?, direction: ChatImageHistoryDirection) throws {
        guard posts.count <= 101, posts.contains(where: { $0.id == anchorID }),
              Set(posts.map(\.id)).count == posts.count,
              posts.allSatisfy({ post in
                  post.id > 0 && post.channel_id == channelID && post.type == "file" && post.file_props?.is_image == true
                    && (post.delete_at ?? 0) == 0 && (threadID.map { post.thread_id == $0 && post.id != $0 } ?? !post.isReply)
              }) else { throw ChatAPIError.invalidResponse }
        let older = posts.filter { $0.id < anchorID }.count, newer = posts.filter { $0.id > anchorID }.count
        guard older <= (direction == .newer ? 0 : 50), newer <= (direction == .older ? 0 : 50) else { throw ChatAPIError.invalidResponse }
        self.posts = posts.sorted { $0.id < $1.id }
        hasOlder = older == 50;hasNewer = newer == 50
    }
}
