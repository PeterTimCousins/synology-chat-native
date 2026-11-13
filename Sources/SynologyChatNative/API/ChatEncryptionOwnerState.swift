import Foundation

/// Strict management eligibility, separate from the tolerant display decoder.
/// An absent/null field is unknown; only two explicit empty strings mean that
/// initial setup cannot overwrite an existing key.
struct ChatEncryptionOwnerState: Equatable {
    let userID: Int64
    let pair: ChatEncryptionKeyPair
    var isInitialized: Bool { pair.isInitialized }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.userID == rhs.userID && lhs.pair.public_key.utf8.elementsEqual(rhs.pair.public_key.utf8)
            && lhs.pair.private_key_enc.utf8.elementsEqual(rhs.pair.private_key_enc.utf8)
    }
}

extension ChatAPIClient {
    /// The recovered official consumer uses User/list v2 plus its verified own
    /// user ID. No User/get contract or mutation is assumed here.
    func encryptionOwnerState(userID: Int64) async throws -> ChatEncryptionOwnerState {
        guard userID > 0 else { throw ChatAPIError.invalidResponse }
        let request = try requestForCall(api: "SYNO.Chat.User", method: "list", version: 2, parameters: [:])
        let list: EncryptionOwnerList = try await perform(request)
        return try Self.ownerState(list,userID:userID)
    }
    /// Decode strict owner fields and participant display/key fields from the
    /// same response, so final preflight cannot discard newer recipient data.
    func encryptionConversationDirectory(ownerID:Int64) async throws -> (owner:ChatEncryptionOwnerState,users:[ChatUser]) {
        guard ownerID > 0 else { throw ChatAPIError.invalidResponse }
        let request = try requestForCall(api:"SYNO.Chat.User",method:"list",version:2,parameters:[:])
        let directory:EncryptionConversationDirectory = try await perform(request)
        return (try Self.ownerState(directory.strict,userID:ownerID),directory.users)
    }
    private static func ownerState(_ list:EncryptionOwnerList,userID:Int64) throws -> ChatEncryptionOwnerState {
        let ids = list.users.map(\.userID)
        guard ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count,
              let own = list.users.first(where: { $0.userID == userID }), let fields = own.fields else {
            throw ChatAPIError.invalidResponse
        }
        let publicKey = fields.publicKey, privateKey = fields.privateKey
        if publicKey.isEmpty && privateKey.isEmpty {
            return ChatEncryptionOwnerState(userID: userID, pair: .init(public_key: "", private_key_enc: ""))
        }
        guard !publicKey.isEmpty, !privateKey.isEmpty,
              publicKey.utf8.count <= 256, privateKey.utf8.count <= 1024 else { throw ChatAPIError.invalidResponse }
        do {
            let publicBytes = try ChatContentCrypto.decodeBase64(publicKey)
            let wrappedBytes = try ChatContentCrypto.decodeBase64(privateKey)
            // Vendor private plaintext is the 44-byte Base64 encoding of its
            // 32-byte secret; secretbox adds a 24-byte nonce and 16-byte MAC.
            guard publicBytes.count == 32, wrappedBytes.count == 84 else { throw ChatAPIError.invalidResponse }
        } catch { throw ChatAPIError.invalidResponse }
        return ChatEncryptionOwnerState(userID: userID,
            pair: .init(public_key: publicKey, private_key_enc: privateKey))
    }
}

private struct EncryptionConversationDirectory:Decodable {
    let strict:EncryptionOwnerList
    let users:[ChatUser]
    private enum CodingKeys:String,CodingKey { case users }
    init(from decoder:Decoder) throws {
        strict = try EncryptionOwnerList(from:decoder)
        users = try decoder.container(keyedBy:CodingKeys.self).decode([ChatUser].self,forKey:.users)
    }
}

private struct EncryptionOwnerList: Decodable {
    let users: [EncryptionOwnerEntry]
}
private struct EncryptionOwnerEntry: Decodable {
    let userID: Int64
    let fields: EncryptionOwnerFields?
    private enum CodingKeys: String, CodingKey { case userID = "user_id" }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = try container.decode(Int64.self, forKey: .userID)
        // Peers may legitimately publish public keys only. Only the selected
        // owner needs the strict nested management fields to be present.
        fields = try? EncryptionOwnerFields(from: decoder)
    }
}
private struct EncryptionOwnerFields: Decodable {
    let publicKey: String
    let privateKey: String
    private enum UserKeys: String, CodingKey { case userProps = "user_props" }
    private enum PropertyKeys: String, CodingKey { case keyPair = "key_pair" }
    private enum PairKeys: String, CodingKey { case publicKey = "public_key", privateKey = "private_key_enc" }
    init(from decoder: Decoder) throws {
        let user = try decoder.container(keyedBy: UserKeys.self)
        let properties = try user.nestedContainer(keyedBy: PropertyKeys.self, forKey: .userProps)
        let pair = try properties.nestedContainer(keyedBy: PairKeys.self, forKey: .keyPair)
        publicKey = try pair.decode(String.self, forKey: .publicKey)
        privateKey = try pair.decode(String.self, forKey: .privateKey)
    }
}
