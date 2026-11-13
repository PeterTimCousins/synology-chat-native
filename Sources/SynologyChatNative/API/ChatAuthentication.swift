import Foundation
import Security

struct ChatAccount: Codable {
    let session: ChatSession
    let username: String
    let importedFromOfficialApp: Bool
    let connectionAddress: String?
    let serverIdentity: String?
    init(session: ChatSession, username: String, importedFromOfficialApp: Bool,
         connectionAddress: String? = nil, serverIdentity: String? = nil) {
        self.session = session; self.username = username; self.importedFromOfficialApp = importedFromOfficialApp
        self.connectionAddress = connectionAddress; self.serverIdentity = serverIdentity
    }
}

/// The desktop client's guest checkbox selects the same Auth v6 route with a
/// guest_ account name. Keep that canonical identity in saved sessions too, so
/// directory lookup and account-scoped local state use the authenticated user.
struct ChatSignInIdentity: Equatable {
    let address: String
    let username: String
    let asGuest: Bool
    var canonicalUsername: String {
        guard asGuest else { return username }
        if username.lowercased().hasPrefix("guest_") { return "guest_" + username.dropFirst(6) }
        return "guest_" + username
    }
}

/// A verification code belongs to the exact form identity which requested it.
/// Changing server, username or login mode must not reuse the pending code.
struct ChatSignInChallenge {
    let identity: ChatSignInIdentity
    func verificationCode(_ value: String, for current: ChatSignInIdentity) -> String {
        current == identity ? value : ""
    }
}

enum ChatSignInError: LocalizedError {
    case invalidAddress, credentials, otpRequired, otpInvalid, rejected(Int), response, connection, storage, sessionRequired
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return NativeLocalizedStrings.text("Enter a direct HTTPS server address, including its port, or a QuickConnect ID.")
        case .credentials: return NativeLocalizedStrings.text("The username or password was not accepted.")
        case .otpRequired: return NativeLocalizedStrings.text("Enter your verification code to finish signing in.")
        case .otpInvalid: return NativeLocalizedStrings.text("The verification code was not accepted. Enter a current code and try again.")
        case .rejected(let code): return NativeLocalizedStrings.integer("Sign-in was rejected by the server (%lld).",Int64(code))
        case .response: return NativeLocalizedStrings.text("The server returned an unexpected sign-in response.")
        case .connection: return NativeLocalizedStrings.text("Could not connect securely to the server. Check the address and certificate.")
        case .storage: return NativeLocalizedStrings.text("Could not save this sign-in in macOS Keychain.")
        case .sessionRequired: return NativeLocalizedStrings.text("Sign in to Synology Chat to connect.")
        }
    }
}

/// Production connections use only the native client's own account. The explicit
/// development import path must never become a fallback for a release build.
enum ChatConnectionAccount {
    static func select(supplied: ChatAccount?, current: ChatAccount?, allowOfficialImport: Bool,
                       loadOfficial: () throws -> ChatAccount = { try OfficialChatSessionLoader.load() }) throws -> ChatAccount {
        if let account = supplied ?? current {
            guard allowOfficialImport || !account.importedFromOfficialApp else { throw ChatSignInError.sessionRequired }
            return account
        }
        guard allowOfficialImport else { throw ChatSignInError.sessionRequired }
        return try loadOfficial()
    }
}

final class ChatAuthentication {
    private let network: URLSession
    init(network: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        self.network = network ?? URLSession(configuration: config, delegate: NoChatRedirects(), delegateQueue: nil)
    }
    deinit { network.invalidateAndCancel() }

    static func serverURL(_ address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var url = URLComponents(string: input), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, !host.hasSuffix("quickconnect.to"), !host.hasSuffix("quickconnect.cn"), host.contains(".") || host.contains(":") || host == "localhost" else {
            throw ChatSignInError.invalidAddress
        }
        url.query = nil; url.fragment = nil
        if url.path.hasSuffix(".cgi") || url.path.hasSuffix(".html") { throw ChatSignInError.invalidAddress }
        guard let result = url.url else { throw ChatSignInError.invalidAddress }
        return result
    }

    func signIn(address: String, username: String, password: String, otp: String, asGuest: Bool = false) async throws -> ChatAccount {
        let identity = ChatSignInIdentity(address: address, username: username, asGuest: asGuest)
        let quick = try ChatQuickConnectAddress.parse(address)
        let resolved = try await ChatServerResolver(network: network).resolveServer(address)
        try Task.checkCancellation()
        let baseURL = resolved.baseURL
        let loginNetwork = resolved.tlsServerName.map { name in
            URLSession(configuration: network.configuration,
                delegate: NoChatRedirects(tlsIdentity: ChatTLSIdentity(origin: baseURL, serverName: name)), delegateQueue: nil)
        } ?? network
        defer { if loginNetwork !== network { loginNetwork.invalidateAndCancel() } }
        // Auth metadata does not request JSON parameter encoding. Use its discovered path, not a fixed DSM path.
        var discovery = URLRequest(url: baseURL.appendingPathComponent("webapi/query.cgi/SYNO.API.Info"))
        discovery.httpMethod = "POST"
        discovery.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        discovery.httpBody = ChatAPIClient.formEncode(["api": "SYNO.API.Info", "method": "query", "version": "1", "query": "SYNO.API.Auth"]).data(using: .utf8)
        struct Discovery: Decodable { let success: Bool; let data: [String: ChatAPIEndpoint]? }
        let info: Discovery = try await request(discovery, using: loginNetwork)
        guard info.success, let endpoint = info.data?["SYNO.API.Auth"], endpoint.minVersion <= 6, endpoint.maxVersion >= 6,
              !endpoint.path.contains("/"), !endpoint.path.contains(".."), !endpoint.path.contains("?"), !endpoint.path.contains("#") else {
            throw ChatSignInError.response
        }
        var url = URLComponents(url: baseURL.appendingPathComponent("webapi/" + endpoint.path + "/SYNO.API.Auth"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "enable_syno_token", value: "yes")]
        var login = URLRequest(url: url.url!)
        login.httpMethod = "POST"
        login.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var fields = ["api": "SYNO.API.Auth", "method": "login", "version": "6", "account": identity.canonicalUsername,
                      "passwd": password, "format": "sid", "session": "chat", "enable_syno_token": "yes"]
        if !otp.isEmpty { fields["otp_code"] = otp }
        login.httpBody = ChatAPIClient.formEncode(fields).data(using: .utf8)
        struct Login: Decodable {
            struct Payload: Decodable { let sid: String; let synotoken: String? }
            struct Failure: Decodable { let code: Int }
            let success: Bool; let data: Payload?; let error: Failure?
        }
        let result: Login = try await request(login, using: loginNetwork)
        guard result.success else {
            switch result.error?.code {
            case 400, 401: throw ChatSignInError.credentials
            case 403: throw ChatSignInError.otpRequired
            case 404: throw ChatSignInError.otpInvalid
            default: throw ChatSignInError.rejected(result.error?.code ?? -1)
            }
        }
        guard let payload = result.data, !payload.sid.isEmpty, let token = payload.synotoken, !token.isEmpty, token != "--------" else {
            throw ChatSignInError.response
        }
        return ChatAccount(session: ChatSession(baseURL: baseURL, sid: payload.sid, synoToken: token, tlsServerName: resolved.tlsServerName), username: identity.canonicalUsername,
                           importedFromOfficialApp: false, connectionAddress: quick?.id, serverIdentity: resolved.quickConnectIdentity)
    }

    private func request<T: Decodable>(_ request: URLRequest, using network: URLSession) async throws -> T {
        try Task.checkCancellation()
        let data: Data; let response: URLResponse
        do { (data, response) = try await network.data(for: request) }
        catch { throw ChatSignInError.connection }
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatSignInError.response }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ChatSignInError.response }
    }
}

/// Optional, explicit "Keep me signed in" persistence. Passwords and OTPs are never stored.
enum ChatAccountKeychain {
    static func serviceName(for bundleID: String?) -> String {
        let base = "com.costwisegroup.synology-chat-native.session"
        switch bundleID {
        case "com.costwisegroup.synology-chat-native.api": return base // Preserve existing normal-app sessions.
        case "com.costwisegroup.synology-chat-native.api-preview": return base + ".preview"
        case "com.costwisegroup.synology-chat-native": return base + ".wrapper-preview"
        default: return base + ".development"
        }
    }
    private static let service = serviceName(for: Bundle.main.bundleIdentifier)
    // Security.framework may wait for a protected macOS authorization dialog.
    // Keep that wait off the UI thread and serialize reads, writes and removals.
    private static let queue = DispatchQueue(label: "com.costwisegroup.synology-chat-native.keychain")

    private static func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }

    static func loadAsync() async throws -> ChatAccount? { try await perform { try load() } }
    static func saveAsync(_ account: ChatAccount) async throws { try await perform { try save(account) } }
    static func removeAsync() async throws { try await perform { try remove() } }
    static func removeAsync(ifMatching account: ChatAccount) async throws {
        try await perform { try remove(ifMatching: account) }
    }
    static func save(_ account: ChatAccount) throws {
        let data = try JSONEncoder().encode(account)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: "current"]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw ChatSignInError.storage }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ChatSignInError.storage }
    }
    static func load() throws -> ChatAccount? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: "current",
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ChatSignInError.storage }
        return try JSONDecoder().decode(ChatAccount.self, from: data)
    }
    static func remove() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: "current"]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ChatSignInError.storage }
    }

    static func remove(ifMatching account: ChatAccount) throws {
        guard let saved = try load(), matchesSession(saved, account) else { return }
        try remove()
    }

    static func matchesSession(_ saved: ChatAccount, _ account: ChatAccount) -> Bool {
        guard saved.session.sid == account.session.sid else { return false }
        if saved.session.baseURL == account.session.baseURL { return true }
        // QuickConnect can select a different trusted endpoint on each restore.
        guard let savedIdentity = saved.serverIdentity, !savedIdentity.isEmpty,
              savedIdentity == account.serverIdentity,
              let savedID = saved.connectionAddress, !savedID.isEmpty,
              let currentID = account.connectionAddress else { return false }
        return savedID.caseInsensitiveCompare(currentID) == .orderedSame
    }
}

/// Apply the user's current persistence choice before publishing the new sign-in.
/// An unchecked choice must not leave an older account queued for the next launch.
enum ChatSavedSignInPreference {
    static func apply(account: ChatAccount, remember: Bool,
                      save: (ChatAccount) async throws -> Void = { try await ChatAccountKeychain.saveAsync($0) },
                      remove: () async throws -> Void = { try await ChatAccountKeychain.removeAsync() }) async -> String? {
        do {
            if remember { try await save(account) }
            else { try await remove() }
            return nil
        } catch {
            return remember
                ? "Signed in, but the session could not be saved to Keychain. You may need to sign in again next time."
                : "Signed in, but the previous saved sign-in could not be removed from Keychain. Remove it from the sign-in window before quitting to prevent it restoring next time."
        }
    }
}
