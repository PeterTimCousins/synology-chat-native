import Foundation

@MainActor final class ChatEmojiRecentSync {
    private let preferences: ChatEmojiPreferences
    private var read: (() async throws -> ChatEmojiRecentSettings)?
    private var write: ((ChatEmojiRecentSettings) async throws -> Void)?
    private var generation = UUID()
    private var pending: [ChatReactionKind] = []
    private(set) var needsRefresh = false
    private(set) var task: Task<Void,Never>?
    init(preferences: ChatEmojiPreferences) { self.preferences = preferences }
    func attach(_ api: ChatAPIClient?) {
        attach(read:api.map { api in { try await api.emojiRecentSettings() } },
               write:api.map { api in { try await api.applyEmojiRecentSettings($0) } })
    }
    func attach(read: (() async throws -> ChatEmojiRecentSettings)?, write: ((ChatEmojiRecentSettings) async throws -> Void)?) {
        generation = UUID();task?.cancel();task = nil;pending = [];needsRefresh = false
        self.read = read;self.write = write
        preferences.didRecord = nil;preferences.refreshRecents = nil
        preferences.setRecentSyncStatus(syncing:false,notice:nil)
        guard read != nil,write != nil else { return }
        preferences.didRecord = { [weak self] choice in self?.enqueue(choice) }
        preferences.refreshRecents = { [weak self] in self?.refresh() }
        refresh()
    }
    private func enqueue(_ choice: ChatReactionKind) {
        guard !needsRefresh else { return }
        pending.removeAll { $0 == choice };pending.append(choice)
        if pending.count > ChatEmojiPreferences.limit { pending.removeFirst(pending.count - ChatEmojiPreferences.limit) }
        start()
    }
    func refresh() {
        guard task == nil else { return }
        needsRefresh = false;start()
    }
    private func start() {
        guard task == nil,let read,let write else { return }
        let expected = generation
        preferences.setRecentSyncStatus(syncing:true,notice:nil)
        task = Task { [weak self] in
            guard let self else { return }
            @MainActor func current() throws {
                try Task.checkCancellation();guard self.generation == expected else { throw CancellationError() }
            }
            defer { if self.generation == expected { self.task = nil;self.preferences.setRecentSyncStatus(syncing:false,notice:self.preferences.recentSyncNotice) } }
            do {
                let snapshot = try await read();try current()
                self.preferences.replaceRecent(snapshot.recent,keeping:self.pending)
                while !self.pending.isEmpty {
                    let choices = self.pending;self.pending = []
                    // Read immediately before each namespace write so unrelated
                    // Chat preferences and other clients' recents are retained.
                    let fresh = try await read();try current()
                    let desired = try fresh.adding(choices)
                    try await write(desired);try current()
                    let confirmed = try await read();try current()
                    guard confirmed.names == desired.names else { throw ChatAPIError.invalidResponse }
                    self.preferences.replaceRecent(confirmed.recent,keeping:self.pending)
                }
            } catch {
                guard self.generation == expected,!Task.isCancelled else { return }
                // A failed response may still mean the write happened. Never
                // automatically replay that batch or later queued selections.
                self.pending = [];self.needsRefresh = true
                self.preferences.setRecentSyncStatus(syncing:false,notice:"Recent emoji could not sync. Your choices are saved on this Mac. Refresh to check the server list.")
            }
        }
    }
}
