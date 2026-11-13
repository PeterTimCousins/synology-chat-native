import Foundation

/// An authoritative raw read, not a model mutation. A complete recent window
/// has reached a short history page; bounded anchor windows are never complete.
struct ChatMainHistoryRefreshWindow {
    let posts:[ChatPost]
    let latest:Bool
    let complete:Bool
}

extension ChatAPIClient {
    func mainHistoryRefresh(channelID:Int64,anchorID:Int64?,context:Bool,cachedLatest:Int64?) async throws -> [ChatMainHistoryRefreshWindow] {
        guard channelID > 0,anchorID == nil || anchorID! > 0,cachedLatest == nil || cachedLatest! > 0 else { throw ChatAPIError.invalidResponse }
        var windows:[ChatMainHistoryRefreshWindow] = []
        if let anchorID {
            let posts = try await mainRefreshPage(channelID:channelID,anchor:anchorID,previous:15,next:15,maximum:31)
            windows.append(.init(posts:posts,latest:false,complete:false))
        }
        if !context || anchorID == nil {
            var recent = try await mainRefreshPage(channelID:channelID,anchor:nil,previous:30,next:0,maximum:30)
            var complete = recent.count < 30,bridgeReads = 0
            while !complete,let cachedLatest,let oldest = recent.first?.id,oldest > cachedLatest {
                guard bridgeReads < 10 else { throw ChatAPIError.invalidResponse }
                let page = try await mainRefreshPage(channelID:channelID,anchor:oldest,previous:30,next:0,maximum:31)
                complete = page.count < 30
                let earlier = ChatHistoryWindow.count(page,before:oldest)
                guard complete || earlier > 0 else { throw ChatAPIError.invalidResponse }
                let merged = ChatTimeline.merge(recent,page)
                guard complete || merged.first.map({ $0.id < oldest }) == true else { throw ChatAPIError.invalidResponse }
                recent = merged;bridgeReads += 1
            }
            // Aggregate the bridge before exposing any authoritative recent
            // result. A bad page or cap failure returns no partial refresh.
            windows.append(.init(posts:recent,latest:true,complete:complete))
        }
        return windows
    }
    private func mainRefreshPage(channelID:Int64,anchor:Int64?,previous:Int,next:Int,maximum:Int) async throws -> [ChatPost] {
        var parameters:[String:ChatParameter] = ["channel_id":.integer(channelID),"prev_count":.integer(Int64(previous)),"next_count":.integer(Int64(next))]
        if let anchor { parameters["post_id"] = .integer(anchor) }
        try Task.checkCancellation()
        let page:PostList = try await perform(requestForCall(api:"SYNO.Chat.Post",method:"list",version:5,parameters:parameters))
        try Task.checkCancellation()
        guard page.posts.count <= maximum,Set(page.posts.map(\.id)).count == page.posts.count else { throw ChatAPIError.invalidResponse }
        let posts = try ChatHistoryWindow.validated(page.posts,channelID:channelID)
        if let anchor {
            guard ChatHistoryWindow.count(posts,before:anchor) <= previous,posts.filter({ $0.id > anchor }).count <= next else { throw ChatAPIError.invalidResponse }
        }
        return posts
    }
}
