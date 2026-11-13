import AppKit
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatUserProfileTests:XCTestCase {
    private func client() async throws -> ChatAPIClient {
        let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [ProfileProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://profile-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:c))
        try await api.discover();return api
    }
    private func user(_ version:Int = 1) throws -> ChatUser {
        var value = ProfileProtocol.users[0];value["avatar_version"] = version
        return try JSONDecoder().decode(ChatUser.self,from:JSONSerialization.data(withJSONObject:value))
    }
    private func model() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [ProfileProtocol.self]
            return try ChatAPIClient(session:session,network:URLSession(configuration:c))
        })
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://profile-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
        model.suspendLiveForProbe();model.liveStatus = .live;model.selection = 93
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    override func setUp() { super.setUp();ProfileProtocol.reset() }
    override func tearDown() { ProfileProtocol.observer = nil;ProfileProtocol.held = nil;super.tearDown() }
    func testProfileMetadataDecodesLiteralFieldsAndPreservesEncryptionMaterial() throws {
        var value = ProfileProtocol.users[0]
        value["user_props"] = ["email":"synthetic@example.invalid","description":"<script>literal 👋</script>","timezoneUTC":"Europe/London","avatar_color":"#123456","key_pair":["public_key":"synthetic-public","private_key_enc":"synthetic-wrapped"]]
        let decoded = try JSONDecoder().decode(ChatUser.self,from:JSONSerialization.data(withJSONObject:value))
        XCTAssertEqual(decoded.user_props?.description,"<script>literal 👋</script>");XCTAssertEqual(decoded.user_props?.key_pair?.private_key_enc,"synthetic-wrapped");XCTAssertEqual(decoded.profileTimeZone?.identifier,"Europe/London")
        value["avatar_version"] = "bad";value["user_props"] = ["email":true,"description":["invalid"],"avatar_color":7]
        let malformed = try JSONDecoder().decode(ChatUser.self,from:JSONSerialization.data(withJSONObject:value))
        XCTAssertNil(malformed.avatar_version);XCTAssertNil(malformed.user_props?.email);XCTAssertNil(malformed.user_props?.description)
        XCTAssertEqual(malformed.displayName,"Synthetic Peter")
    }
    func testProfileAvailabilityAndUnknownTimezoneDoNotInventDetails() throws {
        var value = ProfileProtocol.users[0]
        for modification:[String:Any] in [["is_disabled":true],["delete_at":1000],["type":"bot","bot_type":"incoming"],["user_id":0]] {
            var candidate = value;modification.forEach { candidate[$0.key] = $0.value };XCTAssertFalse(try JSONDecoder().decode(ChatUser.self,from:JSONSerialization.data(withJSONObject:candidate)).canViewProfile)
        }
        value["type"] = "bot";value["bot_type"] = "synobot";value["user_props"] = ["timezoneUTC":"not-a-time-zone"]
        let synobot = try JSONDecoder().decode(ChatUser.self,from:JSONSerialization.data(withJSONObject:value));XCTAssertTrue(synobot.canViewProfile);XCTAssertNil(synobot.profileTimeZone)
    }
    func testAvatarWireUsesDiscoveredEndpointOnlyAndAllVendorSizes() async throws {
        let api = try await client();var sizes:[String] = []
        ProfileProtocol.observer = { fields in
            if fields["api"] == "SYNO.Chat.User.Avatar" { XCTAssertEqual(fields["method"],"get");XCTAssertEqual(fields["version"],"1");XCTAssertEqual(fields["user_id"],"10");XCTAssertEqual(fields["v"],"123");sizes.append(fields["type"]!) }
        }
        for size in ChatAvatarSize.allCases { let bytes = try await api.avatarData(userID:10,size:size,version:123);XCTAssertEqual(bytes,ProfileProtocol.png) }
        XCTAssertEqual(sizes,[#""S""#,#""M""#,#""L""#])
        do { _ = try await api.avatarData(userID:0,size:.small,version:1);XCTFail("Invalid ID sent") } catch ChatAPIError.invalidResponse { }
        do { _ = try await api.avatarData(userID:10,size:.small,version:-1);XCTFail("Invalid version sent") } catch ChatAPIError.invalidResponse { }
    }
    func testAvatarRejectsLoginHTMLExternalFormatsOversizedHeaderAndStream() async throws {
        let api = try await client()
        for mime in ["text/html","application/json","image/svg+xml"] {
            ProfileProtocol.mime = mime
            do { _ = try await api.avatarData(userID:10,size:.small,version:1);XCTFail("Unexpected image type") } catch { }
        }
        ProfileProtocol.mime = "image/png";ProfileProtocol.headerLength = 3*1024*1024
        do { _ = try await api.avatarData(userID:10,size:.small,version:1);XCTFail("Oversized header accepted") } catch { }
        ProfileProtocol.headerLength = nil;ProfileProtocol.bytes = Data(repeating:0,count:2*1024*1024+1)
        do { _ = try await api.avatarData(userID:10,size:.small,version:1);XCTFail("Unbounded body accepted") } catch { }
        ProfileProtocol.bytes = Data()
        do { _ = try await api.avatarData(userID:10,size:.small,version:1);XCTFail("Empty image accepted") } catch { }
        ProfileProtocol.bytes = nil
        for status in [302,401,500] {
            ProfileProtocol.status = status
            do { _ = try await api.avatarData(userID:10,size:.small,version:1);XCTFail("HTTP error image accepted") } catch { }
        }
    }
    func testAvatarDecoderBoundsDimensionsAndUsesOneDownsampledImage() {
        let image = NativeAvatarStore.decode(ProfileProtocol.image(width:256,height:128),maximumPixelSize:96)
        XCTAssertNotNil(image);XCTAssertLessThanOrEqual(image?.size.width ?? 999,96)
        XCTAssertNil(NativeAvatarStore.decode(Data("<svg>not an avatar</svg>".utf8),maximumPixelSize:96))
        XCTAssertNil(NativeAvatarStore.decode(Data(#"{"success":false}"#.utf8),maximumPixelSize:96))
        XCTAssertNil(NativeAvatarStore.decode(ProfileProtocol.image(width:5000,height:1),maximumPixelSize:96))
    }
    func testSharedCacheDeduplicatesRequestsAndSeparatesVersionsAndSizes() async throws {
        let store = NativeAvatarStore();store.attach(try await client());let first = try user(),next = try user(2)
        store.load(first,size:.small);store.load(first,size:.small);await store.waitForLoads()
        XCTAssertNotNil(store.image(first,size:.small));XCTAssertEqual(ProfileProtocol.imageCalls,1)
        store.load(first,size:.large);store.load(next,size:.small);await store.waitForLoads()
        XCTAssertEqual(ProfileProtocol.imageCalls,3);XCTAssertNotNil(store.image(next,size:.small));XCTAssertNotEqual(store.key(first,size:.small),store.key(next,size:.small))
        store.attach(nil);XCTAssertNil(store.image(first,size:.small));XCTAssertNil(store.image(next,size:.small))
    }
    func testFailureCacheUsesFallbackUntilExplicitRetry() async throws {
        let store = NativeAvatarStore();store.attach(try await client());let person = try user()
        ProfileProtocol.mime = "text/html";store.load(person,size:.large);await store.waitForLoads()
        XCTAssertTrue(store.failed(person,size:.large));XCTAssertNil(store.image(person,size:.large));store.load(person,size:.large);await store.waitForLoads();XCTAssertEqual(ProfileProtocol.imageCalls,1)
        ProfileProtocol.mime = "image/png";store.load(person,size:.large,retry:true);await store.waitForLoads()
        XCTAssertNotNil(store.image(person,size:.large));XCTAssertEqual(ProfileProtocol.imageCalls,2)
    }
    func testLateAvatarCannotRepopulateClearedAccountCache() async throws {
        let store = NativeAvatarStore();store.attach(try await client());let person = try user(),started = expectation(description:"Avatar request held")
        ProfileProtocol.holdAvatar = true;ProfileProtocol.observer = { if $0["api"] == "SYNO.Chat.User.Avatar" { started.fulfill() } }
        let oldEpoch = store.epoch;store.load(person,size:.small)
        await fulfillment(of:[started],timeout:2);store.attach(nil);ProfileProtocol.held?.finishImage();await Task.yield()
        XCTAssertNotEqual(store.epoch,oldEpoch);XCTAssertNil(store.image(person,size:.small));XCTAssertFalse(store.failed(person,size:.small))
    }
    func testProfileRefreshUpdatesDirectoryAndSignOutClearsAvatars() async throws {
        let model = try await model();let first = model.directory.first!
        model.avatars.load(first,size:.small);await model.avatars.waitForLoads();XCTAssertNotNil(model.avatars.image(first,size:.small))
        ProfileProtocol.users[0]["nickname"] = "Updated synthetic Peter";ProfileProtocol.users[0]["avatar_version"] = 2
        try await model.refreshUserProfiles();let updated = model.directory.first!
        XCTAssertEqual(model.names[10],"Updated synthetic Peter");XCTAssertNil(model.avatars.image(updated,size:.small))
        model.signOutLocally();XCTAssertNil(model.avatars.image(first,size:.small));XCTAssertTrue(model.directory.isEmpty)
    }
    func testLateProfileRefreshAfterSignOutCannotPublishOldDirectory() async throws {
        let model = try await model(),started = expectation(description:"Profile refresh held")
        ProfileProtocol.holdUsers = true;ProfileProtocol.observer = { if $0["api"] == "SYNO.Chat.User",$0["method"] == "list" { started.fulfill() } }
        let task = Task { try await model.refreshUserProfiles() }
        await fulfillment(of:[started],timeout:2);model.signOutLocally();ProfileProtocol.held?.finish(["success":true,"data":["users":ProfileProtocol.users]])
        do { try await task.value;XCTFail("Old directory published") } catch is CancellationError { }
        XCTAssertTrue(model.directory.isEmpty);XCTAssertTrue(model.names.isEmpty)
    }
    func testProfileMessageReusesExistingDMAndSignalsPresentationDismissal() async throws {
        ProfileProtocol.directChannel = true
        let model = try await model(),oldRoute = model.profileConversationRoute
        var mutations = 0
        ProfileProtocol.observer = { if $0["api"] == "SYNO.Chat.Channel",$0["method"] != "list" { mutations += 1 } }
        try await model.openProfileConversation(userID:6)
        XCTAssertEqual(model.selection,93);XCTAssertNotEqual(model.profileConversationRoute,oldRoute);XCTAssertEqual(mutations,0)
        XCTAssertEqual(model.sidebarUser(model.channels[0])?.user_id,6)
        let owner = UUID(),route = model.profileConversationRoute;model.beginMessageEditing(owner:owner)
        do { try await model.openProfileConversation(userID:6);XCTFail("Unsaved edit discarded") } catch { }
        XCTAssertEqual(model.profileConversationRoute,route);XCTAssertTrue(model.isEditingMessage);model.endMessageEditing(owner:owner)
    }
}

private final class ProfileProtocol:URLProtocol {
    static var users:[[String:Any]] = []
    static var mime = "image/png"
    static var status = 200
    static var png = Data()
    static var bytes:Data?
    static var headerLength:Int?
    static var imageCalls = 0
    static var holdAvatar = false
    static var holdUsers = false
    static var directChannel = false
    static var held:ProfileProtocol?
    static var observer:(([String:String])->Void)?
    static func image(width:Int,height:Int) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        return bitmap.representation(using:.png,properties:[:])!
    }
    static func reset() {
        users = [["user_id":10,"username":"synthetic","nickname":"Synthetic Peter","type":"human","human_type":"dsm","avatar_version":1,"user_props":["email":"synthetic@example.invalid","description":"Literal synthetic profile","timezoneUTC":"Europe/London","avatar_color":"#3d82d1"]],["user_id":6,"username":"synthetic-peer","nickname":"Peer","type":"human","human_type":"dsm","avatar_version":0]]
        mime = "image/png";status = 200;png = image(width:32,height:32);bytes = nil;headerLength = nil;imageCalls = 0;holdAvatar = false;holdUsers = false;directChannel = false;held = nil;observer = nil
    }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var b = [UInt8](repeating:0,count:4096);while stream.hasBytesAvailable { let n = stream.read(&b,maxLength:b.count);if n <= 0 { break };bytes.append(contentsOf:b.prefix(n)) } }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
        let fields = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last });let api = request.url!.lastPathComponent,method = fields["method"] ?? ""
        if request.url!.path.contains("SYNO.API.Info") { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.User.Avatar","SYNO.Chat.Post","SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Channel.Member","SYNO.Chat.Misc","SYNO.Chat.Admin.Setting"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"] as [String:Any]) })]);return }
        if api == "SYNO.Chat.User.Avatar" { Self.imageCalls += 1;if Self.holdAvatar { Self.held = self;Self.observer?(fields);return };Self.observer?(fields);finishImage();return }
        if api == "SYNO.Chat.User",Self.holdUsers { Self.held = self;Self.observer?(fields);return }
        Self.observer?(fields)
        switch (api,method) {
        case ("SYNO.Chat.User","list"):finish(["success":true,"data":["users":Self.users]])
        case ("SYNO.Chat.Channel","list"):finish(["success":true,"data":["channels":[["channel_id":93,"name":Self.directChannel ? "" : "Peter","type":Self.directChannel ? "anonymous" : "public","encrypted":false,"unread":0]]]])
        case ("SYNO.Chat.Channel.Member","get"):finish(["success":true,"data":["user_ids":[10,6]]])
        case ("SYNO.Chat.Misc",_):finish(["success":true,"data":["acls":[]]])
        case ("SYNO.Chat.Admin.Setting",_):finish(["success":true,"data":["hide_post_url_preview":true,"file_size_limit":0]])
        case ("SYNO.Chat.Post","list"):finish(["success":true,"data":["posts":[]]])
        default:finish(["success":false,"error":["code":400]])
        }
    }
    func finishImage() { finishBytes(Self.bytes ?? Self.png,mime:Self.mime,length:Self.headerLength) }
    func finish(_ object:[String:Any]) { finishBytes(try! JSONSerialization.data(withJSONObject:object),mime:"application/json",length:nil) }
    func finishBytes(_ bytes:Data,mime:String,length:Int?) {
        var headers = ["Content-Type":mime];if let length { headers["Content-Length"] = String(length) }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:Self.status,httpVersion:nil,headerFields:headers)!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:bytes);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
