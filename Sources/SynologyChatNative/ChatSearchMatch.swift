import Foundation

/// Search's vendor matcher scores ordered UTF-16 subsequences, not substrings.
/// Larger negative scores rank first; zero means no match and empty query is -1.
/// Iterate UTF-16 after lowercasing to preserve the browser's index arithmetic.
enum ChatSearchMatch {
    private static let caseLocale = Locale(identifier:"en_US_POSIX")
    static func score(_ text:String,query:String,caseSensitive:Bool = false) -> Double {
        guard !text.isEmpty else { return 0 }
        guard !query.isEmpty else { return -1 }
        // Foundation's contextual lowercasing includes Greek final sigma,
        // matching JavaScript; Swift's locale-free mapping does not.
        let text = Array((caseSensitive ? text : text.lowercased(with:caseLocale)).utf16)
        let query = Array((caseSensitive ? query : query.lowercased(with:caseLocale)).utf16)
        var matched = 0,last = 0,cost = 1.0
        for (offset,unit) in text.enumerated() {
            if unit == query[matched] {
                if matched == 0 { cost -= 1.0 / Double(offset+2) }
                else { cost += Double(offset-last) }
                last = offset;matched += 1
                if matched == query.count { return -cost }
            }
        }
        return 0
    }
}
