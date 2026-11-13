import CryptoKit
import Foundation

enum ChatNotificationAccountScope {
    static func make(account: ChatAccount, userID: Int64?) -> String? {
        guard let userID, userID > 0, var url = URLComponents(url: account.session.baseURL, resolvingAgainstBaseURL: false),
              url.scheme == "https", let host = url.host else { return nil }
        url.host = host.lowercased(); url.query = nil; url.fragment = nil; url.user = nil; url.password = nil
        if url.port == 443 { url.port = nil }
        while url.path.hasSuffix("/") { url.path.removeLast() }
        guard let origin = url.string else { return nil }
        // The pinned NAS identity survives QuickConnect endpoint changes and SID rotation.
        let server = account.serverIdentity.flatMap { $0.isEmpty ? nil : "nas:" + $0 } ?? "url:" + origin
        guard let bytes = try? JSONEncoder().encode([server, String(userID)]) else { return nil }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func isValid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Cold launches may queue a click before saved authentication finishes. Explicit sign-out cannot.
struct ChatNotificationRouting {
    private(set) var activeScope: String?
    private var pending: ChatNotificationDestination?
    private var acceptsBeforeAuthentication = true

    mutating func receive(_ destination: ChatNotificationDestination) -> Bool {
        guard activeScope.map({ $0 == destination.accountScope }) ?? acceptsBeforeAuthentication else { return false }
        pending = destination
        return true
    }
    mutating func activate(scope: String?) {
        activeScope = scope
        acceptsBeforeAuthentication = false
        if pending?.accountScope != scope { pending = nil }
    }
    mutating func signOut() {
        activeScope = nil; pending = nil; acceptsBeforeAuthentication = false
    }
    mutating func takePending() -> ChatNotificationDestination? {
        guard let scope = activeScope, pending?.accountScope == scope else { return nil }
        defer { pending = nil }
        return pending
    }
}

struct ChatNotificationDeliverySession {
    struct Ticket: Equatable {
        let scope: String
        let epoch: UUID
        let postID: Int64
        var identifier: String { "native-api:\(scope):\(epoch.uuidString):\(postID)" }
    }
    private(set) var scope: String?
    private(set) var epoch = UUID()
    private var rememberedScope: String?
    private var delivered: Set<Int64> = []
    private var order: [Int64] = []
    private var pending: Set<Int64> = []

    mutating func activate(scope: String?) {
        if scope != rememberedScope { delivered = []; order = [] }
        rememberedScope = scope
        self.scope = scope; epoch = UUID(); pending = []
    }
    mutating func suspend() { scope = nil; epoch = UUID(); pending = [] }
    mutating func reset() { suspend(); rememberedScope = nil; delivered = []; order = [] }
    mutating func reserve(postID: Int64) -> Ticket? {
        guard let scope, !delivered.contains(postID), pending.insert(postID).inserted else { return nil }
        return Ticket(scope: scope, epoch: epoch, postID: postID)
    }
    func isCurrent(_ ticket: Ticket) -> Bool { ticket.scope == scope && ticket.epoch == epoch }
    func canPresent(userInfo: [AnyHashable: Any]) -> Bool {
        guard let scope, userInfo["nativeAccountScope"] as? String == scope,
              let rawEpoch = userInfo["nativeDeliveryEpoch"] as? String else { return false }
        return UUID(uuidString: rawEpoch) == epoch
    }
    mutating func complete(_ ticket: Ticket) -> Bool {
        guard isCurrent(ticket), pending.remove(ticket.postID) != nil else { return false }
        delivered.insert(ticket.postID); order.append(ticket.postID)
        if order.count > 512 { delivered.remove(order.removeFirst()) }
        return true
    }
    mutating func fail(_ ticket: Ticket) {
        if isCurrent(ticket) { pending.remove(ticket.postID) }
    }
    func belongsToCurrentEpoch(identifier: String) -> Bool {
        guard let scope else { return false }
        return identifier.hasPrefix("native-api:\(scope):\(epoch.uuidString):")
    }
    func shouldRemove(identifier: String, userInfo: [AnyHashable: Any], keepSameAccount: Bool) -> Bool {
        guard identifier.hasPrefix("native-api:"), !belongsToCurrentEpoch(identifier: identifier) else { return false }
        if keepSameAccount, let scope, userInfo["nativeAccountScope"] as? String == scope { return false }
        return true
    }
}
