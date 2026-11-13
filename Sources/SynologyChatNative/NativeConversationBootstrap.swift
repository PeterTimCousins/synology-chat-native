import Foundation

/// Member names are optional startup enrichment, not an authentication gate.
/// Missing membership stays unknown rather than becoming an authoritative empty set.
@MainActor
enum NativeConversationBootstrap {
    struct Result {
        var titles: [Int64: String] = [:]
        var memberIDs: [Int64: [Int64]] = [:]
        var unavailableMemberChannelIDs: Set<Int64> = []
    }

    static func resolve(channels: [ChatChannel], names: [Int64: String], currentUserID: Int64?,
                        members: (Int64) async throws -> [Int64],
                        checkCurrent: () throws -> Void = { try Task.checkCancellation() }) async throws -> Result {
        var result = Result()
        for channel in channels where channel.defaultTitle == nil {
            try checkCurrent()
            if channel.type == "chatbot", let id = channel.creator_id, let name = names[id] {
                result.titles[channel.id] = name
                continue
            }
            do {
                let ids = try await members(channel.id)
                try checkCurrent()
                result.memberIDs[channel.id] = ids
                let others = ids.filter { $0 != currentUserID }.compactMap { names[$0] }
                result.titles[channel.id] = others.isEmpty ? "Conversation \(channel.id)" : others.joined(separator: ", ")
            } catch {
                try checkCurrent()
                guard canDeferMemberFailure(error) else { throw error }
                result.unavailableMemberChannelIDs.insert(channel.id)
                result.titles[channel.id] = "Conversation \(channel.id) (members unavailable)"
            }
        }
        try checkCurrent()
        return result
    }

    /// Session, cancellation, server incompatibility and secure transport errors
    /// must remain visible and fail startup instead of being labelled a missing name.
    static func canDeferMemberFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? ChatAPIError {
            switch error {
            case .invalidServer, .unsupportedAPI: return false
            case .server(let code): return ![105, 106, 107, 119].contains(code)
            case .http(let status): return ![401, 403].contains(status)
            case .connection: return false // The API erases underlying TLS and cancellation details.
            case .invalidResponse: return true
            }
        }
        let value = error as NSError
        if value.domain == NSURLErrorDomain {
            let fatalCodes: Set<Int> = [
                URLError.cancelled.rawValue,
                URLError.appTransportSecurityRequiresSecureConnection.rawValue,
                URLError.secureConnectionFailed.rawValue,
                URLError.serverCertificateHasBadDate.rawValue,
                URLError.serverCertificateUntrusted.rawValue,
                URLError.serverCertificateHasUnknownRoot.rawValue,
                URLError.serverCertificateNotYetValid.rawValue,
                URLError.clientCertificateRejected.rawValue,
                URLError.clientCertificateRequired.rawValue,
                URLError.userAuthenticationRequired.rawValue
            ]
            return !fatalCodes.contains(value.code)
        }
        // Decode errors and isolated channel-policy failures can be retried by
        // reconnecting; their absent member entry cannot authorize an action.
        return true
    }
}
