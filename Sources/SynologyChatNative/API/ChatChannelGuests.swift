import Foundation

/// Opening the inventory is read-only; changes use separate guarded operations.
struct ChatChannelGuest: Codable, Equatable, Identifiable {
    let guest_id: Int64
    let expire_at: Int64
    let status: String
    let user_id: Int64
    let email: String
    var id: Int64 { guest_id }
    var expiration: Date? { expire_at == 0 ? nil : Date(timeIntervalSince1970: Double(expire_at)) }
    var statusLabel: String {
        if user_id > 0 { return "Registered" }
        return status == "uninvited" ? "Awaiting registration" : "Registration status unavailable"
    }
}

struct ChatGuestPolicy: Decodable { let allow_guest: Bool }

struct ChatChannelGuestList: Decodable {
    let guests: [ChatChannelGuest]
    func validated() throws -> [ChatChannelGuest] {
        guard guests.count <= 10_000, Set(guests.map(\.id)).count == guests.count,
              guests.allSatisfy({ $0.id > 0 && $0.user_id >= 0 && $0.expire_at >= 0 &&
                  $0.expire_at <= 253_402_300_799 && !$0.email.isEmpty && $0.email.utf8.count <= 4096 && $0.status.utf8.count <= 256 })
        else { throw ChatAPIError.invalidResponse }
        return guests
    }
}

struct ChatChannelGuestsSnapshot {
    let channel: ChatChannel
    let policy: ChatGuestPolicy
    let guests: [ChatChannelGuest]
    let accountGeneration: Int
}

extension ChatChannel {
    var supportsGuestBrowser: Bool {
        id > 2 && type == "private" && !encrypted && is_joined == true &&
        is_closed != true && (hide_global_at ?? 0) == 0
    }
}
