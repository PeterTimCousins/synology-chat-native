import Foundation

enum ServerAddressError: LocalizedError {
    case empty
    case invalid

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter a Synology server address."
        case .invalid:
            return "Enter a valid server address or full Synology Chat URL."
        }
    }
}

enum ServerAddress {
    static let chatLaunchApp = "SYNO.SDS.Chat.Application"

    static func normalizedChatURL(from input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServerAddressError.empty
        }

        var candidate = trimmed
        if isBareQuickConnectID(candidate) {
            candidate = "https://quickconnect.to/\(candidate)"
        }

        if !candidate.contains("://") {
            candidate = "https://\(candidate)"
        }

        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false
        else {
            throw ServerAddressError.invalid
        }

        if components.path.isEmpty {
            components.path = "/"
        }

        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "launchApp" }) {
            queryItems.append(URLQueryItem(name: "launchApp", value: chatLaunchApp))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw ServerAddressError.invalid
        }

        return url.absoluteString
    }

    private static func isBareQuickConnectID(_ input: String) -> Bool {
        !input.contains("://")
            && !input.contains(".")
            && !input.contains(":")
            && !input.contains("/")
            && !input.contains("?")
            && !input.contains("#")
    }
}
