#if DEBUG
import AppKit
import SwiftUI

@MainActor enum NativeSearchResultsUIFixture {
    static func render(to directory:URL) async -> Bool {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            SearchResultsRenderProtocol.image = makeImage(width:320,height:190)
            SearchResultsRenderProtocol.sticker = makeImage(width:64,height:64)
            let mediaDirectory = URL(fileURLWithPath:"/private/tmp/native-search-media-render-"+UUID().uuidString,isDirectory:true)
            let mediaFiles = try await NativeSyntheticMedia.files(in:mediaDirectory);defer { try? FileManager.default.removeItem(at:mediaDirectory) }
            SearchResultsRenderProtocol.documents = [2001:(Data("Synthetic search document\n\nThe original conversation stays selected.\nUnicode: e\u{301} 😀\n".utf8),"text/plain"),2002:(try NativeSyntheticDocument.data(),"application/pdf"),2003:(try Data(contentsOf:mediaFiles[0]),"audio/wav"),2004:(try Data(contentsOf:mediaFiles[1]),"video/mp4")]
            for (name,style,mode) in [("dark-search-image",ChatAppearanceStyle.dark,0),("light-search-image",.light,0),("dark-sticker",.dark,1),("light-sticker",.light,1),("dark-file",.dark,2),("dark-gallery",.dark,3),("light-gallery",.light,3),("light-file",.light,2),("dark-text-preview",.dark,4),("light-text-preview",.light,4),("dark-pdf-preview",.dark,5),("light-pdf-preview",.light,5),("dark-audio-preview",.dark,6),("dark-video-preview",.dark,7)] {
                let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [SearchResultsRenderProtocol.self];config.httpShouldSetCookies = false;config.urlCache = nil
                func network()->URLSession { URLSession(configuration:config) }
                let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://search-results-render.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:network(),makeAttachmentNetwork:network);try await api.discover()
                let model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false)
                model.channels = try [23,24].map { id in try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:["channel_id":id,"name":id == 23 ? "Planning" : "Design research","type":"public","encrypted":false,"is_joined":true,"unread":0])) }
                model.selection = 23;model.connected = true;model.liveStatus = .live;model.names = [10:"Peter — synthetic fixture"];model.stickers.attach(api)
                defer { model.signOutLocally() }
                func post(_ id:Int,channel:Int = 23,kind:String = "file",image:Bool = false)->ChatPost {
                    var row:[String:Any] = ["post_id":id,"channel_id":channel,"creator_id":10,"type":kind,"message":kind == "sticker" ? ":synthetic_01:" : "Updated proposal for the next review.","create_at":1794466800000]
                    if kind == "file" { row["file_props"] = ["name":image ? "Proposal overview.png" : "Research notes for the proposal.txt","is_image":image,"size":image ? 42000 : 14000] }
                    return try! JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:row))
                }
                let first = post(1001,image:true),second = post(1002,channel:24,image:true),sticker = post(1003,kind:"sticker"),file = post(1004)
                if mode == 3 { model.openSearchImage(second,context:[first,second],owner:UUID());await model.imageViewerTask?.value }
                if mode == 1 { _ = await model.stickers.image("synthetic_01") }
                if mode >= 4 {
                    let id = mode+1997,names = ["Research notes.txt","Research report.pdf","Research recording.wav","Research presentation.mp4"]
                    let document = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:["post_id":id,"channel_id":24,"creator_id":10,"type":"file","message":"Stored attachment from the search results.","create_at":1794466800000,"file_props":["name":names[mode-4],"size":SearchResultsRenderProtocol.documents[id]!.0.count,"is_image":false]]))
                    model.openSearchDocument(document,owner:UUID());await model.documentPreviewTask?.value
                    guard model.documentPreviewContent != nil,model.documentPreviewError == nil else { throw ChatAPIError.invalidResponse }
                }
                let content = Group {
                    if mode == 0 { NativeMessageSearchView.renderResultsFixture(model:model,results:[first,second]) }
                    else if mode == 3 { NativeImageViewer(model:model) }
                    else if mode >= 4 { NativeDocumentPreview(model:model) }
                    else { NativeSearchResultContent(post:mode == 1 ? sticker : file,model:model,openImage:{},openDocument:{}).padding(20).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading).background(NativeChatColors.canvas) }
                }.environment(\.nativeChatStyle,style).preferredColorScheme(style.colorScheme)
                let host = NSHostingView(rootView:content);host.appearance = NSAppearance(named:style == .dark ? .darkAqua : .aqua)
                host.frame = NSRect(x:0,y:0,width:mode == 0 ? 680 : mode >= 3 ? 900 : 560,height:mode == 0 ? 640 : mode >= 3 ? 650 : 250)
                host.layoutSubtreeIfNeeded();for _ in 0..<8 { try await Task.sleep(nanoseconds:50_000_000);host.layoutSubtreeIfNeeded() };host.displayIfNeeded()
                guard model.canReadSearchResult(first) else { throw ChatAPIError.invalidResponse }
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw ChatAPIError.invalidResponse }
                host.cacheDisplay(in:host.bounds,to:bitmap);guard let bytes = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
                try bytes.write(to:directory.appendingPathComponent(name+".png"),options:.withoutOverwriting)
            }
            return true
        } catch { fputs("Offscreen synthetic search-results rendering failed.\n",stderr);return false }
    }
    private static func makeImage(width:Int,height:Int)->Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        for y in 0..<height { for x in 0..<width {
            let i = y*bitmap.bytesPerRow+x*4,band = x > width/5 && x < width*4/5 && y > height/3 && y < height*2/3
            bitmap.bitmapData![i] = band ? 110 : 25;bitmap.bitmapData![i+1] = band ? 210 : UInt8(75+y*70/height);bitmap.bitmapData![i+2] = band ? 185 : UInt8(90+x*60/width);bitmap.bitmapData![i+3] = 255
        } };return bitmap.representation(using:.png,properties:[:])!
    }
}

@MainActor struct NativeSearchPreviewSession {
    let model:NativeChatPreviewModel
    let documents:[ChatPost]
    func setSidebarUnreadForChecks(_ count:Int) throws {
        model.channels = try [23,24].map { id in
            try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:["channel_id":id,"name":id == 23 ? "Planning" : "Design research","type":"public","encrypted":false,"is_joined":true,"unread":id == 24 ? max(0,count) : 0]))
        }
    }
    let sourceDirectory:URL
    func cleanup() {
        model.signOutLocally()
        guard sourceDirectory.path.hasPrefix("/private/tmp/native-search-preview-window-"),sourceDirectory.standardizedFileURL == sourceDirectory.resolvingSymlinksInPath().standardizedFileURL else { return }
        try? FileManager.default.removeItem(at:sourceDirectory)
    }
}

extension NativeSearchResultsUIFixture {
    static func makeInteractiveSession() async throws -> NativeSearchPreviewSession {
        let directory = URL(fileURLWithPath:"/private/tmp/native-search-preview-window-"+UUID().uuidString,isDirectory:true)
        var completed = false;defer { if !completed { try? FileManager.default.removeItem(at:directory) } }
        let media = try await NativeSyntheticMedia.files(in:directory),wave = NativeSyntheticMedia.wave()
        let silent = Data(wave.prefix(44))+Data(repeating:0,count:wave.count-44)
        let text = "Synthetic search document\n\nNo sign-in or real NAS data is used.\nUnicode: e\u{301} 😀\n\nLong line: " + String(repeating:"Readable synthetic wrapping check. ",count:18) + "END OF LONG LINE\n"
        SearchResultsRenderProtocol.documents = [2001:(Data(text.utf8),"text/plain"),2002:(try NativeSyntheticDocument.data(),"application/pdf"),2003:(silent,"audio/wav"),2004:(try Data(contentsOf:media[1]),"video/mp4")]
        func network()->URLSession {
            let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [SearchResultsRenderProtocol.self];config.httpShouldSetCookies = false;config.urlCache = nil
            return URLSession(configuration:config)
        }
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://search-results-render.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:network(),makeAttachmentNetwork:network);try await api.discover()
        SearchResultsRenderProtocol.image = makeImage(width:320,height:190);SearchResultsRenderProtocol.calendarEnabled = false
        let model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false)
        model.channels = try [23,24].map { id in try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:["channel_id":id,"name":id == 23 ? "Planning" : "Design research","type":"public","encrypted":false,"is_joined":true,"unread":0])) }
        model.selection = 23;model.connected = true;model.liveStatus = .live;model.names = [10:"Synthetic account"];model.draft = "Unsent synthetic draft — keep this text."
        let names = ["Research notes.txt","Research report.pdf","Silent test recording.wav","Research presentation.mp4"]
        let documents = try names.enumerated().map { index,name in
            let id = 2001+index
            return try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:["post_id":id,"channel_id":24,"creator_id":10,"type":"file","message":"Synthetic preview check. No private data.","create_at":1794466800000,"file_props":["name":name,"size":SearchResultsRenderProtocol.documents[id]!.0.count,"is_image":false]]))
        }
        SearchResultsRenderProtocol.collectionRows = documents.map { post in
            ["post_id":post.id,"channel_id":24,"creator_id":10,"type":"file","message":"Synthetic saved and pinned document","create_at":1794466800000,"is_star":true,"star_at":1794466800000,"last_pin_at":1794466800000,"file_props":["name":post.file_props?.name ?? "Synthetic.txt","size":SearchResultsRenderProtocol.documents[Int(post.id)]?.0.count ?? 0,"is_image":false]] as [String:Any]
        }
        SearchResultsRenderProtocol.collectionRows.insert(["post_id":3001,"channel_id":24,"creator_id":10,"type":"file","message":"Synthetic saved and pinned image","create_at":1794466800000,"is_star":true,"star_at":1794466800000,"last_pin_at":1794466800000,"file_props":["name":"Saved overview.png","size":SearchResultsRenderProtocol.image.count,"is_image":true]],at:0)
        completed = true;return .init(model:model,documents:documents,sourceDirectory:directory)
    }
}

private final class SearchResultsRenderProtocol:URLProtocol {
    static var image = Data(),sticker = Data()
    static var documents:[Int:(Data,String)] = [:]
    static var collectionRows:[[String:Any]] = []
    static var calendarEnabled = false
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "search-results-render.invalid",request.url?.scheme == "https" else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        let leaf = request.url!.lastPathComponent
        if leaf == "SYNO.API.Info" { json(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.Post.File","SYNO.Chat.Sticker","SYNO.Chat.Post","SYNO.Chat.User.Preference"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"] as [String:Any]) })]) }
        else if leaf == "SYNO.Chat.User.Preference",fields()["method"] == "get" { json(["success":true,"data":["preferences":["sidebar_pinning_unread":true,"calendar_enable":Self.calendarEnabled]]]) }
        else if leaf == "SYNO.Chat.User.Preference",fields()["method"] == "set",let raw = fields()["calendar_enable"],let enabled = try? JSONDecoder().decode(Bool.self,from:Data(raw.utf8)) { Self.calendarEnabled = enabled;json(["success":true,"data":[:]]) }
        else if leaf == "SYNO.Chat.Post",fields()["method"] == "search" { let offset = Int(fields()["offset"] ?? "0") ?? 0;json(["success":true,"data":["search_results":Array(Self.collectionRows.dropFirst(offset).prefix(25)),"total":Self.collectionRows.count]]) }
        else if leaf == "SYNO.Chat.Post",fields()["method"] == "list" { json(["success":true,"data":["posts":[]]]) }
        else if leaf == "SYNO.Chat.Sticker" { json(["success":true,"data":["categories":[["category_id":9,"name":"synthetic","stickers":[["name":"synthetic_01","sticker_id":1,"keywords":[]]]]]]]) }
        else if leaf == "style.css" { raw(Data(".syno-chat .sticker-synthetic_01 {width:64px;height:64px;background-image:url(images/sticker/1x/synthetic.png);background-position:0px 0px;}".utf8),mime:"text/css") }
        else if leaf == "synthetic.png" { raw(Self.sticker,mime:"image/png") }
        else if leaf == "SYNO.Chat.Post.File" {
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:4096);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };bytes.append(contentsOf:buffer.prefix(n)) } }
            var parts = URLComponents();parts.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
            let fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
            if let id = fields["post_id"].flatMap(Int.init),let (data,mime) = Self.documents[id] {
                var headers = ["Content-Disposition":"attachment; filename=synthetic"]
                if let range = request.value(forHTTPHeaderField:"Range"),range.hasPrefix("bytes=") {
                    let limits = range.dropFirst(6).split(separator:"-")
                    guard limits.count == 2,let start = Int(limits[0]),let end = Int(limits[1]),start >= 0,end >= start,end < data.count else { client?.urlProtocol(self,didFailWithError:URLError(.badServerResponse));return }
                    let slice = data.subdata(in:start..<(end+1));headers["Content-Range"] = "bytes \(start)-\(end)/\(data.count)";headers["Content-Length"] = String(slice.count);raw(slice,mime:mime,status:206,extra:headers)
                } else { raw(data,mime:mime,extra:headers) }
            } else { raw(Self.image,mime:"image/png",extra:["Content-Disposition":"attachment; filename=synthetic.png"]) }
        }
        else { json(["success":false,"error":["code":400]]) }
    }
    private func json(_ value:Any) { raw(try! JSONSerialization.data(withJSONObject:value),mime:"application/json") }
    private func raw(_ data:Data,mime:String,status:Int = 200,extra:[String:String] = [:]) { var headers = extra;headers["Content-Type"] = mime;client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:headers)!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
    private func fields()->[String:String] {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:4096);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };bytes.append(contentsOf:buffer.prefix(n)) } }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
        return Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
    }
}
#endif
