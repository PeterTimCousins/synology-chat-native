#if DEBUG
import SwiftUI
import AppKit

@MainActor enum NativeNASFilesFixture {
    private static var controller:NSWindowController?
    static func present() {
        guard NativeChatAppConfiguration.standalone,NativeChatAppConfiguration.allowsOfficialSessionImport else {return}
        Task {
            controller?.close()
            let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{session in let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [NASFilesFixtureProtocol.self];return try ChatAPIClient(session:session,network:URLSession(configuration:c))})
            await model.connect(using:.init(session:.init(baseURL:URL(string:"https://nas-files-ui.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
            guard model.connected else {return};model.selection = 93;model.liveStatus = .live;model.draft = "Synthetic NAS caption"
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:660,height:560),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title = "NAS browse/review fixture — no delivery connection";window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView:NASFilesFixtureView(model:model));window.center();controller = NSWindowController(window:window);controller?.showWindow(nil);window.makeKeyAndOrderFront(nil)
        }
    }
}
private struct NASFilesFixtureView:View {
    @ObservedObject var model:NativeChatPreviewModel
    var body:some View {
        if let batch = model.attachmentBatch {NativeAttachmentBatchView(model:model,batch:batch)}
        else {NativeNASFilePicker(model:model,inThread:false) {selection in model.stageNASFiles(selection);if model.attachmentBatch != nil {model.liveStatus = .offline}}.onAppear {model.liveStatus = .live}}
    }
}
private final class NASFilesFixtureProtocol:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool {request.url?.host == "nas-files-ui.invalid"}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        if request.url!.lastPathComponent == "SYNO.API.Info" {finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Core.File","SYNO.Chat.Admin.Setting","SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Post","SYNO.Chat.Misc"].map {($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any])})]);return}
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream {stream.open();defer {stream.close()};var b = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable {let n = stream.read(&b,maxLength:b.count);if n <= 0 {break};data.append(contentsOf:b.prefix(n))}}
        var q = URLComponents();q.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((q.queryItems ?? []).map {($0.name,$0.value ?? "")},uniquingKeysWith:{_,last in last}),api = request.url!.lastPathComponent
        if api == "SYNO.Chat.Admin.Setting" {finish(["success":true,"data":["allow_ds_upload":true,"file_size_limit":0]]);return}
        if api == "SYNO.Core.File" {
            let folder = (fields["folder_path"].flatMap {try? JSONDecoder().decode(String.self,from:Data($0.utf8))}) ?? "/"
            if folder == "/" {finish(["success":true,"data":[["spath":"/Synthetic","text":"Synthetic files"],["spath":"/home","text":"Filtered alias"]]]);return}
            func file(_ name:String,dir:Bool = false,read:Bool = true)->[String:Any] {["path":folder+"/"+name,"name":name,"isdir":dir,"additional":["size":4,"time":["mtime":1000,"ctime":1000],"perm":["acl":["read":read]],"type":"txt"]]}
            let all = folder == "/Synthetic" ? [file("Empty folder",dir:true),file("Cannot read.txt",read:false)]+(1...101).map {file(String(format:"Synthetic-%03d.txt",$0))} : []
            let offset = Int(fields["offset"] ?? "0") ?? 0
            finish(["success":true,"data":["files":Array(all.dropFirst(offset).prefix(100)),"offset":offset,"total":all.count]]);return
        }
        if api == "SYNO.Chat.User" {finish(["success":true,"data":["users":[["user_id":10,"username":"synthetic","nickname":"Synthetic Peter","type":"human","human_type":"dsm"]]]]);return}
        if api == "SYNO.Chat.Channel" {finish(["success":true,"data":["channels":[["channel_id":93,"name":"Peter","type":"anonymous","encrypted":false,"unread":0,"is_joined":true]]]]);return}
        if api == "SYNO.Chat.Post",fields["method"] == "list" {finish(["success":true,"data":["posts":[]]]);return}
        if api == "SYNO.Chat.Misc" {finish(["success":true,"data":["acls":[]]]);return}
        // This UI fixture never sends a message or opens a real connection.
        finish(["success":false,"error":["code":102]])
    }
    private func finish(_ value:[String:Any]) {let d = try! JSONSerialization.data(withJSONObject:value);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:d);client?.urlProtocolDidFinishLoading(self)}
    override func stopLoading() {}
}
#endif
