import Foundation

/// Server-supplied Open Graph metadata. Malformed optional metadata must not hide a message.
struct ChatLinkPreview: Decodable {
    let url: String?
    let title: String?
    let description: String?
    let image: String?
    let favicon: String?
    let image_prop: ChatLinkPreviewImageDimensions?
    let hidden: Bool
    enum CodingKeys: String, CodingKey { case url, title, description, image, favicon, image_prop, hidden }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try? c.decode(String.self, forKey: .url)
        title = try? c.decode(String.self, forKey: .title)
        description = try? c.decode(String.self, forKey: .description)
        image = try? c.decode(String.self, forKey: .image)
        favicon = try? c.decode(String.self, forKey: .favicon)
        image_prop = try? c.decode(ChatLinkPreviewImageDimensions.self, forKey: .image_prop)
        hidden = c.contains(.hidden) ? ((try? c.decode(Bool.self, forKey: .hidden)) ?? true) : false
    }
}

/// Optional NAS metadata controls layout only. Ignore malformed dimensions
/// without discarding the title, destination, or message itself.
struct ChatLinkPreviewImageDimensions: Decodable, Equatable {
    let width: Int
    let height: Int
    private enum CodingKeys: String, CodingKey { case width, height }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        guard width > 0, height > 0, width <= 16_000, height <= 16_000,
              width <= 32_000_000 / height else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid preview image dimensions"))
        }
    }
    var isSmall: Bool { width <= 64 && height <= 64 }
}

enum ChatLinkPreviewAsset: String {
    case image, favicon
    func url(in preview: ChatLinkPreview) -> String? {
        switch self { case .image: return preview.image; case .favicon: return preview.favicon }
    }
}

struct ChatPostProperties: Decodable {
    let safe_url: Bool?
    let encrypted: Bool?
    let vote:ChatPoll?
    let forward:ChatForwardOrigin?
    let remind_at:Double?
    let attachments: [ChatJSON]?
    enum CodingKeys: String, CodingKey { case safe_url, encrypted, vote, forward, remind_at, attachments }
    init(safeURL: Bool?) { safe_url = safeURL; encrypted = nil;vote = nil;forward = nil;remind_at = nil; attachments = nil }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        safe_url = c.contains(.safe_url) ? ((try? c.decode(Bool.self, forKey: .safe_url)) ?? false) : nil
        encrypted = try? c.decode(Bool.self, forKey: .encrypted)
        vote = try? c.decode(ChatPoll.self,forKey:.vote)
        forward = try? c.decode(ChatForwardOrigin.self,forKey:.forward)
        remind_at = try? c.decode(Double.self,forKey:.remind_at)
        attachments = try? c.decode([ChatJSON].self, forKey: .attachments)
    }
}

struct ChatDisplaySettings: Decodable {
    let hide_post_url_preview: Bool?
    let allow_read_status: Bool?
    var hidesPreviews: Bool { hide_post_url_preview != false }
}

struct ChatIndexedLinkPreview: Identifiable {
    let index: Int
    let preview: ChatLinkPreview
    var id: Int { index }
}

/// Shared metadata visibility rules for joined timelines and read-only channel previews.
enum ChatLinkPreviewPolicy {
    static func cards(in post:ChatPost,hidden:Bool) -> [ChatIndexedLinkPreview] {
        guard !hidden,post.props?.encrypted != true,post.props?.safe_url != false,(post.delete_at ?? 0) == 0 else { return [] }
        return (post.url_props ?? []).enumerated().compactMap { index,preview in
            guard !preview.hidden,preview.url.flatMap(ChatMessageLinks.webURL) != nil else { return nil }
            return ChatIndexedLinkPreview(index:index,preview:preview)
        }
    }
}

extension ChatAPIClient {
    /// The NAS serves its stored preview image; never attach credentials to an external image URL.
    func linkPreviewImageData(postID: Int64, imageURL: String) async throws -> Data {
        guard ChatMessageLinks.webURL(imageURL) != nil else { throw ChatAPIError.invalidResponse }
        let request = try requestForCall(api: "SYNO.Chat.Post.File", method: "og", version: 2,
                                        parameters: ["post_id": .integer(postID), "url": .string(imageURL)])
        let (bytes, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType?.hasPrefix("image/") == true, bytes.count <= 4 * 1024 * 1024 else { throw ChatAPIError.invalidResponse }
        return bytes
    }
}
