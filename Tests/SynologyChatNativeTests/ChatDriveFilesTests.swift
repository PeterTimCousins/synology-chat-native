import XCTest
@testable import SynologyChatNative

@MainActor final class ChatDriveFilesTests:XCTestCase {
    override func setUp() {super.setUp();DriveProtocol.reset()}
    private func model() async throws -> NativeChatPreviewModel {
        let m = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{session in let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [DriveProtocol.self];return try ChatAPIClient(session:session,network:URLSession(configuration:c))})
        await m.connect(using:.init(session:.init(baseURL:URL(string:"https://drive.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
        m.selection = 93;m.liveStatus = .live;XCTAssertTrue(m.connected);addTeardownBlock {@MainActor in m.signOutLocally()};return m
    }
    private func file() throws -> ChatDriveFile {try JSONDecoder().decode(ChatDriveFile.self,from:JSONSerialization.data(withJSONObject:DriveProtocol.file()))}
    private func review(_ m:NativeChatPreviewModel) async throws -> ChatDriveReview {try await m.reviewDriveFile(file(),channelID:93,rootID:nil,epoch:m.accountGeneration)}
    func testDriveCategoriesPaginationAndPermissionPreservingComposerInsertion() async throws {
        let m = try await model();m.draft = "Synthetic caption"
        let page = try await m.loadDriveFiles(location:.myDrive,folderID:nil,offset:0,channelID:93,rootID:nil,epoch:m.accountGeneration)
        XCTAssertEqual(page.files.count,1);XCTAssertFalse(page.hasMore)
        XCTAssertEqual(DriveProtocol.lastList?["path"].flatMap {try? JSONDecoder().decode(String.self,from:Data($0.utf8))},"/mydrive")
        for category in ChatDriveLocation.allCases {let p = try await m.loadDriveFiles(location:category,folderID:nil,offset:0,channelID:93,rootID:nil,epoch:m.accountGeneration);XCTAssertEqual(p.files.count+p.teams.count+p.labels.count,category == .labels ? 2 : 1)}
        let r = try await review(m);try await m.insertDriveLink(r)
        XCTAssertEqual(m.draft,"Synthetic caption\nhttps://drive.invalid/d/synthetic");XCTAssertEqual(DriveProtocol.links,1);XCTAssertEqual(DriveProtocol.permissionWrites,0);XCTAssertEqual(DriveProtocol.messageWrites,0)
    }
    func testChangedFileOrPermissionsAndDisabledPolicyPreventLinkCreation() async throws {
        for change in 0..<6 {
            DriveProtocol.reset();let m = try await model(),r = try await review(m)
            switch change {case 0:DriveProtocol.modified = 2000;case 1:DriveProtocol.permissions = [["type":"public","role":"viewer"]];case 2:DriveProtocol.allowed = false;case 3:DriveProtocol.readable = false;case 4:DriveProtocol.guest = true;default:DriveProtocol.encrypted = true}
            do {try await m.insertDriveLink(r);XCTFail("Changed file/policy accepted")} catch {}
            XCTAssertEqual(DriveProtocol.links,0);XCTAssertEqual(m.draft,"");m.signOutLocally()
        }
    }
    func testOldAccountReviewCannotCreateLink() async throws {
        let m = try await model(),r = try await review(m);m.signOutLocally()
        do {try await m.insertDriveLink(r);XCTFail("Old review accepted")} catch {}
        XCTAssertEqual(DriveProtocol.links,0)
    }
    func testSignoutDuringMetadataReadDoesNotDispatch() async throws {
        let m = try await model(),r = try await review(m),started = expectation(description:"Drive info held")
        DriveProtocol.holdInfo = true;DriveProtocol.onInfo = {started.fulfill()}
        let task = Task {try await m.insertDriveLink(r)};await fulfillment(of:[started],timeout:2);m.signOutLocally();DriveProtocol.held?.finish(["success":true,"data":DriveProtocol.file()]);DriveProtocol.held = nil
        do {try await task.value;XCTFail("Old metadata dispatched")} catch {}
        XCTAssertEqual(DriveProtocol.links,0)
    }
    func testUnsafeOrFailedLinkResponseLeavesDraftAndNeverSendsOrChangesACL() async throws {
        for failure in [false,true] {
            DriveProtocol.reset();let m = try await model(),r = try await review(m);m.draft = "Keep me";DriveProtocol.linkFailure = failure;DriveProtocol.link = "https://drive.invalid/d/synthetic?SynoToken=secret"
            do {try await m.insertDriveLink(r);XCTFail("Bad receipt accepted")} catch {}
            XCTAssertEqual(m.draft,"Keep me");XCTAssertEqual(DriveProtocol.links,1);XCTAssertEqual(DriveProtocol.permissionWrites,0);XCTAssertEqual(DriveProtocol.messageWrites,0);m.signOutLocally()
        }
    }
    func testThreadInsertionLeavesMainComposerAlone() async throws {
        let m = try await model();m.threadRoot = try JSONDecoder().decode(ChatPost.self,from:Data("{\"post_id\":50,\"channel_id\":93,\"creator_id\":10,\"type\":\"normal\",\"message\":\"root\",\"create_at\":1000}".utf8));m.draft = "Main";m.replyDraft = "Reply"
        let r = try await m.reviewDriveFile(file(),channelID:93,rootID:50,epoch:m.accountGeneration);try await m.insertDriveLink(r)
        XCTAssertEqual(m.draft,"Main");XCTAssertEqual(m.replyDraft,"Reply\nhttps://drive.invalid/d/synthetic")
    }
    func testLinkValidationAndOpaqueIDs() {
        let base = URL(string:"https://drive.invalid")!
        for id in ["","../file","id:123","/file","abc\n"] {XCTAssertFalse(ChatDriveFile.validID(id))}
        XCTAssertTrue(ChatDriveFile.validID("18446744073709551619"))
        for url in ["http://drive.invalid/d/a","javascript:alert(1)","https://user:pass@drive.invalid/d/a","https://drive.invalid/?_sid=secret","https://drive.invalid/?SynoToken=secret"] {XCTAssertNil(ChatDriveLink(url:url).validatedURL(base:base))}
        XCTAssertEqual(ChatDriveLink(url:"/d/synthetic").validatedURL(base:base)?.absoluteString,"https://drive.invalid/d/synthetic")
        XCTAssertNotNil(ChatDriveLink(url:"https://custom-sharing.invalid/d/synthetic").validatedURL(base:base))
    }
    func testMemberAccessUsesReviewedDSMUIDAndCanonicalNameReadback() async throws {
        let m = try await model(),r = try await review(m);XCTAssertEqual(r.recipients.map(\.uid),[1001]);XCTAssertEqual(r.recipients.map(\.chatID),[6])
        let updated = try await m.changeDriveAccess(r,draft:.init(scope:.members,role:.viewer))
        XCTAssertTrue(updated.file.confirms(.init(scope:.members,role:.viewer),recipients:r.recipients));XCTAssertEqual(DriveProtocol.permissionWrites,1);XCTAssertEqual(DriveProtocol.links,0);XCTAssertEqual(DriveProtocol.messageWrites,0);XCTAssertEqual(m.draft,"")
        try await m.insertDriveLink(updated);XCTAssertEqual(DriveProtocol.permissionWrites,1);XCTAssertEqual(DriveProtocol.links,1)
    }
    func testGroupPolicySwitchPreservesIndividualEntries() async throws {
        let m = try await model();DriveProtocol.permissions = [["type":"public","role":"viewer","inherited":false],["type":"user","name":"unrelated","role":"editor","inherited":false]]
        let r = try await review(m),updated = try await m.changeDriveAccess(r,draft:.init(scope:.internalLink,role:.editor))
        XCTAssertTrue(updated.file.confirms(.init(scope:.internalLink,role:.editor),recipients:[]));XCTAssertTrue(updated.file.unrelatedPermissionsMatch(r.file,draft:.init(scope:.internalLink,role:.editor),recipients:[]))
        XCTAssertEqual(DriveProtocol.permissionWrites,1);XCTAssertEqual(DriveProtocol.messageWrites,0)
    }
    func testMembershipPolicyAndFileDriftPreventPermissionDispatch() async throws {
        for change in 0..<4 {
            DriveProtocol.reset();let m = try await model(),r = try await review(m)
            switch change {case 0:DriveProtocol.memberIDs = [10];case 1:DriveProtocol.denyInvite = true;case 2:DriveProtocol.modified += 1;default:DriveProtocol.unknownPeer = true}
            do {_ = try await m.changeDriveAccess(r,draft:.init(scope:.members,role:.viewer));XCTFail("Stale access review accepted")} catch {}
            XCTAssertEqual(DriveProtocol.permissionWrites,0);m.signOutLocally()
        }
    }
    func testAmbiguousPermissionResponseIsNotRetriedAndCanBeReadBack() async throws {
        let m = try await model(),r = try await review(m);DriveProtocol.mutateThenError = true
        do {_ = try await m.changeDriveAccess(r,draft:.init(scope:.members,role:.viewer));XCTFail("Failed update acknowledged")} catch {}
        XCTAssertEqual(DriveProtocol.permissionWrites,1);XCTAssertEqual(DriveProtocol.links,0)
        let fresh = try await review(m);XCTAssertTrue(fresh.file.confirms(.init(scope:.members,role:.viewer),recipients:r.recipients));XCTAssertEqual(DriveProtocol.permissionWrites,1)
    }
    func testMissingCanonicalPermissionIsUnconfirmedAndDoesNotInsertLink() async throws {
        let m = try await model(),r = try await review(m);DriveProtocol.badACLReceipt = true
        do {_ = try await m.changeDriveAccess(r,draft:.init(scope:.members,role:.editor));XCTFail("Wrong ACL accepted")} catch {}
        XCTAssertEqual(DriveProtocol.permissionWrites,1);XCTAssertEqual(DriveProtocol.links,0);XCTAssertEqual(m.draft,"")
    }
    func testOfficeRolesAndInheritedOrAdvancedPublicPolicyFailClosed() throws {
        let f = try file(),recipients = [ChatDriveRecipient(chatID:6,uid:1001,username:"synthetic-peer",name:"Other Peter")]
        let normal = try JSONDecoder().decode(ChatDrivePolicy.self,from:Data(#"{"sharing_permission":{"public_sharing":true,"internal_link_sharing":true,"invite_sharing":true,"public_force_password":false,"public_force_expiration_days":0}}"#.utf8))
        XCTAssertNil(f.permissionEdits(.init(scope:.members,role:.commenter),recipients:recipients,policy:normal));XCTAssertNotNil(f.permissionEdits(.init(scope:.publicLink,role:.viewer),recipients:[],policy:normal))
        DriveProtocol.permissions = [["type":"public","role":"viewer","inherited":true]];XCTAssertNil(try file().permissionEdits(.init(scope:.internalLink,role:.viewer),recipients:[],policy:normal))
        let restricted = try JSONDecoder().decode(ChatDrivePolicy.self,from:Data(#"{"sharing_permission":{"public_sharing":true,"internal_link_sharing":true,"invite_sharing":true,"public_force_password":true,"public_force_expiration_days":7}}"#.utf8))
        XCTAssertNil(f.permissionEdits(.init(scope:.publicLink,role:.viewer),recipients:[],policy:restricted))
    }
    func testSearchUsesServerKeywordWithoutCreatingLinksOrChangingAccess() async throws {
        let m = try await model()
        let page = try await m.loadDriveFiles(location:.myDrive,folderID:nil,offset:0,channelID:93,rootID:nil,epoch:m.accountGeneration,query:"Synthetic.txt")
        XCTAssertEqual(page.files.count,1);XCTAssertEqual(DriveProtocol.lastList?["method"],"search");XCTAssertEqual(DriveProtocol.lastList?["content_snippet"],"false");XCTAssertNil(DriveProtocol.lastList?["path"])
        XCTAssertEqual(DriveProtocol.lastList?["keyword"],"\"Synthetic.txt\"");XCTAssertEqual(DriveProtocol.links,0);XCTAssertEqual(DriveProtocol.permissionWrites,0)
    }
    func testLabelsPreserveIntegerAndOpaqueStringIdentifiers() async throws {
        let m = try await model(),page = try await m.loadDriveFiles(location:.labels,folderID:nil,offset:0,channelID:93,rootID:nil,epoch:m.accountGeneration)
        XCTAssertEqual(page.labels.map(\.id),[.number(7),.text("label-2")])
        _ = try await m.loadDriveFiles(location:.labels,folderID:nil,offset:0,channelID:93,rootID:nil,epoch:m.accountGeneration,labelID:.number(7));XCTAssertEqual(DriveProtocol.lastList?["method"],"list_labelled");XCTAssertEqual(DriveProtocol.lastList?["label_id"],"7")
        _ = try await m.loadDriveFiles(location:.labels,folderID:nil,offset:0,channelID:93,rootID:nil,epoch:m.accountGeneration,labelID:.text("label-2"));XCTAssertEqual(DriveProtocol.lastList?["label_id"],"\"label-2\"")
        _ = try await m.loadDriveFiles(location:.labels,folderID:"folder-123",offset:0,channelID:93,rootID:nil,epoch:m.accountGeneration);XCTAssertEqual(DriveProtocol.lastList?["method"],"list");XCTAssertNil(DriveProtocol.lastList?["label_id"])
    }
    func testOversizeAndEmptySearchFailBeforeListing() async throws {
        let m = try await model()
        for value in [" ",String(repeating:"x",count:513),"bad\0query"] {
            do {_ = try await m.loadDriveFiles(location:.myDrive,folderID:nil,offset:0,channelID:93,rootID:nil,epoch:m.accountGeneration,query:value);XCTFail("Invalid search accepted")} catch {}
        }
        XCTAssertNil(DriveProtocol.lastList);XCTAssertEqual(DriveProtocol.links,0)
    }
    func testMalformedDuplicatePageFailsClosed() async throws {
        let m = try await model();DriveProtocol.duplicate = true
        do {_ = try await m.loadDriveFiles(location:.myDrive,folderID:nil,offset:0,channelID:93,rootID:nil,epoch:m.accountGeneration);XCTFail("Duplicate accepted")} catch {}
        XCTAssertEqual(DriveProtocol.links,0)
    }
}

private final class DriveProtocol:URLProtocol {
    static var allowed = true,readable = true,guest = false,encrypted = false,holdInfo = false,linkFailure = false,duplicate = false
    static var memberIDs:[Int64] = [10,6]
    static var unknownPeer = false,denyInvite = false,badACLReceipt = false,mutateThenError = false
    static var modified = 1000,links = 0,permissionWrites = 0,messageWrites = 0
    static var permissions:[[String:Any]] = [],lastList:[String:String]?,held:DriveProtocol?,onInfo:(()->Void)?,link = "https://drive.invalid/d/synthetic"
    static func reset() {memberIDs = [10,6];unknownPeer = false;denyInvite = false;badACLReceipt = false;mutateThenError = false;allowed = true;readable = true;guest = false;encrypted = false;holdInfo = false;linkFailure = false;duplicate = false;modified = 1000;links = 0;permissionWrites = 0;messageWrites = 0;permissions = [];lastList = nil;held = nil;onInfo = nil;link = "https://drive.invalid/d/synthetic"}
    static func file()->[String:Any] {["file_id":"18446744073709551619","name":"Synthetic.txt","type":"file","size":62,"modified_time":modified,"version_id":"v1","hash":"synthetic","encrypted":false,"removed":false,"transient":false,"capabilities":["can_read":readable,"can_organize":true,"can_share":true],"shared_with":permissions]}
    override class func canInit(with request:URLRequest)->Bool {request.url?.host == "drive.invalid"}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        if request.url!.lastPathComponent == "SYNO.API.Info" {finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.SynologyDrive.Labels","SYNO.Chat.Channel.Member","SYNO.SynologyDrive.Files","SYNO.SynologyDrive.TeamFolders","SYNO.SynologyDrive.Settings","SYNO.SynologyDrive.Sharing","SYNO.Chat.Admin.Setting","SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Post","SYNO.Chat.Misc"].map {($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any])})]);return}
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream {stream.open();defer {stream.close()};var b = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable {let n = stream.read(&b,maxLength:b.count);if n <= 0 {break};data.append(contentsOf:b.prefix(n))}}
        var q = URLComponents();q.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let f = Dictionary((q.queryItems ?? []).map {($0.name,$0.value ?? "")},uniquingKeysWith:{_,last in last}),api = request.url!.lastPathComponent
        if api == "SYNO.Chat.Admin.Setting" {finish(["success":true,"data":["allow_drive_upload":Self.allowed]]);return}
        if api == "SYNO.SynologyDrive.Settings" {finish(["success":true,"data":["sharing_permission":["public_sharing":true,"internal_link_sharing":true,"invite_sharing":!Self.denyInvite,"public_force_password":false,"public_force_expiration_days":0]]]);return}
        if api == "SYNO.SynologyDrive.Files" {
            if f["method"] == "get" {if Self.holdInfo {Self.held = self;Self.onInfo?();return};finish(["success":true,"data":Self.file()]);return}
            Self.lastList = f;let items = Self.duplicate ? [Self.file(),Self.file()] : [Self.file()];finish(["success":true,"data":["items":items,"total":items.count]]);return
        }
        if api == "SYNO.SynologyDrive.Labels" {finish(["success":true,"data":["items":[["label_id":7,"name":"Synthetic label"],["label_id":"label-2","name":"Second synthetic label"]],"total":2]]);return}
        if api == "SYNO.SynologyDrive.TeamFolders" {finish(["success":true,"data":["items":[["file_id":"team123","name":"Synthetic team","capabilities":["can_read":true,"can_organize":true,"can_share":true]]],"total":1]]);return}
        if api == "SYNO.SynologyDrive.Sharing" {
            if f["method"] == "create_link" {Self.links += 1;if Self.linkFailure {finish(["success":false,"error":["code":500]]);return};finish(["success":true,"data":["url":Self.link]]);return}
            Self.permissionWrites += 1
            if let raw = f["permissions"],let edits = try? JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [[String:Any]] {
                for edit in edits {
                    let member = edit["member"] as? [String:Any] ?? [:],type = member["type"] as? String ?? "",uid = member["uid"] as? Int64
                    Self.permissions.removeAll {entry in (entry["type"] as? String) == type && (type != "user" || (entry["name"] as? String) == "synthetic-peer")}
                    if edit["action"] as? String == "update" && !Self.badACLReceipt {var entry:[String:Any] = ["type":type,"role":edit["role"] ?? "viewer","inherited":false];if type == "user",uid == 1001 {entry["name"] = "synthetic-peer";entry["display_name"] = "Other Peter"};Self.permissions.append(entry)}
                }
            }
            if Self.mutateThenError {finish(["success":false,"error":["code":500]]);return}
            finish(["success":true,"data":[:]]);return
        }
        if api == "SYNO.Chat.Channel.Member" {finish(["success":true,"data":["user_ids":Self.memberIDs]]);return}
        if api == "SYNO.Chat.User" {finish(["success":true,"data":["users":[["user_id":10,"username":"synthetic","dsm_uid":1000,"nickname":"Synthetic Peter","type":"human","human_type":Self.guest ? "guest" : "dsm"],["user_id":6,"username":"synthetic-peer","dsm_uid":Self.unknownPeer ? 0 : 1001,"nickname":"Other Peter","type":"human","human_type":"dsm"]]]]);return}
        if api == "SYNO.Chat.Channel" {finish(["success":true,"data":["channels":[["channel_id":93,"name":"Peter","type":"anonymous","encrypted":Self.encrypted,"unread":0,"is_joined":true]]]]);return}
        if api == "SYNO.Chat.Post" {if f["method"] == "create" {Self.messageWrites += 1};finish(["success":true,"data":["posts":[]]]);return}
        if api == "SYNO.Chat.Misc" {finish(["success":true,"data":["acls":[]]]);return}
        finish(["success":false,"error":["code":102]])
    }
    func finish(_ value:[String:Any]) {let d = try! JSONSerialization.data(withJSONObject:value);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:d);client?.urlProtocolDidFinishLoading(self)}
    override func stopLoading() {}
}
