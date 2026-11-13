#if DEBUG
import AppKit
import SwiftUI

/// Development-only interaction fixture. Its URLSession is intercepted locally;
/// configuration deliberately fails so the model never creates a live socket.
@MainActor
enum NativeEncryptedUIFixture {
    private static var controller: NSWindowController?
    static func present() {
        guard NativeChatAppConfiguration.standalone, NativeChatAppConfiguration.allowsOfficialSessionImport else { return }
        do {
            let model = try makeModel()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Synthetic encryption fixture — local responses only"
            window.contentViewController = NSHostingController(rootView: NativeChatPreviewView(model: model))
            window.isReleasedWhenClosed = false
            window.center()
            controller = NSWindowController(window: window)
            controller?.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            Task {
                await connect(model)
                model.selection = 23
                model.loadSelection()
            }
        } catch { NSSound.beep() }
    }

    static func makeModel() throws -> NativeChatPreviewModel {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/SynologyChatNativeTests/Fixtures/ChatCrypto.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
        let responses = try fixture.responses()
        EncryptedFixtureProtocol.install(responses)
        return NativeChatPreviewModel(restoreNotificationPreference: false, makeClient: { session in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [EncryptedFixtureProtocol.self]
            configuration.urlCache = nil
            let network = URLSession(configuration: configuration)
            return try ChatAPIClient(session: session, network: network)
        })
    }

    static func connect(_ model: NativeChatPreviewModel) async {
        await model.connect(using: .init(session: .init(baseURL: URL(string: "https://native-fixture.invalid")!,
            sid: "synthetic", synoToken: "synthetic"), username: "synthetic", importedFromOfficialApp: false))
        model.liveStatus = .rejected // Offline fixture; never enables outbound actions.
    }

    private struct Fixture: Decodable {
        let publicKey, wrappedPrivateKey, wrappedChannelKey, encryptedMessage: String
        func responses() throws -> [String: Data] {
            let catalog = Dictionary(uniqueKeysWithValues: ["SYNO.Chat.User", "SYNO.Chat.Channel", "SYNO.Chat.Misc", "SYNO.Chat.Post"].map {
                ($0, ["path": "entry.cgi", "minVersion": 1, "maxVersion": 8, "requestFormat": "JSON"] as [String: Any])
            })
            let payloads: [String: Any] = ["SYNO.API.Info": catalog,
                "SYNO.Chat.User": ["users": [["user_id": 10, "username": "synthetic", "nickname": "Synthetic account",
                    "user_props": ["key_pair": ["public_key": publicKey, "private_key_enc": wrappedPrivateKey]]]]],
                "SYNO.Chat.Channel": ["channels": [["channel_id": 23, "name": "Synthetic encrypted", "type": "private",
                    "encrypted": true, "unread": 0, "channel_key_enc": wrappedChannelKey]]],
                "SYNO.Chat.Misc": ["acls": []],
                "SYNO.Chat.Post": ["posts": [["post_id": 100, "channel_id": 23, "creator_id": 10,
                    "message": encryptedMessage, "type": "normal", "create_at": 1000]]]]
            return try payloads.mapValues { try JSONSerialization.data(withJSONObject: ["success": true, "data": $0]) }
        }
    }
}

final class EncryptedFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responseData: [String: Data] = [:]
    static func install(_ responses: [String: Data]) {
        lock.lock(); defer { lock.unlock() }
        responseData = responses
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let responses = Self.responseData
        Self.lock.unlock()
        let payload = request.url?.host == "native-fixture.invalid" ? responses[request.url!.lastPathComponent] : nil
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: payload == nil ? 404 : 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
