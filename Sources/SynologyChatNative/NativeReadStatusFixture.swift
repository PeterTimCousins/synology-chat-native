#if DEBUG
import AppKit
import SwiftUI

/// Read-only local fixture. All network requests are intercepted, and only a
/// synthetic host is accepted. It does not import a session or alter NAS policy.
@MainActor enum NativeReadStatusFixture {
    private static var controller:NSWindowController?
    static func present() {
        guard NativeChatAppConfiguration.standalone,NativeChatAppConfiguration.allowsOfficialSessionImport else { return }
        Task {
            do {
                let model = try await makeModel()
                let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:780),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
                window.title = "Read details fixture — synthetic local responses"
                window.contentViewController = NSHostingController(rootView:NativeChatPreviewView(model:model))
                window.minSize = NSSize(width:800,height:580);window.isReleasedWhenClosed = false;window.center()
                controller = NSWindowController(window:window);controller?.showWindow(nil);window.makeKeyAndOrderFront(nil)
            } catch { NSSound.beep() }
        }
    }
    static func makeModel() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ account in
            let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ReadStatusFixtureProtocol.self];config.urlCache = nil
            return try ChatAPIClient(session:account,network:URLSession(configuration:config))
        })
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://read-status-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
        model.liveStatus = .rejected;model.error = nil
        model.selection = 23;model.loadSelection();await model.historyTask?.value
        return model
    }
}

final class ReadStatusFixtureProtocol:URLProtocol {
    static var holdReadResponse = false
    static var held:ReadStatusFixtureProtocol?
    static var requestObserver:((String,String)->Void)?
    static var readStatusProvider:(() throws -> [String:Any])?
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "read-status-fixture.invalid" else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty,let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048)
            while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count);if count <= 0 { break };bytes.append(contentsOf:buffer.prefix(count)) }
        }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
        let fields = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        let api = request.url!.lastPathComponent
        let method = fields["method"] ?? ""
        Self.requestObserver?(api,method)
        let result:[String:Any]
        switch (api,method) {
        case ("SYNO.API.Info",_):
            result = Dictionary(uniqueKeysWithValues:["SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Misc","SYNO.Chat.Post","SYNO.Chat.Admin.Setting"].map {
                ($0,["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"] as [String:Any])
            })
        case ("SYNO.Chat.User","list"):
            result = ["users":[["user_id":10,"username":"synthetic","nickname":"Alex Morgan"],["user_id":11,"username":"jamie","nickname":"Jamie Chen"],["user_id":12,"username":"sam","nickname":"Sam Rivera"]]]
        case ("SYNO.Chat.Channel","list"):
            result = ["channels":[["channel_id":23,"name":"Project studio","type":"public","encrypted":false,"unread":0]]]
        case ("SYNO.Chat.Misc",_):result = ["acls":[]]
        case ("SYNO.Chat.Admin.Setting","get"):result = ["hide_post_url_preview":true,"allow_read_status":true]
        case ("SYNO.Chat.Post","list"):
            result = ["posts":[["post_id":1,"channel_id":23,"creator_id":10,"type":"normal","message":"The design review is ready for feedback. This is a synthetic local message.","create_at":1792170000000],
                               ["post_id":2,"channel_id":23,"creator_id":11,"type":"normal","message":"Thanks, I’ll take a look this afternoon.","create_at":1792170060000]]]
        case ("SYNO.Chat.Post","get_read_status"):
            guard fields["post_id"] == "1",fields["version"] == "6" else { reject();return }
            if Self.holdReadResponse { Self.held = self;return }
            do { result = try Self.readStatusProvider?() ?? ["read_users":[10,11],"unread_users":[12]] }
            catch { client?.urlProtocol(self,didFailWithError:error);return }
        default:reject();return
        }
        do { respond(try JSONSerialization.data(withJSONObject:["success":true,"data":result])) }
        catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    func deliverReadStatus(_ status:[String:Any]) {
        do { respond(try JSONSerialization.data(withJSONObject:["success":true,"data":status])) }
        catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    private func reject() { respond(Data(#"{"success":false,"error":{"code":400}}"#.utf8)) }
    private func respond(_ data:Data) {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
