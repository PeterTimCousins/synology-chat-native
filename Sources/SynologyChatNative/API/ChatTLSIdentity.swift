import Foundation
import Security

/// A QuickConnect relay transports TLS to a NAS whose certificate names the NAS,
/// not the relay IP. Keep that authenticated DNS identity separate from routing.
/// System roots, certificate validity and SSL hostname validation still apply.
struct ChatTLSIdentity {
    let origin: URL
    let serverName: String

    init?(origin: URL, serverName: String) {
        guard origin.scheme == "https", origin.host != nil, origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil,
              serverName.count <= 253,
              serverName.range(of: "^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+[A-Za-z](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$", options: .regularExpression) != nil else { return nil }
        self.origin = origin
        self.serverName = serverName.lowercased()
    }

    func matches(host: String, port: Int) -> Bool {
        host.lowercased() == origin.host?.lowercased() && port == (origin.port ?? 443)
    }

    func evaluate(_ trust: SecTrust, host: String, port: Int) -> Bool {
        guard matches(host: host, port: port) else { return false }
        let policy = SecPolicyCreateSSL(true, serverName as CFString)
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}
