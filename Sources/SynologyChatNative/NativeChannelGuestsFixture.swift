#if DEBUG
import AppKit
import SwiftUI

@MainActor enum NativeChannelGuestsFixture {
    private static var controller: NativeGuestsFixtureWindow?
    static func present() {
        guard NativeChatAppConfiguration.standalone, NativeChatAppConfiguration.allowsOfficialSessionImport else { return }
        Task {
            controller?.close()
            NativeGuestsFixtureProtocol.guests = NativeGuestsFixtureProtocol.initialGuests
            do {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [NativeGuestsFixtureProtocol.self]
                let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://guests-ui-fixture.invalid")!, sid: "synthetic", synoToken: "synthetic"), network: URLSession(configuration: configuration))
                try await api.discover()
                let model = NativeChatPreviewModel(client: api, restoreNotificationPreference: false)
                model.channels = try await api.channels(); model.selection = 96; model.connected = true; model.liveStatus = .rejected
                model.guestManagement.activate(scope: String(repeating: "a", count: 64))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 510), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "Channel guests fixture — local responses only"; window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView: NativeChannelGuestsView(model: model, channelID: 96))
                window.center(); controller = NativeGuestsFixtureWindow(window: window, model: model)
                controller?.showWindow(nil); window.makeKeyAndOrderFront(nil)
            } catch { NSSound.beep() }
        }
    }
}

@MainActor private final class NativeGuestsFixtureWindow: NSWindowController, NSWindowDelegate {
    let model: NativeChatPreviewModel
    init(window: NSWindow, model: NativeChatPreviewModel) { self.model = model; super.init(window: window); window.delegate = self }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    func windowWillClose(_ notification: Notification) { model.signOutLocally() }
}

private final class NativeGuestsFixtureProtocol: URLProtocol {
    static let initialGuests: [[String: Any]] = [
        ["guest_id": 9, "expire_at": 0, "status": "uninvited", "user_id": 0, "email": "pending@example.invalid"],
        ["guest_id": 4, "expire_at": 1_900_000_000, "status": "registered", "user_id": 42, "email": "registered@example.invalid"]]
    static var guests = initialGuests
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "guests-ui-fixture.invalid" else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let api = request.url!.lastPathComponent
        var result: [String: Any]
        if api == "SYNO.API.Info" {
            let names = ["SYNO.Chat.Misc", "SYNO.Chat.Channel", "SYNO.Chat.Admin.Setting", "SYNO.Chat.Channel.GuestUser"]
            result = Dictionary(uniqueKeysWithValues: names.map { ($0, ["path": "entry.cgi", "minVersion": 1, "maxVersion": 8, "requestFormat": "JSON"] as [String: Any]) })
        } else if api == "SYNO.Chat.Misc" { result = ["acls": [["acl_name": "guest_manage", "allow": true]]] }
        else if api == "SYNO.Chat.Channel" { result = ["channels": [["channel_id": 96, "name": "Project studio", "type": "private", "encrypted": false, "is_joined": true, "unread": 0]]] }
        else if api == "SYNO.Chat.Admin.Setting" { result = ["allow_guest": true] }
        else if api == "SYNO.Chat.Channel.GuestUser" {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 1024); while stream.hasBytesAvailable && data.count < 16_384 { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) } }
            var components = URLComponents(); components.percentEncodedQuery = String(decoding: data, as: UTF8.self)
            let fields = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
            switch fields["method"] {
            case "list": break
            case "register":
                guard let raw = fields["email"], let address = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)), let expires = Int64(fields["expire_at"] ?? "") else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
                let id = (Self.guests.compactMap { $0["guest_id"] as? Int64 }.max() ?? 10) + 1
                Self.guests.append(["guest_id": id, "expire_at": expires, "status": "uninvited", "user_id": 0, "email": address])
            case "set":
                guard let id = Int64(fields["guest_id"] ?? ""), let index = Self.guests.firstIndex(where: { ($0["guest_id"] as? NSNumber)?.int64Value == id }), let expires = Int64(fields["expire_at"] ?? "") else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
                Self.guests[index]["expire_at"] = expires
            case "kick":
                guard let id = Int64(fields["guest_id"] ?? "") else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
                Self.guests.removeAll { ($0["guest_id"] as? NSNumber)?.int64Value == id }
            case "resend_email": break // Local acknowledgement only; no email transport.
            default: client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
            }
            result = ["guests": Self.guests]
        } else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let data = try! JSONSerialization.data(withJSONObject: ["success": true, "data": result])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
