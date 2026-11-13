import Foundation
import CommonCrypto

/// Temporary development bridge. Reads the session the user already established in the official app.
/// This deliberately does not become the production sign-in mechanism or persist a second credential copy.
enum OfficialChatSessionLoader {
    private struct Payload: Decodable {
        let ip: String
        let isHTTPS: Bool
        let sid: String?
        let synotoken: String?
        let username: String
    }
    typealias Imported = ChatAccount
    enum ImportError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "Open the official Synology Chat app, sign in with automatic sign-in enabled, then connect again."
        }
    }

    static func load(from file: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/synochat-client/db")) throws -> Imported {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { throw ImportError.unavailable }
        // NeDB appends replacements and deletion markers by _id. Reconstruct live
        // records before selecting a session, so a deleted/retyped record cannot
        // resurrect an older credential. Never fall back after a corrupt record.
        var records: [String: (position: Int, value: [String: Any])] = [:]
        for (position, line) in text.split(separator: "\n").enumerated() {
            guard let data = String(line).data(using: .utf8),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw ImportError.unavailable
            }
            guard let id = record["_id"] as? String, !id.isEmpty else {
                if record["type"] as? String == "session" { throw ImportError.unavailable }
                continue // NeDB index metadata has no document ID.
            }
            if record["$$deleted"] as? Bool == true { records[id] = nil }
            else { records[id] = (position, record) }
        }
        let decoder = JSONDecoder()
        let latest = records.values.filter { $0.value["type"] as? String == "session" }
            .max { $0.position < $1.position }
        guard let encoded = latest?.value["data"] as? String,
              let bytes = Data(base64Encoded: encoded), bytes.count > 48 else {
            throw ImportError.unavailable
        }
        // Desktop app's own storage format: key(32), IV(16), AES-256-CBC ciphertext with PKCS7.
        let key = Array(bytes.prefix(32)), iv = Array(bytes.dropFirst(32).prefix(16)), ciphertext = Array(bytes.dropFirst(48))
        var cleartext = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var written = 0
        let result = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, ciphertext, ciphertext.count, &cleartext, cleartext.count, &written)
        defer { _ = cleartext.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard result == kCCSuccess,
              let payload = try? decoder.decode(Payload.self, from: Data(cleartext.prefix(written))),
              let sid = payload.sid, let token = payload.synotoken,
              !sid.isEmpty, !token.isEmpty else { throw ImportError.unavailable }
        let address = payload.ip.contains("://") ? payload.ip : (payload.isHTTPS ? "https://" : "http://") + payload.ip
        guard var components = URLComponents(string: address), components.scheme == "https",
              components.host != nil, components.user == nil, components.password == nil else { throw ChatAPIError.invalidServer }
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw ChatAPIError.invalidServer }
        return Imported(session: ChatSession(baseURL: url, sid: sid, synoToken: token), username: payload.username, importedFromOfficialApp: true)
    }
}
