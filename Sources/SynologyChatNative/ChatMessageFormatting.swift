import Foundation
import SwiftUI

/// Synology's small message dialect, rather than CommonMark. Text never passes
/// through an HTML renderer. Code and escaped delimiters remain literal.
enum ChatMessageFormatting {
    struct Block: Equatable {
        enum Kind { case paragraph, quote, bullet, code }
        let kind: Kind
        let text: String
        /// Only a >>> quote owns block children. An ordinary > quote is inline.
        let children: [Block]?
        init(kind: Kind, text: String, children: [Block]? = nil) {
            self.kind = kind; self.text = text; self.children = children
        }
    }
    static func blocks(_ text: String) -> [Block] { blocks(text, allowsMultilineQuote: true) }
    private static func blocks(_ text: String, allowsMultilineQuote: Bool) -> [Block] {
        var result: [Block] = []
        var rest = text[...]
        while !rest.isEmpty {
            if rest.hasPrefix("```"), let end = rest.dropFirst(3).range(of: "```") {
                var code = String(rest[rest.index(rest.startIndex, offsetBy: 3)..<end.lowerBound])
                // HTML pre (used by the official client) suppresses the first newline.
                if code.hasPrefix("\n") { code.removeFirst() }
                result.append(.init(kind: .code, text: code))
                rest = rest[end.upperBound...]
                if rest.hasPrefix("\n") { rest = rest.dropFirst() }
                continue
            }
            if allowsMultilineQuote, rest.hasPrefix(">>>") {
                let quoted = String(rest.dropFirst(3))
                // The vendor parser calls parseBlock(child, true): retain lists,
                // code and ordinary quotes, but do not consume another >>> group.
                result.append(.init(kind: .quote, text: quoted,
                                    children: blocks(quoted, allowsMultilineQuote: false)))
                break
            }
            let end = rest.firstIndex(of: "\n") ?? rest.endIndex
            let line = String(rest[..<end])
            if line.hasPrefix(">") { result.append(.init(kind: .quote, text: String(line.dropFirst()))) }
            else if line.hasPrefix("* ") { result.append(.init(kind: .bullet, text: String(line.dropFirst(2)))) }
            else { result.append(.init(kind: .paragraph, text: line)) }
            rest = end == rest.endIndex ? rest[rest.endIndex...] : rest[rest.index(after: end)...]
        }
        return result
    }
    static func inline(_ text: String, mentions: [Int64: String] = [:], hashtagLinks: Bool = true, calendarLinks: Bool = false) -> AttributedString { ChatDateLinks.render(parse(text, depth: 0, mentions: mentions, hashtagLinks: hashtagLinks), enabled: calendarLinks) }
    private static func parse(_ text: String, depth: Int, mentions: [Int64: String], hashtagLinks: Bool) -> AttributedString {
        guard depth < 8 else { return ChatMessageLinks.attributed(text) }
        // Inline styles have whitespace boundaries in the official grammar.
        // Escaped characters are consumed before delimiters; code is atomic.
        let pattern = #"\\[\\&*_]|(?<!\S)`([^`\n]+)`|(?<!\S)\*((?:\\.|[^*\n])+?)\*(?=\s|$)|(?<!\S)_((?:\\.|[^_\n])+?)_(?=\s|$)|(?<!\S)~([^~\n]+)~(?=\s|$)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        var result = AttributedString(); var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor { result += plain(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), mentions: mentions, hashtagLinks: hashtagLinks) }
            if ns.substring(with: match.range).hasPrefix("\\") {
                result += AttributedString(String(ns.substring(with: match.range).dropFirst()))
            } else {
                for index in 1...4 where match.range(at: index).location != NSNotFound {
                    let value = ns.substring(with: match.range(at: index))
                    // Leading/trailing spaces inside emphasis are not accepted.
                    if index > 1 && value.trimmingCharacters(in: .whitespaces) != value {
                        result += plain(ns.substring(with: match.range), mentions: mentions, hashtagLinks: hashtagLinks); break
                    }
                    var segment = index == 1 ? AttributedString(value) : parse(value, depth: depth + 1, mentions: mentions, hashtagLinks: hashtagLinks)
                    let intent: InlinePresentationIntent = [.code, .stronglyEmphasized, .emphasized, .strikethrough][index - 1]
                    for run in segment.runs {
                        var flags = run.inlinePresentationIntent ?? []
                        flags.insert(intent)
                        segment[run.range].inlinePresentationIntent = flags
                    }
                    result += segment
                    break
                }
            }
            cursor = NSMaxRange(match.range)
        }
        if cursor < ns.length { result += plain(ns.substring(from: cursor), mentions: mentions, hashtagLinks: hashtagLinks) }
        return result
    }
    private static func plain(_ text: String, mentions: [Int64: String], hashtagLinks: Bool) -> AttributedString {
        let result = NSMutableAttributedString(attributedString: NSAttributedString(ChatMessageLinks.attributed(text)))
        let regex = try! NSRegularExpression(pattern: #":([A-Za-z0-9_+\-]+):"#)
        for match in regex.matches(in: result.string, range: NSRange(location: 0, length: result.length)).reversed() {
            guard result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil,
                  let emoji = ChatReactionKind(rawValue: (result.string as NSString).substring(with: match.range(at: 1))) else { continue }
            result.replaceCharacters(in: match.range, with: emoji.emoji)
        }
        return ChatHashtags.render(ChatMentions.render(AttributedString(result), names: mentions), enabled:hashtagLinks)
    }
}

struct NativeFormattedMessageBlock: View {
    let block: ChatMessageFormatting.Block
    var mentions: [Int64: String] = [:]
    var hashtagLinks = true
    var calendarLinks = false
    var body: some View {
        switch block.kind {
        case .paragraph:
            Text(ChatMessageFormatting.inline(block.text, mentions: mentions, hashtagLinks: hashtagLinks, calendarLinks: calendarLinks)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").accessibilityHidden(true)
                Text(ChatMessageFormatting.inline(block.text, mentions: mentions, hashtagLinks: hashtagLinks, calendarLinks: calendarLinks)).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(NativeChatColors.muted.opacity(0.5)).frame(width: 3)
                if let children = block.children {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                            // Erase the recursive branch while keeping the same
                            // literal-code/link/mention renderers at every level.
                            AnyView(NativeFormattedMessageBlock(block: child, mentions: mentions,
                                hashtagLinks: hashtagLinks, calendarLinks: calendarLinks))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(ChatMessageFormatting.inline(block.text, mentions: mentions, hashtagLinks: hashtagLinks, calendarLinks: calendarLinks)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 3)
        case .code:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Code").font(.caption).foregroundColor(NativeChatColors.muted)
                    Spacer()
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(block.text, forType: .string) }
                        .buttonStyle(.plain).font(.caption).foregroundColor(NativeChatColors.green).accessibilityLabel("Copy code")
                }
                ScrollView(.horizontal) {
                    Text(verbatim: block.text).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }.padding(12).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }
}
