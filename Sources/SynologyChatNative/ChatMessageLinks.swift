import Foundation
import AppKit

/// Web navigation is explicit and separate from authenticated NAS API requests.
enum ChatMessageLinks {
    static func renderedDestinations(_ text:String) -> Set<URL> {
        func links(_ blocks:[ChatMessageFormatting.Block]) -> [URL] {
            blocks.flatMap { block -> [URL] in
                if block.kind == .code { return [] }
                if let children = block.children { return links(children) }
                return ChatMessageFormatting.inline(block.text,hashtagLinks:false,calendarLinks:false).runs.compactMap { $0.link.flatMap { messageURL($0.absoluteString) } }
            }
        }
        return Set(links(ChatMessageFormatting.blocks(text)))
    }
    static func webURL(_ value: String) -> URL? {
        guard value.count <= 8192, let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              !(value.removingPercentEncoding ?? value).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !(parts.queryItems ?? []).contains(where: { ["_sid", "synotoken"].contains($0.name.lowercased()) }) else { return nil }
        return url
    }

    static func messageURL(_ value: String) -> URL? { webURL(value) ?? applicationURL(value) }

    /// The vendor message grammar allowlists LINE only. These destinations need
    /// a separate explicit application handoff; they are never web assets.
    static func applicationURL(_ value: String) -> URL? {
        let authority = value.dropFirst("line://".count).prefix { !"/?#".contains($0) }
        guard value.count <= 8192, value.hasPrefix("line://"),
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !value.contains("\\"), let decoded = value.removingPercentEncoding,
              !decoded.contains("\\"), !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: value), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "line", let host = parts.host, !host.isEmpty,
              !authority.contains(":"), !host.contains(":"), !host.contains("@"),
              parts.user == nil, parts.password == nil, parts.port == nil,
              !(parts.queryItems ?? []).contains(where: { ["_sid", "synotoken"].contains($0.name.lowercased()) }) else { return nil }
        return url
    }

    static func attributed(_ text: String) -> AttributedString {
        let result = NSMutableAttributedString(string: text)
        // Case-insensitive matching retains existing web behavior. LINE itself
        // is accepted only with the vendor's literal lowercase scheme.
        let labelled = try! NSRegularExpression(pattern: #"<((?:https?://|line://)[^<>\s|]+)\|([^<>]+)>"#, options: .caseInsensitive)
        for match in labelled.matches(in: result.string, range: NSRange(location: 0, length: result.length)).reversed() {
            let raw = (result.string as NSString).substring(with: match.range(at: 1))
            guard let url = messageURL(raw) else { continue }
            let label = (result.string as NSString).substring(with: match.range(at: 2))
            result.replaceCharacters(in: match.range, with: NSAttributedString(string: label, attributes: [.link: url]))
        }
        // Reserve every LINE-looking candidate, even an invalid one, so a
        // nested http URL cannot turn a rejected app link into a different link.
        let applications = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])line://[^\s<>]+"#, options: .caseInsensitive)
        let candidates = applications.matches(in: result.string, range: NSRange(location: 0, length: result.length))
        for match in candidates {
            guard result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil,
                  let url = applicationURL((result.string as NSString).substring(with: match.range)) else { continue }
            result.addAttribute(.link, value: url, range: match.range)
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: result.string, range: NSRange(location: 0, length: result.length)) {
                guard !candidates.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }),
                      result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil,
                      let raw = match.url?.absoluteString, let url = webURL(raw) else { continue }
                result.addAttribute(.link, value: url, range: match.range)
            }
        }
        return AttributedString(result)
    }
}

enum ChatMessageLinkSource { case body,botText(String),card(Int),library(String) }
struct ChatMessageLinkReview:Identifiable {
    let id = UUID()
    let post:ChatPost
    let channel:ChatChannel
    let destination:URL
    let source:ChatMessageLinkSource
    let accountGeneration:Int
    let keyGeneration:Int
    let requiresConfirmation:Bool
    var flaggedByServer = false
}
enum ChatMessageLinkOpenResult { case opened,confirmation(ChatMessageLinkReview) }
