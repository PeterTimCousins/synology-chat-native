import XCTest
@testable import SynologyChatNative

@MainActor final class ChatPairedDevicesTests:XCTestCase {
    override func setUp() { super.setUp();DeviceProtocol.reset() }
    private func model() async throws -> NativeChatPreviewModel {
        let m = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [DeviceProtocol.self]
            return try ChatAPIClient(session:session,network:URLSession(configuration:c))
        })
        await m.connect(using:.init(session:.init(baseURL:URL(string:"https://devices.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
        XCTAssertTrue(m.connected);addTeardownBlock { @MainActor in m.signOutLocally() };return m
    }
    func testUnpairFreshOwnChatDeviceOnlyAndReadCanonicalList() async throws {
        let m = try await model(),before = try await m.loadPairedDevices()
        XCTAssertEqual(before.devices.count,2);XCTAssertEqual(before.devices[1].firmware_version.display,"18.1")
        m.selection = 93;m.draft = "Unsent message"
        let after = try await m.unpairDevice(before.devices[0],original:before)
        XCTAssertEqual(after.devices.map(\.id),[102]);XCTAssertEqual(m.draft,"Unsent message");XCTAssertEqual(DeviceProtocol.writes,1)
        XCTAssertEqual(DeviceProtocol.lastWrite?["version"],"1");XCTAssertEqual(DeviceProtocol.lastWrite?["package"],"\"Chat\"")
        let rows = try JSONSerialization.jsonObject(with:Data(DeviceProtocol.lastWrite!["list"]!.utf8)) as! [[String:Any]]
        XCTAssertEqual(rows.count,1);XCTAssertEqual(rows[0]["id"] as? Int,101);XCTAssertEqual(rows[0]["identity"] as? String,"synthetic-phone");XCTAssertEqual(rows[0]["app_version"] as? Int,100);XCTAssertEqual(rows[0]["firmware_version"] as? Double,17.4)
        XCTAssertNil(DeviceProtocol.lastWrite?["user_id"])
    }
    func testAlreadyAbsentDeviceDoesNotRepeatUnpair() async throws {
        let m = try await model(),before = try await m.loadPairedDevices();DeviceProtocol.devices.removeFirst()
        let after = try await m.unpairDevice(before.devices[0],original:before)
        XCTAssertEqual(after.devices.count,1);XCTAssertEqual(DeviceProtocol.writes,0)
    }
    func testReusedIDWithChangedIdentityCannotUnpairDifferentRegistration() async throws {
        let m = try await model(),before = try await m.loadPairedDevices();DeviceProtocol.devices[0]["identity"] = "new-registration"
        do { _ = try await m.unpairDevice(before.devices[0],original:before);XCTFail("Changed device unpaired") } catch let e as ChatDeviceUpdateFailure { XCTAssertFalse(e.uncertain) }
        XCTAssertEqual(DeviceProtocol.writes,0)
    }
    func testMalformedDuplicateAndOtherPackageRowsFailClosed() async throws {
        let m = try await model(),original = DeviceProtocol.devices
        for change in ["duplicate","package","identity","id","count","version"] {
            DeviceProtocol.devices = original;DeviceProtocol.countOffset = 0
            switch change {
            case "duplicate":DeviceProtocol.devices[1] = DeviceProtocol.devices[0]
            case "package":DeviceProtocol.devices[0]["package"] = "Other"
            case "identity":DeviceProtocol.devices[0]["identity"] = ""
            case "id":DeviceProtocol.devices[0]["id"] = -1
            case "count":DeviceProtocol.countOffset = 1
            default:DeviceProtocol.devices[0]["app_version"] = true
            }
            do { _ = try await m.loadPairedDevices();XCTFail("Invalid device accepted: \(change)") } catch { }
        }
        XCTAssertEqual(DeviceProtocol.writes,0)
    }
    func testUnconfirmedUnpairRequiresRefreshBeforeAnotherWrite() async throws {
        let m = try await model(),before = try await m.loadPairedDevices();DeviceProtocol.ignoreWrite = true
        do { _ = try await m.unpairDevice(before.devices[0],original:before);XCTFail("Ignored unpair confirmed") } catch let e as ChatDeviceUpdateFailure { XCTAssertTrue(e.uncertain) }
        XCTAssertTrue(m.pairedDevicesNeedRefresh)
        do { _ = try await m.unpairDevice(before.devices[1],original:before);XCTFail("Uncertain unpair repeated") } catch { }
        XCTAssertEqual(DeviceProtocol.writes,1)
        DeviceProtocol.countOffset = 1
        do { _ = try await m.loadPairedDevices();XCTFail("Bad refresh accepted") } catch { }
        XCTAssertTrue(m.pairedDevicesNeedRefresh)
        DeviceProtocol.countOffset = 0;_ = try await m.loadPairedDevices();XCTAssertFalse(m.pairedDevicesNeedRefresh)
    }
    func testOldAccountSnapshotCannotDispatch() async throws {
        let m = try await model(),before = try await m.loadPairedDevices();m.signOutLocally()
        do { _ = try await m.unpairDevice(before.devices[0],original:before);XCTFail("Old account wrote") } catch { }
        XCTAssertEqual(DeviceProtocol.writes,0)
    }
    func testSignOutAfterUnpairCannotPublishOldDevices() async throws {
        let m = try await model(),before = try await m.loadPairedDevices(),started = expectation(description:"Unpair held")
        DeviceProtocol.holdWrite = true;DeviceProtocol.onWrite = { started.fulfill() }
        let action = Task { try await m.unpairDevice(before.devices[0],original:before) }
        await fulfillment(of:[started],timeout:2);let reads = DeviceProtocol.deviceReads;m.signOutLocally();DeviceProtocol.held?.finish(["success":true]);DeviceProtocol.held = nil
        do { _ = try await action.value;XCTFail("Old devices published") } catch is CancellationError { }
        XCTAssertEqual(DeviceProtocol.deviceReads,reads);XCTAssertFalse(m.pairedDevicesBusy)
    }
    func testCancelledUnpairDoesNotAutomaticallyRetry() async throws {
        let m = try await model(),before = try await m.loadPairedDevices(),started = expectation(description:"Unpair held")
        DeviceProtocol.holdWrite = true;DeviceProtocol.onWrite = { started.fulfill() }
        let action = Task { try await m.unpairDevice(before.devices[0],original:before) }
        await fulfillment(of:[started],timeout:2);action.cancel();DeviceProtocol.held?.finish(["success":true]);DeviceProtocol.held = nil
        do { _ = try await action.value;XCTFail("Cancelled unpair confirmed") } catch { }
        XCTAssertTrue(m.pairedDevicesNeedRefresh);XCTAssertEqual(DeviceProtocol.writes,1)
    }
}

private final class DeviceProtocol:URLProtocol {
    static let initial:[[String:Any]] = [["id":101,"device_name":"Synthetic phone","identity":"synthetic-phone","package":"Chat","firmware_version":17.4,"app_version":100],["id":102,"device_name":"Synthetic tablet","identity":"synthetic-tablet","package":"Chat","firmware_version":"18.1","app_version":"2.0"]]
    static var devices = initial
    static var writes = 0,deviceReads = 0,countOffset = 0
    static var ignoreWrite = false,holdWrite = false
    static var lastWrite:[String:String]?
    static var held:DeviceProtocol?
    static var onWrite:(()->Void)?
    static func reset() { devices = initial;writes = 0;deviceReads = 0;countOffset = 0;ignoreWrite = false;holdWrite = false;lastWrite = nil;held = nil;onWrite = nil }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        if request.url!.lastPathComponent == "SYNO.API.Info" { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Personal.Notification.Device","SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Misc"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) })]);return }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var b = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&b,maxLength:b.count);if n <= 0 { break };data.append(contentsOf:b.prefix(n)) } }
        var q = URLComponents();q.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((q.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last }),api = request.url!.lastPathComponent
        if api == "SYNO.Personal.Notification.Device" {
            if fields["method"] == "list" { Self.deviceReads += 1;finish(["success":true,"data":["count":Self.devices.count+Self.countOffset,"list":Self.devices]]);return }
            Self.writes += 1;Self.lastWrite = fields
            if !Self.ignoreWrite,let raw = fields["list"],let rows = try? JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [[String:Any]],let id = rows.first?["id"] as? Int { Self.devices.removeAll { $0["id"] as? Int == id } }
            if Self.holdWrite { Self.held = self;Self.onWrite?();return };finish(["success":true]);return
        }
        if api == "SYNO.Chat.User" { finish(["success":true,"data":["users":[["user_id":10,"username":"synthetic","nickname":"Synthetic Peter"]]]]);return }
        if api == "SYNO.Chat.Channel" { finish(["success":true,"data":["channels":[["channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0,"is_joined":true]]]]);return }
        if api == "SYNO.Chat.Misc" { finish(["success":true,"data":["acls":[]]]);return }
        finish(["success":false,"error":["code":102]])
    }
    func finish(_ value:[String:Any]) { let data = try! JSONSerialization.data(withJSONObject:value);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
