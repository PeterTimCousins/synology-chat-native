import AppKit
import ImageIO
import SwiftUI

@MainActor final class NativeStickerAssets: ObservableObject {
    @Published private(set) var packs: [ChatStickerPack] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var api: ChatAPIClient?
    @Published private(set) var generation = UUID()
    private var manifest: [String: ChatStickerSprite] = [:]
    private var loadTask: Task<([ChatStickerPack], [String: ChatStickerSprite]), Error>?
    private var spriteTasks: [String: Task<Data, Error>] = [:]
    private var images: [String: CGImage] = [:] // At most three current NAS packs; bounded below for other servers.
    func attach(_ client: ChatAPIClient?) {
        generation = UUID(); loadTask?.cancel(); loadTask = nil
        spriteTasks.values.forEach { $0.cancel() }; spriteTasks = [:]
        packs = []; manifest = [:]; images = [:]; error = nil; loading = false; api = client
    }
    func contains(_ name: String) -> Bool { packs.contains { $0.stickers.contains { $0.name == name } } }
    func sticker(_ name: String) -> ChatSticker? { packs.lazy.flatMap(\.stickers).first { $0.name == name } }
    func load() async {
        guard packs.isEmpty, let api else { return }
        let expected = generation
        if loadTask == nil {
            loading = true; error = nil
            loadTask = Task {
                let packs = try await api.stickerCatalogue()
                let data = try await api.stickerAssetData(path: "style.css")
                let mapping = ChatStickerSprite.parse(String(decoding: data, as: UTF8.self))
                guard !packs.isEmpty, !mapping.isEmpty else { throw ChatAPIError.invalidResponse }
                return (packs, mapping)
            }
        }
        guard let task = loadTask else { return }
        do {
            let (loaded, mapping) = try await task.value
            guard expected == generation, !Task.isCancelled else { return }
            packs = loaded; manifest = mapping
        } catch {
            guard expected == generation, !Task.isCancelled else { return }
            self.error = "Could not load sticker packs. Try again when the server is connected."
        }
        if expected == generation { loading = false; loadTask = nil }
    }
    func image(_ name: String) async -> NSImage? {
        let expected = generation
        await load()
        guard expected == generation, contains(name), let tile = manifest[name], let api else { return nil }
        do {
            let sprite: CGImage
            if let cached = images[tile.path] { sprite = cached }
            else {
                if spriteTasks[tile.path] == nil { spriteTasks[tile.path] = Task { try await api.stickerAssetData(path: tile.path) } }
                guard let task = spriteTasks[tile.path] else { return nil }
                let data = try await task.value
                guard expected == generation, !Task.isCancelled else { return nil }
                guard let decoded = images[tile.path] ?? Self.decodeSprite(data) else { return nil }
                spriteTasks[tile.path] = nil
                // Cap decoded pack memory at about 64 MiB (4 sprites × 16 MiB).
                if images.count >= 4 { images.removeAll() }
                images[tile.path] = decoded; sprite = decoded
            }
            guard expected == generation, !Task.isCancelled,
                  tile.x + tile.width <= sprite.width, tile.y + tile.height <= sprite.height,
                  let cropped = sprite.cropping(to: CGRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height)) else { return nil }
            return NSImage(cgImage: cropped, size: NSSize(width: tile.width, height: tile.height))
        } catch {
            if expected == generation { spriteTasks[tile.path] = nil }
            return nil
        }
    }
    static func decodeSprite(_ data: Data) -> CGImage? {
        guard data.count <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 32768, h <= 32768, w * h <= 4 * 1024 * 1024 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

struct NativeStickerImage: View {
    @ObservedObject var assets: NativeStickerAssets
    let name: String
    var size: CGFloat = 80
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
            else { Image(systemName: "face.smiling").foregroundColor(NativeChatColors.muted) }
        }.frame(width: size, height: size).accessibilityLabel(assets.sticker(name)?.displayName ?? name)
            .task(id: assets.generation.uuidString + name) { image = nil; image = await assets.image(name) }
            .onDisappear { image = nil }
    }
}

struct NativeStickerPicker: View {
    @ObservedObject var assets: NativeStickerAssets
    let title: String
    let choose: (String) -> Void
    @State private var query = ""
    @State private var pack: Int64 = -1
    @State private var searchFocused = true
    @State private var selectedSticker: String?
    @Environment(\.dismiss) private var dismiss
    private var matches: [ChatSticker] {
        let all = assets.packs.filter { pack == -1 || $0.id == pack }.flatMap(\.stickers)
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "_" })
        return all.filter { sticker in words.allSatisfy { word in
            sticker.displayName.lowercased().contains(word) || (sticker.keywords ?? []).contains { $0.lowercased().contains(word) }
        } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
            NativeEmojiPickerSearchField(text: $query, focused: $searchFocused,
                label: "Search stickers", placeholder: "Search stickers", command: handleCommand)
                .frame(height: 24)
            Picker("Sticker pack", selection: $pack) {
                Text("All packs").tag(Int64(-1))
                ForEach(assets.packs) { Text($0.displayName).tag($0.id) }
            }.labelsHidden()
            ScrollViewReader { proxy in
              ScrollView {
                if assets.loading { ProgressView("Loading stickers…").frame(maxWidth: .infinity, minHeight: 100) }
                else if let error = assets.error {
                    VStack { Text(error); Button("Try again") { Task { await assets.load() } } }.padding()
                } else if matches.isEmpty {
                    Text("No stickers match this search").foregroundColor(NativeChatColors.muted).padding()
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(94)), count: 3), spacing: 6) {
                        ForEach(matches) { sticker in
                            Button { choose(sticker.name) } label: {
                                NativeStickerImage(assets: assets, name: sticker.name).frame(width: 94, height: 94)
                                    .background(selectedSticker == sticker.name ? NativeChatColors.green.opacity(0.2) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .contentShape(RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).help(sticker.displayName).accessibilityLabel(sticker.displayName)
                                .accessibilityAddTraits(selectedSticker == sticker.name ? [.isSelected] : [])
                                .id(sticker.name)
                        }
                    }
                }
              }.frame(height: 270)
                .onChange(of: selectedSticker) { value in
                    if let value { proxy.scrollTo(value) }
                }
            }
            Text(selectedSticker.flatMap { selected in matches.first { $0.name == selected }?.displayName }
                ?? "\(matches.count) stickers · ↓ to browse, Return to send")
                .font(.caption).foregroundColor(NativeChatColors.muted).lineLimit(1)
        }.padding(16).frame(width: 344).background(NativeChatColors.surface)
            .foregroundColor(NativeChatColors.text).nativeChatAppearance().onAppear { searchFocused = true }.task { await assets.load() }
            .onChange(of: query) { _ in selectedSticker = nil }
            .onChange(of: pack) { _ in selectedSticker = nil }
            .onChange(of: matches.map(\.name)) { _ in selectedSticker = nil }
            .onChange(of: assets.generation) { _ in selectedSticker = nil }
            .onExitCommand { dismiss() }
    }

    private func handleCommand(_ command: NativeEmojiPickerNavigation.Command) -> Bool {
        if command == .cancel { dismiss(); return true }
        let items = matches
        let current = selectedSticker.flatMap { selected in items.firstIndex { $0.name == selected } }
        if (command == .left || command == .right) && current == nil { return false }
        // A catalogue refresh/account detach must never submit an old result.
        guard !assets.loading, assets.error == nil else { return true }
        if command == .submit {
            guard let index = NativeEmojiPickerNavigation.submissionIndex(selected: current, count: items.count) else { return true }
            choose(items[index].name); return true
        }
        selectedSticker = NativeEmojiPickerNavigation.move(selected: current, count: items.count, columns: 3, command: command).map { items[$0].name }
        return true
    }
}

