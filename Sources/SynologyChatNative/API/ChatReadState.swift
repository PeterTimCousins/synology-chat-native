import Foundation
import OSLog

protocol ChatReadStateAPI {
    func enterChannel(_ id: Int64, connectionID: String) async throws
    func leaveChannel(connectionID: String) async throws
    func viewChannel(_ id: Int64, through timestamp: Int64, connectionID: String) async throws
}

extension ChatAPIClient: ChatReadStateAPI { }

/// Only transport failures have a retry contract here. Do not guess whether a
/// Synology server code is transient. The API's generic connection error hides
/// its underlying cause, so retries remain bounded and never alter TLS policy.
enum ChatReadReceiptRetry {
    static let defaultDelays: [TimeInterval] = [0.5, 1.5, 3]
    static func bounded(_ delays: [TimeInterval]) -> [TimeInterval] {
        Array(delays.prefix(3)).filter { $0.isFinite && $0 >= 0 && $0 <= 30 }
    }
    static func sleep(_ delay: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
    static func isTransient(_ error: Error) -> Bool {
        if case ChatAPIError.connection = error { return true }
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else { return false }
        return [URLError.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable].contains { $0.rawValue == value.code }
    }
    static func log(_ error: Error, thread: Bool = false) {
        let code: Int
        if case ChatAPIError.server(let value) = error { code = value }
        else if case ChatAPIError.http(let value) = error { code = value }
        else { code = -1 }
        Logger(subsystem: "com.costwisegroup.synology-chat-native.api-preview", category: "native-read")
            .error("Read request failed thread=\(thread, privacy: .public), code: \(code, privacy: .public)")
    }
}

/// Serialize presence changes so a delayed leave cannot undo a newer enter.
@MainActor
final class ChatReadState {
    struct Target: Equatable {
        let channelID: Int64
        let timestamp: Int64
    }
    private let api: any ChatReadStateAPI
    private let connectionID: String
    private let retryDelays: [TimeInterval]
    private let retrySleep: (TimeInterval) async throws -> Void
    private var desired: Target?
    private var desiredRevision = UUID()
    private var entered: Int64?
    private var cursors: [Int64: Int64] = [:]
    private var task: Task<Void, Never>?
    private var retryWait: Task<Void, Error>?
    private var stopped = false
    private var blocked = false
    var onRead: ((Int64) -> Void)?

    init(api: any ChatReadStateAPI, connectionID: String,
         retryDelays: [TimeInterval] = ChatReadReceiptRetry.defaultDelays,
         retrySleep: @escaping (TimeInterval) async throws -> Void = ChatReadReceiptRetry.sleep) {
        self.api = api; self.connectionID = connectionID
        self.retryDelays = ChatReadReceiptRetry.bounded(retryDelays); self.retrySleep = retrySleep
    }
    func stop() {
        stopped = true; desired = nil
        retryWait?.cancel(); retryWait = nil; task?.cancel(); task = nil
    }

    func update(_ target: Target?) {
        guard !stopped else { return }
        if desired != target {
            // Cancel only the backoff. In-flight enter/leave requests still
            // settle serially before this worker moves to the latest target.
            desiredRevision = UUID(); retryWait?.cancel(); blocked = false
        }
        desired = target
        guard task == nil, !blocked else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            var retryRevision: UUID?, retries = 0
            while !Task.isCancelled, !self.stopped {
                let next = self.desired, revision = self.desiredRevision
                if retryRevision != revision { retryRevision = revision; retries = 0 }
                do {
                    if self.entered != next?.channelID {
                        if self.entered != nil {
                            try await self.api.leaveChannel(connectionID: self.connectionID)
                            self.entered = nil
                            try Task.checkCancellation()
                            continue
                        }
                        if let next {
                            try await self.api.enterChannel(next.channelID, connectionID: self.connectionID)
                            self.entered = next.channelID
                            try Task.checkCancellation()
                            continue
                        }
                    }
                } catch {
                    if Task.isCancelled || self.stopped || error is CancellationError { return }
                    ChatReadReceiptRetry.log(error)
                    if self.desiredRevision != revision { continue }
                    // Presence transitions are not automatically replayed.
                    self.blocked = true; return
                }
                guard let next, next.timestamp > (self.cursors[next.channelID] ?? 0) else { return }
                do {
                    try await self.api.viewChannel(next.channelID, through: next.timestamp, connectionID: self.connectionID)
                    try Task.checkCancellation()
                    self.cursors[next.channelID] = next.timestamp
                    self.onRead?(next.channelID)
                    retries = 0
                } catch {
                    if Task.isCancelled || self.stopped || error is CancellationError { return }
                    ChatReadReceiptRetry.log(error)
                    if self.desiredRevision != revision { continue }
                    guard ChatReadReceiptRetry.isTransient(error), retries < self.retryDelays.count else {
                        // Same-target visibility notifications cannot create an
                        // endless retry loop. A target change or reconnect can.
                        self.blocked = true; return
                    }
                    let delay = self.retryDelays[retries]; retries += 1
                    do { try await self.pauseBeforeRetry(delay) }
                    catch {
                        if Task.isCancelled || self.stopped { return }
                        if self.desiredRevision != revision { continue }
                        self.blocked = true; return
                    }
                }
            }
        }
    }
    private func pauseBeforeRetry(_ delay: TimeInterval) async throws {
        let wait = Task { try await retrySleep(delay) }
        retryWait = wait
        defer { retryWait = nil }
        try await wait.value
    }
}

protocol ChatThreadReadStateAPI {
    func viewThread(channelID: Int64, rootID: Int64) async throws
}
extension ChatAPIClient: ChatThreadReadStateAPI { }

/// Thread receipts use a separate server endpoint. Wait for a stable visible
/// bottom before writing, and never carry a receipt into a newly opened thread.
@MainActor
final class ChatThreadReadState {
    struct Target: Equatable {
        let channelID: Int64
        let rootID: Int64
        let lastPostID: Int64
    }
    private let api: any ChatThreadReadStateAPI
    private let retryDelays: [TimeInterval]
    private let retrySleep: (TimeInterval) async throws -> Void
    private var desired: Target?
    private var desiredRevision = UUID()
    private var viewed: [Int64: Int64] = [:]
    private var task: Task<Void, Never>?
    private var retryWait: Task<Void, Error>?
    private var stopped = false
    private var blocked = false
    var onRead: ((Int64) -> Void)?
    init(api: any ChatThreadReadStateAPI,
         retryDelays: [TimeInterval] = ChatReadReceiptRetry.defaultDelays,
         retrySleep: @escaping (TimeInterval) async throws -> Void = ChatReadReceiptRetry.sleep) {
        self.api = api; self.retryDelays = ChatReadReceiptRetry.bounded(retryDelays); self.retrySleep = retrySleep
    }
    func stop() {
        stopped = true; desired = nil
        retryWait?.cancel(); retryWait = nil; task?.cancel(); task = nil
    }
    func update(_ target: Target?) {
        guard !stopped else { return }
        if desired != target { desiredRevision = UUID(); retryWait?.cancel(); blocked = false }
        desired = target
        guard task == nil, !blocked else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            var retryRevision: UUID?, retries = 0
            while !Task.isCancelled, !self.stopped, let next = self.desired {
                let revision = self.desiredRevision
                if retryRevision != revision { retryRevision = revision; retries = 0 }
                if next.lastPostID <= (self.viewed[next.rootID] ?? 0) { return }
                do { try await Task.sleep(nanoseconds: 150_000_000) }
                catch { return }
                guard self.desiredRevision == revision else { continue }
                do {
                    try Task.checkCancellation()
                    try await self.api.viewThread(channelID: next.channelID, rootID: next.rootID)
                    try Task.checkCancellation()
                    self.viewed[next.rootID] = next.lastPostID
                    self.onRead?(next.channelID)
                    retries = 0
                } catch {
                    if Task.isCancelled || self.stopped || error is CancellationError { return }
                    ChatReadReceiptRetry.log(error, thread: true)
                    if self.desiredRevision != revision { continue }
                    guard ChatReadReceiptRetry.isTransient(error), retries < self.retryDelays.count else {
                        self.blocked = true; return
                    }
                    let delay = self.retryDelays[retries]; retries += 1
                    do { try await self.pauseBeforeRetry(delay) }
                    catch {
                        if Task.isCancelled || self.stopped { return }
                        if self.desiredRevision != revision { continue }
                        self.blocked = true; return
                    }
                }
            }
        }
    }
    private func pauseBeforeRetry(_ delay: TimeInterval) async throws {
        let wait = Task { try await retrySleep(delay) }
        retryWait = wait
        defer { retryWait = nil }
        try await wait.value
    }
}
