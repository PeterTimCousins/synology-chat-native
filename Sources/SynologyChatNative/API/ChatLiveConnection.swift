import Foundation
import OSLog

/// A lossless JSON value for protocol metadata, including 64-bit post identifiers.
enum ChatJSON: Codable, Equatable {
    case object([String: ChatJSON]), array([ChatJSON]), string(String), integer(Int64), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Int64.self) { self = .integer(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([ChatJSON].self) { self = .array(value) }
        else { self = .object(try c.decode([String: ChatJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(key: String) -> ChatJSON? { if case .object(let v) = self { return v[key] }; return nil }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var integer: Int64? { if case .integer(let v) = self { return v }; return nil }
}

struct ChatLiveEvent: Equatable {
    let name: String
    let payload: ChatJSON
    var normalized: ChatLiveEvent {
        if name == "client.broadcast", let type = payload["type"]?.string, let data = payload["data"] {
            return ChatLiveEvent(name: "client." + type, payload: data)
        }
        return self
    }
    var channelID: Int64? { payload["channel_id"]?.integer ?? payload["data"]?["channel_id"]?.integer ?? payload["channel"]?["channel_id"]?.integer }
    var postID: Int64? { payload["post_id"]?.integer ?? payload["data"]?["post_id"]?.integer }
}

enum ChatSocketFrame: Equatable {
    case open(pingInterval: Int64, pingTimeout: Int64)
    case connected, closed, pong, ping(String), event(ChatLiveEvent), rejected, ignored

    static func parse(_ packet: String) throws -> ChatSocketFrame {
        if packet.first == "0" {
            struct Hello: Decodable { let pingInterval: Int64; let pingTimeout: Int64 }
            let hello = try JSONDecoder().decode(Hello.self, from: Data(packet.dropFirst().utf8))
            guard (1_000...300_000).contains(hello.pingInterval), (1_000...300_000).contains(hello.pingTimeout) else {
                throw ChatAPIError.invalidResponse
            }
            return .open(pingInterval: hello.pingInterval, pingTimeout: hello.pingTimeout)
        }
        if packet == "1" || packet == "41" { return .closed }
        if packet == "40" { return .connected }
        if packet.first == "2" { return .ping(String(packet.dropFirst())) }
        if packet.first == "3" { return .pong }
        if packet.hasPrefix("44") { return .rejected }
        if packet.hasPrefix("42[") {
            let values = try JSONDecoder().decode([ChatJSON].self, from: Data(packet.dropFirst(2).utf8))
            guard let name = values.first?.string else { throw ChatAPIError.invalidResponse }
            return .event(ChatLiveEvent(name: name, payload: values.count > 1 ? values[1] : .null))
        }
        return .ignored
    }
}

enum ChatLiveStatus: Equatable {
    case connecting, live, reconnecting, offline, rejected
    var title: String {
        title(language:.system)
    }
    func title(language:NativeInterfaceLanguage,bundle:Bundle? = nil)->String {
        let key:String
        switch self {
        case .connecting: key = "Connecting live updates…"
        case .live: key = "Live"
        case .reconnecting: key = "Reconnecting · messages may be out of date"
        case .offline: key = "Offline · refresh to check for new messages"
        case .rejected: key = "Live updates were rejected · reconnect or sign in again"
        }
        return NativeLocalizedStrings.text(key,language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle)
    }
}

/// Engine.IO v3 / Socket.IO v4, as used by the installed server. No web renderer required.
@MainActor
final class ChatLiveConnection {
    private let credentials: ChatSession
    private let version: String
    private let network: URLSession
    private var runTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var userActive = false
    private let presenceLog = Logger(subsystem: "com.costwisegroup.synology-chat-native", category: "native-presence")
    private var sentUserActive: Bool?
    private var socket: (any ChatSocketTransport)?
    private let makeSocket: ((URLRequest) -> any ChatSocketTransport)?
    private let retryDelay: (Int) -> TimeInterval
    private var receivedPong = true
    private var epoch = 0
    private var systemSleeping = false
    private var wantsConnection = false
    private var sleepMonitor: ChatSystemSleepMonitor?
    private(set) var connectionID: String?
    private(set) var receivedHeartbeatCount = 0
    var onStatus: ((ChatLiveStatus) -> Void)?
    var onReady: (() -> Void)?
    var onEvent: ((ChatLiveEvent) -> Void)?

    init(session: ChatSession, version: String,
         makeSocket: ((URLRequest) -> any ChatSocketTransport)? = nil,
         sleepNotifications: NotificationCenter? = nil,
         retryDelay: @escaping (Int) -> TimeInterval = { attempt in
             min(30.0, pow(2.0, Double(min(attempt, 5))) * Double.random(in: 0.75...1.25))
         }) {
        credentials = session
        self.version = version
        self.makeSocket = makeSocket
        self.retryDelay = retryDelay
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        network = URLSession(configuration: config, delegate: NoChatRedirects(tlsIdentity: session.tlsIdentity), delegateQueue: nil)
        if let sleepNotifications {
            sleepMonitor = ChatSystemSleepMonitor(center: sleepNotifications,
                willSleep: { [weak self] in self?.systemWillSleep() }, didWake: { [weak self] in self?.systemDidWake() })
        }
    }

    deinit {
        runTask?.cancel()
        heartbeatTask?.cancel()
        activityTask?.cancel()
        network.invalidateAndCancel()
    }

    nonisolated static func request(session: ChatSession, version: String) throws -> URLRequest {
        guard session.baseURL.scheme == "https", let host = session.baseURL.host,
              session.baseURL.user == nil, session.baseURL.password == nil, session.hasValidTLSIdentity else { throw ChatAPIError.invalidServer }
        var url = URLComponents(url: session.baseURL, resolvingAgainstBaseURL: false)!
        url.scheme = "wss"
        var path = url.path
        if path.hasSuffix("/") { path.removeLast() }
        url.path = path + "/sc/socket.io/"
        url.fragment = nil
        url.queryItems = [URLQueryItem(name: "EIO", value: "3"), URLQueryItem(name: "transport", value: "websocket"),
                          URLQueryItem(name: "SynoToken", value: session.synoToken), URLQueryItem(name: "client", value: "browser"),
                          URLQueryItem(name: "version_ui", value: version)]
        guard let endpoint = url.url, !session.sid.isEmpty, session.sid.unicodeScalars.allSatisfy({
            (0x21...0x7E).contains($0.value) && ![0x22, 0x2C, 0x3B, 0x5C].contains($0.value)
        }) else {
            throw ChatAPIError.invalidServer
        }
        var request = URLRequest(url: endpoint)
        request.setValue("id=" + session.sid, forHTTPHeaderField: "Cookie")
        var origin = URLComponents()
        origin.scheme = "https"; origin.host = host; origin.port = session.baseURL.port
        request.setValue(origin.url!.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        return request
    }

    func start() {
        stop()
        wantsConnection = true
        guard !systemSleeping else { return }
        let expected = epoch
        runTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self, self.epoch == expected else { return }
                self.onStatus?(attempt == 0 ? .connecting : .reconnecting)
                do {
                    let request = try Self.request(session: self.credentials, version: self.version)
                    let ws = self.makeSocket?(request) ?? ChatURLSessionSocket(socket: self.network.webSocketTask(with: request))
                    self.socket = ws
                    self.connectionID = nil
                    ws.resume()
                    // A silent handshake must not leave the interface permanently "connecting".
                    let deadline = Task { [weak self, weak ws] in
                        try? await Task.sleep(nanoseconds: 20_000_000_000)
                        guard !Task.isCancelled, let self, self.epoch == expected, self.connectionID == nil else { return }
                        ws?.cancel()
                    }
                    defer { deadline.cancel() }
                    for try await message in ws.messages {
                        guard self.epoch == expected, !Task.isCancelled else { return }
                        let text: String
                        switch message {
                        case .string(let value): text = value
                        case .data(let data):
                            guard let value = String(data: data, encoding: .utf8) else { throw ChatAPIError.invalidResponse }
                            text = value
                        @unknown default: continue
                        }
                        switch try ChatSocketFrame.parse(text) {
                        case .open(let interval, let timeout): self.startHeartbeat(ws, interval: interval, timeout: timeout)
                        case .event(let event):
                            if event.name == "client.init" {
                                guard let id = event.payload["id"]?.string, !id.isEmpty else { throw ChatAPIError.invalidResponse }
                                try await ws.send(.string("42[\"client.initdone\"]"))
                                guard self.epoch == expected, !Task.isCancelled else { return }
                                self.connectionID = id
                                attempt = 0
                                self.sentUserActive = nil
                                self.syncUserActivity()
                                self.onStatus?(.live)
                                self.onReady?()
                            } else { self.onEvent?(event) }
                        case .pong:
                            self.receivedPong = true
                            self.receivedHeartbeatCount += 1
                        case .ping(let payload): try await ws.send(.string("3" + payload))
                        case .rejected:
                            self.stop()
                            self.onStatus?(.rejected)
                            return
                        case .closed: throw ChatAPIError.connection
                        case .connected, .ignored: break
                        }
                    }
                } catch { /* Never publish raw networking errors: they may contain session-bearing URLs. */ }
                guard self.epoch == expected else { return }
                self.heartbeatTask?.cancel()
                self.activityTask?.cancel(); self.activityTask = nil
                self.socket?.cancel()
                self.socket = nil
                self.connectionID = nil
                guard !Task.isCancelled, self.epoch == expected else { return }
                attempt += 1
                self.onStatus?(.reconnecting)
                let delay = self.retryDelay(attempt)
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
            }
        }
    }

    func stop() {
        wantsConnection = false
        epoch += 1
        runTask?.cancel(); runTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        activityTask?.cancel(); activityTask = nil
        sentUserActive = nil
        socket?.cancel(); socket = nil
        connectionID = nil
        onStatus?(.offline)
    }

    private func systemWillSleep() {
        guard !systemSleeping else { return }
        systemSleeping = true
        let resumeAfterWake = wantsConnection
        stop()
        wantsConnection = resumeAfterWake
    }

    private func systemDidWake() {
        guard systemSleeping else { return }
        systemSleeping = false
        if wantsConnection { start() }
    }

    /// Match the official client's foreground/background events without marking messages read.
    func setUserActive(_ active: Bool) {
        userActive = active
        syncUserActivity()
    }

    private func syncUserActivity() {
        guard activityTask == nil, connectionID != nil, let ws = socket else { return }
        let expected = epoch
        activityTask = Task { [weak self, weak ws] in
            guard let self, let ws else { return }
            // Automatic retries share a run epoch, so task ownership must also
            // match the socket. A cancelled send may return after its replacement.
            defer { if self.epoch == expected, self.socket === ws { self.activityTask = nil } }
            do {
                while !Task.isCancelled, self.epoch == expected, self.socket === ws, self.connectionID != nil,
                      self.sentUserActive != self.userActive {
                    let active = self.userActive
                    let event = active ? "client.user.activate" : "client.user.deactivate"
                    try await ws.send(.string("42[\"\(event)\"]"))
                    guard !Task.isCancelled, self.epoch == expected, self.socket === ws else { return }
                    self.sentUserActive = active
                    self.presenceLog.notice("Presence frame sent active=\(active, privacy: .public)")
                }
            } catch { if self.epoch == expected, self.socket === ws { ws.cancel() } }
        }
    }

    #if DEBUG
    /// Development probe: exercise the real reconnect loop without changing server or network settings.
    func interruptTransportForProbe() { socket?.cancel() }
    #endif

    private func startHeartbeat(_ ws: any ChatSocketTransport, interval: Int64, timeout: Int64) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self, weak ws] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
                    guard let self, let ws else { return }
                    self.receivedPong = false
                    try await ws.send(.string("2"))
                    let deadline = Date().addingTimeInterval(Double(timeout) / 1_000)
                    while !self.receivedPong {
                        try await Task.sleep(nanoseconds: 500_000_000)
                        guard Date() < deadline else { throw ChatAPIError.connection }
                    }
                }
            } catch {
                if !Task.isCancelled { ws?.cancel() }
            }
        }
    }
}
