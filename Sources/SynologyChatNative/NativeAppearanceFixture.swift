#if DEBUG
import AppKit
import SwiftUI

@MainActor enum NativeAppearanceFixture {
    private static var controller: AppearanceFixtureWindow?
    static func toggleSize() {
        guard let window = controller?.window, window.isVisible else { return }
        let compact = (window.contentView?.bounds.width ?? 0) >= 1040
        window.setContentSize(NSSize(width: compact ? 800 : 1140, height: compact ? 600 : 790))
    }
    static func present() {
        guard NativeChatAppConfiguration.standalone, NativeChatAppConfiguration.allowsOfficialSessionImport else { return }
        Task {
            do {
                controller?.close()
                AppearanceFixtureProtocol.settings = .init(style: .dark, background: .preset0)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [AppearanceFixtureProtocol.self]
                let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://appearance-preview.invalid")!, sid: "synthetic", synoToken: "synthetic"), network: URLSession(configuration: configuration))
                try await api.discover()
                let model = NativeChatPreviewModel(client: api, restoreNotificationPreference: false)
                model.connected = true; model.liveStatus = .rejected
                model.channels = [try JSONDecoder().decode(ChatChannel.self, from: Data(#"{"channel_id":23,"name":"Design studio — local appearance preview","type":"private","encrypted":false,"is_joined":true,"unread":0}"#.utf8))]
                model.directory = [try JSONDecoder().decode(ChatUser.self, from: Data(#"{"user_id":10,"username":"synthetic","nickname":"Avery Morgan","type":"human"}"#.utf8))]
                model.names = [10: "Avery Morgan"]; model.selection = 23
                model.posts = try JSONDecoder().decode([ChatPost].self, from: JSONSerialization.data(withJSONObject: [
                    ["post_id": 100, "channel_id": 23, "creator_id": 10, "message": "A quieter place to work. This is a local preview of account themes and backgrounds.", "type": "normal", "create_at": 1794400000000],
                    ["post_id": 101, "channel_id": 23, "creator_id": 10, "message": "Switch between light and dark while keeping the conversation and your draft in place.", "type": "normal", "create_at": 1794400040000]
                ]))
                model.draft = "An unsent draft — still here after changing appearance."
                _ = try await model.loadAppearanceSettings()
                let preferences = NativeAppearancePreferences(); preferences.followsAccount = true
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 790), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = "Appearance preview — local synthetic account"; window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView: NativeChatPreviewView(model: model, appearancePreferences: preferences))
                window.setContentSize(NSSize(width: 1140, height: 790))
                window.minSize = NSSize(width: 800, height: 580)
                window.center(); controller = AppearanceFixtureWindow(window: window, model: model)
                controller?.showWindow(nil); window.makeKeyAndOrderFront(nil)
            } catch { NSSound.beep() }
        }
    }
}
@MainActor private final class AppearanceFixtureWindow: NSWindowController, NSWindowDelegate {
    let model: NativeChatPreviewModel
    init(window: NSWindow, model: NativeChatPreviewModel) { self.model = model; super.init(window: window); window.delegate = self }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { model.signOutLocally() }
}
private final class AppearanceFixtureProtocol: URLProtocol {
    static var settings = ChatAppearanceSettings(style: .dark, background: .preset0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "appearance-preview.invalid" else { fail(); return }
        if let name = request.url?.lastPathComponent, name.hasPrefix("wallpaper_") {
            let allowed = ChatAppearanceStyle.allCases.flatMap { style in (1...3).map { "wallpaper_\(style.rawValue)_0\($0).jpg" } }
            guard allowed.contains(name), let data = try? Data(contentsOf: URL(fileURLWithPath: "/private/tmp/synology-appearance-catalogue-20261111/" + name)) else { fail(); return }
            finish(data, type: "image/jpeg"); return
        }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable && data.count < 16_384 { let count = stream.read(&bytes, maxLength: min(bytes.count, 16_384 - data.count)); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
        }
        var components = URLComponents(); components.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        let fields = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        let response: [String: Any]
        switch request.url?.lastPathComponent {
        case "SYNO.API.Info": response = ["success": true, "data": ["SYNO.Chat.User.Preference": ["path": "entry.cgi", "minVersion": 1, "maxVersion": 4, "requestFormat": "JSON"], "SYNO.Chat.Post": ["path": "entry.cgi", "minVersion": 1, "maxVersion": 5, "requestFormat": "JSON"]]]
        case "SYNO.Chat.Post": response = ["success": true, "data": ["posts": [["post_id": 200, "thread_id": 100, "channel_id": 23, "creator_id": 10, "message": "A local thread reply with the same account appearance.", "type": "normal", "create_at": 1794400100000]]]]
        case "SYNO.Chat.User.Preference":
            if fields["method"] == "set" {
                let style = fields["theme_style"].flatMap { try? JSONDecoder().decode(ChatAppearanceStyle.self, from: Data($0.utf8)) } ?? Self.settings.style
                let background = fields["theme_background"].flatMap(Int.init).flatMap(ChatAppearanceBackground.init(rawValue:)) ?? Self.settings.background
                Self.settings = .init(style: style, background: background)
                response = ["success": true]
            } else { response = ["success": true, "data": ["preferences": ["theme_style": Self.settings.style.rawValue, "theme_background": Self.settings.background.rawValue]]] }
        default: response = ["success": false, "error": ["code": 102]]
        }
        finish(try! JSONSerialization.data(withJSONObject: response), type: "application/json")
    }
    private func fail() { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)) }
    private func finish(_ bytes: Data, type: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
