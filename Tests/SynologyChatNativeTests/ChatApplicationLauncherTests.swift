import XCTest
@testable import SynologyChatNative

@MainActor final class ChatApplicationLauncherTests:XCTestCase {
    override func setUp() {super.setUp();LauncherProtocol.reset()}
    private func model() async throws -> NativeChatPreviewModel {
        let m = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{session in let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [LauncherProtocol.self];return try ChatAPIClient(session:session,network:URLSession(configuration:c))})
        await m.connect(using:.init(session:.init(baseURL:URL(string:"https://launcher.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
        XCTAssertTrue(m.connected);addTeardownBlock {@MainActor in m.signOutLocally()};return m
    }
    func testLauncherRouteRejectsExternalCredentialsAndUnknownRouting() throws {
        func app(_ route:String,type:String = "local") throws -> ChatLauncherApplication {
            let data = try JSONSerialization.data(withJSONObject:["appname":"SYNO.Cal.Application","name":"Calendar","description":"Calendar","type":type,"launch_url":route])
            return try JSONDecoder().decode(ChatLauncherApplication.self,from:data)
        }
        let base = URL(string:"https://launcher.invalid")!
        for safe in ["/?launchApp=SYNO.Cal.Application","https://launcher.invalid:443/?launchApp=SYNO.Cal.Application"] {XCTAssertNotNil(try app(safe).launchURL(baseURL:base))}
        for unsafe in ["https://other.invalid/?launchApp=SYNO.Cal.Application","http://launcher.invalid/?launchApp=SYNO.Cal.Application","https://user:password@launcher.invalid/?launchApp=SYNO.Cal.Application","/?launchApp=SYNO.Cal.Application&SynoToken=synthetic","/?launchApp=Other","/?launchApp=SYNO.Cal.Application#token","/webapi/entry.cgi?launchApp=SYNO.Cal.Application","javascript:alert(1)","/?launchApp=SYNO.Cal.Application&launchApp=Other"] {XCTAssertNil(try app(unsafe).launchURL(baseURL:base))}
        XCTAssertNil(try app("/?launchApp=SYNO.Cal.Application",type:"wsg").launchURL(baseURL:base))
    }
    func testFreshLaunchAllowsBadgeChangesButNotChangedRoutesOrRemovedApps() async throws {
        let m = try await model(),before = try await m.loadLauncherApplications(),app = before.applications[0]
        LauncherProtocol.apps[0]["badge"] = 7
        let url = try await m.resolveLauncherApplication(app,original:before);XCTAssertEqual(url.query,"launchApp=SYNO.Cal.Application")
        LauncherProtocol.apps[0]["launch_url"] = "https://other.invalid/?launchApp=SYNO.Cal.Application"
        do {_ = try await m.resolveLauncherApplication(app,original:before);XCTFail("Changed route opened")} catch {}
        LauncherProtocol.apps.removeFirst()
        do {_ = try await m.resolveLauncherApplication(app,original:before);XCTFail("Unavailable app opened")} catch {}
        XCTAssertEqual(LauncherProtocol.writes,0)
    }
    func testOrderRoundtripSendsAllAppNamesInChosenOrderAndPreservesDraft() async throws {
        let m = try await model(),before = try await m.loadLauncherApplications(),names = Array(before.applications.map(\.appname).reversed())
        m.selection = 93;m.draft = "Unsent message"
        let after = try await m.saveLauncherOrder(names,original:before)
        XCTAssertEqual(after.applications.map(\.appname),names);XCTAssertEqual(m.draft,"Unsent message")
        XCTAssertEqual(LauncherProtocol.lastWrite?["version"],"1");XCTAssertNil(LauncherProtocol.lastWrite?["launch_url"])
        let restored = try await m.saveLauncherOrder(before.applications.map(\.appname),original:after)
        XCTAssertEqual(restored.applications.map(\.appname),before.applications.map(\.appname));XCTAssertEqual(LauncherProtocol.writes,2)
    }
    func testNoOpStaleOrderAndInvalidMembershipDoNotWrite() async throws {
        let m = try await model(),before = try await m.loadLauncherApplications(),names = before.applications.map(\.appname)
        _ = try await m.saveLauncherOrder(names,original:before)
        do {_ = try await m.saveLauncherOrder([names[0],names[0]],original:before);XCTFail("Duplicate order wrote")} catch {}
        LauncherProtocol.apps.reverse()
        do {_ = try await m.saveLauncherOrder(Array(names.reversed()),original:before);XCTFail("Stale order wrote")} catch {}
        XCTAssertEqual(LauncherProtocol.writes,0)
    }
    func testUnconfirmedOrderBlocksOpeningAndWritingUntilRefresh() async throws {
        let m = try await model(),before = try await m.loadLauncherApplications(),names = Array(before.applications.map(\.appname).reversed());LauncherProtocol.ignoreWrite = true
        do {_ = try await m.saveLauncherOrder(names,original:before);XCTFail("Ignored order confirmed")} catch {}
        XCTAssertTrue(m.launcherNeedsRefresh)
        do {_ = try await m.resolveLauncherApplication(before.applications[0],original:before);XCTFail("Uncertain view opened app")} catch {}
        do {_ = try await m.saveLauncherOrder(names,original:before);XCTFail("Repeated uncertain order")} catch {}
        XCTAssertEqual(LauncherProtocol.writes,1);_ = try await m.loadLauncherApplications();XCTAssertFalse(m.launcherNeedsRefresh)
    }
    func testDuplicateAndTruncatedListsFailClosed() async throws {
        let m = try await model();LauncherProtocol.apps[1] = LauncherProtocol.apps[0]
        do {_ = try await m.loadLauncherApplications();XCTFail("Duplicate apps accepted")} catch {}
        LauncherProtocol.apps = LauncherProtocol.initial;LauncherProtocol.countOffset = 1
        do {_ = try await m.loadLauncherApplications();XCTFail("Truncated apps accepted")} catch {}
        XCTAssertEqual(LauncherProtocol.writes,0)
    }
    func testSignOutAfterOrderDispatchCannotPublishOldList() async throws {
        let m = try await model(),before = try await m.loadLauncherApplications(),names = Array(before.applications.map(\.appname).reversed()),started = expectation(description:"Order held")
        LauncherProtocol.holdWrite = true;LauncherProtocol.onWrite = {started.fulfill()}
        let action = Task {try await m.saveLauncherOrder(names,original:before)}
        await fulfillment(of:[started],timeout:2);m.signOutLocally();LauncherProtocol.held?.finish(["success":true]);LauncherProtocol.held = nil
        do {_ = try await action.value;XCTFail("Old launcher published")} catch is CancellationError {}
        XCTAssertFalse(m.launcherBusy)
        do {_ = try await m.resolveLauncherApplication(before.applications[0],original:before);XCTFail("Old account opened app")} catch {}
    }
    func testCancelledOrderRequiresRefreshAndNoAutomaticRetry() async throws {
        let m = try await model(),before = try await m.loadLauncherApplications(),names = Array(before.applications.map(\.appname).reversed()),started = expectation(description:"Order held")
        LauncherProtocol.holdWrite = true;LauncherProtocol.onWrite = {started.fulfill()}
        let action = Task {try await m.saveLauncherOrder(names,original:before)}
        await fulfillment(of:[started],timeout:2);action.cancel();LauncherProtocol.held?.finish(["success":true]);LauncherProtocol.held = nil
        do {_ = try await action.value;XCTFail("Cancelled order confirmed")} catch {}
        XCTAssertTrue(m.launcherNeedsRefresh);XCTAssertEqual(LauncherProtocol.writes,1)
    }
}

private final class LauncherProtocol:URLProtocol {
    static let initial:[[String:Any]] = [["appname":"SYNO.Cal.Application","name":"Calendar","description":"Calendar","type":"local","badge":2,"launch_url":"https://launcher.invalid/?launchApp=SYNO.Cal.Application"],["appname":"SYNO.SDS.Drive.Application","name":"Drive","description":"Drive","type":"local","badge":0,"launch_url":"https://launcher.invalid/?launchApp=SYNO.SDS.Drive.Application"]]
    static var apps = initial
    static var writes = 0,countOffset = 0
    static var ignoreWrite = false,holdWrite = false
    static var lastWrite:[String:String]?,held:LauncherProtocol?,onWrite:(()->Void)?
    static func reset() {apps = initial;writes = 0;countOffset = 0;ignoreWrite = false;holdWrite = false;lastWrite = nil;held = nil;onWrite = nil}
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        if request.url!.lastPathComponent == "SYNO.API.Info" {finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Personal.Application.Info","SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Misc"].map {($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any])})]);return}
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream {stream.open();defer {stream.close()};var b = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable {let n = stream.read(&b,maxLength:b.count);if n <= 0 {break};data.append(contentsOf:b.prefix(n))}}
        var q = URLComponents();q.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((q.queryItems ?? []).map {($0.name,$0.value ?? "")},uniquingKeysWith:{_,last in last}),api = request.url!.lastPathComponent
        if api == "SYNO.Personal.Application.Info" {
            if fields["method"] == "get" {finish(["success":true,"data":["total":Self.apps.count+Self.countOffset,"applications":Self.apps]]);return}
            Self.writes += 1;Self.lastWrite = fields
            if !Self.ignoreWrite,let raw = fields["app_order"],let names = try? JSONDecoder().decode([String].self,from:Data(raw.utf8)) {Self.apps = names.compactMap {n in Self.apps.first(where:{$0["appname"] as? String == n})}}
            if Self.holdWrite {Self.held = self;Self.onWrite?();return};finish(["success":true]);return
        }
        if api == "SYNO.Chat.User" {finish(["success":true,"data":["users":[["user_id":10,"username":"synthetic","nickname":"Synthetic Peter"]]]]);return}
        if api == "SYNO.Chat.Channel" {finish(["success":true,"data":["channels":[["channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0,"is_joined":true]]]]);return}
        if api == "SYNO.Chat.Misc" {finish(["success":true,"data":["acls":[]]]);return}
        finish(["success":false,"error":["code":102]])
    }
    func finish(_ v:[String:Any]) {let d = try! JSONSerialization.data(withJSONObject:v);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:d);client?.urlProtocolDidFinishLoading(self)}
    override func stopLoading() {}
}
