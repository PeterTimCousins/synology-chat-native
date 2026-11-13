#if DEBUG
import Foundation

/// Read-only research of the official client's fixed, same-server theme assets.
/// Never accepts arbitrary asset URLs or records session credentials.
enum ChatAppearanceContractProbe {
    static func run(directory: URL) async -> Bool {
        do {
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw ChatAPIError.invalidResponse }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let account = try OfficialChatSessionLoader.load()
            let api = try ChatAPIClient(session: account.session)
            try await api.discover()
            let owners = try await api.users().filter { $0.username?.caseInsensitiveCompare(account.username) == .orderedSame }
            guard owners.count == 1, let owner = owners.first, [6, 10].contains(owner.user_id),
                  owner.is_disabled != true, (owner.delete_at ?? 0) == 0 else { throw ChatAPIError.invalidResponse }
            for style in ["light", "dark"] {
                let url = account.session.baseURL.appendingPathComponent("webman/3rdparty/Chat/" + style + ".css")
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 30
                let (bytes, response) = try await api.network.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.mimeType == "text/css", !bytes.isEmpty, bytes.count <= 2 * 1024 * 1024,
                      String(data: bytes, encoding: .utf8) != nil else { throw ChatAPIError.invalidResponse }
                let file = directory.appendingPathComponent(style + ".css")
                try bytes.write(to: file, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                print("Retained official \(style) stylesheet (\(bytes.count) bytes). No account preferences changed.")
            }
            let settings = try await api.appearanceSettings()
            try JSONEncoder().encode(settings).write(to: directory.appendingPathComponent("account-appearance.json"), options: .withoutOverwriting)
            for style in ChatAppearanceStyle.allCases {
                for background in ChatAppearanceBackground.allCases where background.rawValue != 0 {
                    let settings = ChatAppearanceSettings(style: style, background: background)
                    guard let bytes = try await api.appearanceWallpaper(settings) else { throw ChatAPIError.invalidResponse }
                    let file = directory.appendingPathComponent("wallpaper_\(style.rawValue)_0\(background.rawValue).jpg")
                    try bytes.write(to: file, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    print("Retained fixed \(style.rawValue) background\(background.rawValue) (\(bytes.count) bytes).")
                }
            }
            return true
        } catch {
            print("Read-only appearance asset check failed. No account preferences changed; no credentials recorded.")
            return false
        }
    }
}
#endif
