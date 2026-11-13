import XCTest
@testable import SynologyChatNative

@MainActor final class ChatManualPresenceTests:XCTestCase {
    override func setUp() { super.setUp();PresenceProtocol.reset() }
    private func model() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [PresenceProtocol.self]
            return try ChatAPIClient(session:session,network:URLSession(configuration:c))
        })
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://presence.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
        model.liveStatus = .live;XCTAssertTrue(model.connected)
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    func testAwayAndAutomaticRoundTripUsesOnlyBooleanUserSetV3() async throws {
        let model = try await model(),before = try await model.loadManualPresence()
        XCTAssertFalse(before.away);XCTAssertEqual(before.userID,10);XCTAssertEqual(PresenceProtocol.writes,0)
        model.selection = 93;model.draft = "Unsent draft";XCTAssertTrue(model.canSend)
        let away = try await model.setManualPresence(away:true,original:before)
        XCTAssertTrue(away.away);XCTAssertEqual(model.manualAway,true);XCTAssertTrue(model.canSend);XCTAssertEqual(model.draft,"Unsent draft");XCTAssertEqual(model.selection,93)
        XCTAssertEqual(PresenceProtocol.lastWrite?["is_always_offline"],"true");XCTAssertEqual(PresenceProtocol.lastWrite?["version"],"3")
        for field in ["user_id","nickname","description","avatar","timezone"] { XCTAssertNil(PresenceProtocol.lastWrite?[field]) }
        let online = try await model.setManualPresence(away:false,original:away)
        XCTAssertFalse(online.away);XCTAssertEqual(model.manualAway,false);XCTAssertEqual(PresenceProtocol.writes,2)
    }
    func testNoOpDoesNotSubmitMutation() async throws {
        let model = try await model(),before = try await model.loadManualPresence()
        _ = try await model.setManualPresence(away:false,original:before)
        XCTAssertEqual(PresenceProtocol.writes,0)
    }
    func testChangedRemoteFlagIsNotToggledBackFromStaleSnapshot() async throws {
        let model = try await model(),before = try await model.loadManualPresence();PresenceProtocol.away = true
        do { _ = try await model.setManualPresence(away:true,original:before);XCTFail("Stale availability overwrote") } catch let error as ChatManualPresenceFailure { XCTAssertFalse(error.uncertain) }
        XCTAssertEqual(model.manualAway,true);XCTAssertEqual(PresenceProtocol.writes,0)
    }
    func testMissingOrMalformedOwnFlagPreventsWrite() async throws {
        let model = try await model(),before = try await model.loadManualPresence()
        for value:Any in [NSNull(),"false",0] {
            PresenceProtocol.rawFlag = value
            do { _ = try await model.setManualPresence(away:true,original:before);XCTFail("Unsupported flag wrote") } catch { }
        }
        XCTAssertEqual(PresenceProtocol.writes,0)
    }
    func testWrongUserAndOldAccountSnapshotCannotDispatch() async throws {
        let model = try await model(),before = try await model.loadManualPresence()
        let wrong = ChatManualPresenceSnapshot(userID:6,away:false,accountGeneration:before.accountGeneration)
        do { _ = try await model.setManualPresence(away:true,original:wrong);XCTFail("Wrong user dispatched") } catch { }
        model.signOutLocally()
        do { _ = try await model.setManualPresence(away:true,original:before);XCTFail("Old account dispatched") } catch { }
        XCTAssertEqual(PresenceProtocol.writes,0)
    }
    func testUnconfirmedWriteRequiresRefreshAndRetainsDraft() async throws {
        let model = try await model(),before = try await model.loadManualPresence();model.selection = 93;model.draft = "Keep me";PresenceProtocol.ignoreWrite = true
        do { _ = try await model.setManualPresence(away:true,original:before);XCTFail("Ignored flag confirmed") } catch let error as ChatManualPresenceFailure { XCTAssertTrue(error.uncertain) }
        XCTAssertTrue(model.manualPresenceNeedsRefresh)
        do { _ = try await model.setManualPresence(away:true,original:before);XCTFail("Uncertain mutation repeated") } catch { }
        XCTAssertEqual(PresenceProtocol.writes,1);XCTAssertEqual(model.draft,"Keep me")
        let fresh = try await model.loadManualPresence();XCTAssertFalse(model.manualPresenceNeedsRefresh);PresenceProtocol.ignoreWrite = false
        _ = try await model.setManualPresence(away:true,original:fresh);XCTAssertEqual(PresenceProtocol.writes,2)
    }
    func testSignOutAfterDispatchCannotPublishOldProfile() async throws {
        let model = try await model(),before = try await model.loadManualPresence(),started = expectation(description:"Presence write held")
        PresenceProtocol.holdWrite = true;PresenceProtocol.onWrite = { started.fulfill() }
        let action = Task { try await model.setManualPresence(away:true,original:before) }
        await fulfillment(of:[started],timeout:2);let reads = PresenceProtocol.userReads;model.signOutLocally();PresenceProtocol.held?.finish(["success":true]);PresenceProtocol.held = nil
        do { _ = try await action.value;XCTFail("Old profile published") } catch is CancellationError { }
        XCTAssertEqual(PresenceProtocol.userReads,reads);XCTAssertTrue(model.directory.isEmpty);XCTAssertFalse(model.manualPresenceBusy)
    }
    func testCancellationAfterDispatchRequiresAuthoritativeRefresh() async throws {
        let model = try await model(),before = try await model.loadManualPresence(),started = expectation(description:"Presence write held")
        PresenceProtocol.holdWrite = true;PresenceProtocol.onWrite = { started.fulfill() }
        let action = Task { try await model.setManualPresence(away:true,original:before) }
        await fulfillment(of:[started],timeout:2);action.cancel();PresenceProtocol.held?.finish(["success":true]);PresenceProtocol.held = nil
        do { _ = try await action.value;XCTFail("Cancelled profile confirmed") } catch { }
        XCTAssertTrue(model.manualPresenceNeedsRefresh);XCTAssertFalse(model.manualPresenceBusy);XCTAssertEqual(PresenceProtocol.writes,1)
    }
}

private final class PresenceProtocol:URLProtocol {
    static var away = false,ignoreWrite = false,holdWrite = false
    static var rawFlag:Any?
    static var writes = 0,userReads = 0
    static var lastWrite:[String:String]?
    static var held:PresenceProtocol?
    static var onWrite:(()->Void)?
    static func reset() { away = false;ignoreWrite = false;holdWrite = false;rawFlag = nil;writes = 0;userReads = 0;lastWrite = nil;held = nil;onWrite = nil }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        if request.url!.lastPathComponent == "SYNO.API.Info" { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Misc"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) })]);return }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };data.append(contentsOf:buffer.prefix(n)) } }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        var fields = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last });fields["api"] = request.url!.lastPathComponent
        if fields["api"] == "SYNO.Chat.User",fields["method"] == "set" {
            Self.writes += 1;Self.lastWrite = fields;if !Self.ignoreWrite { Self.away = fields["is_always_offline"] == "true" }
            if Self.holdWrite { Self.held = self;Self.onWrite?();return };finish(["success":true]);return
        }
        if fields["api"] == "SYNO.Chat.User" {
            Self.userReads += 1;finish(["success":true,"data":["users":[["user_id":10,"username":"synthetic","nickname":"Synthetic Peter","type":"human","human_type":"dsm","user_props":["is_always_offline":Self.rawFlag ?? Self.away,"timezoneUTC":"GMT"]]]]]);return
        }
        if fields["api"] == "SYNO.Chat.Channel" { finish(["success":true,"data":["channels":[["channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0,"is_joined":true]]]]);return }
        if fields["api"] == "SYNO.Chat.Misc" { finish(["success":true,"data":["acls":[]]]);return }
        finish(["success":false,"error":["code":102]])
    }
    func finish(_ value:[String:Any]) { let data = try! JSONSerialization.data(withJSONObject:value);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
