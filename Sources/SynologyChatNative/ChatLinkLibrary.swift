import Foundation
import CryptoKit

/// Link-library identity is the exact server URL, not a normalized host/path.
/// Retain the first loaded source for duplicates, matching the official repo;
/// recomputing after refresh promotes the next source when the first disappears.
enum ChatLinkLibrary {
    struct Entry: Identifiable {
        let rawURL: String
        let destination: URL
        let post: ChatPost
        let preview: ChatLinkPreview
        var id: String { SHA256.hash(data: Data(rawURL.utf8)).map { String(format: "%02x", $0) }.joined() }
        var time: Double {
            if let updated = post.update_at, updated.isFinite, updated > 0 { return updated }
            return post.create_at.isFinite ? post.create_at : 0
        }
    }
    static func entries(_ posts: [ChatPost]) -> [Entry] {
        var seen = Set<String>(); var values: [Entry] = []
        for post in posts where (post.delete_at ?? 0) == 0 && post.props?.encrypted != true {
            for preview in post.url_props ?? [] {
                guard let raw = preview.url, let destination = ChatMessageLinks.webURL(raw), seen.insert(raw).inserted else { continue }
                values.append(.init(rawURL: raw, destination: destination, post: post, preview: preview))
            }
        }
        return values.enumerated().sorted { a, b in
            a.element.time == b.element.time ? a.offset < b.offset : a.element.time > b.element.time
        }.map(\.element)
    }
}
