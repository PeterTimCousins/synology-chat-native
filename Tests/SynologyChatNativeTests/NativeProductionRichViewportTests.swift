import AppKit
import SwiftUI
import XCTest
@testable import SynologyChatNative

/// Production-compatible rendering and read-only fake transport; no DEBUG seams.
@MainActor final class NativeProductionRichViewportTests:XCTestCase {
    @MainActor private final class Census {
        let hosts = NSHashTable<NSView>.weakObjects()
        var maximum = 0
        func observe(_ document:NativeVirtualTimeline.Document) {
            let cells = document.subviews.compactMap { $0 as? NativeVirtualTimeline.Cell }
            XCTAssertLessThanOrEqual(cells.count,32)
            for cell in cells { if let host = cell.host { hosts.add(host) } }
            maximum = max(maximum,hosts.allObjects.count)
            XCTAssertLessThanOrEqual(maximum,32)
            let order = cells.map { document.row(for:$0) }
            XCTAssertTrue(order.allSatisfy({ $0 >= 0 }));XCTAssertEqual(order,order.sorted())
        }
    }
    @MainActor private struct Harness {
        let model:NativeChatPreviewModel
        let host:NSHostingView<AnyView>
        let window:NSWindow
        let scroll:NativeTimelineScrollView
        let document:NativeVirtualTimeline.Document
        let census:Census
        let thread:Bool
    }
    private func rows(thread:Bool) throws -> [ChatPost] {
        try (100..<160).map { id in
            var value:[String:Any] = ["post_id":id,"channel_id":23,"creator_id":id%2 == 0 ? 10 : 20,"type":"normal","message":"Synthetic production rich row \(id)","create_at":1_794_481_200_000+id*60_000]
            if thread { value["thread_id"] = 9000 }
            if [120,124].contains(id) { value["type"] = "file";value["file_props"] = ["id":id,"name":"Synthetic \(id).png","is_image":true,"size":ProductionRichProtocol.png.count] }
            if id == 124 { value["creator_id"] = 20;value["create_at"] = 1_794_481_200_000+123*60_000 }
            if id == 121 { value["type"] = "file";value["file_props"] = ["id":121,"name":"Synthetic document.pdf","is_image":false,"size":62] }
            if id == 122 { value["props"] = ["safe_url":true];value["url_props"] = [["url":"https://example.invalid/story","title":"Synthetic production title","description":"Synthetic image geometry changes after its generated pixels arrive.","image":"https://preview.invalid/hero.png"]] }
            return try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:value))
        }
    }
    private func make(thread:Bool) async throws -> Harness {
        _ = NSApplication.shared;try ProductionRichProtocol.reset()
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ProductionRichProtocol.self];config.httpShouldSetCookies = false;config.urlCache = nil
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://production-rich.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        try await api.discover()
        let model = NativeChatPreviewModel(client:api,restoreNotificationPreference:false,notificationDefaults:nil)
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":23,"name":"Synthetic production rich","type":"channel","encrypted":false,"unread":0}"#.utf8))]
        model.selection = 23;model.connected = true;model.liveStatus = .live
        model.handleLiveEvent(.init(name:"client.setting.update",payload:.object(["hide_post_url_preview":.bool(false)])))
        model.draft = "Synthetic rich main draft"
        let values = try rows(thread:thread)
        let rootPost = try JSONDecoder().decode(ChatPost.self,from:Data(#"{"post_id":9000,"channel_id":23,"creator_id":10,"type":"normal","message":"Synthetic rich root","create_at":1000}"#.utf8))
        if thread {
            model.posts = [rootPost];model.threadRoot = rootPost;model.replies = values;model.replyDraft = "Synthetic rich reply draft"
        } else { model.posts = values;model.threadDrafts[9000] = "Synthetic rich reply draft" }
        let appearance = NativeAppearancePreferences(defaults:nil),content:AnyView
        if thread { content = AnyView(NativeThreadView(appearancePreferences:appearance,model:model).usingNativeMessageViewport()) }
        else { content = AnyView(NativeChatPreviewView(model:model,appearancePreferences:appearance).usingNativeMessageViewport()) }
        let host = NSHostingView(rootView:AnyView(content.environment(\.nativeChatStyle,ChatAppearanceStyle.dark).preferredColorScheme(.dark)))
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:thread ? 640 : 1100,height:thread ? 680 : 840),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = host
        addTeardownBlock { @MainActor in ProductionRichProtocol.cancelPending();model.signOutLocally();host.rootView = AnyView(EmptyView());window.contentView = nil;window.close() }
        var selected:NativeTimelineScrollView?
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds:15_000_000);host.layoutSubtreeIfNeeded()
            selected = scrolls(host).first { $0.documentView is NativeVirtualTimeline.Document && $0.contentView.bounds.height > 0 }
            if selected != nil { break }
        }
        let scroll = try XCTUnwrap(selected),document = try XCTUnwrap(scroll.documentView as? NativeVirtualTimeline.Document)
        let value = Harness(model:model,host:host,window:window,scroll:scroll,document:document,census:Census(),thread:thread)
        try await settle(value)
        return value
    }
    private func scrolls(_ view:NSView)->[NativeTimelineScrollView] { (view as? NativeTimelineScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
    private func rasters(_ view:NSView)->[NativeInlineImageRaster] { (view as? NativeInlineImageRaster).map { [$0] } ?? view.subviews.flatMap(rasters) }
    private func settle(_ value:Harness,delay:UInt64 = 30_000_000) async throws {
        try await Task.sleep(nanoseconds:delay);value.host.layoutSubtreeIfNeeded();value.host.needsDisplay = true;value.host.displayIfNeeded();value.census.observe(value.document);XCTAssertFalse(value.window.isVisible)
    }
    private func cell(_ id:Int64,in value:Harness) throws -> NativeVirtualTimeline.Cell {
        let index = try XCTUnwrap(value.document.canonicalRows.firstIndex(of:.post(id)))
        let cell = try XCTUnwrap(value.document.hostedView(forRow:index) as? NativeVirtualTimeline.Cell)
        XCTAssertEqual(cell.row,.post(id));XCTAssertNotNil(cell.host);XCTAssertEqual(value.document.row(for:cell),index)
        return cell
    }
    private func position(_ id:Int64,in value:Harness) async throws {
        for _ in 0..<30 {
            let index = try XCTUnwrap(value.document.canonicalRows.firstIndex(of:.post(id))),rect = value.document.rect(ofRow:index)
            value.scroll.contentView.scroll(to:NSPoint(x:0,y:min(max(0,value.document.bounds.height-value.scroll.contentView.bounds.height),rect.minY)))
            value.scroll.reflectScrolledClipView(value.scroll.contentView);try await settle(value)
            let current = value.document.rect(ofRow:index),clip = value.scroll.documentVisibleRect,tolerance = 1/value.window.backingScaleFactor
            if let cell = value.document.hostedView(forRow:index) as? NativeVirtualTimeline.Cell,cell.host != nil,
               abs(current.minY-clip.minY) <= tolerance,current.intersection(clip).height >= min(current.height,clip.height)-tolerance { return }
        }
        XCTFail("Synthetic target \(id) was not hosted/visible");throw ChatAPIError.invalidResponse
    }
    private func readable(_ value:Harness)->(id:Int64,offset:CGFloat)? {
        for (index,row) in value.document.canonicalRows.enumerated() {
            guard case let .post(id) = row else { continue }
            let rect = value.document.rect(ofRow:index)
            if rect.intersection(value.scroll.documentVisibleRect).height >= min(20,rect.height),value.document.hostedView(forRow:index) != nil { return (id,rect.minY-value.scroll.documentVisibleRect.minY) }
        };return nil
    }
    private func bitmap(_ value:Harness) throws -> NSBitmapImageRep {
        value.host.needsDisplay = true;value.host.displayIfNeeded()
        let bitmap = try XCTUnwrap(value.host.bitmapImageRepForCachingDisplay(in:value.host.bounds));value.host.cacheDisplay(in:value.host.bounds,to:bitmap);return bitmap
    }
    private func magentaSamples(_ bitmap:NSBitmapImageRep)->Int {
        guard let image = bitmap.cgImage,let space = CGColorSpace(name:CGColorSpace.sRGB) else { XCTFail("Missing bitmap color space");return 0 }
        // Source PNGs use sRGB; native captures use the monitor's ICC profile.
        // Convert both through their CGImage profiles before applying the same
        // >0.85 red/blue, <0.2 green, >0.8 alpha thresholds on 8-bit pixels.
        var pixels = [UInt8](repeating:0,count:image.width*image.height*4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data:bytes.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { XCTFail("Cannot normalize bitmap");return 0 }
            context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            var found = 0
            for y in stride(from:0,to:image.height,by:8) { for x in stride(from:0,to:image.width,by:8) {
                let index = (y*image.width+x)*4
                if bytes[index] > 216 && bytes[index+1] < 51 && bytes[index+2] > 216 && bytes[index+3] > 204 { found += 1 }
            } };return found
        }
    }
    private func capture(_ bitmap:NSBitmapImageRep,name:String) throws {
        guard let path = ProcessInfo.processInfo.environment["NATIVE_PRODUCTION_VIEWPORT_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath:path,isDirectory:true);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let bytes = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        try bytes.write(to:directory.appendingPathComponent(name+"-"+UUID().uuidString+".png"),options:.withoutOverwriting)
    }
    private func scenario(thread:Bool) async throws {
        let value = try await make(thread:thread),model = value.model
        let sourceHero = try XCTUnwrap(NSBitmapImageRep(data:ProductionRichProtocol.hero))
        XCTAssertGreaterThan(magentaSamples(sourceHero),50,"Generated source asset must actually contain magenta pixels")
        try capture(sourceHero,name:thread ? "rich-thread-source-og" : "rich-main-source-og")
        let token = model.nativeThreadViewportToken,account = model.accountGeneration,documentID = ObjectIdentifier(value.document),scrollID = ObjectIdentifier(value.scroll)
        let data = thread ? model.replies : model.posts
        XCTAssertTrue(NativeTimelineGrouping.isContinuation(try XCTUnwrap(data.first(where:{ $0.id == 124 })),after:data.first(where:{ $0.id == 123 }),calendar:.current))
        for id in [Int64(120),124] {
            try await position(id,in:value)
            for _ in 0..<40 { if rasters(try cell(id,in:value)).contains(where:{ $0.image?.size == NSSize(width:120,height:80) }) { break };try await settle(value,delay:20_000_000) }
            XCTAssertTrue(rasters(try cell(id,in:value)).contains(where:{ $0.image?.size == NSSize(width:120,height:80) }))
        }
        try await position(121,in:value);_ = try cell(121,in:value)
        XCTAssertEqual(model.attachmentName(try XCTUnwrap(data.first(where:{ $0.id == 121 }))),"Synthetic document.pdf")
        try await position(122,in:value);_ = try cell(122,in:value)
        let link = try XCTUnwrap(data.first(where:{ $0.id == 122 })),preview = try XCTUnwrap(model.linkPreviews(for:link).first)
        XCTAssertEqual(preview.preview.title,"Synthetic production title");XCTAssertNil(preview.preview.image_prop)
        for _ in 0..<40 { if ProductionRichProtocol.activePending > 0 { break };try await settle(value,delay:20_000_000) }
        XCTAssertGreaterThan(ProductionRichProtocol.activePending,0)
        try await settle(value,delay:100_000_000)
        let linkIndex = try XCTUnwrap(value.document.canonicalRows.firstIndex(of:.post(122))),referenceIndex = try XCTUnwrap(value.document.canonicalRows.firstIndex(of:.post(123)))
        let beforeHeight = value.document.rect(ofRow:linkIndex).height,tolerance = 1/value.window.backingScaleFactor,tail = 20-tolerance
        value.scroll.contentView.scroll(to:NSPoint(x:0,y:value.document.rect(ofRow:linkIndex).maxY-tail));value.scroll.reflectScrolledClipView(value.scroll.contentView)
        try await settle(value,delay:100_000_000)
        let baseline = try XCTUnwrap(readable(value));XCTAssertEqual(baseline.id,123)
        XCTAssertEqual(value.document.rect(ofRow:linkIndex).intersection(value.scroll.documentVisibleRect).height,tail,accuracy:tolerance)
        _ = try cell(122,in:value);_ = try cell(123,in:value)
        XCTAssertGreaterThan(ProductionRichProtocol.activePending,0,"The actual visible card's held request must remain alive before release")
        try capture(bitmap(value),name:thread ? "rich-thread-before-og" : "rich-main-before-og")
        ProductionRichProtocol.release()
        var grew = false
        for delay:UInt64 in [100_000_000,100_000_000,800_000_000] {
            try await settle(value,delay:delay)
            let actual = try XCTUnwrap(readable(value))
            XCTAssertEqual(actual.id,123)
            XCTAssertEqual(actual.offset,baseline.offset,accuracy:tolerance,"ref=\(value.document.rect(ofRow:referenceIndex)); clip=\(value.scroll.documentVisibleRect)")
            grew = grew || value.document.rect(ofRow:linkIndex).height-beforeHeight >= 20
            XCTAssertEqual(ObjectIdentifier(value.document),documentID);XCTAssertEqual(ObjectIdentifier(value.scroll),scrollID)
        }
        XCTAssertTrue(grew,"A completed transport is insufficient: actual committed rich row must grow")
        XCTAssertGreaterThan(ProductionRichProtocol.completed["og:122",default:0],0)
        let reads = ProductionRichProtocol.requested
        let decodedOG = await model.linkPreviewImage(for:link,preview:preview.preview)
        XCTAssertNotNil(decodedOG);XCTAssertEqual(ProductionRichProtocol.requested,reads)
        try await position(122,in:value);try await settle(value,delay:100_000_000)
        let rendered = try bitmap(value)
        print("SYNTHETIC_RICH_PAINT thread=\(thread) source_magenta=\(magentaSamples(sourceHero)) rendered_magenta=\(magentaSamples(rendered)) row122=\(value.document.rect(ofRow:linkIndex)) clip=\(value.scroll.documentVisibleRect) readable=\(String(describing:readable(value)))")
        XCTAssertGreaterThan(magentaSamples(rendered),50,"Actual generated magenta image pixels must render; cache admission alone is insufficient")
        try capture(rendered,name:thread ? "rich-thread-rendered-og" : "rich-main-rendered-og")
        let readsBeforeRecycle = ProductionRichProtocol.requested
        try await position(100,in:value)
        for id in [Int64(120),124,122] {
            try await position(id,in:value);try await settle(value,delay:100_000_000)
            if id != 122 { XCTAssertTrue(rasters(try cell(id,in:value)).contains(where:{ $0.image?.size == NSSize(width:120,height:80) })) }
        }
        XCTAssertEqual(ProductionRichProtocol.requested,readsBeforeRecycle,"Production recycled rows must reuse decoded image/OG caches")
        XCTAssertEqual((thread ? model.replies : model.posts).map(\.id),Array(Int64(100)..<160))
        XCTAssertEqual(model.draft,"Synthetic rich main draft");XCTAssertEqual(model.threadDrafts[9000],"Synthetic rich reply draft")
        XCTAssertEqual(model.nativeThreadViewportToken,token);XCTAssertEqual(model.accountGeneration,account)
        XCTAssertEqual(model.selection,23);XCTAssertNil(model.error);XCTAssertFalse(value.window.isVisible)
        XCTAssertEqual(ProductionRichProtocol.unexpected,[]);XCTAssertEqual(ProductionRichProtocol.writes,0)
        value.census.observe(value.document)
    }
    func testProductionMainRichRowsRenderRetainAnchorAndReuseDecodedImages() async throws { try await scenario(thread:false) }
    func testProductionThreadRichRowsRenderRetainAnchorAndReuseDecodedImages() async throws { try await scenario(thread:true) }
}

private final class ProductionRichProtocol:URLProtocol {
    @MainActor static var png = Data(),hero = Data(),requested:[String:Int] = [:],completed:[String:Int] = [:],unexpected:[String] = []
    @MainActor static var writes = 0,released = false,pending:[ProductionRichProtocol] = []
    @MainActor static var activePending:Int { pending.filter { !$0.isStopped }.count }
    private let lock = NSLock();private var stopped = false
    private var isStopped:Bool { lock.lock();defer { lock.unlock() };return stopped }
    @MainActor static func reset() throws { cancelPending();requested = [:];completed = [:];unexpected = [];writes = 0;released = false;png = try asset(width:120,height:80,color:NSColor(deviceRed:0,green:0.7,blue:0.7,alpha:1));hero = try asset(width:400,height:200,color:NSColor(deviceRed:1,green:0,blue:1,alpha:1)) }
    @MainActor private static func asset(width:Int,height:Int,color:NSColor) throws -> Data {
        guard let image = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let context = NSGraphicsContext(bitmapImageRep:image) else { throw ChatAPIError.invalidResponse }
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = context;color.setFill();NSRect(x:0,y:0,width:CGFloat(width),height:CGFloat(height)).fill();NSGraphicsContext.restoreGraphicsState()
        guard let data = image.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse };return data
    }
    @MainActor static func cancelPending() { let values = pending;pending = [];for value in values { value.fail() } }
    @MainActor static func release() { released = true;let values = pending;pending = [];for value in values { value.image(hero,key:"og:122") } }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func stopLoading() { lock.lock();stopped = true;lock.unlock() }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var bytes = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable,data.count < 16_384 { let count = stream.read(&bytes,maxLength:min(bytes.count,16_384-data.count));if count <= 0 { break };data.append(contentsOf:bytes.prefix(count)) } }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        DispatchQueue.main.async { self.route(fields) }
    }
    @MainActor private func route(_ fields:[String:String]) {
        guard !isStopped else { return }
        guard let url = request.url,url.scheme == "https",url.host == "production-rich.invalid" else { Self.unexpected.append("foreign-origin");fail();return }
        func field(_ key:String)->String { let raw = fields[key] ?? "";return (try? JSONSerialization.jsonObject(with:Data(raw.utf8),options:.fragmentsAllowed) as? String) ?? raw }
        let endpoint = url.lastPathComponent,method = field("method")
        if endpoint == "SYNO.API.Info",method == "query" { Self.requested["discover",default:0] += 1;json(["SYNO.Chat.Post.File":["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"]]);return }
        if endpoint == "SYNO.Chat.Post.File",method == "thumbnail",["120","124"].contains(field("post_id")),field("type") == "M" {
            let key = "thumbnail:"+field("post_id");Self.requested[key,default:0] += 1;image(Self.png,key:key);return
        }
        if endpoint == "SYNO.Chat.Post.File",method == "og",field("post_id") == "122",field("url") == "https://preview.invalid/hero.png" {
            Self.requested["og:122",default:0] += 1;if Self.released { image(Self.hero,key:"og:122") } else { Self.pending.append(self) };return
        }
        if ["set","create","delete","update","read","vote"].contains(method) { Self.writes += 1 }
        Self.unexpected.append(endpoint+":"+method);fail()
    }
    @MainActor private func json(_ payload:[String:Any]) { guard let bytes = try? JSONSerialization.data(withJSONObject:["success":true,"data":payload]) else { fail();return };send(bytes,mime:"application/json") }
    @MainActor private func image(_ data:Data,key:String) { guard !isStopped else { return };Self.completed[key,default:0] += 1;send(data,mime:"image/png") }
    private func send(_ data:Data,mime:String) { guard !isStopped,let url = request.url,let response = HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":mime]) else { return };client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    private func fail() { guard !isStopped else { return };client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL)) }
}
