#if DEBUG
import AppKit
import SwiftUI

/// Synthetic files from the checkout, intercepted authenticated routes and no socket.
@MainActor enum NativeOfficePreviewFixture {
    private static var controller: NativeOfficeFixtureWindow?
    static func present() {
        guard NativeChatAppConfiguration.standalone, NativeChatAppConfiguration.allowsOfficialSessionImport else { return }
        Task {
            controller?.close()
            do {
                func network() -> URLSession { let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [OfficePreviewFixtureProtocol.self]; return URLSession(configuration: configuration) }
                let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://office-preview-fixture.invalid")!, sid: "synthetic", synoToken: "synthetic"), network: network(), makeAttachmentNetwork: network)
                try await api.discover()
                let model = NativeChatPreviewModel(client: api, restoreNotificationPreference: false)
                model.channels = try await api.channels(); model.selection = 96; model.connected = true; model.liveStatus = .rejected
                let posts = try ["NativeOffice.docx", "NativeOffice.xlsx"].enumerated().map { index, name in
                    try JSONDecoder().decode(ChatPost.self, from: JSONSerialization.data(withJSONObject: ["post_id": 501 + index, "channel_id": 96, "creator_id": 10, "create_at": 1, "message": "Synthetic office preview — no delivery connection", "type": "file", "file_props": ["name": name, "is_image": false]]))
                }
                model.posts = posts; model.openDocumentPreview(posts[0])
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = "Office preview fixture — local responses only"; window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView: VStack(spacing: 0) {
                    HStack { Button("Word fixture") { model.openDocumentPreview(posts[0]) }; Button("Spreadsheet fixture") { model.openDocumentPreview(posts[1]) }; Spacer() }.padding(10)
                    NativeDocumentPreview(model: model)
                })
                window.center(); controller = NativeOfficeFixtureWindow(window: window, model: model); controller?.showWindow(nil); window.makeKeyAndOrderFront(nil)
            } catch { NSSound.beep() }
        }
    }
}
@MainActor private final class NativeOfficeFixtureWindow: NSWindowController, NSWindowDelegate {
    let model: NativeChatPreviewModel
    init(window: NSWindow, model: NativeChatPreviewModel) { self.model = model; super.init(window: window); window.delegate = self }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    func windowWillClose(_ notification: Notification) { model.signOutLocally() }
}
private final class OfficePreviewFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "office-preview-fixture.invalid" else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let api = request.url!.lastPathComponent
        if api == "SYNO.Chat.Post.File" {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 1024); while stream.hasBytesAvailable && data.count < 16_384 { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) } }
            var components = URLComponents(); components.percentEncodedQuery = String(decoding: data, as: UTF8.self)
            let fields = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
            guard fields["method"] == "get", let id = fields["post_id"], ["501", "502"].contains(id) else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
            let name = id == "501" ? "NativeOffice.docx" : "NativeOffice.xlsx"
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard let bytes = try? Data(contentsOf: root.appendingPathComponent("Tests/SynologyChatNativeTests/Fixtures/" + name)) else { client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return }
            finish(bytes, headers: ["Content-Type": "application/octet-stream", "Content-Disposition": "attachment; filename=\"" + name + "\""]); return
        }
        let result: [String: Any]
        if api == "SYNO.API.Info" { result = Dictionary(uniqueKeysWithValues: ["SYNO.Chat.Channel", "SYNO.Chat.Post.File"].map { ($0, ["path": "entry.cgi", "minVersion": 1, "maxVersion": 8, "requestFormat": "JSON"] as [String: Any]) }) }
        else if api == "SYNO.Chat.Channel" { result = ["channels": [["channel_id": 96, "name": "Synthetic office", "type": "private", "encrypted": false, "is_joined": true, "unread": 0]]] }
        else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        finish(try! JSONSerialization.data(withJSONObject: ["success": true, "data": result]), headers: ["Content-Type": "application/json"])
    }
    private func finish(_ bytes: Data, headers: [String: String]) { client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
#endif
