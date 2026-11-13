import CryptoKit
import Foundation

enum ChatQuickConnectError: LocalizedError {
    case invalidID, discovery, trustedConnection
    var errorDescription: String? {
        switch self {
        case .invalidID: return NativeLocalizedStrings.text("Enter a valid QuickConnect ID or a direct HTTPS server address.")
        case .discovery: return NativeLocalizedStrings.text("QuickConnect could not find this NAS. Check the ID and try again.")
        case .trustedConnection: return NativeLocalizedStrings.text("QuickConnect found the NAS, but could not establish a trusted HTTPS connection. Try its direct HTTPS address.")
        }
    }
}

struct ChatQuickConnectAddress: Equatable {
    let id: String
    let discoveryHost: String
    static func parse(_ input: String) throws -> Self? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let validID: (String) -> Bool = { $0.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil }
        if !text.contains("://"), validID(text), text.lowercased() != "localhost" {
            return .init(id: text, discoveryHost: "global.quickconnect.to")
        }
        let candidate = text.contains("://") ? text : "https://" + text
        guard let url = URLComponents(string: candidate), let host = url.host?.lowercased() else { return nil }
        let isRoot = host == "quickconnect.to" || host == "quickconnect.cn"
        let isSubdomain = host.hasSuffix(".quickconnect.to") || host.hasSuffix(".quickconnect.cn")
        guard isRoot || isSubdomain else { return nil }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
              url.port == nil else { throw ChatQuickConnectError.invalidID }
        let pieces = url.path.split(separator: "/")
        let id = isRoot ? pieces.first.map(String.init) : host.split(separator: ".").first.map(String.init)
        guard let id, validID(id), isRoot ? pieces.count == 1 : pieces.isEmpty,
              isRoot || host.split(separator: ".").count == 3 else { throw ChatQuickConnectError.invalidID }
        return .init(id: id, discoveryHost: host.hasSuffix(".cn") ? "global.quickconnect.cn" : "global.quickconnect.to")
    }
}

struct ChatQuickConnectInfo: Decodable {
    struct Server: Decodable {
        struct External: Decodable { let ip: String? }
        struct Interface: Decodable { let ip: String? }
        let serverID: String
        let ddns: String?
        let fqdn: String?
        let external: External?
        let interface: [Interface]?
    }
    struct Service: Decodable { let port: Int; let ext_port: Int?; let relay_ip: String?; let relay_port: Int? }
    struct Environment: Decodable { let control_host: String? }
    struct SmartDNS: Decodable { let host: String?; let external: String?; let lan: [String]?; let hole_punch: String? }
    let errno: Int
    let sites: [String]?
    let server: Server?
    let service: Service?
    let smartdns: SmartDNS?
    let env: Environment?
}

struct ChatResolvedServer {
    let baseURL: URL
    let quickConnectIdentity: String?
    let tlsServerName: String?
    init(baseURL: URL, quickConnectIdentity: String?, tlsServerName: String? = nil) {
        self.baseURL = baseURL; self.quickConnectIdentity = quickConnectIdentity; self.tlsServerName = tlsServerName
    }
}

/// QuickConnect discovery contains no account credentials. A candidate must pass
/// normal TLS validation and the NAS identity check before it can receive a login.
final class ChatServerResolver {
    private let network: URLSession
    private let ownsNetwork: Bool
    init(network: URLSession? = nil) {
        ownsNetwork = network == nil
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 20
        self.network = network ?? URLSession(configuration: config, delegate: NoChatRedirects(), delegateQueue: nil)
    }
    deinit { if ownsNetwork { network.invalidateAndCancel() } }

    func resolve(_ address: String) async throws -> URL { try await resolveServer(address).baseURL }

    func resolveServer(_ address: String, expectedIdentity: String? = nil, relayOnly: Bool = false) async throws -> ChatResolvedServer {
        guard let quick = try ChatQuickConnectAddress.parse(address) else {
            return .init(baseURL: try ChatAuthentication.serverURL(address), quickConnectIdentity: nil)
        }
        var info = try await discover(quick, host: quick.discoveryHost)
        var controlHost = quick.discoveryHost
        if info.errno != 0 {
            var found: ChatQuickConnectInfo?
            for site in (info.sites ?? []).prefix(4) where Self.isControlHost(site) {
                if let regional = try? await discover(quick, host: site), regional.errno == 0 { found = regional; controlHost = site; break }
            }
            guard let found else { throw ChatQuickConnectError.discovery }
            info = found
        }
        guard let server = info.server, !server.serverID.isEmpty else { throw ChatQuickConnectError.discovery }
        let expected = Self.legacyIdentity(server.serverID)
        guard expectedIdentity == nil || expectedIdentity == expected else { throw ChatQuickConnectError.trustedConnection }
        if let host = info.env?.control_host, Self.isControlHost(host) { controlHost = host }
        let candidates = relayOnly ? [] : Self.candidates(info)
        let network = network
        let selected = await withTaskGroup(of: URL?.self, returning: URL?.self) { group in
            for candidate in candidates.prefix(8) {
                group.addTask {
                    await Self.matchesIdentity(candidate, expected: expected, network: network) ? candidate : nil
                }
            }
            for await candidate in group {
                if let candidate { group.cancelAll(); return candidate }
            }
            return nil
        }
        try Task.checkCancellation()
        if let selected { return .init(baseURL: selected, quickConnectIdentity: expected) }
        let tunnel = try await discover(quick, host: controlHost, command: "request_tunnel")
        try Task.checkCancellation()
        guard tunnel.errno == 0, tunnel.server?.serverID == server.serverID,
              let host = tunnel.service?.relay_ip, host.range(of: "^[A-Za-z0-9.:-]+$", options: .regularExpression) != nil,
              let port = tunnel.service?.relay_port, (1...65535).contains(port) else { throw ChatQuickConnectError.trustedConnection }
        var parts = URLComponents(); parts.scheme = "https"; parts.host = host; parts.port = port
        guard let endpoint = parts.url else { throw ChatQuickConnectError.trustedConnection }
        // Use only names advertised by the initial trusted discovery, never a name
        // supplied by an unauthenticated relay or a certificate's own subject.
        for name in [server.ddns, server.fqdn].compactMap({ $0 }) {
            guard let identity = ChatTLSIdentity(origin: endpoint, serverName: name) else { continue }
            let config = network.configuration
            config.httpShouldSetCookies = false; config.urlCache = nil
            let relayNetwork = URLSession(configuration: config, delegate: NoChatRedirects(tlsIdentity: identity), delegateQueue: nil)
            let matches = await Self.matchesIdentity(endpoint, expected: expected, network: relayNetwork)
            relayNetwork.invalidateAndCancel()
            try Task.checkCancellation()
            if matches { return .init(baseURL: endpoint, quickConnectIdentity: expected, tlsServerName: name) }
        }
        throw ChatQuickConnectError.trustedConnection
    }

    private func discover(_ quick: ChatQuickConnectAddress, host: String, command: String = "get_server_info") async throws -> ChatQuickConnectInfo {
        try Task.checkCancellation()
        guard Self.isControlHost(host), let url = URL(string: "https://\(host)/Serv.php") else { throw ChatQuickConnectError.discovery }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["version": 1, "command": command, "serverID": quick.id,
                                                                       "id": "dsm_portal_https", "get_ca_fingerprints": true])
        do {
            let (data, response) = try await network.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatQuickConnectError.discovery }
            return try JSONDecoder().decode(ChatQuickConnectInfo.self, from: data)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ChatQuickConnectError.discovery
        }
    }

    static func isControlHost(_ host: String) -> Bool {
        host.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.quickconnect\\.(?:to|cn)$", options: .regularExpression) != nil
    }

    static func candidates(_ info: ChatQuickConnectInfo) -> [URL] {
        guard let server = info.server, let service = info.service else { return [] }
        let externalPort = (service.ext_port ?? 0) > 0 ? service.ext_port! : service.port
        var hosts: [(String?, Int)] = [(server.ddns, externalPort), (server.fqdn, externalPort),
            (info.smartdns?.host, externalPort), (info.smartdns?.external, externalPort), (server.external?.ip, externalPort)]
        hosts += (info.smartdns?.lan ?? []).map { ($0, externalPort) }
        hosts += (server.interface ?? []).map { ($0.ip, service.port) }
        var seen: Set<URL> = []
        return hosts.compactMap { host, port in
            guard let host, host != "NULL", !host.isEmpty, (1...65535).contains(port),
                  host.range(of: "^[A-Za-z0-9.:-]+$", options: .regularExpression) != nil else { return nil }
            var parts = URLComponents(); parts.scheme = "https"; parts.host = host; parts.port = port
            guard let url = parts.url, seen.insert(url).inserted else { return nil }
            return url
        }
    }

    static func legacyIdentity(_ serverID: String) -> String {
        // Compatibility checksum used by Synology's connector, not a password hash or TLS substitute.
        Insecure.MD5.hash(data: Data(serverID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func matchesIdentity(_ candidate: URL, expected: String, network: URLSession) async -> Bool {
        struct Ping: Decodable { let success: Bool; let ezid: String? }
        var parts = URLComponents(url: candidate.appendingPathComponent("webman/pingpong.cgi"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "quickconnect", value: "true")]
        var request = URLRequest(url: parts.url!); request.timeoutInterval = 6
        do {
            let (data, response) = try await network.data(for: request)
            guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            let ping = try JSONDecoder().decode(Ping.self, from: data)
            return ping.success && ping.ezid?.lowercased() == expected
        } catch { return false }
    }
}
