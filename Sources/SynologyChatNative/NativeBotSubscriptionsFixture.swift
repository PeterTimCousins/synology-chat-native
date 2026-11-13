#if DEBUG
import AppKit
import SwiftUI

@MainActor enum NativeBotSubscriptionsFixture {
    private static var controller: SubscriptionFixtureController?
    static func present() {
        guard NativeChatAppConfiguration.standalone, NativeChatAppConfiguration.allowsOfficialSessionImport else { return }
        controller?.close()
        NativeBotSubscriptionFixtureProtocol.reset(); NativeBotSubscriptionFixtureProtocol.hasChannel = false
        Task { @MainActor in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-bot-subscription-ui-" + UUID().uuidString)
            let model = NativeChatPreviewModel(restoreNotificationPreference: false, makeClient: { session in
                let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [NativeBotSubscriptionFixtureProtocol.self]
                return try ChatAPIClient(session: session, network: URLSession(configuration: c))
            }, botSubscriptionJournal: .init(directory: folder))
            await model.connect(using: .init(session: .init(baseURL: URL(string: "https://bot-subscriptions.invalid")!, sid: "synthetic", synoToken: "synthetic"), username: "synthetic", importedFromOfficialApp: false))
            guard model.connected else { NSSound.beep(); return }; model.liveStatus = .live
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 850), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Synthetic bot subscriptions — local responses only"; window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SubscriptionFixtureView(model: model))
            window.center(); controller = SubscriptionFixtureController(window: window, model: model, folder: folder)
            controller?.showWindow(nil); window.makeKeyAndOrderFront(nil)
        }
    }
}
@MainActor private final class SubscriptionFixtureController: NSWindowController, NSWindowDelegate {
    let model: NativeChatPreviewModel
    let folder: URL
    init(window: NSWindow, model: NativeChatPreviewModel, folder: URL) { self.model = model; self.folder = folder; super.init(window: window); window.delegate = self }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { model.signOutLocally(); try? FileManager.default.removeItem(at: folder) }
}
private struct SubscriptionFixtureView: View {
    @ObservedObject var model: NativeChatPreviewModel
    @State private var revision = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Local bot subscription fixture").font(.headline)
                    Text("No NAS connection, real account, socket, posts or callback. Local mutations: \(NativeBotSubscriptionFixtureProtocol.mutations.count)").font(.caption)
                    Text("Fixture revisions: \(revision)").font(.caption)
                }
                Spacer()
                Button("Lose next response") { NativeBotSubscriptionFixtureProtocol.loseReply = true; revision += 1 }
            }.padding(12).background(Color.orange.opacity(0.15))
            NativeChatPreviewView(model: model)
        }.frame(width: 1120, height: 850).nativeChatAppearance()
            .onChange(of: model.botBrowserBusy) { if !$0 { revision += 1 } }
    }
}

final class NativeBotSubscriptionFixtureProtocol: URLProtocol, @unchecked Sendable {
    static var hasChannel = true, blocked = false, hidden = false, disabled = false, deleted = false, malformedProps = false, duplicateChannel = false
    static var loseReply = false, ignoreMutation = false, holdReply = false
    static var name = "Calendar", kind = "chatbot", responseType = "chatbot"
    static var botMembers: [Int64] = [10], blockedOverride: [Int64]?
    static var mutations: [[String: String]] = [], postCreates = 0
    static var held: (NativeBotSubscriptionFixtureProtocol, [String: Any])?, onHeld: (() -> Void)?
    static func reset() { hasChannel = true; blocked = false; hidden = false; disabled = false; deleted = false; malformedProps = false; duplicateChannel = false; loseReply = false; ignoreMutation = false; holdReply = false; name = "Calendar"; kind = "chatbot"; responseType = "chatbot"; botMembers = [10]; blockedOverride = nil; mutations = []; postCreates = 0; held = nil; onHeld = nil }
    static var human: [String: Any] { ["user_id": 10, "username": "synthetic", "nickname": "Peter", "type": "human", "human_type": "dsm"] }
    static var bot: [String: Any] {
        let props: [String: Any] = malformedProps ? ["purpose": "Missing privacy field"] : ["hide_from_user": hidden, "purpose": "Synthetic calendar bot", "welcome_note": "Welcome"]
        return ["user_id": 16, "nickname": name, "type": "bot", "bot_type": kind, "is_disabled": disabled, "deleted": deleted, "chatbot_props": props]
    }
    static var channel: [String: Any] { ["channel_id": 46, "name": "", "type": "chatbot", "creator_id": 16, "encrypted": false, "unread": 0, "is_joined": !blocked, "hide_global_at": 0] }
    static var humanChannels: [[String: Any]] { [93, 94].map { ["channel_id": $0, "name": "Synthetic human chat \($0)", "type": "anonymous", "encrypted": false, "unread": 0, "is_joined": true] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "bot-subscriptions.invalid" else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let api = request.url!.lastPathComponent
        if api == "SYNO.API.Info" { finish(Dictionary(uniqueKeysWithValues: ["SYNO.Chat.User", "SYNO.Chat.Channel", "SYNO.Chat.Channel.Member", "SYNO.Chat.Channel.Chatbot", "SYNO.Chat.Post"].map { ($0, ["path": "entry.cgi", "minVersion": 1, "maxVersion": 5, "requestFormat": "JSON"] as [String: Any]) })); return }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var b = [UInt8](repeating: 0, count: 2048); while stream.hasBytesAvailable { let n = stream.read(&b, maxLength: b.count); if n <= 0 { break }; data.append(contentsOf: b.prefix(n)) } }
        var query = URLComponents(); query.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        let f = Dictionary((query.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last }), method = f["method"] ?? ""
        if api == "SYNO.Chat.User" { finish(["users": [Self.human, Self.bot]]); return }
        if api == "SYNO.Chat.Channel" {
            if method != "list" { finish([:]); return }
            var bots = Self.hasChannel && (f["is_joined"] == "false") == Self.blocked ? [Self.channel] : []
            if Self.duplicateChannel && !bots.isEmpty { var duplicate = Self.channel; duplicate["channel_id"] = 47; bots.append(duplicate) }
            finish(["channels": (f["is_joined"] == "false" ? [] : Self.humanChannels) + bots]); return
        }
        if api == "SYNO.Chat.Channel.Member" { finish(["user_ids": f["channel_id"] == "46" ? Self.botMembers : [10, 6]]); return }
        if api == "SYNO.Chat.Post" { if method == "create" { Self.postCreates += 1 }; finish(["posts": []]); return }
        guard api == "SYNO.Chat.Channel.Chatbot" else { finish([:]); return }
        if method == "list_blocked" { finish(["blocked_user_ids": Self.blockedOverride ?? (Self.blocked ? [16] : [])]); return }
        Self.mutations.append(f)
        if !Self.ignoreMutation { if method == "initiate" { Self.hasChannel = true; Self.blocked = false } else if method == "block" { Self.blocked = true } }
        var value = method == "initiate" ? Self.channel : [:]; if method == "initiate" { value["type"] = Self.responseType }
        if Self.holdReply { Self.holdReply = false; Self.held = (self, value); Self.onHeld?(); return }
        if Self.loseReply { Self.loseReply = false; client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        finish(value)
    }
    static func release() { if let held { Self.held = nil; held.0.finish(held.1) } }
    private func finish(_ value: [String: Any]) { let data = try! JSONSerialization.data(withJSONObject: ["success": true, "data": value]); client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}

#endif
