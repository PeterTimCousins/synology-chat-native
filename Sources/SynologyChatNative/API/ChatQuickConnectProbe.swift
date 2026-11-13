import Foundation

enum ChatQuickConnectProbe {
    static func run(id: String) async -> Bool {
        do {
            let resolved = try await ChatServerResolver().resolveServer(id, relayOnly: CommandLine.arguments.contains("--relay-only"))
            guard let identity = resolved.quickConnectIdentity else { return false }
            let account = try OfficialChatSessionLoader.load()
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            let network = URLSession(configuration: config, delegate: NoChatRedirects(), delegateQueue: nil)
            defer { network.invalidateAndCancel() }
            guard await ChatServerResolver.matchesIdentity(account.session.baseURL, expected: identity, network: network) else {
                print("QuickConnect does not match the currently authorized NAS. No session sent."); return false
            }
            print("QuickConnect resolved over trusted HTTPS and matched the authorized NAS identity.")
            let session = ChatSession(baseURL: resolved.baseURL, sid: account.session.sid, synoToken: account.session.synoToken, tlsServerName: resolved.tlsServerName)
            let api = try ChatAPIClient(session: session)
            try await api.discover()
            let channels = try await api.channels()
            print("Existing authorized session works through the resolved endpoint: \(channels.count) conversations.")
            if CommandLine.arguments.contains("--relay-only") {
                guard resolved.tlsServerName != nil else { return false }
                print("Native relay TLS and NAS identity verified with normal certificate-chain validation.")
            }
            if CommandLine.arguments.contains("--verify-live") {
                let live = await ChatLiveConnection(session: session, version: try await api.runtimeVersion())
                let passed = await verifyLive(live)
                guard passed else { return false }
                print("Native resolved-route WebSocket handshake and heartbeat verified.")
            }
            return true
        } catch {
            print((error as? ChatQuickConnectError)?.errorDescription ?? (error as? ChatAPIError)?.errorDescription ?? "QuickConnect probe failed; details suppressed.")
            return false
        }
    }

    @MainActor private static func verifyLive(_ live: ChatLiveConnection) async -> Bool {
        defer { live.stop() }
        var ready = false
        live.onReady = { ready = true }
        live.start()
        do {
            for _ in 0..<150 where !ready { try await Task.sleep(nanoseconds: 100_000_000) }
            guard ready else { return false }
            for _ in 0..<70 where live.receivedHeartbeatCount == 0 { try await Task.sleep(nanoseconds: 500_000_000) }
            return live.receivedHeartbeatCount > 0
        } catch { return false }
    }
}
