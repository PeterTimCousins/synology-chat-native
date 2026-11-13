import AppKit
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeAppearanceSettingsTests:XCTestCase {
    override func setUp() { super.setUp();AppearanceSettingsProtocol.reset() }
    override func tearDown() { AppearanceSettingsProtocol.reset();super.tearDown() }
    private func account(_ username:String = "owner")->ChatAccount {
        .init(session:.init(baseURL:URL(string:"https://appearance.synthetic.invalid/proxy/")!,sid:"synthetic-appearance-sid",synoToken:"synthetic-appearance-token"),username:username,importedFromOfficialApp:false)
    }
    private func network()->URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AppearanceSettingsProtocol.self];config.urlCache = nil;config.httpShouldSetCookies = false
        return URLSession(configuration:config,delegate:NoChatRedirects(),delegateQueue:nil)
    }
    private func model() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in try ChatAPIClient(session:session,network:self.network()) })
        await model.connect(using:account());XCTAssertTrue(model.connected)
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    private func settings(_ style:ChatAppearanceStyle,_ background:ChatAppearanceBackground)->ChatAppearanceSettings { .init(style:style,background:background) }
    private func root() throws -> ChatPost {
        try JSONDecoder().decode(ChatPost.self,from:Data(#"{"post_id":500,"channel_id":93,"creator_id":10,"type":"normal","message":"Synthetic root","create_at":1}"#.utf8))
    }
    func testChangedStylePreservesConcurrentBackgroundAndExactUnsentDraftsAndSelection() async throws {
        let model = try await model(),original = try await model.loadAppearanceSettings()
        model.selection = 93;model.draft = "Unsent main 👋\nexact spacing  "
        model.threadRoot = try root();model.replyDraft = "Unsent reply 🌍\nretained  "
        let main = model.drafts,replies = model.threadDrafts,selection = model.selection,thread = model.threadRoot?.id
        AppearanceSettingsProtocol.background = 2
        AppearanceSettingsProtocol.unrelated = ["notification_mute":true,"custom":["preserve":123]]
        let saved = try await model.saveAppearanceSettings(original:original,desired:settings(.dark,.preset0))
        XCTAssertEqual(saved.settings,settings(.dark,.preset2));XCTAssertEqual(model.appearanceSettings,saved.settings)
        XCTAssertEqual(model.drafts,main);XCTAssertEqual(model.threadDrafts,replies)
        XCTAssertEqual(model.selection,selection);XCTAssertEqual(model.threadRoot?.id,thread)
        XCTAssertEqual(AppearanceSettingsProtocol.writes.count,1)
        let write = try XCTUnwrap(AppearanceSettingsProtocol.writes.first)
        XCTAssertEqual(write["theme_style"],"\"dark\"");XCTAssertNil(write["theme_background"])
        XCTAssertEqual(Set(write.keys),["api","method","version","theme_style"])
        XCTAssertEqual(AppearanceSettingsProtocol.background,2)
        XCTAssertEqual(AppearanceSettingsProtocol.unrelated["notification_mute"] as? Bool,true)
        XCTAssertEqual((AppearanceSettingsProtocol.unrelated["custom"] as? [String:Int])?["preserve"],123)
        XCTAssertFalse(model.appearanceSettingsBusy);XCTAssertFalse(model.appearanceSettingsNeedRefresh)
    }
    func testChangedBackgroundPreservesConcurrentStyleAndOnlyWritesBackground() async throws {
        let model = try await model(),original = try await model.loadAppearanceSettings()
        AppearanceSettingsProtocol.style = "dark"
        let saved = try await model.saveAppearanceSettings(original:original,desired:settings(.light,.preset3))
        XCTAssertEqual(saved.settings,settings(.dark,.preset3))
        let write = try XCTUnwrap(AppearanceSettingsProtocol.writes.first)
        XCTAssertEqual(write["theme_background"],"3");XCTAssertNil(write["theme_style"])
        XCTAssertEqual(Set(write.keys),["api","method","version","theme_background"])
    }
    func testStaleTouchedStyleOrBackgroundCannotDispatchEvenIfDesiredMatchesServer() async throws {
        let model = try await model(),original = try await model.loadAppearanceSettings()
        AppearanceSettingsProtocol.style = "dark"
        do {
            _ = try await model.saveAppearanceSettings(original:original,desired:settings(.dark,.preset0));XCTFail("Stale style dispatched")
        } catch let failure as ChatPreferenceUpdateFailure { XCTAssertFalse(failure.uncertain) }
        AppearanceSettingsProtocol.style = "light";AppearanceSettingsProtocol.background = 1
        do {
            _ = try await model.saveAppearanceSettings(original:original,desired:settings(.light,.preset2));XCTFail("Stale background dispatched")
        } catch let failure as ChatPreferenceUpdateFailure { XCTAssertFalse(failure.uncertain) }
        XCTAssertTrue(AppearanceSettingsProtocol.writes.isEmpty)
        XCTAssertFalse(model.appearanceSettingsBusy);XCTAssertFalse(model.appearanceSettingsNeedRefresh)
    }
    func testIgnoredWriteBlocksFurtherWritesUntilExplicitSuccessfulReadOnlyRefresh() async throws {
        let model = try await model(),original = try await model.loadAppearanceSettings()
        AppearanceSettingsProtocol.ignoreWrites = true
        do {
            _ = try await model.saveAppearanceSettings(original:original,desired:settings(.dark,.preset0));XCTFail("Ignored write accepted")
        } catch let failure as ChatPreferenceUpdateFailure { XCTAssertTrue(failure.uncertain) }
        XCTAssertTrue(model.appearanceSettingsNeedRefresh);XCTAssertFalse(model.appearanceSettingsBusy)
        do { _ = try await model.saveAppearanceSettings(original:original,desired:settings(.dark,.preset0));XCTFail("Uncertain write replayed") } catch { }
        XCTAssertEqual(AppearanceSettingsProtocol.writes.count,1)
        AppearanceSettingsProtocol.failReads = true
        do { _ = try await model.loadAppearanceSettings();XCTFail("Failed refresh accepted") } catch { }
        XCTAssertTrue(model.appearanceSettingsNeedRefresh)
        do { _ = try await model.saveAppearanceSettings(original:original,desired:settings(.dark,.preset0));XCTFail("Failed refresh allowed write") } catch { }
        XCTAssertEqual(AppearanceSettingsProtocol.writes.count,1)
        AppearanceSettingsProtocol.failReads = false
        let refreshed = try await model.loadAppearanceSettings()
        XCTAssertEqual(refreshed.settings,settings(.light,.preset0));XCTAssertFalse(model.appearanceSettingsNeedRefresh)
        XCTAssertEqual(AppearanceSettingsProtocol.writes.count,1)
        AppearanceSettingsProtocol.ignoreWrites = false
        let saved = try await model.saveAppearanceSettings(original:refreshed,desired:settings(.dark,.preset0))
        XCTAssertEqual(saved.settings,settings(.dark,.preset0));XCTAssertEqual(AppearanceSettingsProtocol.writes.count,2)
    }
    func testLostWriteResponseRequiresRefreshWithoutAutomaticReplay() async throws {
        let model = try await model(),original = try await model.loadAppearanceSettings()
        AppearanceSettingsProtocol.loseWriteResponse = true
        do {
            _ = try await model.saveAppearanceSettings(original:original,desired:settings(.dark,.preset1));XCTFail("Lost receipt accepted")
        } catch let failure as ChatPreferenceUpdateFailure { XCTAssertTrue(failure.uncertain) }
        // The synthetic server applied both fields before losing its response.
        XCTAssertEqual(AppearanceSettingsProtocol.style,"dark");XCTAssertEqual(AppearanceSettingsProtocol.background,1)
        XCTAssertTrue(model.appearanceSettingsNeedRefresh)
        do { _ = try await model.saveAppearanceSettings(original:original,desired:settings(.dark,.preset1));XCTFail("Unknown write replayed") } catch { }
        XCTAssertEqual(AppearanceSettingsProtocol.writes.count,1)
        let confirmed = try await model.loadAppearanceSettings()
        XCTAssertEqual(confirmed.settings,settings(.dark,.preset1));XCTAssertFalse(model.appearanceSettingsNeedRefresh)
        XCTAssertEqual(AppearanceSettingsProtocol.writes.count,1)
    }
    func testAccountRetirementDuringHeldReadCannotPublishIntoReplacementEpoch() async throws {
        let model = try await model(),held = expectation(description:"Old appearance read held")
        let oldEpoch = model.accountGeneration
        AppearanceSettingsProtocol.holdNextRead = true;AppearanceSettingsProtocol.onHeld = { held.fulfill() }
        let operation = Task { try await model.loadAppearanceSettings() }
        await fulfillment(of:[held],timeout:2)
        model.signOutLocally()
        AppearanceSettingsProtocol.style = "dark";AppearanceSettingsProtocol.background = 3
        AppearanceSettingsProtocol.username = "replacement";AppearanceSettingsProtocol.userID = 20
        await model.connect(using:account("replacement"));XCTAssertTrue(model.connected)
        let newEpoch = model.accountGeneration
        XCTAssertNotEqual(oldEpoch,newEpoch);XCTAssertEqual(model.appearanceSettings,settings(.dark,.preset3))
        AppearanceSettingsProtocol.releaseHeld()
        do { _ = try await operation.value;XCTFail("Retired read published") } catch is CancellationError { }
        XCTAssertEqual(model.accountGeneration,newEpoch);XCTAssertEqual(model.userID,20)
        XCTAssertEqual(model.appearanceSettings,settings(.dark,.preset3))
        XCTAssertFalse(model.appearanceSettingsBusy);XCTAssertFalse(model.appearanceSettingsNeedRefresh)
    }
    func testNativeDarkDefaultAndLocalFollowPreferenceNeverWriteServer() async throws {
        let model = try await model(),requestCount = AppearanceSettingsProtocol.requests.count
        let name = "NativeAppearanceSettingsTests."+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:name))
        defaults.removePersistentDomain(forName:name)
        addTeardownBlock { defaults.removePersistentDomain(forName:name) }
        let initial = NativeAppearancePreferences(defaults:defaults)
        XCTAssertFalse(initial.followsAccount);XCTAssertFalse(NativeAppearancePreferences().followsAccount)
        initial.followsAccount = true
        XCTAssertTrue(NativeAppearancePreferences(defaults:defaults).followsAccount)
        initial.followsAccount = false
        XCTAssertFalse(NativeAppearancePreferences(defaults:defaults).followsAccount)
        XCTAssertTrue(AppearanceSettingsProtocol.writes.isEmpty)
        XCTAssertEqual(AppearanceSettingsProtocol.requests.count,requestCount)
        XCTAssertEqual(model.appearanceSettings,settings(.light,.preset0))
    }
    func testWallpaperUsesOnlyFixed2xPathsAndNoSessionHeadersQueriesOrCookies() async throws {
        let model = try await model()
        AppearanceSettingsProtocol.wallpaperData = try raster(.jpeg)
        let start = AppearanceSettingsProtocol.wallpaperRequests.count
        for style in ChatAppearanceStyle.allCases {
            for background in ChatAppearanceBackground.allCases where background != .preset0 {
                let bytes = try await model.loadAppearanceWallpaper(settings(style,background))
                XCTAssertEqual(bytes,AppearanceSettingsProtocol.wallpaperData)
            }
        }
        let requests = Array(AppearanceSettingsProtocol.wallpaperRequests.dropFirst(start))
        XCTAssertEqual(requests.count,6)
        let expected = Set(["light","dark"].flatMap { style in (1...3).map { "/proxy/webman/3rdparty/Chat/images/theme/2x/wallpaper_\(style)_0\($0).jpg" } })
        XCTAssertEqual(Set(requests.compactMap(\.url?.path)),expected)
        for request in requests {
            XCTAssertEqual(request.url?.host,"appearance.synthetic.invalid")
            XCTAssertEqual(request.httpMethod,"GET");XCTAssertNil(request.url?.query)
            for header in ["Cookie","Authorization","SynoToken","X-SYNO-TOKEN"] { XCTAssertNil(request.value(forHTTPHeaderField:header)) }
            XCTAssertFalse(request.url!.absoluteString.contains("synthetic-appearance-sid"))
            XCTAssertFalse(request.url!.absoluteString.contains("synthetic-appearance-token"))
        }
        XCTAssertTrue(AppearanceSettingsProtocol.writes.isEmpty)
        let count = AppearanceSettingsProtocol.wallpaperRequests.count
        let plain = try await model.loadAppearanceWallpaper(settings(.dark,.preset0))
        XCTAssertNil(plain);XCTAssertEqual(AppearanceSettingsProtocol.wallpaperRequests.count,count)
    }
    func testWallpaperRejectsWrongMimeActualFormatSizeStatusAndDimensions() async throws {
        let model = try await model(),jpeg = try raster(.jpeg),png = try raster(.png)
        let tooWide = try replacingJPEGDimensions(jpeg,width:8193,height:1)
        let tooManyPixels = try replacingJPEGDimensions(jpeg,width:5000,height:5000)
        let cases:[(Data,String,Int)] = [(jpeg,"image/png",200),(png,"image/jpeg",200),(Data(),"image/jpeg",200),(Data("not an image".utf8),"image/jpeg",200),(jpeg+Data(repeating:0,count:4*1024*1024),"image/jpeg",200),(tooWide,"image/jpeg",200),(tooManyPixels,"image/jpeg",200),(jpeg,"image/jpeg",302)]
        for (data,mime,status) in cases {
            AppearanceSettingsProtocol.wallpaperData = data;AppearanceSettingsProtocol.wallpaperMime = mime;AppearanceSettingsProtocol.wallpaperStatus = status
            do { _ = try await model.loadAppearanceWallpaper(settings(.dark,.preset1));XCTFail("Invalid wallpaper accepted: \(mime)/\(status)/\(data.count)") } catch { }
        }
        XCTAssertTrue(AppearanceSettingsProtocol.writes.isEmpty)
    }
    func testProductionWallpaperSessionDisablesCookiesAndRedirectDelegateRefusesForwarding() throws {
        let api = try ChatAPIClient(session:account().session)
        XCTAssertFalse(api.network.configuration.httpShouldSetCookies)
        let delegate = try XCTUnwrap(api.network.delegate as? NoChatRedirects)
        let original = URL(string:"https://appearance.synthetic.invalid/proxy/webman/3rdparty/Chat/images/theme/2x/wallpaper_dark_01.jpg")!
        let response = try XCTUnwrap(HTTPURLResponse(url:original,statusCode:302,httpVersion:nil,headerFields:["Location":"https://external.synthetic.invalid/image.jpg"]))
        let task = api.network.dataTask(with:original) // Deliberately never resumed: no request leaves this process.
        defer { task.cancel() }
        var called = false
        delegate.urlSession(api.network,task:task,willPerformHTTPRedirection:response,newRequest:URLRequest(url:URL(string:"https://external.synthetic.invalid/image.jpg")!)) { redirected in
            called = true;XCTAssertNil(redirected)
        }
        XCTAssertTrue(called);XCTAssertTrue(AppearanceSettingsProtocol.wallpaperRequests.isEmpty)
    }
    private func raster(_ format:NSBitmapImageRep.FileType) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:3,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        bitmap.bitmapData?.initialize(repeating:127,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
        return try XCTUnwrap(bitmap.representation(using:format,properties:[:]))
    }
    private func replacingJPEGDimensions(_ original:Data,width:Int,height:Int) throws -> Data {
        var bytes = [UInt8](original),index = 2
        let frames:Set<UInt8> = [0xc0,0xc1,0xc2,0xc3,0xc5,0xc6,0xc7,0xc9,0xca,0xcb,0xcd,0xce,0xcf]
        while index+8 < bytes.count {
            guard bytes[index] == 0xff else { throw ChatAPIError.invalidResponse }
            let marker = bytes[index+1]
            if marker == 0xda || marker == 0xd9 { break }
            let length = Int(bytes[index+2])*256+Int(bytes[index+3])
            guard length >= 2,index+2+length <= bytes.count else { throw ChatAPIError.invalidResponse }
            if frames.contains(marker) {
                bytes[index+5] = UInt8(height >> 8);bytes[index+6] = UInt8(height & 255)
                bytes[index+7] = UInt8(width >> 8);bytes[index+8] = UInt8(width & 255)
                return Data(bytes)
            }
            index += 2+length
        }
        throw ChatAPIError.invalidResponse
    }
}

private final class AppearanceSettingsProtocol:URLProtocol {
    static var style = "light",background = 0,username = "owner",userID = 10
    static var unrelated:[String:Any] = [:]
    static var writes:[[String:String]] = [],requests:[URLRequest] = [],wallpaperRequests:[URLRequest] = []
    static var ignoreWrites = false,loseWriteResponse = false,failReads = false,holdNextRead = false
    static var held:AppearanceSettingsProtocol?,heldPayload:[String:Any]?,onHeld:(()->Void)?
    static var wallpaperData = Data(),wallpaperMime = "image/jpeg",wallpaperStatus = 200
    static func reset() {
        style = "light";background = 0;username = "owner";userID = 10;unrelated = [:]
        writes = [];requests = [];wallpaperRequests = [];ignoreWrites = false;loseWriteResponse = false;failReads = false;holdNextRead = false
        held = nil;heldPayload = nil;onHeld = nil;wallpaperData = Data();wallpaperMime = "image/jpeg";wallpaperStatus = 200
    }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "appearance.synthetic.invalid" else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        Self.requests.append(request)
        if request.url?.path.contains("/webman/3rdparty/Chat/images/theme/2x/") == true {
            Self.wallpaperRequests.append(request);finishBytes(Self.wallpaperData,mime:Self.wallpaperMime,status:Self.wallpaperStatus);return
        }
        let api = request.url!.lastPathComponent
        if api == "SYNO.API.Info" {
            finish(Dictionary(uniqueKeysWithValues:["SYNO.Chat.User.Preference","SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Misc"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) }));return
        }
        let fields = Self.fields(request)
        if api == "SYNO.Chat.User.Preference" {
            if fields["method"] == "set" {
                Self.writes.append(fields)
                if !Self.ignoreWrites {
                    if let raw = fields["theme_style"],let value = try? JSONDecoder().decode(String.self,from:Data(raw.utf8)) { Self.style = value }
                    if let raw = fields["theme_background"],let value = Int(raw) { Self.background = value }
                }
                if Self.loseWriteResponse { Self.loseWriteResponse = false;client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost));return }
                finish([:]);return
            }
            var preferences = Self.unrelated
            preferences["theme_style"] = Self.style;preferences["theme_background"] = Self.background
            preferences["prefer_user_name_format"] = "nickname";preferences["sidebar_pinning_unread"] = false
            let payload:[String:Any] = ["preferences":preferences]
            if Self.holdNextRead { Self.holdNextRead = false;Self.held = self;Self.heldPayload = payload;Self.onHeld?();return }
            if Self.failReads { finishBytes(Data("unavailable".utf8),mime:"application/json",status:503);return }
            finish(payload);return
        }
        if api == "SYNO.Chat.User" { finish(["users":[["user_id":Self.userID,"username":Self.username,"nickname":"Synthetic owner","type":"human","human_type":"dsm"]]]);return }
        if api == "SYNO.Chat.Channel" { finish(["channels":[["channel_id":93,"name":"Synthetic private channel","type":"private","encrypted":false,"unread":0,"is_joined":true]]]);return }
        finish(["acls":[]]) // Runtime-version decoding fails locally; no live socket is created.
    }
    static func releaseHeld() {
        guard let held,let payload = heldPayload else { return }
        Self.held = nil;Self.heldPayload = nil;held.finish(payload)
    }
    private static func fields(_ request:URLRequest)->[String:String] {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty,let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048)
            while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count);if count <= 0 { break };bytes.append(contentsOf:buffer.prefix(count)) }
        }
        var components = URLComponents();components.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
        return Dictionary((components.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ first,_ in first })
    }
    private func finish(_ payload:[String:Any]) {
        let data = try! JSONSerialization.data(withJSONObject:["success":true,"data":payload])
        finishBytes(data,mime:"application/json",status:200)
    }
    private func finishBytes(_ bytes:Data,mime:String,status:Int) {
        let response = HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":mime])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:bytes);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
