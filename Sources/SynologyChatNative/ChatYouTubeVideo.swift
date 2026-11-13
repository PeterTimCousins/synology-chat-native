import Foundation

/// A video identity, rather than an arbitrary URL forwarded into the player.
/// Canonical destinations contain only the reviewed ID and bounded start time.
struct ChatYouTubeVideo: Equatable, Sendable {
    let id: String
    let startSeconds: Int?

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == (scheme == "https" ? 443 : 80),
              let host = parts.host?.lowercased(),
              parts.percentEncodedHost?.lowercased() == host else { return nil }
        let fullHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com",
                                     "youtube-nocookie.com", "www.youtube-nocookie.com"]
        guard host == "youtu.be" || fullHosts.contains(host) else { return nil }
        let items = parts.queryItems ?? []
        let videoValues = items.filter { $0.name == "v" }
        let startValues = items.filter { $0.name == "start" }
        let timeValues = items.filter { $0.name == "t" }
        guard videoValues.count <= 1, startValues.count <= 1, timeValues.count <= 1 else { return nil }

        let path = parts.percentEncodedPath
        let candidate: String
        if host == "youtu.be" {
            guard path.hasPrefix("/") else { return nil }
            candidate = String(path.dropFirst())
        } else if path == "/watch" {
            guard let value = videoValues.first?.value else { return nil }
            candidate = value
        } else {
            let segments = path.split(separator: "/", omittingEmptySubsequences: false)
            guard segments.count == 3, segments[0].isEmpty,
                  ["embed", "v", "shorts"].contains(String(segments[1])) else { return nil }
            candidate = String(segments[2])
        }
        guard Self.validID(candidate),
              videoValues.isEmpty || videoValues[0].value == candidate else { return nil }
        var start: Int?
        if let item = startValues.first {
            guard let value = item.value, let seconds = Self.decimalSeconds(value) else { return nil }
            start = seconds
        }
        if let item = timeValues.first {
            guard let value = item.value, let seconds = Self.timeSeconds(value),
                  start == nil || start == seconds else { return nil }
            start = seconds
        }
        id = candidate
        startSeconds = start
    }

    var embedURL: URL {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "www.youtube-nocookie.com"; parts.path = "/embed/" + id
        parts.queryItems = [.init(name: "autoplay", value: "0"), .init(name: "playsinline", value: "1")]
        if let startSeconds { parts.queryItems?.append(.init(name: "start", value: String(startSeconds))) }
        return parts.url!
    }

    var watchURL: URL {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "www.youtube.com"; parts.path = "/watch"
        parts.queryItems = [.init(name: "v", value: id)]
        if let startSeconds { parts.queryItems?.append(.init(name: "t", value: "\(startSeconds)s")) }
        return parts.url!
    }

    private static func validID(_ value: String) -> Bool {
        value.utf8.count == 11 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
    private static func decimalSeconds(_ value: String) -> Int? {
        guard !value.isEmpty, value.utf8.count <= 6,
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              let seconds = Int(value), seconds <= 86_400 else { return nil }
        return seconds
    }
    private static func timeSeconds(_ value: String) -> Int? {
        if let seconds = decimalSeconds(value) { return seconds }
        guard !value.isEmpty, value.utf8.count <= 24 else { return nil }
        var total = 0, digits = "", previousUnit = 0
        for byte in value.utf8 {
            if (48...57).contains(byte) { digits.append(Character(UnicodeScalar(byte))); continue }
            let unit: Int, multiplier: Int
            switch byte {
            case 104: unit = 1; multiplier = 3600 // h
            case 109: unit = 2; multiplier = 60   // m
            case 115: unit = 3; multiplier = 1   // s
            default: return nil
            }
            guard unit > previousUnit, let component = decimalSeconds(digits),
                  component <= (86_400 - total) / multiplier else { return nil }
            total += component * multiplier; previousUnit = unit; digits = ""
        }
        guard digits.isEmpty, previousUnit > 0 else { return nil }
        return total
    }
}
