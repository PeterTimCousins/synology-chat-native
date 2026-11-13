import Foundation

struct NativeSnippetDraft:Equatable {
    static let maximumBytes = 1 << 20
    var filename = "Untitled.txt"
    var caption = ""
    var content = ""
    var lineCount:Int { content.reduce(1) { $1.isNewline ? $0+1 : $0 } }
    /// Normalize only the bounded visual excerpt; the full draft stays byte-exact.
    static func preview(_ content:String,lines:Int = 12) -> String {
        guard lines > 0 else { return "" }
        return String(content.split(maxSplits:lines,omittingEmptySubsequences:false,whereSeparator:{ $0.isNewline }).prefix(lines).joined(separator:"\n").prefix(12000))
    }
    static func previewIsTruncated(_ content:String,lines:Int = 12) -> Bool {
        NativeSnippetDraft(content:content).lineCount > lines || content.count > 12000
    }
    func hasSameBytes(as other:Self) -> Bool {
        filename.utf8.elementsEqual(other.filename.utf8) && caption.utf8.elementsEqual(other.caption.utf8) && content.utf8.elementsEqual(other.content.utf8)
    }
    // SwiftUI draft-change observation must retain Unicode encoding changes too.
    static func == (lhs:Self,rhs:Self) -> Bool { lhs.hasSameBytes(as:rhs) }
    func validated() throws -> Self {
        var value = self;value.filename = filename.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.filename.isEmpty,value.filename != ".lease",value.filename.utf8.count <= 255,ChatMultipartBody.safeFilename(value.filename) == value.filename else { throw ChatTransferError(message:"Enter a filename of up to255 bytes without folders or control characters.") }
        guard !content.isEmpty,!content.contains("\0") else { throw ChatTransferError(message:"Enter some snippet text without null characters.") }
        guard content.utf8.count <= Self.maximumBytes else { throw ChatTransferError(message:"Snippets can contain up to1MiB of UTF-8 text.") }
        guard ChatMessageText.isAllowed(caption) else { throw ChatTransferError(message:"Keep the description within2,000 characters.") }
        return value
    }
    /// Staging only: no upload or automatic send happens here.
    func writeTemporary() throws -> URL {
        let value = try validated(),file = try NativeSnippetTemporaryFiles.shared.create(filename:value.filename)
        do { try Data(value.content.utf8).write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path);return file }
        catch { NativeSnippetTemporaryFiles.shared.remove(file);throw error }
    }
}

struct NativeSyntaxToken:Equatable {
    enum Kind { case keyword,string,number,comment }
    let range:NSRange
    let kind:Kind
}
/// A bounded linear lexer, never an evaluator. Unknown language modes remain plain text.
enum NativeSnippetSyntax {
    static func tokens(_ text:String,language:String) throws -> [NativeSyntaxToken] {
        guard text.utf8.count <= NativeSnippetDraft.maximumBytes else { return [] }
        let hash = ["python","ruby","r","sh","yaml","powershell"].contains(language)
        let sql = ["sql","mysql","pgsql"].contains(language)
        let markup = ["xml","html"].contains(language)
        let c = ["swift","javascript","typescript","java","c_cpp","csharp","kotlin","golang","rust","css","json"].contains(language)
        guard hash || sql || markup || c else { return [] }
        let keywords:Set<String> = Set((sql ? "select from where join inner outer left right on as and or not null true false insert into values update set delete create table index drop alter group by having order asc desc limit distinct union case when then else end" : language == "python" ? "False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield" : "let var const func function class struct enum protocol extension import return if else for while switch case break continue default guard throw throws try catch async await public private internal static final override self super true false null nil new void int string boolean typeof interface type export package in is as do where defer") .split(separator:" ").map(String.init))
        let units = Array(text.utf16);var i = 0;var result:[NativeSyntaxToken] = []
        func match(_ value:[UInt16],at index:Int)->Bool { index+value.count <= units.count && Array(units[index..<index+value.count]) == value }
        func identifier(_ u:UInt16)->Bool { (65...90).contains(u) || (97...122).contains(u) || u == 95 || u == 36 || u > 127 }
        func digit(_ u:UInt16)->Bool { (48...57).contains(u) }
        while i < units.count {
            if i % 4096 == 0 { try Task.checkCancellation() }
            let start = i,u = units[i]
            let lineComment = (hash && u == 35) || (sql && match([45,45],at:i)) || (c && language != "json" && match([47,47],at:i))
            if lineComment { while i < units.count && units[i] != 10 { i += 1 };result.append(.init(range:.init(location:start,length:i-start),kind:.comment));continue }
            let block = c && language != "json" && match([47,42],at:i),htmlComment = markup && match([60,33,45,45],at:i)
            if block || htmlComment {
                let close:[UInt16] = block ? [42,47] : [45,45,62];i += block ? 2 : 4
                while i < units.count && !match(close,at:i) { i += 1 }
                i = min(units.count,i+close.count);result.append(.init(range:.init(location:start,length:i-start),kind:.comment));continue
            }
            if u == 34 || u == 39 || (c && u == 96) {
                i += 1
                while i < units.count { let current = units[i];i += 1;if current == 92 { i = min(units.count,i+1) } else if current == u { break } }
                result.append(.init(range:.init(location:start,length:i-start),kind:.string));continue
            }
            if identifier(u) {
                i += 1;while i < units.count && (identifier(units[i]) || digit(units[i])) { i += 1 }
                let word = String(decoding:units[start..<i],as:UTF16.self)
                if keywords.contains(sql ? word.lowercased() : word) { result.append(.init(range:.init(location:start,length:i-start),kind:.keyword)) };continue
            }
            if digit(u) { i += 1;while i < units.count && (digit(units[i]) || units[i] == 46 || units[i] == 95) { i += 1 };result.append(.init(range:.init(location:start,length:i-start),kind:.number));continue }
            i += 1
        }
        return result
    }
}

enum NativeSnippetTemporaryFiles {
    static let shared = NativeMediaTemporaryFiles(purpose:"upload",acceptsFilename:{ !$0.isEmpty && $0 != ".lease" && $0.utf8.count <= 255 && ChatMultipartBody.safeFilename($0) == $0 })
}
