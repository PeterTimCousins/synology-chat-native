import Foundation
import Combine

/// Local to a verified NAS/account scope. Stores catalogue identifiers only.
/// The official recent queue keeps 24 exact variants. The sync coordinator
/// replaces this local cache from the account's NAS application preferences.
@MainActor final class ChatEmojiPreferences: ObservableObject {
    static let limit = 24
    @Published private(set) var recent: [ChatReactionKind] = []
    @Published private(set) var skinTone = 0
    @Published private(set) var recentSyncing = false
    @Published private(set) var recentSyncNotice: String?
    var didRecord: ((ChatReactionKind) -> Void)?
    var refreshRecents: (() -> Void)?
    private var scope: String?
    private let defaults: UserDefaults?
    private var memory: [String: Data] = [:]
    private struct Record: Codable { var version: Int; var recent: [String]; var tone: Int }
    init(defaults: UserDefaults? = nil) { self.defaults = defaults }
    static func standard() -> ChatEmojiPreferences { .init(defaults: .standard) }
    static func key(_ scope: String) -> String { "nativeEmojiPreferences." + scope }
    func activate(scope: String?) {
        self.scope = scope.flatMap { value in
            ChatNotificationAccountScope.isValid(value) ? value : nil
        }
        recent = []; skinTone = 0
        guard let scope = self.scope,
              let data = defaults?.data(forKey: Self.key(scope)) ?? memory[scope], data.count <= 4096,
              let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1 else { return }
        var seen = Set<String>()
        recent = Array(record.recent.compactMap { name -> ChatReactionKind? in
            guard let kind = ChatReactionKind(rawValue: name), seen.insert(name).inserted else { return nil }
            return kind
        }.prefix(Self.limit))
        skinTone = (0...5).contains(record.tone) ? record.tone : 0
    }
    func record(_ kind: ChatReactionKind) {
        guard scope != nil, let validated = ChatReactionKind(rawValue: kind.rawValue) else { return }
        recent.removeAll { $0.rawValue == validated.rawValue }
        recent.insert(validated, at: 0)
        recent = Array(recent.prefix(Self.limit)); persist();didRecord?(validated)
    }
    func replaceRecent(_ values:[ChatReactionKind],keeping choices:[ChatReactionKind] = []) {
        guard scope != nil else { return }
        var seen = Set<String>();recent = Array(values.filter{seen.insert($0.rawValue).inserted}.prefix(Self.limit))
        for choice in choices { recent.removeAll{$0 == choice};recent.insert(choice,at:0) }
        recent = Array(recent.prefix(Self.limit));persist()
    }
    func setRecentSyncStatus(syncing:Bool,notice:String?) { recentSyncing = syncing;recentSyncNotice = notice }
    func setSkinTone(_ value: Int) {
        guard scope != nil, (0...5).contains(value), value != skinTone else { return }
        skinTone = value; persist()
    }
    private func persist() {
        guard let scope, let data = try? JSONEncoder().encode(Record(version: 1, recent: recent.map(\.rawValue), tone: skinTone)) else { return }
        if let defaults { defaults.set(data, forKey: Self.key(scope)) } else { memory[scope] = data }
    }
}
