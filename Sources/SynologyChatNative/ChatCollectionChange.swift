import Foundation

struct ChatCollectionChange {
    enum State { case invalidated, updated(ChatPost), deleted }
    let accountGeneration: Int
    let channelID: Int64
    let postID: Int64
    let state: State
}
