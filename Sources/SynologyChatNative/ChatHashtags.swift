import Foundation
import SwiftUI

enum ChatHashtags {
    private static let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        .union(CharacterSet(charactersIn: "|~!@#$%^&*()+\\[]'\":{}?;.,/=><`"))
    static func valid(_ tag: String) -> Bool {
        !tag.isEmpty && tag.utf16.count <= 32 && !tag.unicodeScalars.contains { forbidden.contains($0) }
    }
    static func destination(_ tag: String) -> URL? {
        guard valid(tag) else { return nil }
        var parts = URLComponents(); parts.scheme = "synology-chat-hashtag"; parts.host = "browse"
        parts.queryItems = [.init(name:"tag",value:tag)]
        return parts.url
    }
    static func tag(from url: URL) -> String? {
        guard url.scheme == "synology-chat-hashtag", url.host == "browse", url.path.isEmpty,
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let items = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems, items.count == 1,
              items[0].name == "tag", let tag = items[0].value, valid(tag) else { return nil }
        return tag
    }
    static func render(_ text: AttributedString, enabled: Bool) -> AttributedString {
        guard enabled else { return text }
        let source = String(text.characters)
        var matches: [(Range<String.Index>,String)] = []
        for index in source.indices where source[index] == "#" {
            guard index == source.startIndex || source[..<index].last?.isWhitespace == true else { continue }
            let start = source.index(after:index); var end = start
            while end < source.endIndex && !source[end].unicodeScalars.contains(where:{ forbidden.contains($0) }) { end = source.index(after:end) }
            let tag = String(source[start..<end])
            if valid(tag) { matches.append((index..<end,tag)) }
        }
        var result = text
        for (raw,tag) in matches.reversed() {
            guard let url = destination(tag),
                  let start = AttributedString.Index(raw.lowerBound,within:result), let end = AttributedString.Index(raw.upperBound,within:result),
                  !result[start..<end].runs.contains(where:{ $0.link != nil }) else { continue }
            result[start..<end].link = url
            result[start..<end].foregroundColor = NativeChatColors.green
        }
        return result
    }
}
struct NativeHashtagDestination: Identifiable { let name: String; var id: String { name } }
