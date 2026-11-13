import Foundation

enum ChatPinSort: String, CaseIterable, Identifiable {
    case pinned = "last_pin_at", activity = "last_comment_at", message = "create_at"
    var id: String { rawValue }
    var title: String {
        switch self { case .pinned: return "Pin time"; case .activity: return "Latest reply"; case .message: return "Message time" }
    }
    private func time(_ post: ChatPost) -> Double {
        let value: Double
        switch self { case .pinned: value = post.last_pin_at ?? 0; case .activity: value = post.last_comment_at ?? 0; case .message: value = post.create_at }
        return value.isFinite ? value : 0
    }
    func ordered(_ posts: [ChatPost]) -> [ChatPost] {
        // Post/search may apply last_comment_at ordering without returning that
        // usable field (including a zero placeholder). Keep pagination order
        // instead of guessing from post IDs.
        if self == .activity, posts.contains(where: { $0.last_comment_at.map { !$0.isFinite || $0 <= 0 } ?? true }) {
            return posts.filter { $0.is_sticky == true } + posts.filter { $0.is_sticky != true }
        }
        return posts.sorted(by: precedes)
    }
    func precedes(_ left: ChatPost, _ right: ChatPost) -> Bool {
        if (left.is_sticky == true) != (right.is_sticky == true) { return left.is_sticky == true }
        let a = time(left), b = time(right)
        return a == b ? left.id > right.id : a > b
    }
}
