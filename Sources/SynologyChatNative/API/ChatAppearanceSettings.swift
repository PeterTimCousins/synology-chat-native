import Foundation

/// Exact choices in the cached official ThemePanel/ThemeSwitcher. Background IDs
/// are intentionally neutral: the cached JavaScript does not identify artwork.
enum ChatAppearanceStyle: String, Codable, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
}
enum ChatAppearanceBackground: Int, Codable, CaseIterable, Identifiable {
    case preset0 = 0, preset1 = 1, preset2 = 2, preset3 = 3
    var id: Int { rawValue }
}
struct ChatAppearanceSettings: Codable, Equatable {
    let style: ChatAppearanceStyle
    let background: ChatAppearanceBackground
    private enum CodingKeys: String, CodingKey {
        case style = "theme_style", background = "theme_background"
    }
}
struct ChatAppearanceSettingsSnapshot: Equatable {
    let settings: ChatAppearanceSettings
    let accountGeneration: Int
}
struct ChatAppearanceSettingsPatch: Equatable {
    let style: ChatAppearanceStyle?
    let background: ChatAppearanceBackground?
    var isEmpty: Bool { style == nil && background == nil }
    init(original: ChatAppearanceSettings, desired: ChatAppearanceSettings) throws {
        style = original.style == desired.style ? nil : desired.style
        background = original.background == desired.background ? nil : desired.background
        guard !isEmpty else { throw ChatTransferError(message: "The appearance settings have not changed.") }
    }
    var parameters: [String: ChatParameter] {
        var fields: [String: ChatParameter] = [:]
        if let style { fields["theme_style"] = .string(style.rawValue) }
        if let background { fields["theme_background"] = .integer(Int64(background.rawValue)) }
        return fields
    }
    /// Compare only fields this edit touches. Concurrent unrelated preferences
    /// and an untouched appearance choice must not be overwritten or conflict.
    func matches(current: ChatAppearanceSettings, original: ChatAppearanceSettings) -> Bool {
        (style == nil || current.style == original.style)
            && (background == nil || current.background == original.background)
    }
}

extension ChatAPIClient {
    func appearanceSettings() async throws -> ChatAppearanceSettings {
        struct Result: Decodable { let preferences: ChatAppearanceSettings }
        let request = try requestForCall(api: "SYNO.Chat.User.Preference", method: "get", version: 4, parameters: [:])
        let result: Result = try await perform(request)
        return result.preferences
    }
    func setAppearanceSettings(_ patch: ChatAppearanceSettingsPatch) async throws {
        guard !patch.isEmpty else { throw ChatAPIError.invalidResponse }
        try await callVoid(api: "SYNO.Chat.User.Preference", method: "set", version: 4, parameters: patch.parameters)
    }
}
