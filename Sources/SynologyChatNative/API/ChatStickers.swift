import Foundation

struct ChatSticker: Decodable, Identifiable {
    let name: String
    let sticker_id: Int64
    let keywords: [String]?
    var id: String { name }
    var displayName: String { name.replacingOccurrences(of: "_", with: " ").capitalized }
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128 && name.range(of: #"^[A-Za-z0-9_+\-]+$"#, options: .regularExpression) != nil
    }
}
struct ChatStickerPack: Decodable, Identifiable {
    let category_id: Int64
    let name: String
    let stickers: [ChatSticker]
    var id: Int64 { category_id }
    var displayName: String { name.replacingOccurrences(of: "_", with: " ").capitalized }
}
struct ChatStickerCatalogue: Decodable { let categories: [ChatStickerPack] }

/// The official client uses these CSS declarations as its sprite manifest. Only
/// bounded PNG paths inside the NAS's sticker/1x directory are admitted. This is
/// asset metadata, not HTML/CSS injected into the native interface.
struct ChatStickerSprite: Equatable {
    let path: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    static func parse(_ css: String) -> [String: Self] {
        guard css.utf8.count <= 4 * 1024 * 1024 else { return [:] }
        let regex = try! NSRegularExpression(pattern: #"\.sticker-([A-Za-z0-9_+\-]+)\s*\{([^{}]*)\}"#)
        let text = css as NSString
        var result: [String: Self] = [:]
        func captures(_ pattern: String, _ value: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
            let s = value as NSString; return (1..<m.numberOfRanges).map { s.substring(with: m.range(at: $0)) }
        }
        for match in regex.matches(in: css, range: NSRange(css.startIndex..., in: css)) {
            let name = text.substring(with: match.range(at: 1)); let body = text.substring(with: match.range(at: 2))
            guard let path = captures(#"background-image\s*:\s*url\(["']?(images/sticker/1x/[A-Za-z0-9_\-]+\.png)["']?\)"#, body)?.first,
                  let w = captures(#"(?:^|;)\s*width\s*:\s*([0-9]+)px"#, body)?.first.flatMap(Int.init),
                  let h = captures(#"(?:^|;)\s*height\s*:\s*([0-9]+)px"#, body)?.first.flatMap(Int.init),
                  let pos = captures(#"background-position\s*:\s*(-?[0-9]+)(?:px)?\s+(-?[0-9]+)(?:px)?"#, body),
                  let x = Int(pos[0]), let y = Int(pos[1]), x <= 0, y <= 0, x > -32768, y > -32768,
                  w > 0, h > 0, w <= 1024, h <= 1024 else { continue }
            result[name] = Self(path: path, x: -x, y: -y, width: w, height: h)
        }
        return result
    }
}
