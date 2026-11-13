import Foundation

struct ChatSearchFilters: Equatable {
    enum Content: String, CaseIterable, Identifiable {
        case any = "", file, vote
        var id: String { rawValue }
        var label: String { self == .any ? "Any message" : self == .file ? "Files" : "Polls" }
    }
    enum Attribute: String, CaseIterable, Identifiable {
        case any = "", url, reaction, pin, star
        var id: String { rawValue }
        var label: String {
            switch self { case .any: return "Any content"; case .url: return "Links"; case .reaction: return "Reactions"; case .pin: return "Pins"; case .star: return "Bookmarks" }
        }
    }
    var authorID: Int64?
    var mentionID: Int64?
    var content = Content.any
    var attribute = Attribute.any
    var fileType = ""
    var after: Date?
    var before: Date?
    var authorIDs: [Int64] = []
    var mentionIDs: [Int64] = []
    var channelIDs: [Int64] = []
    var contents: [Content] = []
    var attributes: [Attribute] = []
    var fileTypes: [String] = []
    var hashtags: [String] = []
    var isEmpty: Bool { authorID == nil && mentionID == nil && content == .any && attribute == .any && fileType.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && after == nil && before == nil && authorIDs.isEmpty && mentionIDs.isEmpty && channelIDs.isEmpty && contents.isEmpty && attributes.isEmpty && fileTypes.isEmpty && hashtags.isEmpty }
    static var localCalendar: Calendar { var value = Calendar(identifier:.gregorian); value.timeZone = .current; return value }
    func parameters(calendar: Calendar = Self.localCalendar) throws -> [String:ChatParameter] {
        var result: [String:ChatParameter] = [:]
        func unique<T:Hashable>(_ values:[T]) -> [T] { var seen = Set<T>();return values.filter{seen.insert($0).inserted} }
        for (key,values) in [("from",(authorID.map{[$0]} ?? []) + authorIDs),("mention",(mentionID.map{[$0]} ?? []) + mentionIDs),("in",channelIDs)] {
            let ids = unique(values)
            guard ids.count <= 100,ids.allSatisfy({$0 > 0}) else { throw ChatAPIError.invalidResponse }
            if !ids.isEmpty { result[key] = .array(ids.map(ChatParameter.integer)) }
        }
        let kinds = unique(([content]+contents).filter{$0 != .any}.map(\.rawValue))
        if !kinds.isEmpty { result["post_type"] = .array(kinds.map(ChatParameter.string)) }
        let attrs = unique(([attribute]+attributes).filter{$0 != .any}.map(\.rawValue))
        if !attrs.isEmpty { result["has"] = .array(attrs.map(ChatParameter.string)) }
        let extensions = unique(([fileType]+fileTypes).map{$0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()}.filter{!$0.isEmpty})
        guard extensions.count <= 100 else { throw ChatAPIError.invalidResponse }
        for ext in extensions {
            guard ext.range(of:#"^[a-z0-9]{1,16}$"#,options:.regularExpression) != nil else {
                throw ChatTransferError(message:"Use a file extension such as pdf, png or docx, without a dot.")
            }
        }
        if !extensions.isEmpty { result["file_type"] = .array(extensions.map(ChatParameter.string)) }
        guard hashtags.count <= 100,hashtags.allSatisfy(ChatHashtags.valid) else { throw ChatTransferError(message:"Enter a valid hashtag after #.") }
        if !hashtags.isEmpty { result["hashtag"] = .array(unique(hashtags).map(ChatParameter.string)) }
        var first: Date?; var last: Date?
        if let after {
            guard after.timeIntervalSince1970.isFinite, (1000...2999).contains(calendar.component(.year,from:after)) else { throw ChatTransferError(message:"Choose a start date between years 1000 and 2999.") }
            first = calendar.startOfDay(for:after)
            result["after"] = .integer(Int64((first!.timeIntervalSince1970 * 1000).rounded()))
        }
        if let before {
            guard before.timeIntervalSince1970.isFinite, (1000...2999).contains(calendar.component(.year,from:before)) else { throw ChatTransferError(message:"Choose an end date between years 1000 and 2999.") }
            let start = calendar.startOfDay(for:before)
            guard let next = calendar.date(byAdding:.day,value:1,to:start) else { throw ChatAPIError.invalidResponse }
            // Official dateToTime sets local 23:59:59, with zero milliseconds.
            last = next.addingTimeInterval(-1)
            result["before"] = .integer(Int64((last!.timeIntervalSince1970 * 1000).rounded()))
        }
        if let first, let last, first > last { throw ChatTransferError(message:"The start date must be on or before the end date.") }
        return result
    }
}
