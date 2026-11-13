import Foundation

/// A read-only projection of the server's reaction membership. Unknown emoji
/// identifiers remain visible; unavailable people retain their stable user ID.
struct ChatReactionDetails: Equatable {
    struct Group: Identifiable, Equatable {
        let id: String
        var userIDs: [Int64]
    }
    struct Person: Identifiable, Equatable {
        let id: Int64
        let reactionNames: [String]
    }
    let groups: [Group]
    init(_ reactions: [ChatReaction]) {
        var ordered: [Group] = []
        for reaction in reactions where !reaction.sticker_name.isEmpty {
            let index: Int
            if let found = ordered.firstIndex(where: { $0.id == reaction.sticker_name }) { index = found }
            else { index = ordered.count; ordered.append(.init(id: reaction.sticker_name, userIDs: [])) }
            for id in reaction.user_ids where id > 0 && !ordered[index].userIDs.contains(id) { ordered[index].userIDs.append(id) }
        }
        groups = ordered.filter { !$0.userIDs.isEmpty }
    }
    var reactionCount: Int { groups.reduce(0) { $0 + $1.userIDs.count } }
    func people(reaction: String? = nil) -> [Person] {
        let selected = groups.filter { reaction == nil || $0.id == reaction }
        var ids: [Int64] = []
        for group in selected { for id in group.userIDs where !ids.contains(id) { ids.append(id) } }
        return ids.map { id in .init(id: id, reactionNames: selected.filter { $0.userIDs.contains(id) }.map(\.id)) }
    }
}
