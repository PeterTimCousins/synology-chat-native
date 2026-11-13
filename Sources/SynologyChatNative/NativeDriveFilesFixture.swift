#if DEBUG
import AppKit
import SwiftUI

@MainActor enum NativeDriveFilesFixture {
    private static var controller:NSWindowController?
    static func present() {
        guard NativeChatAppConfiguration.standalone,NativeChatAppConfiguration.allowsOfficialSessionImport else {return}
        Task {
            controller?.close()
            let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{session in let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [DriveFilesFixtureProtocol.self];return try ChatAPIClient(session:session,network:URLSession(configuration:c))})
            await model.connect(using:.init(session:.init(baseURL:URL(string:"https://drive-files-ui.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
            guard model.connected else {return};model.selection = 93;model.liveStatus = .live;model.draft = "Synthetic Drive caption"
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:530),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title = "Drive picker fixture — intercepted responses only";window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView:DriveFilesFixtureView(model:model));window.center();controller = NSWindowController(window:window);controller?.showWindow(nil);window.makeKeyAndOrderFront(nil)
        }
    }
}
private struct DriveFilesFixtureView:View {
    @ObservedObject var model:NativeChatPreviewModel
    var body:some View {
        if model.draft.contains("https://") {VStack(alignment:.leading,spacing:20) {Text("Link added to synthetic draft").font(.title2);Text(model.draft).textSelection(.enabled);Text("No Chat send or permission update was made.")}.padding(30).frame(width:680,height:530).nativeChatAppearance()}
        else {NativeDriveFilePicker(model:model,inThread:false)}
    }
}
private final class DriveFilesFixtureProtocol:URLProtocol {
    static var allowed = true,readable = true,guest = false,encrypted = false,holdInfo = false,linkFailure = false,duplicate = false
    static var memberIDs:[Int64] = [10,6]
    static var unknownPeer = false,denyInvite = false,badACLReceipt = false,mutateThenError = false
    static var modified = 1000,links = 0,permissionWrites = 0,messageWrites = 0
    static var permissions:[[String:Any]] = [],lastList:[String:String]?,held:DriveFilesFixtureProtocol?,onInfo:(()->Void)?,link = "https://drive-files-ui.invalid/d/synthetic"
    static func reset() {memberIDs = [10,6];unknownPeer = false;denyInvite = false;badACLReceipt = false;mutateThenError = false;allowed = true;readable = true;guest = false;encrypted = false;holdInfo = false;linkFailure = false;duplicate = false;modified = 1000;links = 0;permissionWrites = 0;messageWrites = 0;permissions = [];lastList = nil;held = nil;onInfo = nil;link = "https://drive-files-ui.invalid/d/synthetic"}
    static func file()->[String:Any] {["file_id":"18446744073709551619","name":"Synthetic.txt","type":"file","size":62,"modified_time":modified,"version_id":"v1","hash":"synthetic","encrypted":false,"removed":false,"transient":false,"capabilities":["can_read":readable,"can_organize":true,"can_share":true],"shared_with":permissions]}
    override class func canInit(with request:URLRequest)->Bool {request.url?.host == "drive-files-ui.invalid"}
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
            if f["method"] == "get" {if Self.holdInfo {Self.held = self;Self.onInfo?();return};var item = Self.file();let path = f["path"].flatMap {try? JSONDecoder().decode(String.self,from:Data($0.utf8))} ?? "id:synthetic-1";let id = String(path.dropFirst(3));item["file_id"] = id;item["name"] = String(format:"Synthetic-%03d.txt",Int(id.split(separator:"-").last ?? "1") ?? 1);finish(["success":true,"data":item]);return}
            Self.lastList = f
            let path = f["path"].flatMap {try? JSONDecoder().decode(String.self,from:Data($0.utf8))}
            let offset = Int(f["offset"] ?? "0") ?? 0
            let all:[[String:Any]] = path == "id:empty" ? [] : (1...103).map {i in var item = Self.file();item["file_id"] = "synthetic-"+String(i);item["name"] = String(format:"Synthetic-%03d.txt",i);if i == 2 {item["capabilities"] = ["can_read":false,"can_organize":false,"can_share":false]};return item}
            finish(["success":true,"data":["items":Array(all.dropFirst(offset).prefix(100)),"total":all.count]]);return
        }
        if api == "SYNO.SynologyDrive.Labels" {finish(["success":true,"data":["items":[["label_id":7,"name":"Synthetic label"],["label_id":"label-2","name":"Second synthetic label"]],"total":2]]);return}
        if api == "SYNO.SynologyDrive.TeamFolders" {finish(["success":true,"data":["items":[["file_id":"empty","name":"Synthetic team","capabilities":["can_read":true,"can_organize":true,"can_share":true]]],"total":1]]);return}
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

#endif
