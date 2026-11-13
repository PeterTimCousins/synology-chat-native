#if DEBUG
import AppKit
import SwiftUI

/// Rich-control routing with a synthetic connected model and intercepted image reads.
/// No actions, menus, downloads, website opens or clipboard operations are executed.
@MainActor enum NativeVirtualTimelineRichActionChecks {
    nonisolated static let host = "virtual-rich-actions.invalid"
    private static let draft = "Synthetic rich action draft — retained."
    @MainActor private final class Receipt {
        var checks:[String:Bool] = [:],samples:[[String:Any]] = []
    }
    static func render(to directory:URL,reactionInput:Bool = false) async -> Bool {
        let receipt = Receipt()
        var stage = "prepare"
        do {
            guard !FileManager.default.fileExists(atPath:directory.path) else { return false }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            _ = NSApplication.shared;try RichActionProtocol.reset()
            RichActionProtocol.reactionInputAllowed = reactionInput
            let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
                guard session.baseURL.scheme == "https",session.baseURL.host == host else { throw ChatAPIError.invalidResponse }
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [RichActionProtocol.self];config.httpShouldSetCookies = false;config.urlCache = nil
                return try ChatAPIClient(session:session,network:URLSession(configuration:config))
            },downloadPreferences:.init(defaults:nil),emojiPreferences:.init(defaults:nil),notificationDefaults:nil)
            defer { model.signOutLocally() }
            await model.connect(using:.init(session:.init(baseURL:URL(string:"https://"+host)!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic-rich-actions",importedFromOfficialApp:false))
            receipt.checks["synthetic_connected_identity"] = model.connected && model.userID == 10
            guard receipt.checks["synthetic_connected_identity"] == true else { throw ChatAPIError.invalidResponse }
            model.suspendLiveForProbe();model.liveStatus = .live;model.selection = 23;model.error = nil
            model.posts = try posts();model.draft = draft
            let originalMessages = model.posts.map(\.message)
            guard let image = model.posts.first(where:{ $0.id == 120 }),let compactImage = model.posts.first(where:{ $0.id == 124 }),
                  let file = model.posts.first(where:{ $0.id == 121 }),let link = model.posts.first(where:{ $0.id == 122 }),
                  let reaction = model.posts.first(where:{ $0.id == 123 }),let previous = model.posts.first(where:{ $0.id == 119 }) else { throw ChatAPIError.invalidResponse }
            receipt.checks["image_read_prerequisites"] = model.canPreviewThumbnail(image) && model.canPreviewThumbnail(compactImage)
            receipt.checks["file_save_and_pdf_preview_prerequisites"] = model.canRead(23) && model.canPreviewDocument(file) && model.documentKind(file) == .pdf
            receipt.checks["reaction_enabled_prerequisite"] = model.canAct(on:reaction) && ChatReactionKind(rawValue:"thumbsup") != nil
            receipt.checks["link_metadata_prerequisite"] = model.canRead(23) && model.linkPreviews(for:link).count == 1
            receipt.checks["noncompact_image_grouping"] = !NativeTimelineGrouping.isContinuation(image,after:previous,calendar:.current)
            receipt.checks["compact_image_grouping"] = NativeTimelineGrouping.isContinuation(compactImage,after:reaction,calendar:.current)
            let timeline = NativeVirtualTimeline(model:model,onBottomChanged:{ _ in })
            let root = NSHostingView(rootView:AnyView(timeline.environment(\.nativeChatStyle,ChatAppearanceStyle.dark).environment(\.colorScheme,.dark)))
            let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:680,height:520),styleMask:[],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = root
            defer { root.rootView = AnyView(EmptyView());root.layoutSubtreeIfNeeded();window.contentView = nil;window.close() }
            stage = "find-virtual-document"
            var candidate:NSScrollView?
            for _ in 0..<40 {
                try await settle(root,delay:15_000_000);candidate = findScroll(root)
                if candidate != nil { break }
            }
            guard let scroll = candidate,let document = scroll.documentView as? NativeVirtualTimeline.Document else { throw ChatAPIError.invalidResponse }
            receipt.checks["actual_virtual_backend"] = scroll.identifier?.rawValue == "native-virtual-timeline" && document.identifier?.rawValue == "native-virtual-timeline"
            if reactionInput {
                return try await renderReactionInput(model:model,root:root,window:window,scroll:scroll,document:document,directory:directory,receipt:receipt)
            }
            let account = model.accountGeneration,token = model.historyViewportToken
            let targetKinds:[Int64:[String]] = [120:["image-open","file-save"],121:["file-save","file-preview"],122:["link-open:0"],123:["reaction:thumbsup"],124:["image-open","file-save"]]
            var priorHosts:[Int64:String] = [:]
            for (phase,width,recycle) in [("wide",CGFloat(680),false),("narrow",CGFloat(480),false),("recycled-narrow",CGFloat(480),true)] {
                window.setContentSize(NSSize(width:width,height:520));try await settle(root,delay:100_000_000)
                for id in [Int64(120),121,122,123,124] {
                    stage = phase+"-post-"+String(id)
                    let prefix = phase+"_"+String(id)+"_"
                    if recycle {
                        try await navigate(100,model:model,root:root,document:document)
                        try await settle(root,delay:50_000_000)
                        let index = document.canonicalRows.firstIndex(of:.post(id))
                        let offscreenHost = index.flatMap { document.hostedView(forRow:$0) as? NativeVirtualTimeline.Cell }?.host
                        receipt.checks[prefix+"target_recycled_while_away"] = offscreenHost == nil
                    }
                    try await navigate(id,model:model,root:root,document:document)
                    model.scrollPostID = nil;try await settle(root,delay:40_000_000)
                    guard let index = document.canonicalRows.firstIndex(of:.post(id)),let cell = document.hostedView(forRow:index) as? NativeVirtualTimeline.Cell,let hostView = cell.host else { throw ChatAPIError.invalidResponse }
                    let expectedKinds = targetKinds[id] ?? []
                    var targetMarkers:[NativeMessageActionMarker.Marker] = []
                    for _ in 0..<40 {
                        targetMarkers = markers(cell).filter { $0.postID == id }
                        let ready = expectedKinds.allSatisfy { kind in targetMarkers.contains(where:{ $0.kind == kind && $0.bounds.width > 0 && $0.bounds.height > 0 }) }
                        let imageReady = ![120,124].contains(id) || rasters(cell).contains(where:{ $0.image?.size == NSSize(width:120,height:80) })
                        if ready && imageReady { break }
                        try await settle(root,delay:20_000_000)
                    }
                    receipt.checks[prefix+"all_real_control_markers_found"] = expectedKinds.allSatisfy { kind in targetMarkers.contains(where:{ $0.kind == kind }) }
                    if [120,124].contains(id) { receipt.checks[prefix+"actual_png_raster_decoded"] = rasters(cell).contains(where:{ $0.image?.size == NSSize(width:120,height:80) }) }
                    let hostIdentity = String(describing:ObjectIdentifier(hostView))
                    if recycle { receipt.checks[prefix+"returned_host_attached_after_away"] = receipt.checks[prefix+"target_recycled_while_away"] == true && hostView.superview === cell && priorHosts[id] != nil }
                    priorHosts[id] = hostIdentity
                    let cellRect = cell.convert(cell.bounds,to:document),viewport = scroll.documentVisibleRect
                    let tolerance = 1/max(1,window.backingScaleFactor)
                    for kind in expectedKinds {
                        guard let marker = targetMarkers.first(where:{ $0.kind == kind }) else { continue }
                        let frame = marker.convert(marker.bounds,to:document)
                        let point = NSPoint(x:frame.midX,y:frame.midY)
                        let finite = [frame.minX,frame.minY,frame.width,frame.height].allSatisfy(\.isFinite) && frame.width > 0 && frame.height > 0
                        receipt.checks[prefix+kind+"_finite_marker"] = finite
                        guard finite else { continue }
                        let inputBefore = document.debugDiagnostics["input_generation"] as? String
                        let receiverPoint = document.convert(point,to:root.superview)
                        let hit = root.hitTest(receiverPoint)
                        let screenPoint = window.convertPoint(toScreen:document.convert(point,to:nil))
                        let accessibilityHit = root.accessibilityHitTest(screenPoint)
                        let accessible = accessibilityHit as? NSAccessibilityProtocol
                        let hostAccessibilityHit = hostView.accessibilityHitTest(screenPoint)
                        let hostAccessible = hostAccessibilityHit as? NSAccessibilityProtocol
                        let hitIndex = hit.map { document.row(for:$0) } ?? -1
                        let hitInCell = hit.map { $0 === cell || $0.isDescendant(of:cell) } ?? false
                        let hitInHost = hit.map { $0 === hostView || $0.isDescendant(of:hostView) } ?? false
                        let control = controlAncestor(hit,inside:cell)
                        let controlRect = control.map { $0.convert($0.bounds,to:document) }
                        receipt.checks[prefix+kind+"_owning_cell_and_host_routing"] = hitInCell && hitInHost && hitIndex == index
                        receipt.checks[prefix+kind+"_actual_enabled_NSControl_ancestry"] = control?.isEnabled == true && controlRect?.contains(point) == true
                        receipt.checks[prefix+kind+"_marker_does_not_intercept"] = !(hit is NativeMessageActionMarker.Marker)
                        receipt.checks[prefix+kind+"_full_horizontal_marker_inside_cell"] = horizontal(cellRect,frame,tolerance:tolerance)
                        receipt.checks[prefix+kind+"_full_horizontal_marker_inside_viewport"] = horizontal(viewport,frame,tolerance:tolerance)
                        receipt.checks[prefix+kind+"_center_inside_viewport"] = viewport.contains(point)
                        receipt.checks[prefix+kind+"_input_generation_unchanged"] = inputBefore != nil && document.debugDiagnostics["input_generation"] as? String == inputBefore
                        var sample:[String:Any] = ["phase":phase,"post_id":id,"kind":kind,"width":width,"marker_rect":rect(frame),"marker_center":xy(point),"receiver_superview_point":xy(receiverPoint),
                            "cell_rect":rect(cellRect),"cell_bounds":rect(cell.bounds),"committed_rect":rect(document.rect(ofRow:index)),"viewport":rect(viewport),"cell_row_index":index,"hit_row_index":hitIndex,
                            "hit_type":hit.map { String(describing:type(of:$0)) } ?? "nil","hit_in_cell":hitInCell,"hit_in_host":hitInHost,
                            "accessibility_hit_type":accessibilityHit.map { String(describing:type(of:$0)) } ?? "nil",
                            "accessibility_role":accessible?.accessibilityRole()?.rawValue as Any? ?? NSNull(),
                            "accessibility_label":accessible?.accessibilityLabel() as Any? ?? NSNull(),
                            "accessibility_enabled":accessible?.isAccessibilityEnabled() as Any? ?? NSNull(),
                            "host_accessibility_hit_type":hostAccessibilityHit.map { String(describing:type(of:$0)) } ?? "nil",
                            "host_accessibility_role":hostAccessible?.accessibilityRole()?.rawValue as Any? ?? NSNull(),
                            "host_accessibility_label":hostAccessible?.accessibilityLabel() as Any? ?? NSNull(),
                            "host_accessibility_enabled":hostAccessible?.isAccessibilityEnabled() as Any? ?? NSNull(),
                            "host_accessibility_tree":accessibilityTree(hostView),
                            "control_ancestry":ancestry(hit,until:cell),"NSControl_found":control != nil,"NSControl_enabled":control?.isEnabled as Any? ?? NSNull(),
                            "input_generation_before":inputBefore as Any? ?? NSNull(),"input_generation_after":document.debugDiagnostics["input_generation"] as Any? ?? NSNull(),
                            "host_identity":hostIdentity,"cell_identity":String(describing:ObjectIdentifier(cell)),"document_identity":String(describing:ObjectIdentifier(document))]
                        if let controlRect { sample["NSControl_rect"] = rect(controlRect) }
                        if let accessible { sample["accessibility_frame"] = rect(accessible.accessibilityFrame());sample["screen_point"] = xy(screenPoint) }
                        receipt.samples.append(sample)
                    }
                    try capture(root,to:directory.appendingPathComponent(phase+"-"+String(id)+".png"))
                }
            }
            let beforeCache = RichActionProtocol.requested
            for post in model.posts.filter({ [120,124].contains($0.id) }) {
                let image = await model.thumbnail(for:post)
                receipt.checks["image_"+String(post.id)+"_cache_decoded_without_request"] = image?.size == NSSize(width:120,height:80) && RichActionProtocol.requested == beforeCache
            }
            receipt.checks["exact_post_order_and_content_retained"] = model.posts.map(\.id) == Array(Int64(100)...159) && model.posts.map(\.message) == originalMessages
            receipt.checks["draft_retained"] = model.draft == draft
            receipt.checks["synthetic_account_scope_retained"] = model.connected && model.userID == 10 && model.accountGeneration == account && model.historyViewportToken == token && model.selection == 23
            receipt.checks["zero_writes_or_unknown_requests"] = RichActionProtocol.writes == 0 && RichActionProtocol.unknown.isEmpty
            receipt.checks["runtime_config_denied_before_live_transport"] = RichActionProtocol.runtimeDenied == 1
            receipt.checks["window_never_visible"] = !window.isVisible
            receipt.checks["actual_weak_hosts_bounded"] = (document.debugDiagnostics["max_hosted_cells"] as? Int).map { $0 > 0 && $0 <= 32 } ?? false
            receipt.samples.append(["phase":"final","virtual_diagnostics":document.debugDiagnostics,"requests":RichActionProtocol.requested,"completed":RichActionProtocol.completed,"post_ids":model.posts.map(\.id),"draft":model.draft])
            guard receipt.checks.values.allSatisfy({ $0 }) else { throw ChatAPIError.invalidResponse }
            try write(receipt,stage:"passed",to:directory.appendingPathComponent("result.json"));return true
        } catch {
            try? write(receipt,stage:stage,to:directory.appendingPathComponent("failure.json"));return false
        }
    }
    private static func renderReactionInput(model:NativeChatPreviewModel,root:NSHostingView<AnyView>,window:NSWindow,scroll:NSScrollView,document:NativeVirtualTimeline.Document,directory:URL,receipt:Receipt) async throws -> Bool {
        try await navigate(123,model:model,root:root,document:document)
        model.scrollPostID = nil;try await settle(root,delay:100_000_000)
        guard let index = document.canonicalRows.firstIndex(of:.post(123)),let cell = document.hostedView(forRow:index) as? NativeVirtualTimeline.Cell,
              let marker = markers(cell).first(where:{ $0.kind == "reaction:thumbsup" }),let post = model.posts.first(where:{ $0.id == 123 }) else { throw ChatAPIError.invalidResponse }
        let frame = marker.convert(marker.bounds,to:document),point = NSPoint(x:frame.midX,y:frame.midY)
        let hit = root.hitTest(document.convert(point,to:root.superview))
        receipt.checks["reaction_click_routes_exact_owning_row"] = hit.map { document.row(for:$0) == index && $0.isDescendant(of:cell) } ?? false
        receipt.checks["reaction_click_inside_visible_marker"] = scroll.documentVisibleRect.contains(point) && frame.width > 0 && frame.height > 0
        receipt.checks["initial_reaction_owned_by_synthetic_user"] = post.reactions?.first(where:{ $0.sticker_name == "thumbsup" })?.user_ids == [10,20] && model.canAct(on:post)
        guard receipt.checks.values.allSatisfy({ $0 }) else { throw ChatAPIError.invalidResponse }
        try capture(root,to:directory.appendingPathComponent("reaction-before.png"))
        let location = document.convert(point,to:nil),timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:timestamp,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1),
              let up = NSEvent.mouseEvent(with:.leftMouseUp,location:location,modifierFlags:[],timestamp:timestamp+0.02,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0) else { throw ChatAPIError.invalidResponse }
        // Owned process queue only. No CGEvent/global input or desktop window.
        // A native tracking loop may consume the queued up event synchronously.
        NSApplication.shared.postEvent(up,atStart:true)
        window.sendEvent(down)
        for _ in 0..<50 {
            try await settle(root,delay:20_000_000)
            if RichActionProtocol.reactionDeletes == 1,RichActionProtocol.reactionReads == 1,model.pendingMessageActions.isEmpty { break }
        }
        receipt.checks["one_exact_fake_reaction_delete"] = RichActionProtocol.reactionDeletes == 1 && RichActionProtocol.writes == 1
        receipt.checks["one_exact_canonical_reaction_read"] = RichActionProtocol.reactionReads == 1
        receipt.checks["canonical_reaction_user_removed_after_button_click"] = model.posts.first(where:{ $0.id == 123 })?.reactions?.first(where:{ $0.sticker_name == "thumbsup" })?.user_ids == [20]
        receipt.checks["reaction_pending_cleared_without_error"] = model.pendingMessageActions.isEmpty && model.error == nil
        receipt.checks["synthetic_draft_order_and_other_content_retained"] = model.draft == draft && model.posts.map(\.id) == Array(Int64(100)...159) && model.posts.allSatisfy { $0.message == "Synthetic rich routing row \($0.id)" }
        receipt.checks["no_unknown_requests_or_visible_window"] = RichActionProtocol.unknown.isEmpty && !window.isVisible
        receipt.samples.append(["probe":"owned-hidden-window-reaction-input","marker_rect":rect(frame),"hit_type":hit.map { String(describing:type(of:$0)) } ?? "nil","delete_count":RichActionProtocol.reactionDeletes,"read_count":RichActionProtocol.reactionReads,"model_error":model.error as Any? ?? NSNull(),"window_visible":window.isVisible,"limits":"Owned NSApplication event queue and window dispatch only; no global input, real account or physical desktop acceptance. One exact synthetic reaction deletion permitted; not image/file/link execution proof."])
        try capture(root,to:directory.appendingPathComponent("reaction-after.png"))
        let passed = receipt.checks.values.allSatisfy({ $0 })
        try write(receipt,stage:passed ? "reaction-input-passed" : "reaction-input-unaccepted",to:directory.appendingPathComponent(passed ? "result.json" : "failure.json"))
        return passed
    }
    private static func posts() throws -> [ChatPost] {
        try (100..<160).map { id in
            var value:[String:Any] = ["post_id":id,"channel_id":23,"creator_id":id%2 == 0 ? 10 : 20,"type":"normal","message":"Synthetic rich routing row \(id)","create_at":1_794_481_200_000+id*60_000,"thread_id":0]
            if [120,124].contains(id) { value["type"] = "file";value["file_props"] = ["id":id,"name":"Synthetic image \(id).png","is_image":true,"size":RichActionProtocol.png.count] }
            if id == 124 { value["creator_id"] = 20;value["create_at"] = 1_794_481_200_000+123*60_000 }
            if id == 121 { value["type"] = "file";value["file_props"] = ["id":121,"name":"Synthetic document.pdf","is_image":false,"size":62] }
            if id == 122 { value["props"] = ["safe_url":true];value["url_props"] = [["url":"https://example.invalid/story","title":"Synthetic website title","description":"Synthetic metadata only; never open this address."]] }
            if id == 123 { value["reactions"] = [["sticker_name":"thumbsup","user_ids":[10,20]]] }
            return try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:value))
        }
    }
    private static func navigate(_ id:Int64,model:NativeChatPreviewModel,root:NSView,document:NativeVirtualTimeline.Document) async throws {
        model.scrollPostID = id
        for _ in 0..<40 { try await settle(root,delay:20_000_000);if let index = document.canonicalRows.firstIndex(of:.post(id)),document.hostedView(forRow:index) != nil { return } }
        throw ChatAPIError.invalidResponse
    }
    private static func controlAncestor(_ view:NSView?,inside cell:NSView)->NSControl? {
        var candidate = view
        while let current = candidate,current === cell || current.isDescendant(of:cell) {
            if let control = current as? NSControl { return control }
            if current === cell { break };candidate = current.superview
        };return nil
    }
    private static func accessibilityTree(_ root:NSAccessibilityProtocol)->[[String:Any]] {
        var result:[[String:Any]] = [],queue:[(NSAccessibilityProtocol,Int)] = [(root,0)]
        var cursor = 0
        while cursor < queue.count,result.count < 80 {
            let (node,depth) = queue[cursor];cursor += 1
            result.append(["type":String(describing:type(of:node)),"depth":depth,"role":node.accessibilityRole()?.rawValue as Any? ?? NSNull(),"label":node.accessibilityLabel() as Any? ?? NSNull(),"enabled":node.isAccessibilityEnabled(),"frame":rect(node.accessibilityFrame())])
            if depth < 8 { queue.append(contentsOf:(node.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityProtocol).map { ($0,depth+1) } }) }
        }
        return result
    }
    private static func ancestry(_ view:NSView?,until cell:NSView)->[[String:Any]] {
        var values:[[String:Any]] = [],candidate = view
        while let current = candidate {
            var value:[String:Any] = ["type":String(describing:type(of:current)),"frame":rect(current.frame),"is_NSControl":current is NSControl]
            if let control = current as? NSControl { value["enabled"] = control.isEnabled }
            values.append(value);if current === cell { break };candidate = current.superview
        };return values
    }
    private static func markers(_ view:NSView)->[NativeMessageActionMarker.Marker] { (view as? NativeMessageActionMarker.Marker).map { [$0] } ?? view.subviews.flatMap(markers) }
    private static func rasters(_ view:NSView)->[NativeInlineImageRaster] { (view as? NativeInlineImageRaster).map { [$0] } ?? view.subviews.flatMap(rasters) }
    private static func findScroll(_ view:NSView)->NSScrollView? {
        if let scroll = view as? NativeTableTimeline.Scroll,scroll.documentView is NativeVirtualTimeline.Document { return scroll }
        for child in view.subviews { if let value = findScroll(child) { return value } };return nil
    }
    private static func horizontal(_ outer:NSRect,_ inner:NSRect,tolerance:CGFloat)->Bool { inner.minX >= outer.minX-tolerance && inner.maxX <= outer.maxX+tolerance }
    private static func xy(_ value:NSPoint)->[String:CGFloat] { ["x":value.x,"y":value.y] }
    private static func rect(_ value:NSRect)->[String:CGFloat] { ["x":value.minX,"y":value.minY,"width":value.width,"height":value.height] }
    private static func settle(_ root:NSView,delay:UInt64) async throws { try await Task.sleep(nanoseconds:delay);root.layoutSubtreeIfNeeded();root.needsDisplay = true;root.displayIfNeeded() }
    private static func capture(_ root:NSView,to url:URL) throws { guard let bitmap = root.bitmapImageRepForCachingDisplay(in:root.bounds) else { throw ChatAPIError.invalidResponse };root.cacheDisplay(in:root.bounds,to:bitmap);guard let data = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse };try data.write(to:url,options:.withoutOverwriting) }
    private static func write(_ receipt:Receipt,stage:String,to url:URL) throws {
        let value:[String:Any] = ["stage":stage,"synthetic_only":true,"normal_startup":false,"no_real_account":true,"forced_synthetic_live_status":true,"checks":receipt.checks,"samples":receipt.samples,
            "requests":RichActionProtocol.requested,"completed":RichActionProtocol.completed,"writes":RichActionProtocol.writes,"unknown_requests":RichActionProtocol.unknown,
            "reaction_input_probe":RichActionProtocol.reactionInputAllowed,
            "limits":RichActionProtocol.reactionInputAllowed
                ? "Owned hidden-window event dispatch; only one exact synthetic thumbsup deletion on post123 and its canonical readback may succeed. No global input, desktop activation, real account, image/file/link execution or physical-input acceptance. Counters and canonical state determine success; do not infer delivery from sending events."
                : "Hidden synthetic connected model, actual production controls and outer-root hit routing. NSControl ancestry remains a strict prerequisite; hosting-only hits fail. No action, menu, download, preview, website, clipboard, physical input or live-account authorization execution." ]
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.withoutOverwriting)
    }
}

private final class RichActionProtocol:URLProtocol {
    @MainActor static var png = Data(),requested:[String:Int] = [:],completed:[String:Int] = [:],unknown:[String] = []
    @MainActor static var writes = 0,runtimeDenied = 0
    @MainActor static var reactionInputAllowed = false,reactionDeletes = 0,reactionReads = 0
    private let lock = NSLock();private var stopped = false
    private var isStopped:Bool { lock.lock();defer { lock.unlock() };return stopped }
    @MainActor static func reset() throws {
        requested = [:];completed = [:];unknown = [];writes = 0;runtimeDenied = 0
        reactionInputAllowed = false;reactionDeletes = 0;reactionReads = 0
        guard let image = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:120,pixelsHigh:80,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let context = NSGraphicsContext(bitmapImageRep:image) else { throw ChatAPIError.invalidResponse }
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = context;NSColor.systemTeal.setFill();NSRect(x:0,y:0,width:120,height:80).fill();NSGraphicsContext.restoreGraphicsState()
        guard let data = image.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse };png = data
    }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func stopLoading() { lock.lock();stopped = true;lock.unlock() }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048)
            while stream.hasBytesAvailable,data.count < 16_384 { let count = stream.read(&buffer,maxLength:min(buffer.count,16_384-data.count));if count <= 0 { break };data.append(contentsOf:buffer.prefix(count)) }
        }
        guard data.count < 16_384 else { fail();return }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        let fields = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        DispatchQueue.main.async { self.route(fields) }
    }
    @MainActor private func route(_ fields:[String:String]) {
        guard !isStopped,let url = request.url else { return }
        guard url.scheme == "https",url.host == NativeVirtualTimelineRichActionChecks.host else { Self.unknown.append("foreign-origin");fail();return }
        if url.path == "/webman/3rdparty/Chat/config" { Self.runtimeDenied += 1;fail();return }
        guard url.path.hasPrefix("/webapi/") else { Self.unknown.append("unknown-path");fail();return }
        func field(_ key:String)->String { let raw = fields[key] ?? "";return (try? JSONSerialization.jsonObject(with:Data(raw.utf8),options:.fragmentsAllowed) as? String) ?? raw }
        let endpoint = url.lastPathComponent,method = field("method"),key = endpoint+":"+method
        Self.requested[key,default:0] += 1
        if endpoint == "SYNO.Chat.Post.File",method == "thumbnail",["120","124"].contains(field("post_id")),field("type") == "M" {
            let asset = "thumbnail:"+field("post_id");Self.requested[asset,default:0] += 1
            Self.completed[asset,default:0] += 1;send(Self.png,mime:"image/png");return
        }
        let payload:[String:Any]
        switch (endpoint,method) {
        case ("SYNO.API.Info","query"):
            let names = ["SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Channel.Member","SYNO.Chat.Misc","SYNO.Chat.Post","SYNO.Chat.Post.File","SYNO.Chat.Admin.Setting","SYNO.Chat.User.Preference","SYNO.Chat.Post.Subscribe"] + (Self.reactionInputAllowed ? ["SYNO.Chat.Post.Reaction"] : [])
            payload = Dictionary(uniqueKeysWithValues:names.map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"] as [String:Any]) })
        case ("SYNO.Chat.Post.Reaction","delete") where Self.reactionInputAllowed && Self.reactionDeletes == 0 && field("post_id") == "123" && field("sticker_name") == "thumbsup":
            Self.reactionDeletes += 1;Self.writes += 1;payload = [:]
        case ("SYNO.Chat.Post","list") where Self.reactionInputAllowed && Self.reactionDeletes == 1 && Self.reactionReads == 0 && field("channel_id") == "23" && field("post_id") == "123" && field("thread_id") == "0" && field("prev_count") == "0" && field("next_count") == "0":
            Self.reactionReads += 1
            payload = ["posts":[["post_id":123,"channel_id":23,"creator_id":20,"type":"normal","message":"Synthetic rich routing row 123","create_at":1_794_481_200_000+123*60_000,"thread_id":0,"reactions":[["sticker_name":"thumbsup","user_ids":[20]]]]]]
        case ("SYNO.Chat.User","list"):payload = ["users":[["user_id":10,"username":"synthetic-rich-actions","nickname":"Synthetic Alex","type":"human","human_type":"dsm"],["user_id":20,"username":"synthetic-peer","nickname":"Synthetic Jordan","type":"human","human_type":"dsm"]]]
        case ("SYNO.Chat.Channel","list"):payload = ["channels":[["channel_id":23,"name":"Synthetic rich controls","type":"private","encrypted":false,"is_joined":true,"creator_id":10,"unread":0]]]
        case ("SYNO.Chat.Channel.Member","get"):payload = ["user_ids":[10,20]]
        case ("SYNO.Chat.Misc","acl"):payload = ["acls":[]]
        case ("SYNO.Chat.Admin.Setting","get"):payload = ["hide_post_url_preview":false,"allow_read_status":false,"file_size_limit":0]
        case ("SYNO.Chat.User.Preference","get"):payload = ["preferences":["theme_style":"dark","theme_background":0,"prefer_user_name_format":"nickname","sidebar_pinning_unread":false,"notification_showmessage":false,"notification_browser_active":false,"notification_mute":true,"calendar_enable":false,"recent_emoji":[]]]
        case ("SYNO.Chat.Post.Subscribe","get"):payload = ["subscribes":[]]
        default:
            if ["create","set","update","delete","read","vote","hide"].contains(method) { Self.writes += 1 }
            else { Self.unknown.append(key) };fail();return
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject:["success":true,"data":payload]) else { fail();return }
        Self.completed[key,default:0] += 1;send(bytes,mime:"application/json")
    }
    private func send(_ data:Data,mime:String) {
        guard !isStopped,let url = request.url,let response = HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":mime]) else { return }
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    private func fail() { guard !isStopped else { return };client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL)) }
}
#endif
