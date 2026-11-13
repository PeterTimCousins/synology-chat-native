#if DEBUG
import AppKit
import SwiftUI

/// Render only a synthetic app-owned view. No window, desktop capture, input,
/// official-session import or NAS connection is involved.
@MainActor enum NativeInlineAudioRenderFixture {
    static func render(to directory: URL) async -> Bool {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (name, width, style) in [("dark-comfortable", 480.0, ChatAppearanceStyle.dark),
                                          ("dark-compact", 300.0, .dark), ("light-comfortable", 480.0, .light)] {
                func network() -> URLSession {
                    let config = URLSessionConfiguration.ephemeral
                    config.protocolClasses = [InlineAudioRenderProtocol.self]; config.urlCache = nil
                    return URLSession(configuration: config)
                }
                let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://inline-audio-render.invalid")!, sid: "synthetic", synoToken: "synthetic"),
                                            network: network(), makeAttachmentNetwork: network)
                try await api.discover()
                let model = NativeChatPreviewModel(client: api, restoreNotificationPreference: false)
                defer { model.signOutLocally() }
                let channel = try JSONDecoder().decode(ChatChannel.self, from: Data(#"{"channel_id":93,"name":"Synthetic Peter","type":"anonymous","encrypted":false,"unread":0}"#.utf8))
                let post = try JSONDecoder().decode(ChatPost.self, from: JSONSerialization.data(withJSONObject: [
                    "post_id":777,"channel_id":93,"creator_id":10,"create_at":1000,"type":"file","message":"Synthetic audio fixture",
                    "file_props":["name":"voice-note.wav","size":InlineAudioRenderProtocol.bytes.count,"is_image":false]]))
                model.channels = [channel]; model.selection = 93; model.connected = true; model.liveStatus = .live; model.posts = [post]
                let owner = UUID()
                model.openInlineAudio(post, ownerID: owner)
                await model.documentPreviewTask?.value
                guard case .media(let playback) = model.documentPreviewContent, model.documentPreviewError == nil,
                      model.ownsInlineAudio(postID: post.id, ownerID: owner) else { throw ChatAPIError.invalidResponse }
                playback.setVolume(0); playback.player.pause()
                let content = VStack(alignment: .leading, spacing: 0) {
                    NativeFileAttachmentCard(post: post, model: model, audioOwnerID: owner)
                }.padding(16).frame(width: width, height: 210, alignment: .topLeading)
                    .background(NativeChatColors.canvas).foregroundColor(NativeChatColors.text)
                    .environment(\.nativeChatStyle, style).preferredColorScheme(style.colorScheme)
                let view = NSHostingView(rootView: content)
                view.appearance = NSAppearance(named: style == .dark ? .darkAqua : .aqua)
                view.frame = NSRect(x: 0, y: 0, width: width, height: 210)
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 60_000_000)
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ChatAPIError.invalidResponse }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ChatAPIError.invalidResponse }
                let file = directory.appendingPathComponent(name + ".png")
                try png.write(to: file, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                model.closeDocumentPreview()
            }
            print("Rendered three synthetic inline-audio views without opening a window.")
            return true
        } catch { print("Offscreen inline-audio rendering failed; no desktop or NAS accessed."); return false }
    }
}

private final class InlineAudioRenderProtocol: URLProtocol {
    static let bytes: Data = {
        let wave = NativeSyntheticMedia.wave()
        return Data(wave.prefix(44)) + Data(repeating: 0, count: wave.count - 44)
    }()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "inline-audio-render.invalid" else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        if request.url?.path.hasSuffix("/SYNO.API.Info") == true {
            let data = Data(#"{"success":true,"data":{"SYNO.Chat.Post.File":{"path":"entry.cgi","minVersion":1,"maxVersion":2,"requestFormat":"JSON"}}}"#.utf8)
            reply(data, status: 200, headers: ["Content-Type":"application/json"]);return
        }
        guard request.url?.path.hasSuffix("/SYNO.Chat.Post.File") == true,
              let raw = request.value(forHTTPHeaderField: "Range"), raw.hasPrefix("bytes=") else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL));return
        }
        let values = raw.dropFirst(6).split(separator: "-")
        guard values.count == 2, let start = Int(values[0]), let end = Int(values[1]), start >= 0, end >= start,
              end < Self.bytes.count, end - start < 64 * 1024 else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse));return }
        let body = Self.bytes.subdata(in: start..<(end + 1))
        reply(body, status: 206, headers: ["Content-Type":"audio/wav","Content-Disposition":"attachment; filename=synthetic.wav",
            "Content-Range":"bytes \(start)-\(end)/\(Self.bytes.count)","Content-Length":String(body.count)])
    }
    private func reply(_ data: Data, status: Int, headers: [String:String]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
