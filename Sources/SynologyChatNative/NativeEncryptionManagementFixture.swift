#if DEBUG
import AppKit
import SwiftUI

/// Real model/views with a synthetic account, local API responses and no socket.
@MainActor enum NativeEncryptionManagementFixture {
    private static var controller: EncryptionManagementFixtureWindow?
    static var account: ChatAccount { .init(session: .init(baseURL: URL(string: "https://encryption-management-fixture.invalid")!, sid: "synthetic", synoToken: "synthetic"), username: "synthetic", importedFromOfficialApp: false) }
    static func network() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [EncryptionManagementFixtureProtocol.self]
        configuration.urlCache = nil; return URLSession(configuration: configuration)
    }
    static func makeModel(pair: ChatEncryptionKeyPair = .init(public_key: "", private_key_enc: ""),
                          journal: ChatEncryptionWriteJournal? = nil,
                          connection: @escaping () -> String? = { "synthetic-client-init-id" }) async throws -> NativeChatPreviewModel {
        EncryptionManagementFixtureProtocol.reset(pair: pair)
        let model = NativeChatPreviewModel(restoreNotificationPreference: false, makeClient: { session in
            try ChatAPIClient(session: session, network: network())
        }, encryptionJournal: journal, managementConnectionID: connection)
        await model.connect(using: account)
        guard model.connected else { throw ChatAPIError.connection }
        model.selection = 23; model.liveStatus = .rejected; model.error = nil
        return model
    }
    static func present() {
        guard NativeChatAppConfiguration.standalone, NativeChatAppConfiguration.allowsOfficialSessionImport else { return }
        Task {
            controller?.close()
            do {
                let model = try await makeModel()
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "Encryption management fixture — synthetic account only"; window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView: NativeEncryptionManagementView(model: model))
                window.center(); controller = EncryptionManagementFixtureWindow(window: window, model: model)
                controller?.showWindow(nil); window.makeKeyAndOrderFront(nil)
            } catch { NSSound.beep() }
        }
    }
}
@MainActor private final class EncryptionManagementFixtureWindow: NSWindowController, NSWindowDelegate {
    let model: NativeChatPreviewModel
    init(window: NSWindow, model: NativeChatPreviewModel) { self.model = model; super.init(window: window); window.delegate = self }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    func windowWillClose(_ notification: Notification) { model.signOutLocally() }
}
final class EncryptionManagementFixtureProtocol: URLProtocol {
    static var pair = ChatEncryptionKeyPair(public_key: "", private_key_enc: "")
    static var writes: [[String: String]] = []
    static var userLists = 0, maximumUserVersion = 8
    static var holdNextList = false, holdWrite = false
    static var held: EncryptionManagementFixtureProtocol?
    static var heldResponse: [String: Any]?
    static var observer: ((String) -> Void)?
    static func reset(pair: ChatEncryptionKeyPair) {
        self.pair = pair; writes = []; userLists = 0; maximumUserVersion = 8
        holdNextList = false; holdWrite = false; held = nil; heldResponse = nil; observer = nil
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "encryption-management-fixture.invalid" else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let api = request.url!.lastPathComponent
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 1024); while stream.hasBytesAvailable && data.count < 16_384 { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) } }
        var components = URLComponents(); components.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        let fields = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        if api == "SYNO.API.Info" {
            finish(["success": true, "data": Dictionary(uniqueKeysWithValues: ["SYNO.Chat.User", "SYNO.Chat.Channel", "SYNO.Chat.Misc", "SYNO.Chat.Post"].map {
                ($0, ["path": "entry.cgi", "minVersion": 1, "maxVersion": $0 == "SYNO.Chat.User" ? Self.maximumUserVersion : 8, "requestFormat": "JSON"] as [String: Any])
            })]); return
        }
        if api == "SYNO.Chat.User", ["set", "change_password"].contains(fields["method"] ?? "") {
            func string(_ key: String) -> String? { fields[key].flatMap { try? JSONDecoder().decode(String.self, from: Data($0.utf8)) } }
            guard let wrapped = string("private_key_enc") else { finish(["success": false, "error": ["code": 407]]); return }
            Self.writes.append(fields)
            if fields["method"] == "set" {
                guard let publicKey = string("public_key") else { finish(["success": false, "error": ["code": 407]]); return }
                Self.pair = .init(public_key: publicKey, private_key_enc: wrapped)
            } else { Self.pair = .init(public_key: Self.pair.public_key, private_key_enc: wrapped) }
            if Self.holdWrite { Self.held = self; Self.observer?("write"); return }
            finish(["success": true]); return
        }
        if api == "SYNO.Chat.User", fields["method"] == "list" {
            Self.userLists += 1
            let result: [String: Any] = ["success": true, "data": ["users": [
                ["user_id": 10, "username": "synthetic", "nickname": "Synthetic account", "type": "human",
                 "user_props": ["email": "synthetic@example.invalid", "avatar_color": "#123456", "key_pair": ["public_key": Self.pair.public_key, "private_key_enc": Self.pair.private_key_enc]]],
                ["user_id": 6, "username": "synthetic-peer", "nickname": "Synthetic peer", "type": "human"]]]]
            if Self.holdNextList { Self.holdNextList = false; Self.held = self; Self.heldResponse = result; Self.observer?("list"); return }
            finish(result); return
        }
        if api == "SYNO.Chat.Channel" { finish(["success": true, "data": ["channels": [["channel_id": 23, "name": "Synthetic ordinary", "type": "private", "encrypted": false, "is_joined": true, "unread": 0]]]]); return }
        if api == "SYNO.Chat.Misc" { finish(["success": true, "data": ["acls": []]]); return }
        if api == "SYNO.Chat.Post" { finish(["success": true, "data": ["posts": []]]); return }
        finish(["success": false, "error": ["code": 102]])
    }
    func finish(_ response: [String: Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject: response)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
