import XCTest
import CoreGraphics
import ImageIO
@testable import SynologyChatNative

@MainActor final class ChatProfileEditingTests:XCTestCase {
    override func setUp() { super.setUp();ProfileEditProtocol.reset() }
    private func model() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [ProfileEditProtocol.self]
            return try ChatAPIClient(session:session,network:URLSession(configuration:c))
        })
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://profile-edit.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
        XCTAssertTrue(model.connected);addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    func testDirtyTextPatchPreservesUnrelatedAndConcurrentlyChangedFields() async throws {
        let model = try await model(),before = try await model.loadEditableProfile();var draft = ChatProfileTextDraft(before)
        draft.description = "  New description \n";ProfileEditProtocol.nickname = "Changed elsewhere"
        model.selection = 93;model.draft = "Unsent message"
        let saved = try await model.saveProfileText(draft,original:before)
        XCTAssertEqual(saved.description,"New description");XCTAssertEqual(saved.nickname,"Changed elsewhere");XCTAssertEqual(model.draft,"Unsent message")
        XCTAssertEqual(ProfileEditProtocol.writes,1);XCTAssertEqual(ProfileEditProtocol.lastWrite?["version"],"3")
        for field in ["nickname","avatar","remove_avatar","is_always_offline","timezone","email","user_id"] { XCTAssertNil(ProfileEditProtocol.lastWrite?[field]) }
    }
    func testNicknameTrimAndDescriptionClearCanonicalReadback() async throws {
        let model = try await model(),before = try await model.loadEditableProfile();var draft = ChatProfileTextDraft(before)
        draft.nickname = "  New Peter  ";draft.description = "  "
        let saved = try await model.saveProfileText(draft,original:before)
        XCTAssertEqual(saved.nickname,"New Peter");XCTAssertEqual(saved.description,"");XCTAssertEqual(model.names[10],"New Peter")
    }
    func testNoOpAndClearNicknameUsesAccountDefault() async throws {
        let model = try await model(),before = try await model.loadEditableProfile();var draft = ChatProfileTextDraft(before)
        _ = try await model.saveProfileText(draft,original:before);XCTAssertEqual(ProfileEditProtocol.writes,0)
        draft.nickname = "   ";let saved = try await model.saveProfileText(draft,original:before)
        XCTAssertEqual(saved.nickname,"");XCTAssertEqual(ProfileEditProtocol.writes,1)
    }
    func testAdminRestrictionRecheckedBeforeDispatch() async throws {
        let model = try await model(),before = try await model.loadEditableProfile();var draft = ChatProfileTextDraft(before);draft.nickname = "New Peter"
        ProfileEditProtocol.readonly = ["nickname"]
        do { _ = try await model.saveProfileText(draft,original:before);XCTFail("Restricted field wrote") } catch let e as ChatProfileEditFailure { XCTAssertFalse(e.uncertain) }
        XCTAssertEqual(ProfileEditProtocol.writes,0)
        let fresh = try await model.loadEditableProfile();XCTAssertFalse(fresh.policy.allows("nickname"));XCTAssertTrue(fresh.policy.allows("description"))
    }
    func testConflictingDirtyFieldRejectsWithoutWrite() async throws {
        let model = try await model(),before = try await model.loadEditableProfile();var draft = ChatProfileTextDraft(before);draft.description = "Mine";ProfileEditProtocol.description = "Other client"
        do { _ = try await model.saveProfileText(draft,original:before);XCTFail("Stale profile wrote") } catch let e as ChatProfileEditFailure { XCTAssertFalse(e.uncertain) }
        XCTAssertEqual(ProfileEditProtocol.writes,0)
    }
    func testUnsupportedPolicyAndDescriptionCannotEnableWrites() async throws {
        let model = try await model();ProfileEditProtocol.invalidPolicy = true
        do { _ = try await model.loadEditableProfile();XCTFail("Missing policy accepted") } catch { }
        ProfileEditProtocol.invalidPolicy = false;ProfileEditProtocol.missingDescription = true
        do { _ = try await model.loadEditableProfile();XCTFail("Missing description accepted") } catch { }
        XCTAssertEqual(ProfileEditProtocol.writes,0)
    }
    func testUnconfirmedSaveBlocksRepeatUntilRefresh() async throws {
        let model = try await model(),before = try await model.loadEditableProfile();var draft = ChatProfileTextDraft(before);draft.description = "New";ProfileEditProtocol.ignoreWrite = true
        do { _ = try await model.saveProfileText(draft,original:before);XCTFail("Unconfirmed save accepted") } catch let e as ChatProfileEditFailure { XCTAssertTrue(e.uncertain) }
        XCTAssertTrue(model.profileEditingNeedsRefresh)
        do { _ = try await model.saveProfileText(draft,original:before);XCTFail("Repeat dispatched") } catch { }
        XCTAssertEqual(ProfileEditProtocol.writes,1)
        let fresh = try await model.loadEditableProfile();XCTAssertFalse(model.profileEditingNeedsRefresh);ProfileEditProtocol.ignoreWrite = false
        _ = try await model.saveProfileText(draft,original:fresh);XCTAssertEqual(ProfileEditProtocol.writes,2)
    }
    func testWrongAccountAndSignOutAfterDispatchCannotPublish() async throws {
        let model = try await model(),before = try await model.loadEditableProfile();var draft = ChatProfileTextDraft(before);draft.description = "New"
        let wrong = ChatProfileEditSnapshot(userID:6,nickname:before.nickname,description:before.description,policy:before.policy,accountGeneration:before.accountGeneration)
        do { _ = try await model.saveProfileText(draft,original:wrong);XCTFail("Wrong user wrote") } catch { }
        XCTAssertEqual(ProfileEditProtocol.writes,0)
        let started = expectation(description:"Write held");ProfileEditProtocol.holdWrite = true;ProfileEditProtocol.onWrite = { started.fulfill() }
        let submitted = draft
        let action = Task { try await model.saveProfileText(submitted,original:before) }
        await fulfillment(of:[started],timeout:2);let reads = ProfileEditProtocol.userReads;model.signOutLocally();ProfileEditProtocol.held?.finish(["success":true]);ProfileEditProtocol.held = nil
        do { _ = try await action.value;XCTFail("Old profile published") } catch is CancellationError { }
        XCTAssertEqual(ProfileEditProtocol.userReads,reads);XCTAssertTrue(model.directory.isEmpty);XCTAssertFalse(model.profileEditingBusy)
    }
    func testCancellationAfterDispatchRequiresRefresh() async throws {
        let model = try await model(),before = try await model.loadEditableProfile();var draft = ChatProfileTextDraft(before);draft.nickname = "New"
        let started = expectation(description:"Write held");ProfileEditProtocol.holdWrite = true;ProfileEditProtocol.onWrite = { started.fulfill() };let submitted = draft
        let action = Task { try await model.saveProfileText(submitted,original:before) }
        await fulfillment(of:[started],timeout:2);action.cancel();ProfileEditProtocol.held?.finish(["success":true]);ProfileEditProtocol.held = nil
        do { _ = try await action.value;XCTFail("Cancelled save confirmed") } catch { }
        XCTAssertTrue(model.profileEditingNeedsRefresh);XCTAssertEqual(ProfileEditProtocol.writes,1)
    }

    func testFailedCanonicalPhotoRefreshDoesNotUnlockUncertainMutation() async throws {
        let model = try await model(),before = try await model.loadEditableProfilePhoto(),png = try photo();ProfileEditProtocol.badAvatar = true
        do { _ = try await model.saveProfilePhoto(png,original:before.profile);XCTFail("Unreadable canonical photo confirmed") } catch { }
        XCTAssertTrue(model.profileEditingNeedsRefresh)
        do { _ = try await model.loadEditableProfilePhoto();XCTFail("Unreadable canonical refresh accepted") } catch { }
        XCTAssertTrue(model.profileEditingNeedsRefresh)
        ProfileEditProtocol.badAvatar = false
        _ = try await model.loadEditableProfilePhoto();XCTAssertFalse(model.profileEditingNeedsRefresh)
    }
    func testProfileTextLimitsRejectBeforeDispatchAndPreserveUnsentDraft() async throws {
        let m = try await model(),original = try await m.loadEditableProfile();m.selection = 93;m.draft = "Unsent message"
        for invalidName in [String(repeating:"x",count:256),"tab\tname","line\nbreak","\u{007f}name",String(repeating:"😀",count:128)] {
            var draft = ChatProfileTextDraft(original);draft.nickname = invalidName
            do {_ = try await m.saveProfileText(draft,original:original);XCTFail("Invalid nickname dispatched")} catch {}
        }
        var draft = ChatProfileTextDraft(original);draft.description = String(repeating:"x",count:257)
        do {_ = try await m.saveProfileText(draft,original:original);XCTFail("Long description dispatched")} catch {}
        XCTAssertEqual(ProfileEditProtocol.writes,0);XCTAssertEqual(m.draft,"Unsent message")
    }
    func testProfileUTF16BoundaryAndMultilineDescriptionAccepted() async throws {
        let m = try await model(),original = try await m.loadEditableProfile();var draft = ChatProfileTextDraft(original)
        draft.nickname = String(repeating:"😀",count:127)+"X";draft.description = String(repeating:"x",count:254)+"\ny"
        let result = try await m.saveProfileText(draft,original:original)
        XCTAssertEqual(result.nickname.utf16.count,255);XCTAssertEqual(result.description.utf16.count,256);XCTAssertTrue(result.description.contains("\n"))
    }
    func testUntouchedLegacyProfileTextIsPreservedWhenEditingOtherField() async throws {
        let m = try await model();ProfileEditProtocol.nickname = String(repeating:"x",count:300)
        let original = try await m.loadEditableProfile();var draft = ChatProfileTextDraft(original);draft.description = "Changed description"
        _ = try await m.saveProfileText(draft,original:original)
        XCTAssertNil(ProfileEditProtocol.lastWrite?["nickname"]);XCTAssertEqual(ProfileEditProtocol.writes,1)
    }
    private func photo() throws -> Data {
        let context = CGContext(data:nil,width:400,height:200,bitsPerComponent:8,bytesPerRow:1600,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red:0.2,green:0.7,blue:0.4,alpha:1));context.fill(CGRect(x:0,y:0,width:400,height:200))
        return try NativeProfilePhoto.render(context.makeImage()!)
    }
    func testProfilePhotoUploadAndRemoveUseAvatarOnlyAndReadCanonicalImage() async throws {
        let model = try await model(),before = try await model.loadEditableProfilePhoto(),png = try photo()
        XCTAssertNil(before.image);XCTAssertEqual(before.profile.avatarVersion,0)
        let saved = try await model.saveProfilePhoto(png,original:before.profile)
        XCTAssertEqual(saved.image,png);XCTAssertEqual(saved.profile.avatarVersion,1);XCTAssertEqual(ProfileEditProtocol.uploads,1)
        let multipart = ProfileEditProtocol.lastMultipart!
        XCTAssertTrue(multipart.contains(Data("name=\"avatar\"; filename=\"profile.png\"".utf8)))
        for field in ["nickname","description","timezone","email","is_always_offline","user_id","remove_avatar"] { XCTAssertFalse(multipart.contains(Data("name=\"\(field)\"".utf8))) }
        let removed = try await model.saveProfilePhoto(nil,original:saved.profile)
        XCTAssertNil(removed.image);XCTAssertEqual(removed.profile.avatarVersion,0);XCTAssertEqual(ProfileEditProtocol.lastWrite?["remove_avatar"],"true")
        XCTAssertNil(ProfileEditProtocol.lastWrite?["nickname"])
    }
    func testProfilePhotoNoOpRemoveAndInvalidImageCannotWrite() async throws {
        let model = try await model(),before = try await model.loadEditableProfilePhoto()
        _ = try await model.saveProfilePhoto(nil,original:before.profile);XCTAssertEqual(ProfileEditProtocol.writes,0)
        do { _ = try await model.saveProfilePhoto(Data("not an image".utf8),original:before.profile);XCTFail("Invalid image wrote") } catch { }
        XCTAssertEqual(ProfileEditProtocol.writes,0)
    }
    func testProfilePhotoFreshVersionAndPolicyPreventStaleWrites() async throws {
        let model = try await model(),before = try await model.loadEditableProfilePhoto(),png = try photo()
        ProfileEditProtocol.avatarVersion = 2
        do { _ = try await model.saveProfilePhoto(png,original:before.profile);XCTFail("Stale photo overwrote") } catch let e as ChatProfileEditFailure { XCTAssertFalse(e.uncertain) }
        ProfileEditProtocol.avatarVersion = 0;ProfileEditProtocol.readonly = ["avatar"]
        do { _ = try await model.saveProfilePhoto(png,original:before.profile);XCTFail("Restricted photo wrote") } catch { }
        XCTAssertEqual(ProfileEditProtocol.writes,0)
    }
    func testUnconfirmedPhotoChangeBlocksRepeatUntilRefresh() async throws {
        let model = try await model(),before = try await model.loadEditableProfilePhoto(),png = try photo();ProfileEditProtocol.ignoreWrite = true
        do { _ = try await model.saveProfilePhoto(png,original:before.profile);XCTFail("Ignored upload confirmed") } catch let e as ChatProfileEditFailure { XCTAssertTrue(e.uncertain) }
        XCTAssertTrue(model.profileEditingNeedsRefresh)
        do { _ = try await model.saveProfilePhoto(png,original:before.profile);XCTFail("Repeated uncertain upload") } catch { }
        XCTAssertEqual(ProfileEditProtocol.writes,1)
        _ = try await model.loadEditableProfilePhoto();XCTAssertFalse(model.profileEditingNeedsRefresh)
    }
    func testPhotoCancellationAfterUploadRequiresRefresh() async throws {
        let model = try await model(),before = try await model.loadEditableProfilePhoto(),png = try photo(),started = expectation(description:"Photo upload held")
        ProfileEditProtocol.holdWrite = true;ProfileEditProtocol.onWrite = { started.fulfill() }
        let action = Task { try await model.saveProfilePhoto(png,original:before.profile) }
        await fulfillment(of:[started],timeout:2);action.cancel();ProfileEditProtocol.held?.finish(["success":true]);ProfileEditProtocol.held = nil
        do { _ = try await action.value;XCTFail("Cancelled upload confirmed") } catch { }
        XCTAssertTrue(model.profileEditingNeedsRefresh);XCTAssertEqual(ProfileEditProtocol.writes,1)
    }
    func testPhotoOldAccountCannotPublishAfterUpload() async throws {
        let model = try await model(),before = try await model.loadEditableProfilePhoto(),png = try photo(),started = expectation(description:"Photo upload held")
        ProfileEditProtocol.holdWrite = true;ProfileEditProtocol.onWrite = { started.fulfill() }
        let action = Task { try await model.saveProfilePhoto(png,original:before.profile) }
        await fulfillment(of:[started],timeout:2);let reads = ProfileEditProtocol.userReads;model.signOutLocally();ProfileEditProtocol.held?.finish(["success":true]);ProfileEditProtocol.held = nil
        do { _ = try await action.value;XCTFail("Old photo published") } catch is CancellationError { }
        XCTAssertEqual(ProfileEditProtocol.userReads,reads);XCTAssertTrue(model.directory.isEmpty);XCTAssertFalse(model.profileEditingBusy)
    }

}

private final class ProfileEditProtocol:URLProtocol {
    static var badAvatar = false
    static var avatarVersion:Int64 = 0,uploads = 0
    static var photoData = Data(),lastMultipart:Data?
    static var nickname = "Synthetic Peter",description = "Original description",readonly:[String] = []
    static var invalidPolicy = false,missingDescription = false
    static var away = false,ignoreWrite = false,holdWrite = false
    static var rawFlag:Any?
    static var writes = 0,userReads = 0
    static var lastWrite:[String:String]?
    static var held:ProfileEditProtocol?
    static var onWrite:(()->Void)?
    static func reset() { badAvatar = false;avatarVersion = 0;uploads = 0;photoData = Data();lastMultipart = nil;nickname = "Synthetic Peter";description = "Original description";readonly = [];invalidPolicy = false;missingDescription = false;away = false;ignoreWrite = false;holdWrite = false;rawFlag = nil;writes = 0;userReads = 0;lastWrite = nil;held = nil;onWrite = nil }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        if request.url!.lastPathComponent == "SYNO.API.Info" { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.User.Avatar","SYNO.Chat.Admin.Setting","SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Misc"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) })]);return }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };data.append(contentsOf:buffer.prefix(n)) } }
        if request.url!.lastPathComponent == "SYNO.Chat.User.Avatar" {
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"image/png"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:Self.badAvatar ? Data("not an image".utf8) : Self.photoData);client?.urlProtocolDidFinishLoading(self);return
        }
        if request.value(forHTTPHeaderField:"Content-Type")?.hasPrefix("multipart/form-data;") == true {
            Self.writes += 1;Self.uploads += 1;Self.lastMultipart = data
            if !Self.ignoreWrite,let start = data.range(of:Data([137,80,78,71,13,10,26,10])),let end = data.range(of:Data("\r\n--".utf8),options:[],in:start.lowerBound..<data.endIndex) { Self.photoData = data.subdata(in:start.lowerBound..<end.lowerBound);Self.avatarVersion += 1 }
            if Self.holdWrite { Self.held = self;Self.onWrite?();return };finish(["success":true]);return
        }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        var fields = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last });fields["api"] = request.url!.lastPathComponent
        if fields["api"] == "SYNO.Chat.Admin.Setting" { finish(["success":true,"data":Self.invalidPolicy ? [:] : ["readonly_profile":Self.readonly]]);return }
        if fields["api"] == "SYNO.Chat.User",fields["method"] == "set" {
            Self.writes += 1;Self.lastWrite = fields;if !Self.ignoreWrite {
                if fields["remove_avatar"] == "true" { Self.avatarVersion = 0;Self.photoData = Data() }
                if let encoded = fields["nickname"],let value = try? JSONDecoder().decode(String.self,from:Data(encoded.utf8)) { Self.nickname = value }
                if let encoded = fields["description"],let value = try? JSONDecoder().decode(String.self,from:Data(encoded.utf8)) { Self.description = value }
            }
            if Self.holdWrite { Self.held = self;Self.onWrite?();return };finish(["success":true]);return
        }
        if fields["api"] == "SYNO.Chat.User" {
            Self.userReads += 1;finish(["success":true,"data":["users":[["user_id":10,"username":"synthetic","nickname":Self.nickname,"avatar_version":Self.avatarVersion,"type":"human","human_type":"dsm","user_props":["is_always_offline":Self.away,"description":Self.missingDescription ? NSNull() as Any : Self.description as Any,"timezoneUTC":"GMT"]]]]]);return
        }
        if fields["api"] == "SYNO.Chat.Channel" { finish(["success":true,"data":["channels":[["channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0,"is_joined":true]]]]);return }
        if fields["api"] == "SYNO.Chat.Misc" { finish(["success":true,"data":["acls":[]]]);return }
        finish(["success":false,"error":["code":102]])
    }
    func finish(_ value:[String:Any]) { let data = try! JSONSerialization.data(withJSONObject:value);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
