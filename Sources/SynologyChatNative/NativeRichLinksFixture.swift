#if DEBUG
import AppKit
import SwiftUI

/// Uses actual native consumers with intercepted local responses, including the
/// global/per-card hide rules. No external metadata/image requests or socket.
@MainActor enum NativeRichLinksFixture {
    private static var controller: NSWindowController?
    static func present() {
        guard NativeChatAppConfiguration.standalone, NativeChatAppConfiguration.allowsOfficialSessionImport else { return }
        Task {
            do {
                let model = try await makeModel()
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = "Rich links fixture — local responses only"
                window.contentViewController = NSHostingController(rootView: NativeChatPreviewView(model: model))
                window.setContentSize(NSSize(width: 1120, height: 780))
                window.minSize = NSSize(width: 800, height: 580)
                window.isReleasedWhenClosed = false; window.center()
                controller = NSWindowController(window: window)
                controller?.showWindow(nil); window.makeKeyAndOrderFront(nil)
            } catch { NSSound.beep() }
        }
    }
    static func makeModel() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference: false, makeClient: { account in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [RichLinksFixtureProtocol.self]; config.urlCache = nil
            return try ChatAPIClient(session: account, network: URLSession(configuration: config))
        })
        await model.connect(using: .init(session: .init(baseURL: URL(string: "https://rich-links-fixture.invalid")!,
            sid: "synthetic", synoToken: "synthetic"), username: "synthetic", importedFromOfficialApp: false))
        model.liveStatus = .rejected; model.error = nil // No socket or writable transport.
        model.selection = 23; model.loadSelection(); await model.historyTask?.value
        return model
    }
}

private final class RichLinksFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "rich-links-fixture.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let path = request.url!.path
        let api = path.components(separatedBy: "/").last ?? ""
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while body.count < 16_384 {
                let count = stream.read(&buffer, maxLength: min(buffer.count, 16_384 - body.count))
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        let fields = URLComponents(string: "https://fixture.invalid/?" + (String(data: body, encoding: .utf8) ?? ""))?.queryItems ?? []
        if api == "SYNO.Chat.Post.File" {
            let raw = fields.first { $0.name == "url" }?.value ?? ""
            let isFavicon = raw.contains("favicon")
            let width = isFavicon ? 32 : 400, height = isFavicon ? 32 : 160
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<height { for x in 0..<width {
                bitmap.setColor(NSColor(calibratedRed: CGFloat(40 + x / 4) / 255, green: CGFloat(80 + y / 2) / 255, blue: 0.5, alpha: 1), atX: x, y: y)
            } }
            respond(bitmap.representation(using: .png, properties: [:])!, mime: "image/png"); return
        }
        let object: [String: Any]
        switch api {
        case "SYNO.API.Info":
            object = Dictionary(uniqueKeysWithValues: ["SYNO.Chat.User", "SYNO.Chat.Channel", "SYNO.Chat.Misc", "SYNO.Chat.Post", "SYNO.Chat.Admin.Setting", "SYNO.Chat.Post.File"].map {
                ($0, ["path": "entry.cgi", "minVersion": 1, "maxVersion": 8, "requestFormat": "JSON"] as [String: Any])
            })
        case "SYNO.Chat.User": object = ["users": [["user_id": 10, "username": "synthetic", "nickname": "Alex Morgan"]]]
        case "SYNO.Chat.Channel": object = ["channels": [["channel_id": 23, "name": "Project studio", "type": "public", "encrypted": false, "unread": 0]]]
        case "SYNO.Chat.Misc": object = ["acls": []]
        case "SYNO.Chat.Admin.Setting": object = ["hide_post_url_preview": false]
        case "SYNO.Chat.Post":
            let preview: [String: Any] = ["url": "https://example.invalid/project", "title": "A shared space for the next release",
                "description": "Server-provided title, description and image, rendered with native controls. This is a local fixture, not a fetched external page.",
                "image": "https://images.example.invalid/preview.png", "favicon": "https://images.example.invalid/favicon.png",
                "image_prop": ["width": 400, "height": 160], "hidden": false]
            func post(_ id: Int, _ message: String, safe: Bool, links: [[String: Any]]) -> [String: Any] {
                ["post_id": id, "channel_id": 23, "creator_id": 10, "type": "normal", "message": message,
                 "create_at": 1792170000000 + id * 60000, "props": ["safe_url": safe], "url_props": links]
            }
            var hidden = preview; hidden["hidden"] = true
            var imagePost = post(4, "A synthetic image for local viewer checks.", safe: true, links: [])
            imagePost["type"] = "file"
            imagePost["file_props"] = ["name": "fixture-image.png", "is_image": true]
            let imageOnly = fields.first { $0.name == "file_type" }?.value?.contains("image") == true
            object = ["posts": imageOnly ? [imagePost] : [
                post(1, "The project notes are ready: <https://example.invalid/project|Read the project notes>", safe: true, links: [preview]),
                post(2, "This link has its preview hidden: https://example.invalid/project", safe: true, links: [hidden]),
                post(3, "A flagged link stays behind a warning: https://unsafe.example.invalid/test", safe: false, links: []), imagePost]]
        default:
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self); return
        }
        respond(try! JSONSerialization.data(withJSONObject: ["success": true, "data": object]), mime: "application/json")
    }
    private func respond(_ data: Data, mime: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": mime])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
