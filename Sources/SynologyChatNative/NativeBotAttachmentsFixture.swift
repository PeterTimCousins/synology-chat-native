#if DEBUG
import AppKit
import SwiftUI

@MainActor enum NativeBotAttachmentsFixture {
    private static var controller: BotFixtureController?
    static func runRecoveryFixture() {
        let app = NSApplication.shared, delegate = BotRecoveryFixtureDelegate()
        app.delegate = delegate; app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    static func makeRecoveryModel(directory: URL) async throws -> NativeChatPreviewModel {
        BotFixtureProtocol.reset()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        BotFixtureProtocol.dispatchRecordURL = directory.appendingPathComponent("synthetic-dispatch-count.txt")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BotFixtureProtocol.self]; config.urlCache = nil
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://bot-fixture.invalid")!, sid: "synthetic", synoToken: "synthetic"), network: URLSession(configuration: config))
        try await api.discover()
        let model = NativeChatPreviewModel(client: api, restoreNotificationPreference: false,
            makeClient: { _ in throw ChatAPIError.unsupportedAPI }, botActionJournal: .init(directory: directory.appendingPathComponent("receipts")))
        model.channels = [try JSONDecoder().decode(ChatChannel.self, from: Data(#"{"channel_id":93,"name":"Synthetic bot card","type":"anonymous","encrypted":false,"unread":0,"is_joined":true}"#.utf8))]
        model.connected = true; model.liveStatus = .live; model.selection = 93
        model.posts = [try BotFixtureProtocol.post()]
        model.restoreBotActionRecovery(scope: String(repeating: "a", count: 64))
        return model
    }
    static func present() {
        guard NativeChatAppConfiguration.standalone, NativeChatAppConfiguration.allowsOfficialSessionImport else { return }
        Task { @MainActor in
            do {
                BotFixtureProtocol.reset()
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BotFixtureProtocol.self]
                let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://bot-fixture.invalid")!, sid: "synthetic", synoToken: "synthetic"), network: URLSession(configuration: config))
                try await api.discover()
                let model = NativeChatPreviewModel(client: api, restoreNotificationPreference: false)
                model.channels = [try JSONDecoder().decode(ChatChannel.self, from: Data(#"{"channel_id":93,"name":"Synthetic bot card","type":"anonymous","encrypted":false,"unread":0,"is_joined":true}"#.utf8))]
                model.connected = true; model.liveStatus = .live; model.selection = 93
                model.posts = [try BotFixtureProtocol.post()]
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = "Synthetic bot attachments — local responses only"; window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView: BotFixtureView(model: model))
                window.center(); controller = BotFixtureController(window: window, model: model)
                controller?.showWindow(nil); window.makeKeyAndOrderFront(nil)
            } catch { NSSound.beep() }
        }
    }
}
@MainActor private final class BotRecoveryFixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Bot Action Recovery Test", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
        Task { @MainActor in
            do {
                guard let config = Bundle.main.url(forResource: "FixtureRecoveryDirectory", withExtension: "txt") else { throw ChatAPIError.invalidResponse }
                let path = try String(contentsOf: config, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                guard path.hasPrefix("/private/tmp/native-bot-recovery-ui."), !path.contains(".."), !path.contains("\0") else { throw ChatAPIError.invalidResponse }
                let model = try await NativeBotAttachmentsFixture.makeRecoveryModel(directory: URL(fileURLWithPath: path, isDirectory: true))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
                window.title = "Bot Action Recovery Test — synthetic callbacks only"
                window.contentViewController = NSHostingController(rootView: BotFixtureView(model: model))
                window.isReleasedWhenClosed = false; window.center(); self.window = window
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            } catch { NSApp.terminate(nil) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@MainActor private final class BotFixtureController: NSWindowController, NSWindowDelegate {
    let model: NativeChatPreviewModel
    init(window: NSWindow, model: NativeChatPreviewModel) { self.model = model; super.init(window: window); window.delegate = self }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { model.signOutLocally() }
}
private struct BotFixtureView: View {
    @ObservedObject var model: NativeChatPreviewModel
    @State private var changed = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Synthetic integration card").font(.title2.bold())
            Text("Every request is intercepted locally. This window has no NAS account, live socket or external callback connection.").foregroundColor(NativeChatColors.muted).fixedSize(horizontal: false, vertical: true)
            Text("Local action submissions this process: \(BotFixtureProtocol.writes)")
            if let file = BotFixtureProtocol.dispatchRecordURL {
                Text("Total synthetic callback requests: " + ((try? String(contentsOf: file, encoding: .utf8)) ?? "0")).font(.caption)
            }
            if let post = model.posts.first { NativeBotAttachmentsView(post: post, model: model) }
            Button("Change synthetic card") { BotFixtureProtocol.version += 1; changed += 1 }
                .disabled(!model.botActionsPending.isEmpty)
            Button("Remove synthetic card") {
                BotFixtureProtocol.cardsRemoved = true
                if let post = try? BotFixtureProtocol.post() { model.posts = [post] }
                changed += 1
            }.disabled(!model.botActionsPending.isEmpty)
            Text("Fixture revisions: \(changed)").font(.caption).foregroundColor(NativeChatColors.muted)
            Spacer()
        }.padding(24).frame(minWidth: 600, minHeight: 700, alignment: .topLeading).background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text).nativeChatAppearance().tint(NativeChatColors.green)
    }
}
private final class BotFixtureProtocol: URLProtocol {
    static var version = 0, writes = 0, accepted = 0
    static var dispatchRecordURL: URL?
    static var cardsRemoved = false
    static func reset() { version = 0; writes = 0; accepted = 0; dispatchRecordURL = nil; cardsRemoved = false }
    static var fields: [String: Any] {
        ["post_id": 700, "channel_id": 93, "creator_id": 6, "type": "normal", "message": "Synthetic bot fixture", "create_at": 1000, "update_at": 1000 + version,
         "props": ["safe_url": true, "attachments": cardsRemoved ? [] : [["text": "*Synthetic card* — revision \(version). Accepted locally: \(accepted).", "callback_id": "local-fixture", "actions": [
            ["type": "button", "name": "ack", "value": "ack", "text": "Acknowledge locally", "style": "primary"],
            ["type": "button", "name": "unknown", "value": "unknown", "text": "Simulate lost reply", "style": "danger"],
            ["type": "select", "text": "Unsupported select"]]]]]]
    }
    static func post() throws -> ChatPost { try JSONDecoder().decode(ChatPost.self, from: JSONSerialization.data(withJSONObject: fields)) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "bot-fixture.invalid" else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let api = request.url!.lastPathComponent
        if api == "SYNO.API.Info" {
            let names = ["SYNO.Chat.Post", "SYNO.Chat.Post.Attachment", "SYNO.Chat.Channel"]
            finish(["success": true, "data": Dictionary(uniqueKeysWithValues: names.map { ($0, ["path": "entry.cgi", "minVersion": 1, "maxVersion": 5, "requestFormat": "JSON"] as [String: Any]) })]); return
        }
        if api == "SYNO.Chat.Post" { finish(["success": true, "data": ["posts": [Self.fields]]]); return }
        if api == "SYNO.Chat.Channel" { finish(["success": true]); return }
        if api == "SYNO.Chat.Post.Attachment" {
            Self.writes += 1
            if let file = Self.dispatchRecordURL {
                let previous = (try? String(contentsOf: file, encoding: .utf8)).flatMap(Int.init) ?? 0
                try? Data(String(previous + 1).utf8).write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            let body = Self.body(request); var q = URLComponents(); q.percentEncodedQuery = String(decoding: body, as: UTF8.self)
            let payload = q.queryItems?.first(where: { $0.name == "payload" })?.value
            let data = payload.flatMap { $0.data(using: .utf8) }, json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let actions = json?["actions"] as? [[String: Any]]
            if actions?.first?["value"] as? String == "unknown" { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
            Self.accepted += 1; Self.version += 1; finish(["success": true]); return
        }
        finish(["success": false, "error": ["code": 102]])
    }
    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }; stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 2048)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }; return data
    }
    private func finish(_ value: [String: Any]) { let data = try! JSONSerialization.data(withJSONObject: value); client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
#endif
