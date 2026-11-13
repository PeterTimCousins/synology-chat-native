#if DEBUG
import AppKit
import SwiftUI

/// Routing only: forced-visible production quick actions in two owned hidden windows.
/// Never opens a menu, executes an action, sends input, or creates an API session.
@MainActor enum NativeVirtualTimelineActionChecks {
    private static let draft = "Synthetic action routing draft — unchanged."
    @MainActor private final class Receipt {
        var checks:[String:Bool] = [:]
        var samples:[[String:Any]] = []
    }
    static func render(to directory:URL) async -> Bool {
        let receipt = Receipt()
        do {
            guard !FileManager.default.fileExists(atPath:directory.path) else { return false }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            _ = NSApplication.shared
            for compact in [false,true] {
                let variant = compact ? "compact" : "plain"
                do {
                    try await runVariant(compact:compact,directory:directory,receipt:receipt)
                    receipt.checks[variant+"_fixture_setup_completed"] = true
                } catch {
                    receipt.checks[variant+"_fixture_setup_completed"] = false
                    receipt.samples.append(["variant":variant,"stage":"setup-or-capture-failed","error":String(describing:error),"synthetic_only":true])
                }
            }
            guard !receipt.checks.isEmpty,receipt.checks.values.allSatisfy({ $0 }) else {
                try write(receipt,to:directory.appendingPathComponent("failure.json"),status:"failed");return false
            }
            try write(receipt,to:directory.appendingPathComponent("result.json"),status:"passed")
            return true
        } catch {
            try? write(receipt,to:directory.appendingPathComponent("failure.json"),status:"failed")
            return false
        }
    }
    private static func runVariant(compact:Bool,directory:URL,receipt:Receipt) async throws {
        let variant = compact ? "compact" : "plain"
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,notificationDefaults:nil)
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":23,"name":"Synthetic action channel","type":"channel","encrypted":false,"unread":0}"#.utf8))]
        model.selection = 23
        model.posts = try (100..<160).map { id in
            let object:[String:Any] = ["post_id":id,"channel_id":23,"creator_id":compact && id == 119 ? 10 : id%2+10,
                "type":"normal","message":"Synthetic action routing row \(id)","create_at":1000+id]
            return try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:object))
        }
        model.scrollPostID = 120;model.draft = draft
        guard let post = model.posts.first(where:{ $0.id == 120 }),let predecessor = model.posts.first(where:{ $0.id == 119 }) else { throw ChatAPIError.invalidResponse }
        let actualCompact = NativeTimelineGrouping.isContinuation(post,after:predecessor,calendar:.current)
        receipt.checks[variant+"_expected_grouping"] = actualCompact == compact
        let initialCanonical = model.posts.map { $0.message }
        let timeline = NativeVirtualTimeline(model:model,onBottomChanged:{ _ in },fixtureActionPosts:[120])
        let root = NSHostingView(rootView:AnyView(timeline.environment(\.nativeChatStyle,ChatAppearanceStyle.dark).environment(\.colorScheme,.dark)))
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:680,height:520),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = root
        defer { root.rootView = AnyView(EmptyView());root.layoutSubtreeIfNeeded();window.contentView = nil;window.close() }
        var candidate:NSScrollView?
        for _ in 0..<40 {
            root.layoutSubtreeIfNeeded()
            candidate = scroll(in:root)
            if candidate != nil { break }
            try await Task.sleep(nanoseconds:15_000_000)
        }
        guard let scroll = candidate,let document = scroll.documentView as? NativeVirtualTimeline.Document else { throw ChatAPIError.invalidResponse }
        receipt.checks[variant+"_actual_virtual_backend"] = scroll.identifier?.rawValue == "native-virtual-timeline" && document.identifier?.rawValue == "native-virtual-timeline"
        try await settle(root)
        model.scrollPostID = nil
        root.layoutSubtreeIfNeeded();try await settle(root)
        guard let index = document.canonicalRows.firstIndex(of:.post(120)),
              let cell = document.hostedView(forRow:index) as? NativeVirtualTimeline.Cell,let host = cell.host else { throw ChatAPIError.invalidResponse }
        var selectedMarkers:[NativeMessageActionMarker.Marker] = []
        for _ in 0..<30 {
            selectedMarkers = markers(in:cell).filter { $0.postID == 120 }
            if selectedMarkers.contains(where:{ $0.kind == "toolbar" && $0.bounds.width > 100 }),selectedMarkers.contains(where:{ $0.kind == "more" }) { break }
            try await Task.sleep(nanoseconds:15_000_000)
            root.layoutSubtreeIfNeeded();root.needsDisplay = true;root.displayIfNeeded()
        }
        receipt.checks[variant+"_exact_two_action_markers"] = selectedMarkers.count == 2
        guard let toolbar = selectedMarkers.first(where:{ $0.kind == "toolbar" }),let more = selectedMarkers.first(where:{ $0.kind == "more" }) else { throw ChatAPIError.invalidResponse }
        let toolbarRect = toolbar.convert(toolbar.bounds,to:document),moreRect = more.convert(more.bounds,to:document),visible = scroll.documentVisibleRect
        let tolerance = 1/max(1,window.backingScaleFactor)
        let morePoint = NSPoint(x:moreRect.midX,y:moreRect.midY)
        let rowMarker = timelineMarkers(in:cell).first(where:{ $0.postID == 120 })
        let messageRect = rowMarker.map { $0.convert($0.bounds,to:document) } ?? document.rect(ofRow:index)
        let bodyPoint = NSPoint(x:min(messageRect.maxX-8,messageRect.minX+90),y:messageRect.minY+messageRect.height*0.7)
        let geometryFinite = [toolbarRect,moreRect,messageRect,visible,cell.frame,cell.bounds,host.frame,host.bounds].allSatisfy { rect in
            [rect.minX,rect.minY,rect.width,rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
        }
        receipt.checks[variant+"_finite_positive_geometry"] = geometryFinite
        guard geometryFinite else { throw ChatAPIError.invalidResponse }
        receipt.checks[variant+"_active_full_toolbar_width"] = toolbarRect.width > 100 && toolbarRect.height > 0
        receipt.checks[variant+"_more_marker_is_28_point_frame"] = abs(moreRect.width-28) <= tolerance && abs(moreRect.height-28) <= tolerance
        receipt.checks[variant+"_full_toolbar_inside_viewport"] = contains(visible,toolbarRect,tolerance:tolerance)
        receipt.checks[variant+"_more_center_inside_viewport"] = visible.contains(morePoint)
        receipt.checks[variant+"_body_control_inside_message_and_viewport"] = messageRect.contains(bodyPoint) && visible.contains(bodyPoint)
        let inputBefore = document.debugDiagnostics["input_generation"] as? String
        let clipBefore = scroll.documentVisibleRect
        let countBefore = model.posts.count
        var sample:[String:Any] = ["variant":variant,"synthetic_only":true,"expected_compact":compact,"actual_compact":actualCompact,
            "committed_row_index":index,"committed_row_rect":rect(document.rect(ofRow:index)),"cell_frame":rect(cell.frame),"cell_bounds":rect(cell.bounds),
            "cell_rect_in_document":rect(cell.convert(cell.bounds,to:document)),"host_frame":rect(host.frame),"host_bounds":rect(host.bounds),
            "toolbar_rect":rect(toolbarRect),"more_rect":rect(moreRect),"message_rect":rect(messageRect),"viewport":rect(visible),
            "more_center":point(morePoint),"body_control_point":point(bodyPoint),"input_generation_before":inputBefore as Any? ?? NSNull(),
            "scroll_identity":String(describing:ObjectIdentifier(scroll)),"document_identity":String(describing:ObjectIdentifier(document)),
            "cell_identity":String(describing:ObjectIdentifier(cell)),"host_identity":String(describing:ObjectIdentifier(host)),
            "action_marker_count":selectedMarkers.count,"window_visible":window.isVisible]
        for (kind,location) in [("more",morePoint),("body",bodyPoint)] {
            // NSView.hitTest receives a point in the RECEIVER'S SUPERVIEW.
            // Resolve from the actual outer root, not a conveniently chosen child.
            let receiverPoint = document.convert(location,to:root.superview)
            let hit = root.hitTest(receiverPoint)
            let hitInCell = hit.map { $0 === cell || $0.isDescendant(of:cell) } ?? false
            let hitInHost = hit.map { $0 === host || $0.isDescendant(of:host) } ?? false
            let hitIndex = hit.map { document.row(for:$0) } ?? -1
            let hitRow = hitIndex >= 0 && hitIndex < document.canonicalRows.count ? document.canonicalRows[hitIndex] : nil
            var hitPost:Int64?
            if case let .post(id)? = hitRow { hitPost = id }
            let markerIntercepted = hit is NativeMessageActionMarker.Marker
            sample[kind+"_root_receiver_superview_point"] = point(receiverPoint)
            sample[kind+"_hit_type"] = hit.map { String(describing:type(of:$0)) } ?? "nil"
            sample[kind+"_hit_identity"] = hit.map { String(describing:ObjectIdentifier($0)) } as Any? ?? NSNull()
            sample[kind+"_hit_in_actual_cell"] = hitInCell;sample[kind+"_hit_in_actual_host"] = hitInHost
            sample[kind+"_hit_row_index"] = hitIndex;sample[kind+"_hit_post_id"] = hitPost.map { $0 as Any } ?? NSNull()
            sample[kind+"_marker_intercepted"] = markerIntercepted
            sample[kind+"_point_in_cell_bounds"] = cell.bounds.contains(document.convert(location,to:cell))
            if let hit { sample[kind+"_hit_frame"] = rect(hit.frame);sample[kind+"_hit_bounds"] = rect(hit.bounds) }
            receipt.checks[variant+"_"+kind+"_root_hit_routes_120_cell_and_host"] = hitInCell && hitInHost && hitPost == 120 && hitIndex == index
            receipt.checks[variant+"_"+kind+"_marker_does_not_intercept"] = !markerIntercepted
        }
        let diagnostics = document.debugDiagnostics
        let maxHosts = diagnostics["max_hosted_cells"] as? Int ?? Int.max
        sample["native_virtual_diagnostics"] = diagnostics
        sample["input_generation_after"] = diagnostics["input_generation"] as Any? ?? NSNull()
        sample["post_ids_after"] = model.posts.map(\.id)
        sample["canonical_120_after"] = model.posts.first(where:{ $0.id == 120 })?.message as Any? ?? NSNull()
        sample["draft_after"] = model.draft;sample["model_connected"] = model.connected
        sample["application_is_running"] = NSApplication.shared.isRunning;sample["activation_policy_raw_value"] = NSApplication.shared.activationPolicy().rawValue
        receipt.samples.append(sample)
        receipt.checks[variant+"_input_generation_unchanged"] = inputBefore != nil && diagnostics["input_generation"] as? String == inputBefore
        receipt.checks[variant+"_viewport_unchanged_by_hit_test"] = scroll.documentVisibleRect == clipBefore
        receipt.checks[variant+"_model_count_order_canonical_draft_unchanged"] = countBefore == 60 && model.posts.map(\.id) == Array(Int64(100)...159) && model.posts.map({ $0.message }) == initialCanonical && model.draft == draft
        receipt.checks[variant+"_no_connected_account"] = !model.connected && model.userID == nil
        receipt.checks[variant+"_actual_weak_hosts_bounded"] = maxHosts > 0 && maxHosts <= 32
        receipt.checks[variant+"_native_window_never_visible"] = !window.isVisible
        try capture(root,to:directory.appendingPathComponent(variant+"-root.png"))
    }
    private static func contains(_ outer:NSRect,_ inner:NSRect,tolerance:CGFloat)->Bool {
        inner.width > 0 && inner.height > 0 && inner.minX >= outer.minX-tolerance && inner.maxX <= outer.maxX+tolerance && inner.minY >= outer.minY-tolerance && inner.maxY <= outer.maxY+tolerance
    }
    private static func point(_ point:NSPoint)->[String:CGFloat] { ["x":point.x,"y":point.y] }
    private static func rect(_ rect:NSRect)->[String:CGFloat] { ["x":rect.minX,"y":rect.minY,"width":rect.width,"height":rect.height] }
    private static func scroll(in view:NSView)->NSScrollView? {
        if let scroll = view as? NativeTableTimeline.Scroll,scroll.documentView is NativeVirtualTimeline.Document { return scroll }
        for child in view.subviews { if let result = scroll(in:child) { return result } };return nil
    }
    private static func markers(in view:NSView)->[NativeMessageActionMarker.Marker] {
        let own = (view as? NativeMessageActionMarker.Marker).map { [$0] } ?? []
        return own+view.subviews.flatMap { markers(in:$0) }
    }
    private static func timelineMarkers(in view:NSView)->[NativeTimelineRowMarker.Marker] {
        let own = (view as? NativeTimelineRowMarker.Marker).map { [$0] } ?? []
        return own+view.subviews.flatMap { timelineMarkers(in:$0) }
    }
    private static func settle(_ root:NSView) async throws {
        for _ in 0..<12 { try await Task.sleep(nanoseconds:15_000_000);root.layoutSubtreeIfNeeded();root.needsDisplay = true;root.displayIfNeeded() }
    }
    private static func capture(_ root:NSView,to url:URL) throws {
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in:root.bounds) else { throw ChatAPIError.invalidResponse }
        root.cacheDisplay(in:root.bounds,to:bitmap)
        guard let data = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
        try data.write(to:url,options:.withoutOverwriting)
    }
    private static func write(_ receipt:Receipt,to url:URL,status:String) throws {
        let value:[String:Any] = ["status":status,"synthetic_only":true,"normal_startup":false,"no_api_client_or_session_created":true,
            "checks":receipt.checks,"samples":receipt.samples,"visible_window_opened":false,
            "limits":"Hidden production virtual row toolbar forced visible by DEBUG seam; validates outer-root AppKit hit routing only. No hover activation, physical input, action execution, open menu, sending, clipboard, API authentication/permissions, or live-app acceptance."]
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.withoutOverwriting)
    }
}
#endif
