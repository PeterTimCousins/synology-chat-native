import Foundation

enum ChatSearchCompletion {
    struct Trigger: Equatable {
        let source: String
        let selection: NSRange
        let range: NSRange
        let prefix: String
    }
    static func trigger(text:String,selection:NSRange) -> Trigger? {
        guard selection.length == 0,let caret = ChatComposerEdit.validRange(selection,in:text)?.lowerBound else { return nil }
        var start = text.startIndex,quoted = false,escaped = false
        var spans:[Range<String.Index>] = []
        for index in text.indices {
            let char = text[index]
            if escaped { escaped = false;continue }
            if quoted && char == "\\" { escaped = true;continue }
            if char == "\"" { quoted.toggle();continue }
            if char.isWhitespace && !quoted {
                if start < index { spans.append(start..<index) };start = text.index(after:index)
            }
        }
        if start < text.endIndex { spans.append(start..<text.endIndex) }
        if let range = spans.first(where:{$0.lowerBound < caret && caret <= $0.upperBound}) {
            guard !text[range].hasPrefix("\"") else { return nil }
            return .init(source:text,selection:selection,range:NSRange(range,in:text),prefix:String(text[range.lowerBound..<caret]))
        }
        // An empty slot offers operators without replacing either adjacent
        // word. Spaces inside quoted spans were handled above, never here.
        let previousIsSpace = caret > text.startIndex && text[text.index(before:caret)].isWhitespace
        let nextIsSpaceOrEnd = caret == text.endIndex || text[caret].isWhitespace
        guard (text.isEmpty || previousIsSpace || caret == text.startIndex),nextIsSpaceOrEnd else { return nil }
        return .init(source:text,selection:selection,range:selection,prefix:"")
    }
    static func applying(_ suggestion:ChatSearchQuery.Suggestion,trigger:Trigger,text:String,selection:NSRange) -> ChatComposerEdit.Result? {
        guard Self.trigger(text:text,selection:selection) == trigger else { return nil }
        let needsValue = suggestion.replacement.hasSuffix(":") || ["@","#"].contains(suggestion.replacement)
        return ChatComposerEdit.insert(suggestion.replacement,into:text,selection:trigger.range,separated:!needsValue)
    }
}
