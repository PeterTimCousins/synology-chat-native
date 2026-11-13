import Foundation
import SwiftUI

enum ChatMentions {
    static func render(_ text: AttributedString, names: [Int64: String]) -> AttributedString {
        var result = text
        let source = String(text.characters)
        let regex = try! NSRegularExpression(pattern: #"(?<!\S)@u:([0-9]+)|(?<!\S)@(channel|here)(?![A-Za-z0-9_])"#)
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let range = Range(match.range, in: source),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result),
                  !result[start..<end].runs.contains(where: { $0.link != nil }) else { continue }
            let label: String
            if match.range(at: 1).location != NSNotFound {
                let raw = (source as NSString).substring(with: match.range(at: 1))
                guard let id = Int64(raw), let name = names[id], !name.isEmpty else { continue }
                label = "@" + name
            } else { label = (source as NSString).substring(with: match.range) }
            var replacement = AttributedString(label)
            replacement.foregroundColor = NativeChatColors.green
            replacement.backgroundColor = NativeChatColors.selected.opacity(0.65)
            result.replaceSubrange(start..<end, with: replacement)
        }
        return result
    }
}
