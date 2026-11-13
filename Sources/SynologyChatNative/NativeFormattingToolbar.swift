import SwiftUI

extension ChatComposerEdit {
    enum Style: CaseIterable {
        case bold, italic, strike, code, quote, bullet, codeBlock
        var label: String {
            switch self {
            case .bold: return "Bold"
            case .italic: return "Italic"
            case .strike: return "Strikethrough"
            case .code: return "Inline code"
            case .quote: return "Quote"
            case .bullet: return "Bulleted list"
            case .codeBlock: return "Code block"
            }
        }
        var symbol: String {
            switch self {
            case .bold: return "bold"
            case .italic: return "italic"
            case .strike: return "strikethrough"
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .quote: return "text.quote"
            case .bullet: return "list.bullet"
            case .codeBlock: return "curlybraces"
            }
        }
        var marker: String? {
            switch self { case .bold: return "*"; case .italic: return "_"; case .strike: return "~"; case .code: return "`"; default: return nil }
        }
    }
    static func format(_ style: Style, text: String, selection: NSRange) -> Result {
        var range = validRange(selection, in: text) ?? text.endIndex..<text.endIndex
        var original = String(text[range])
        let initiallySelectedLength = original.utf16.count
        var expandedMarkers = 0
        func replace(_ range: Range<String.Index>, _ value: String, selectedOffset: Int = 0, selectedLength: Int? = nil) -> Result {
            let prefix = String(text[..<range.lowerBound]); let suffix = String(text[range.upperBound...])
            return .init(text: prefix + value + suffix, selection: NSRange(location: prefix.utf16.count + selectedOffset, length: selectedLength ?? value.utf16.count))
        }
        if let marker = style.marker {
            // Preserve existing nested emphasis without inserting spaces between
            // delimiters. Keep the original inner content selected afterward.
            if marker != "`", !original.contains("\n") {
                while let left = text[..<range.lowerBound].last, let right = text[range.upperBound...].first,
                      left == right, ["*", "_", "~"].contains(String(left)), String(left) != marker {
                    range = text.index(before:range.lowerBound)..<text.index(after:range.upperBound)
                    expandedMarkers += 1; original = String(text[range])
                }
            }
            // Clicking again while the inner text is selected removes its delimiters.
            if text[..<range.lowerBound].hasSuffix(marker), text[range.upperBound...].hasPrefix(marker) {
                let expanded = text.index(before: range.lowerBound)..<text.index(after: range.upperBound)
                return replace(expanded, original, selectedOffset:expandedMarkers,selectedLength:initiallySelectedLength)
            }
            if original.contains("\n") {
                let lines = original.components(separatedBy: "\n")
                let transformed = lines.map { line -> String in
                    let leading = String(line.prefix(while: \.isWhitespace))
                    let trailing = String(line.reversed().prefix(while: \.isWhitespace).reversed())
                    let core = line.trimmingCharacters(in: .whitespaces)
                    guard !core.isEmpty else { return line }
                    let body = core.hasPrefix(marker) && core.hasSuffix(marker) && core.count >= 2 ? String(core.dropFirst().dropLast()) : marker + core + marker
                    return leading + body + trailing
                }.joined(separator: "\n")
                return replace(range, transformed)
            }
            let leading = String(original.prefix(while: \.isWhitespace))
            let core = original.trimmingCharacters(in: .whitespaces)
            let trailing = core.isEmpty ? "" : String(original.reversed().prefix(while: \.isWhitespace).reversed())
            if core.hasPrefix(marker), core.hasSuffix(marker), core.count >= 2 {
                return replace(range, leading + String(core.dropFirst().dropLast()) + trailing)
            }
            let before = leading.isEmpty && text[..<range.lowerBound].last.map { !$0.isWhitespace } == true ? " " : ""
            let after = trailing.isEmpty && text[range.upperBound...].first.map { !$0.isWhitespace } == true ? " " : ""
            let value = before + leading + marker + core + marker + trailing + after
            return replace(range, value, selectedOffset: before.utf16.count + leading.utf16.count + marker.utf16.count + expandedMarkers, selectedLength: max(0,core.utf16.count - expandedMarkers * 2))
        }
        if style == .codeBlock {
            if text[..<range.lowerBound].hasSuffix("```\n"), text[range.upperBound...].hasPrefix("\n```") {
                return replace(text.index(range.lowerBound,offsetBy:-4)..<text.index(range.upperBound,offsetBy:4),original)
            }
            // The backend dialect has no escape for nested triple-backtick fences.
            guard !original.contains("```") else { return .init(text:text,selection:selection) }
            let before = range.lowerBound != text.startIndex && text[..<range.lowerBound].last != "\n" ? "\n" : ""
            let after = range.upperBound != text.endIndex && text[range.upperBound...].first != "\n" ? "\n" : ""
            let body = before + "```\n" + original + "\n```" + after
            return replace(range,body,selectedOffset:before.utf16.count + 4,selectedLength:original.utf16.count)
        }
        // Lists and quotes act on complete lines, even with a word selected.
        let ns = text as NSString
        let whole = ns.lineRange(for: NSRange(range,in:text))
        guard let linesRange = validRange(whole,in:text) else { return .init(text:text,selection:selection) }
        let source = String(text[linesRange]); let marker = style == .quote ? "> " : "* "
        var lines = source.components(separatedBy:"\n")
        let trailingNewline = lines.last == "" && source.hasSuffix("\n")
        if trailingNewline { lines.removeLast() }
        let remove = !lines.isEmpty && lines.allSatisfy { $0.hasPrefix(marker) }
        let transformed = lines.map { remove ? String($0.dropFirst(marker.count)) : marker + $0 }.joined(separator:"\n") + (trailingNewline ? "\n" : "")
        func mapped(_ position: Int) -> Int {
            var old = 0; var new = 0
            for line in lines {
                let count = line.utf16.count
                if position <= old + count {
                    return new + (remove ? max(0,position - old - marker.utf16.count) : position - old + marker.utf16.count)
                }
                old += count + 1
                new += count + (remove ? -marker.utf16.count : marker.utf16.count) + 1
            }
            return transformed.utf16.count
        }
        let selected = NSRange(range,in:text)
        let start = mapped(selected.location - whole.location)
        let end = mapped(NSMaxRange(selected) - whole.location)
        return replace(linesRange,transformed,selectedOffset:start,selectedLength:max(0,end-start))
    }
}

struct NativeFormattingToolbar: View {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var focused: Bool
    var body: some View {
        HStack(spacing: 3) {
            ForEach(ChatComposerEdit.Style.allCases, id: \.self) { style in
                Button {
                    let edit = ChatComposerEdit.format(style,text:text,selection:selection)
                    text = edit.text; selection = edit.selection; focused = true
                } label: { Image(systemName:style.symbol) }
                    .buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel(style.label + " selection")
                    .help(style.label + (style == .bold ? " (⌘B)" : style == .italic ? " (⌘I)" : style == .codeBlock ? " (⌘⇧C)" : ""))
                if style == .code {
                    Rectangle().fill(NativeChatColors.separator).frame(width:1,height:14).padding(.horizontal,5).accessibilityHidden(true)
                }
            }
            Spacer(minLength:0)
        }.accessibilityElement(children:.contain).accessibilityLabel("Message formatting")
    }
}
