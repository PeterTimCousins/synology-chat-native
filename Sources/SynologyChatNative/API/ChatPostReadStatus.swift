import Foundation

struct ChatPostReadStatus: Decodable {
    let read_users: [Int64]
    let unread_users: [Int64]
    func validate() throws {
        guard read_users.count + unread_users.count <= 10000,
              (read_users + unread_users).allSatisfy({ $0 > 0 }),
              Set(read_users).isDisjoint(with:unread_users) else { throw ChatAPIError.invalidResponse }
    }
    var readIDs:[Int64] { Array(Set(read_users)).sorted() }
    var unreadIDs:[Int64] { Array(Set(unread_users)).sorted() }
}
