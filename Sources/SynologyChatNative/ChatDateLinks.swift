import Foundation
import SwiftUI

/// Foundation detection deliberately stays outside code, mentions and web links.
/// Its language coverage differs from the official client's chrono parser.
enum ChatDateLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    struct Selection: Identifiable {
        let date: Date
        let allDay: Bool
        let text: String
        var id: String { destination.absoluteString }
        var destination: URL {
            var c = URLComponents(); c.scheme = "synology-chat-calendar"; c.host = "event"
            c.queryItems = [.init(name: "date", value: String(Int64(date.timeIntervalSince1970))), .init(name: "allDay", value: allDay ? "1" : "0"), .init(name: "text", value: text)]
            return c.url!
        }
    }
    static func selection(_ url: URL) -> Selection? {
        guard url.scheme == "synology-chat-calendar", url.host == "event", url.path.isEmpty,
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, q.count == 3,
              q.map(\.name) == ["date", "allDay", "text"], let raw = q[0].value, let seconds = Int64(raw), seconds >= 0, seconds <= 253_402_214_400,
              let allDay = q[1].value, ["0", "1"].contains(allDay), let text = q[2].value, !text.isEmpty, text.utf16.count <= 1000 else { return nil }
        return .init(date: Date(timeIntervalSince1970: Double(seconds)), allDay: allDay == "1", text: text)
    }
    static func render(_ value: AttributedString, enabled: Bool) -> AttributedString {
        guard enabled else { return value }
        let source = String(value.characters)
        guard source.utf16.count <= 16_384, let detector else { return value }
        var result = value
        for match in detector.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let date = match.date, date.timeIntervalSince1970 >= 0, date.timeIntervalSince1970 <= 253_402_214_400,
                  let raw = Range(match.range, in: source), let start = AttributedString.Index(raw.lowerBound, within: result), let end = AttributedString.Index(raw.upperBound, within: result),
                  !result[start..<end].runs.contains(where: { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true }) else { continue }
            let label = String(source[raw])
            let timed = label.range(of: #"(?i)(\d{1,2}:\d{2}|\d\s*(am|pm)\b|\b(noon|midnight)\b|\bat\s+\d)"#, options: .regularExpression) != nil
            let selected = Selection(date: date, allDay: !timed, text: label)
            result[start..<end].link = selected.destination
            result[start..<end].foregroundColor = NativeChatColors.green
        }
        return result
    }
}
