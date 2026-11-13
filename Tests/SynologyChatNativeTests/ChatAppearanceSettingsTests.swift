import XCTest
@testable import SynologyChatNative

final class ChatAppearanceSettingsTests: XCTestCase {
    override func setUp() { super.setUp(); AppearanceSettingsProtocol.reset() }
    override func tearDown() { AppearanceSettingsProtocol.reset(); super.tearDown() }
    private func api() async throws -> ChatAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppearanceSettingsProtocol.self]
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://appearance-fixture.invalid")!, sid: "synthetic", synoToken: "synthetic"), network: URLSession(configuration: configuration))
        try await api.discover(); AppearanceSettingsProtocol.calls = []; return api
    }
    private func settings(_ style: ChatAppearanceStyle = .dark, _ background: ChatAppearanceBackground = .preset0) -> ChatAppearanceSettings {
        .init(style: style, background: background)
    }
    func testExactVendorCatalogueAndWireKeyEncoding() throws {
        XCTAssertEqual(ChatAppearanceStyle.allCases.map(\.rawValue), ["light", "dark"])
        XCTAssertEqual(ChatAppearanceBackground.allCases.map(\.rawValue), [0, 1, 2, 3])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings(.dark, .preset2))) as? [String: Any])
        XCTAssertEqual(object["theme_style"] as? String, "dark")
        XCTAssertEqual(object["theme_background"] as? Int, 2)
        XCTAssertEqual(Set(object.keys), ["theme_style", "theme_background"])
    }
    func testReaderUsesGetV4AndPreservesExactStyleAndBackground() async throws {
        let api = try await api()
        for style in ChatAppearanceStyle.allCases {
            for background in ChatAppearanceBackground.allCases {
                AppearanceSettingsProtocol.preferences = ["theme_style": style.rawValue, "theme_background": background.rawValue, "future_setting": ["untouched": true]]
                let value = try await api.appearanceSettings()
                XCTAssertEqual(value, settings(style, background))
                let call = try XCTUnwrap(AppearanceSettingsProtocol.calls.last)
                XCTAssertEqual(call["api"], "SYNO.Chat.User.Preference"); XCTAssertEqual(call["method"], "get"); XCTAssertEqual(call["version"], "4")
                XCTAssertNil(call["theme_style"]); XCTAssertNil(call["theme_background"])
            }
        }
    }
    func testUnknownMissingNullOrWrongTypeValuesNeverBecomeDefaults() async throws {
        let api = try await api()
        let invalid: [[String: Any]] = [[:], ["theme_style": "dark"], ["theme_background": 0],
            ["theme_style": "system", "theme_background": 0], ["theme_style": "DARK", "theme_background": 0],
            ["theme_style": NSNull(), "theme_background": 0], ["theme_style": true, "theme_background": 0],
            ["theme_style": "dark", "theme_background": NSNull()], ["theme_style": "dark", "theme_background": "0"],
            ["theme_style": "dark", "theme_background": true], ["theme_style": "dark", "theme_background": -1],
            ["theme_style": "dark", "theme_background": 4], ["theme_style": "dark", "theme_background": 1.5]]
        for fields in invalid {
            AppearanceSettingsProtocol.preferences = fields
            do { _ = try await api.appearanceSettings(); XCTFail("Unknown appearance was replaced with guessed defaults") } catch { }
        }
        for value: Any in [NSNull(), [], "dark"] {
            AppearanceSettingsProtocol.preferences = value
            do { _ = try await api.appearanceSettings(); XCTFail("Malformed preference envelope accepted") } catch { }
        }
    }
    func testPatchIncludesOnlyChangedFieldsAndComparesOnlyTouchedOriginalFields() throws {
        let original = settings(.dark, .preset1)
        let style = try ChatAppearanceSettingsPatch(original: original, desired: settings(.light, .preset1))
        XCTAssertEqual(style.style, .light); XCTAssertNil(style.background)
        XCTAssertEqual(Set(style.parameters.keys), ["theme_style"])
        XCTAssertTrue(style.matches(current: settings(.dark, .preset3), original: original))
        XCTAssertFalse(style.matches(current: settings(.light, .preset1), original: original))
        let background = try ChatAppearanceSettingsPatch(original: original, desired: settings(.dark, .preset2))
        XCTAssertNil(background.style); XCTAssertEqual(background.background, .preset2)
        XCTAssertEqual(Set(background.parameters.keys), ["theme_background"])
        XCTAssertTrue(background.matches(current: settings(.light, .preset1), original: original))
        XCTAssertFalse(background.matches(current: settings(.dark, .preset3), original: original))
        let both = try ChatAppearanceSettingsPatch(original: original, desired: settings(.light, .preset3))
        XCTAssertEqual(Set(both.parameters.keys), ["theme_style", "theme_background"])
        XCTAssertThrowsError(try ChatAppearanceSettingsPatch(original: original, desired: original))
    }
    func testSetWireSendsOnlyExplicitChangedFieldsAndAcceptsVoidSuccess() async throws {
        let api = try await api(), original = settings(.dark, .preset0)
        for desired in [settings(.light, .preset0), settings(.dark, .preset2), settings(.light, .preset3)] {
            let patch = try ChatAppearanceSettingsPatch(original: original, desired: desired)
            try await api.setAppearanceSettings(patch)
            let fields = try XCTUnwrap(AppearanceSettingsProtocol.calls.last)
            XCTAssertEqual(fields["api"], "SYNO.Chat.User.Preference"); XCTAssertEqual(fields["method"], "set"); XCTAssertEqual(fields["version"], "4")
            XCTAssertEqual(fields["theme_style"], patch.style.map { #""\#($0.rawValue)""# })
            XCTAssertEqual(fields["theme_background"], patch.background.map { String($0.rawValue) })
            for name in ["user_id", "preferences", "notification_mute", "sidebar_pinning_unread", "prefer_user_name_format"] { XCTAssertNil(fields[name]) }
        }
        XCTAssertEqual(AppearanceSettingsProtocol.calls.count, 3)
    }
    func testUnsupportedVersionFailsBeforeReadOrWriteAndServerFailureDoesNotRetry() async throws {
        AppearanceSettingsProtocol.maximumVersion = 3
        let old = try await api(), patch = try ChatAppearanceSettingsPatch(original: settings(), desired: settings(.light))
        do { _ = try await old.appearanceSettings(); XCTFail() } catch ChatAPIError.unsupportedAPI { }
        do { try await old.setAppearanceSettings(patch); XCTFail() } catch ChatAPIError.unsupportedAPI { }
        XCTAssertTrue(AppearanceSettingsProtocol.calls.isEmpty)
        AppearanceSettingsProtocol.maximumVersion = 4; let current = try await api()
        AppearanceSettingsProtocol.writeError = 117
        do { try await current.setAppearanceSettings(patch); XCTFail() } catch ChatAPIError.server(117) { }
        XCTAssertEqual(AppearanceSettingsProtocol.calls.count, 1)
    }
}

private final class AppearanceSettingsProtocol: URLProtocol {
    static var preferences: Any = ["theme_style": "dark", "theme_background": 0]
    static var calls: [[String: String]] = []
    static var maximumVersion = 4
    static var writeError: Int?
    static func reset() {
        preferences = ["theme_style": "dark", "theme_background": 0]
        calls = []; maximumVersion = 4; writeError = nil
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "appearance-fixture.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable && data.count < 16_384 {
                let count = stream.read(&bytes, maxLength: min(bytes.count, 16_384 - data.count))
                if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count))
            }
        }
        var form = URLComponents(); form.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        let items = (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []) + (form.queryItems ?? [])
        var fields = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        let api = fields["api"] ?? request.url!.lastPathComponent; fields["api"] = api
        let response: [String: Any]
        if api == "SYNO.API.Info" {
            response = ["success": true, "data": ["SYNO.Chat.User.Preference": ["path": "entry.cgi", "minVersion": 1, "maxVersion": Self.maximumVersion, "requestFormat": "JSON"]]]
        } else {
            Self.calls.append(fields)
            if fields["method"] == "set" {
                if let code = Self.writeError { response = ["success": false, "error": ["code": code]] }
                else { response = ["success": true] }
            } else { response = ["success": true, "data": ["preferences": Self.preferences]] }
        }
        let bytes = try! JSONSerialization.data(withJSONObject: response)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
