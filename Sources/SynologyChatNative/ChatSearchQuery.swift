import Foundation

struct ChatSearchEntity {
    let id: Int64
    let label: String
    let aliases: [String]
    var canMention: Bool = true
}

extension ChatChannel {
    var supportsSearchSuggestion:Bool {
        id > 0 && !encrypted && is_closed != true && is_joined != false && (hide_global_at ?? 0) == 0
    }
}

/// Native text equivalent of Search.ConditionParser's typed nodes. Quoted
/// names are a native input convenience; transport always uses resolved IDs.
struct ChatSearchQuery {
    let keyword: String
    let filters: ChatSearchFilters
    struct Suggestion: Identifiable, Equatable {
        let id: String
        let label: String
        let replacement: String
        var group:String {
            if id.hasPrefix("from:u:") { return "People" }
            if id.hasPrefix("in:@c:") { return "Conversations" }
            if id.hasPrefix("@u:") { return "Mentions" }
            if id.hasPrefix("has:"),id != "has:" { return "Contains" }
            return "Search operators"
        }
        var symbol:String {
            switch group { case "People":return "person";case "Conversations":return "bubble.left.and.bubble.right";case "Mentions":return "at";case "Contains":return "line.3.horizontal.decrease.circle";default:return "magnifyingglass" }
        }
        var explanation:String? {
            switch id { case "in:":return "Choose a conversation";case "from:":return "Choose an author";case "has:":return "Files, links, reactions and more";case "before:":return "Before a date";case "after:":return "After a date";case "filetype:":return "For example, pdf or png";case "@":return "Messages mentioning a person";case "#":return "Messages with a hashtag";default:return nil }
        }
    }
    private static func tokens(_ text: String) throws -> [String] {
        guard text.utf16.count <= 4096 else { throw ChatTransferError(message:"Use a search shorter than 4,096 characters.") }
        var result:[String] = [],token = "",quoted = false,escaped = false
        for char in text {
            if escaped { token.append(char);escaped = false;continue }
            if quoted && char == "\\" { token.append(char);escaped = true;continue }
            if char == "\"" { quoted.toggle();token.append(char);continue }
            if char.isWhitespace && !quoted { if !token.isEmpty { result.append(token);token = "" } }
            else { token.append(char) }
        }
        guard !quoted else { throw ChatTransferError(message:"Close the quotation mark in this search.") }
        if !token.isEmpty { result.append(token) };return result
    }
    private static func name(_ value:String) throws -> String {
        if value.hasPrefix("\"") {
            guard let decoded = try? JSONDecoder().decode(String.self,from:Data(value.utf8)),!decoded.isEmpty else { throw ChatTransferError(message:"Enter a complete quoted name.") };return decoded
        }
        guard !value.isEmpty else { throw ChatTransferError(message:"Complete the search operator, or select a suggestion.") };return value
    }
    private static func resolve(_ value:String,canonicalPrefix:String,entities:[ChatSearchEntity],kind:String) throws -> Int64 {
        let value = try name(value)
        if value.hasPrefix(canonicalPrefix),let id = Int64(value.dropFirst(canonicalPrefix.count)),id > 0,entities.contains(where:{$0.id == id}) { return id }
        let matches = Set(entities.filter { entity in entity.aliases.contains { $0.caseInsensitiveCompare(value) == .orderedSame } }.map(\.id))
        guard matches.count == 1,let id = matches.first else { throw ChatTransferError(message:matches.count > 1 ? "That \(kind) name is ambiguous. Select a suggestion or use its unique name." : "No available \(kind) matches “\(value)”.") }
        return id
    }
    private static func date(_ value:String,calendar:Calendar) throws -> Date {
        guard value.range(of:#"^[0-9]{4}[\-/][0-9]{1,2}[\-/][0-9]{1,2}$"#,options:.regularExpression) != nil else { throw ChatTransferError(message:"Use a date in YYYY-MM-DD format.") }
        let parts = value.split(whereSeparator:{$0 == "-" || $0 == "/"})
        guard parts.count == 3,parts[0].count == 4,(1...2).contains(parts[1].count),(1...2).contains(parts[2].count),parts.allSatisfy({$0.allSatisfy(\.isNumber)}),let year = Int(parts[0]),let month = Int(parts[1]),let day = Int(parts[2]),(1000...2999).contains(year),
              let date = calendar.date(from:DateComponents(year:year,month:month,day:day)),calendar.component(.year,from:date) == year,calendar.component(.month,from:date) == month,calendar.component(.day,from:date) == day else {
            throw ChatTransferError(message:"Use a real date in YYYY-MM-DD format, between years 1000 and 2999.")
        }
        return date
    }
    static func parse(_ text:String,base:ChatSearchFilters = .init(),users:[ChatSearchEntity],channels:[ChatSearchEntity],fixedChannelID:Int64? = nil,calendar:Calendar = ChatSearchFilters.localCalendar) throws -> Self {
        var filters = base,words:[String] = []
        for token in try tokens(text) {
            if token.hasPrefix("from:") { filters.authorIDs.append(try resolve(String(token.dropFirst(5)),canonicalPrefix:"u:",entities:users,kind:"author")) }
            else if token.hasPrefix("in:") {
                let id = try resolve(String(token.dropFirst(3)),canonicalPrefix:"@c:",entities:channels,kind:"conversation")
                guard fixedChannelID == nil || fixedChannelID == id else { throw ChatTransferError(message:"This search is restricted to its current conversation.") };filters.channelIDs.append(id)
            } else if token.hasPrefix("has:") {
                switch token.dropFirst(4) {
                case "file":filters.contents.append(.file)
                case "vote":filters.contents.append(.vote)
                case "url":filters.attributes.append(.url)
                case "reaction":filters.attributes.append(.reaction)
                case "pin":filters.attributes.append(.pin)
                case "bookmark":filters.attributes.append(.star)
                default:throw ChatTransferError(message:"Use has:file, has:vote, has:url, has:reaction, has:pin or has:bookmark. Quote the token to search it literally.")
                }
            } else if token.hasPrefix("filetype:") { filters.fileTypes.append(try name(String(token.dropFirst(9)))) }
            else if token.hasPrefix("after:") { filters.after = try date(String(token.dropFirst(6)),calendar:calendar) }
            else if token.hasPrefix("before:") { filters.before = try date(String(token.dropFirst(7)),calendar:calendar) }
            else if token.hasPrefix("@") { filters.mentionIDs.append(try resolve(String(token.dropFirst()),canonicalPrefix:"u:",entities:users,kind:"person")) }
            else if token.hasPrefix("#") { filters.hashtags.append(String(token.dropFirst())) }
            else { words.append(token) }
        }
        _ = try filters.parameters(calendar:calendar)
        return .init(keyword:words.joined(separator:" "),filters:filters)
    }
    static let suggestionGroupLimit = 100
    private static let operators = ["in:","has:","before:","from:","after:","filetype:","@","#"]
    static func suggestions(_ text:String,users:[ChatSearchEntity],channels:[ChatSearchEntity]) -> [Suggestion] {
        guard let trigger = ChatSearchCompletion.trigger(text:text,selection:NSRange(location:text.utf16.count,length:0)) else { return [] }
        return suggestions(token:trigger.prefix,users:users,channels:channels)
    }
    static func suggestions(token raw:String,users:[ChatSearchEntity],channels:[ChatSearchEntity]) -> [Suggestion] {
        if raw.isEmpty { return operators.map { .init(id:$0,label:$0,replacement:$0) } }
        if raw == "before:" || raw == "after:" || raw.hasPrefix("filetype:") || raw.hasPrefix("#") { return [] }
        if raw.hasPrefix("has:") {
            let query = String(raw.dropFirst(4))
            return ranked(["url","file","reaction","pin","bookmark","vote"],query:query).map { .init(id:"has:"+$0,label:"has:"+$0,replacement:"has:"+$0) }
        }
        let prefix = raw.hasPrefix("from:") ? "from:" : raw.hasPrefix("in:") ? "in:" : raw.hasPrefix("@") ? "@" : ""
        guard !prefix.isEmpty else {
            guard !raw.contains(":"),!raw.contains("@"),!raw.contains("#"),!raw.contains("\"") else { return [] }
            let modifiers = ranked(Array(operators.prefix(6)),query:raw).map { Suggestion(id:$0,label:$0,replacement:$0) }
            return suggestions(token:"from:"+raw,users:users,channels:channels)
                + suggestions(token:"in:"+raw,users:users,channels:channels) + modifiers
        }
        let value = String(raw.dropFirst(prefix.count))
        let query:String
        if value.hasPrefix("\"") {
            query = (try? JSONDecoder().decode(String.self,from:Data(value.utf8))) ?? String(value.dropFirst()).replacingOccurrences(of:"\\\"",with:"\"")
        } else { query = value }
        let source = prefix == "in:" ? channels : users
        var seen:Set<Int64> = []
        let entities = source.filter { $0.id > 0 && seen.insert($0.id).inserted }
        // Resolve friendly aliases once per group rather than scanning the full
        // directory separately for each of the hundred visible candidates.
        func aliasKey(_ value:String) -> String { value.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX")).precomposedStringWithCanonicalMapping }
        var aliasOwners:[String:Set<Int64>] = [:]
        for entity in entities { for alias in entity.aliases { aliasOwners[aliasKey(alias),default:[]].insert(entity.id) } }
        let matches = entities.enumerated().compactMap { index,entity -> (Int,ChatSearchEntity,Double)? in
            guard prefix != "@" || entity.canMention else { return nil }
            let scores = entity.aliases.map { ChatSearchMatch.score($0,query:query) }.filter { $0 != 0 }
            let score:Double? = query.isEmpty ? -1 : scores.max()
            guard let score else { return nil };return (index,entity,score)
        }.sorted { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 > $1.2 }
        return matches.prefix(suggestionGroupLimit).map { _,entity,_ in
            let canonical = prefix == "in:" ? "in:@c:\(entity.id)" : prefix == "from:" ? "from:u:\(entity.id)" : "@u:\(entity.id)"
            let namespace = prefix == "in:" ? "@c:" : "u:"
            let uniqueName = entity.aliases.first { alias in
                !alias.isEmpty && aliasOwners[aliasKey(alias)]?.count == 1
                    && !(alias.hasPrefix(namespace) && Int64(alias.dropFirst(namespace.count)).map { $0 > 0 } == true)
            }
            let replacement:String
            if let uniqueName {
                let escaped = String(decoding:try! JSONEncoder().encode(uniqueName),as:UTF8.self)
                replacement = prefix + (uniqueName.contains(where:{$0.isWhitespace || $0 == "\"" || $0 == "\\"}) ? escaped : uniqueName)
            } else { replacement = canonical }
            return .init(id:canonical,label:prefix+entity.label,replacement:replacement)
        }
    }
    private static func ranked(_ choices:[String],query:String) -> [String] {
        choices.enumerated().compactMap { index,value -> (Int,String,Double)? in
            let score = ChatSearchMatch.score(value,query:query);return score == 0 ? nil : (index,value,score)
        }.sorted { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 > $1.2 }.map { $0.1 }
    }
    static func applying(_ suggestion:Suggestion,to text:String) -> String {
        let prefix = text.lastIndex(where:{$0.isWhitespace}).map{String(text[...$0])} ?? ""
        return prefix+suggestion.replacement+" "
    }
}
