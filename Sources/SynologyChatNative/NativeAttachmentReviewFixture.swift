#if DEBUG
import AppKit
import SwiftUI

/// Windowless rendering of the actual review, using only owned generated files.
/// The disconnected model has no account, API client or delivery connection.
@MainActor enum NativeAttachmentReviewFixture {
    static func render(to directory: URL) async -> Bool {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let source = FileManager.default.temporaryDirectory.appendingPathComponent("native-attachment-review-render-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: source) }
            let landscape = source.appendingPathComponent("Design overview.png")
            let portrait = source.appendingPathComponent("Portrait reference.png")
            let notes = source.appendingPathComponent("Research notes — decisions and follow-up for the next design review.txt")
            for (file, bytes) in [(landscape, try image(width: 640, height: 360)),
                                  (portrait, try image(width: 300, height: 520)),
                                  (notes, Data("Synthetic attachment review notes.\nNo personal files or account data.\n".utf8))] {
                guard FileManager.default.createFile(atPath: file.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else { throw ChatAPIError.invalidResponse }
            }
            // This validates generated originals, not whether SwiftUI's async
            // image task has appeared. Inspect the exported review images too.
            guard NativeAttachmentImageLoader.load(landscape) != nil, NativeAttachmentImageLoader.load(portrait) != nil else { throw ChatAPIError.invalidResponse }
            for style in ChatAppearanceStyle.allCases {
                for mode in ["landscape", "portrait", "multiple", "empty"] {
                    let model = NativeChatPreviewModel(restoreNotificationPreference: false, makeClient: { _ in throw ChatAPIError.unsupportedAPI })
                    defer { model.signOutLocally() }
                    model.channels = [try JSONDecoder().decode(ChatChannel.self, from: JSONSerialization.data(withJSONObject: [
                        "channel_id": 23, "name": "Design studio", "type": "private", "encrypted": false, "is_joined": true, "unread": 0
                    ]))]
                    model.selection = 23; model.connected = true; model.liveStatus = .live
                    model.draft = "Unsent synthetic review draft — retained."
                    let batch: NativeAttachmentBatch
                    if mode == "empty" {
                        batch = NativeAttachmentBatch(files: [], caption: "", channelID: 23, channelTitle: "Design studio", rootID: nil, encrypted: false, keyEnvelope: nil)
                    } else {
                        let files = mode == "multiple" ? [landscape, notes, portrait] : [mode == "portrait" ? portrait : landscape]
                        model.stageAttachments(files)
                        guard let staged = model.attachmentBatch else { throw ChatAPIError.invalidResponse }
                        batch = staged
                        batch.caption(batch.items[0].id, text: mode == "multiple" ? "Overview for the next review." : "Review the layout and image detail before sending.")
                        if mode == "multiple" {
                            batch.caption(batch.items[1].id, text: "Notes with a deliberately longer filename.")
                            batch.caption(batch.items[2].id, text: "Portrait companion image.")
                        }
                    }
                    let content = NativeAttachmentBatchView(model: model, batch: batch)
                        .environment(\.nativeChatStyle, style).preferredColorScheme(style.colorScheme)
                    let view = NSHostingView(rootView: content)
                    view.appearance = NSAppearance(named: style == .dark ? .darkAqua : .aqua)
                    let single = mode == "landscape" || mode == "portrait"
                    view.frame = NSRect(x: 0, y: 0, width: 660, height: single ? 600 : 560)
                    view.layoutSubtreeIfNeeded()
                    // Give the real image preview task bounded opportunities to
                    // finish while the caller's app run loop remains active.
                    for _ in 0..<8 {
                        try await Task.sleep(nanoseconds: 50_000_000)
                        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                    }
                    guard model.draft == "Unsent synthetic review draft — retained.", batch.sentCount == 0,
                          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ChatAPIError.invalidResponse }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ChatAPIError.invalidResponse }
                    try data.write(to: directory.appendingPathComponent(style.rawValue + "-attachment-" + mode + ".png"), options: .withoutOverwriting)
                }
            }
            return true
        } catch { fputs("Offscreen synthetic attachment review rendering failed.\n", stderr); return false }
    }

    private static func image(width: Int, height: Int) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let pixels = bitmap.bitmapData else { throw ChatAPIError.invalidResponse }
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bitmap.bytesPerRow + x * 4
                let inset = x > width / 6 && x < width * 5 / 6 && y > height / 4 && y < height * 3 / 4
                let stripe = inset && ((x / 32 + y / 32) % 2 == 0)
                pixels[offset] = inset ? (stripe ? 116 : 74) : 43
                pixels[offset + 1] = inset ? (stripe ? 213 : 164) : UInt8(36 + y * 25 / height)
                pixels[offset + 2] = inset ? (stripe ? 188 : 149) : UInt8(61 + x * 24 / width)
                pixels[offset + 3] = 255
            }
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ChatAPIError.invalidResponse }
        return data
    }
}
#endif
