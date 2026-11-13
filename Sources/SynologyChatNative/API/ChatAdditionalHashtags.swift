import Foundation

struct ChatAdditionalHashtag: Decodable, Equatable, Identifiable {
    let hashtag: String
    let user_id: Int64?
    var id: String { hashtag }
}
struct ChatPostHashtagSnapshot {
    let post: ChatPost
    let accountGeneration: Int
    // The NAS hashtags array is the complete index, including added tags.
    var indexed: [String] { post.hashtags ?? [] }
    var otherIndexed: [String] { indexed.filter { name in !additional.contains { $0.hashtag == name } } }
    var additional: [ChatAdditionalHashtag] { post.hashtags_additional ?? [] }
}
