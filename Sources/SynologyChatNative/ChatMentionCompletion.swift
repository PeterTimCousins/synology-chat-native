import Foundation

enum ChatMentionCompletion {
    struct Trigger: Equatable { let range: NSRange; let query: String; let marker: Character }
    private static func tokenCharacter(_ c: Character) -> Bool {
        !c.isWhitespace && !c.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && !"@#:;/\\<>[]{}(),!?\"'`*|=+".contains(c)
    }
    static func trigger(text: String, selection: NSRange, marker: Character = "@") -> Trigger? {
        guard marker == "@" || marker == "#" else { return nil }
        let isTag = marker == "#"
        let allowed: (Character) -> Bool = { isTag ? ChatHashtags.valid(String($0)) : tokenCharacter($0) }
        guard selection.length == 0, let caret = ChatComposerEdit.validRange(selection, in: text)?.lowerBound else { return nil }
        var start = caret
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous] == marker { start = previous; break }
            guard allowed(text[previous]) else { return nil }
            start = previous
        }
        guard start < caret, text[start] == marker, start == text.startIndex || text[text.index(before: start)].isWhitespace else { return nil }
        guard !inCode(text[..<start]) else { return nil }
        let before = text[..<start]
        if let bracket = before.lastIndex(of: "["), before.lastIndex(of: "]").map({ $0 < bracket }) ?? true { return nil }
        let queryStart = text.index(after: start)
        let query = String(text[queryStart..<caret])
        guard query.utf16.count <= (isTag ? 32 : 64), query.allSatisfy(allowed) else { return nil }
        var end = caret
        while end < text.endIndex && allowed(text[end]) { end = text.index(after: end) }
        guard end == text.endIndex || text[end] != ":" else { return nil }
        return .init(range: NSRange(start..<end, in: text), query: query, marker: marker)
    }
    /// Track delimiter runs so inline backticks inside a fence cannot reopen
    /// suggestions. Unknown/unclosed spans fail closed until their delimiter.
    private static func inCode(_ text: Substring) -> Bool {
        var delimiter: Int?; var escaped = false; var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c == "`", !escaped {
                var end = index
                while end < text.endIndex, text[end] == "`" { end = text.index(after: end) }
                let count = text.distance(from: index, to: end)
                if let active = delimiter {
                    if active >= 3 ? count >= active : count == active { delimiter = nil }
                } else { delimiter = count }
                index = end; escaped = false; continue
            }
            if c == "\\" { escaped.toggle() } else { escaped = false }
            index = text.index(after: index)
        }
        return delimiter != nil
    }
    static func insert(hashtag: String, trigger: Trigger, text: String, selection: NSRange) -> ChatComposerEdit.Result? {
        guard ChatHashtags.valid(hashtag), self.trigger(text: text, selection: selection, marker: "#") == trigger else { return nil }
        return ChatComposerEdit.insert("#" + hashtag, into: text, selection: trigger.range, separated: true)
    }
    static func insert(userID: Int64, trigger: Trigger, text: String, selection: NSRange) -> ChatComposerEdit.Result? {
        guard userID > 0, self.trigger(text: text, selection: selection) == trigger else { return nil }
        return ChatComposerEdit.insert("@u:\(userID)", into: text, selection: trigger.range, separated: true)
    }
}
