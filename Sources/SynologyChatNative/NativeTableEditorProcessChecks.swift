#if DEBUG
import AppKit
import SwiftUI

/// Exact installed-host unit data and mutation, exercised under NSApplication.run.
/// No API client, authentication, menu action or save is involved.
@MainActor enum NativeTableEditorProcessChecks {
    private static let original = "Synthetic editor original café 😀\nSecond line for caret movement."
    private static let composerDraft = "Synthetic ordinary composer draft"
    @MainActor private struct Harness {
        let model:NativeChatPreviewModel
        let root:NSHostingView<AnyView>
        let scroll:NativeTableTimeline.Scroll
        let table:NSView
        let window:NSWindow
        let owner:UUID
        func update() { root.layoutSubtreeIfNeeded() }
        var rowCount:Int { (table as? NativeTableTimeline.Table)?.numberOfRows ?? (table as? NativeVirtualTimeline.Document)?.numberOfRows ?? 0 }
        var diagnostics:[String:Any] { (table as? NativeTableTimeline.Table)?.debugDiagnostics ?? (table as? NativeVirtualTimeline.Document)?.debugDiagnostics ?? [:] }
        func rect(ofRow index:Int)->NSRect { (table as? NativeTableTimeline.Table)?.rect(ofRow:index) ?? (table as? NativeVirtualTimeline.Document)?.rect(ofRow:index) ?? .zero }
        func row(for view:NSView)->Int { (table as? NativeTableTimeline.Table)?.row(for:view) ?? (table as? NativeVirtualTimeline.Document)?.row(for:view) ?? -1 }
        func cell(at index:Int)->NSView? { (table as? NativeTableTimeline.Table)?.view(atColumn:0,row:index,makeIfNecessary:false) ?? (table as? NativeVirtualTimeline.Document)?.hostedView(forRow:index) }
    }
    @MainActor private final class Receipt {
        var samples:[[String:Any]] = []
        var checks:[String:Bool] = [:]
        var backend = "native-table"
    }
    static func render(to directory:URL,closeTypingEvent:Bool = false,useVirtual:Bool = false) async -> Bool {
        let receipt = Receipt()
        receipt.backend = useVirtual ? "native-virtual" : "native-table"
        var stage = "prepare"
        do {
            guard !FileManager.default.fileExists(atPath:directory.path) else { return false }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            _ = NSApplication.shared
            let model = NativeChatPreviewModel(restoreNotificationPreference:false,notificationDefaults:nil),owner = UUID()
            model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":23,"name":"Synthetic editor channel","type":"channel","encrypted":false,"unread":0}"#.utf8))]
            model.selection = 23;model.posts = try (100..<160).map { try post(Int64($0),text:$0 == 120 ? original : nil) }
            model.scrollPostID = 120;model.draft = composerDraft
            let timeline:AnyView = useVirtual
                ? AnyView(NativeVirtualTimeline(model:model,onBottomChanged:{ _ in },fixtureEditors:[120:.init(owner:owner,text:original)]))
                : AnyView(NativeTableTimeline(model:model,onBottomChanged:{ _ in },fixtureEditors:[120:.init(owner:owner,text:original)],traceRowFrames:true))
            let root = NSHostingView(rootView:AnyView(timeline.environment(\.nativeChatStyle,ChatAppearanceStyle.dark).environment(\.colorScheme,.dark)))
            let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:680,height:520),styleMask:[],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = root
            defer { model.endMessageEditing(owner:owner);root.rootView = AnyView(EmptyView());root.layoutSubtreeIfNeeded();window.contentView = nil;window.close() }
            for _ in 0..<40 {
                root.layoutSubtreeIfNeeded()
                if tableScroll(root) != nil { break }
                try await Task.sleep(nanoseconds:15_000_000)
            }
            guard let scroll = tableScroll(root),let table = scroll.documentView else { throw ChatAPIError.invalidResponse }
            receipt.checks["requested_backend_selected"] = useVirtual ? table is NativeVirtualTimeline.Document : table is NativeTableTimeline.Table
            let host = Harness(model:model,root:root,scroll:scroll,table:table,window:window,owner:owner)
            host.update();try await settle(host)
            model.scrollPostID = nil;host.update();try await settle(host)
            model.beginMessageEditing(owner:owner);try await settle(host)
            stage = "actual-editor-setup"
            let candidates = editors(table)
            receipt.checks["exactly_one_real_editable_text_view"] = candidates.count == 1
            guard let text = candidates.first else { throw ChatAPIError.invalidResponse }
            receipt.checks["initial_text_exact"] = text.string == original
            receipt.checks["make_first_responder_succeeded"] = window.makeFirstResponder(text)
            receipt.checks["initial_first_responder"] = window.firstResponder === text
            receipt.checks["initial_edit_owner"] = model.activeMessageEditor == owner
            guard let undo = text.undoManager else { throw ChatAPIError.invalidResponse }
            receipt.checks["native_editor_allows_undo"] = text.allowsUndo
            // These are deliberately the exact unit insertion and selection operations.
            text.setSelectedRange(NSRange(location:(text.string as NSString).length,length:0))
            undo.beginUndoGrouping();text.insertText(" — unsaved 😀",replacementRange:text.selectedRange());undo.endUndoGrouping()
            if closeTypingEvent {
                receipt.checks["known_outer_typing_event_group"] = undo.groupingLevel == 1
                guard undo.groupingLevel == 1 else { throw ChatAPIError.invalidResponse }
                undo.endUndoGrouping()
                receipt.checks["synthetic_typing_event_closed"] = undo.groupingLevel == 0
            }
            try await settle(host)
            let content = Data(text.string.utf8),selection = text.selectedRange()
            let before = geometry(host,text:text,label:"before-prepend")
            receipt.samples.append(before)
            receipt.checks["inserted_exact_unsaved_suffix"] = text.string == original+" — unsaved 😀"
            receipt.checks["baseline_real_undo_available"] = undo.canUndo
            receipt.checks["baseline_expected_row_21"] = before["expected_index"] as? Int == 21 && before["actual_row_for_view"] as? Int == 21
            guard let textOffset = before["text_offset"] as? CGFloat,let rowOffset = before["row_offset"] as? CGFloat else { throw ChatAPIError.invalidResponse }
            let textID = ObjectIdentifier(text),undoID = ObjectIdentifier(undo),scrollID = ObjectIdentifier(scroll),tableID = ObjectIdentifier(table),account = model.accountGeneration,token = model.historyViewportToken
            let tolerance = 1/window.backingScaleFactor
            try capture(root,to:directory.appendingPathComponent("before-prepend.png"))
            let afterCapture = geometry(host,text:text,label:"before-prepend-after-capture")
            receipt.samples.append(afterCapture)
            receipt.checks["baseline_capture_did_not_move_text"] = (afterCapture["text_offset"] as? CGFloat).map { abs($0-textOffset) <= tolerance } ?? false
            receipt.checks["baseline_capture_did_not_move_row"] = (afterCapture["row_offset"] as? CGFloat).map { abs($0-rowOffset) <= tolerance } ?? false
            receipt.checks["baseline_actual_row_matches_committed"] = afterCapture["actual_row_matches_committed"] as? Bool == true
            stage = "exact-three-post-mutation"
            (table as? NativeTableTimeline.Table)?.resetTrace?()
            let operationStarted = ProcessInfo.processInfo.systemUptime
            model.posts = try (97..<100).map { try post(Int64($0)) }+model.posts
            receipt.samples.append(geometry(host,text:text,label:"model-changed-before-update"))
            host.update()
            // Read-only geometry observations run alongside the unchanged unit's
            // twelve 15ms layout/display ticks, then its 800ms passive delay.
            // They never reposition, retile, focus or paint the editor.
            let observations:[(String,UInt64)] = [("100ms",100_000_000),("200ms",200_000_000),("1sec",1_000_000_000)]
            var tasks:[Task<Void,Error>] = []
            for (label,delay) in observations {
                tasks.append(Task { @MainActor in
                    try await Task.sleep(nanoseconds:delay)
                    var sample = geometry(host,text:text,label:"after-prepend-"+label)
                    sample["elapsed_ms"] = (ProcessInfo.processInfo.systemUptime-operationStarted)*1000
                    sample["baseline_text_offset"] = textOffset;sample["baseline_row_offset"] = rowOffset
                    sample["text_offset_delta"] = (sample["text_offset"] as? CGFloat).map { $0-textOffset } as Any? ?? NSNull()
                    sample["row_offset_delta"] = (sample["row_offset"] as? CGFloat).map { $0-rowOffset } as Any? ?? NSNull()
                    sample["one_backing_pixel_tolerance"] = tolerance;receipt.samples.append(sample)
                    let currentEditors = editors(table)
                    receipt.checks["same_actual_editor_"+label] = currentEditors.count == 1 && currentEditors.first.map { ObjectIdentifier($0) == textID } == true
                    receipt.checks["same_first_responder_"+label] = window.firstResponder === text
                    receipt.checks["unsaved_content_exact_"+label] = Data(text.string.utf8) == content
                    receipt.checks["selection_exact_"+label] = text.selectedRange() == selection
                    receipt.checks["same_undo_available_"+label] = text.undoManager.map { ObjectIdentifier($0) == undoID && $0.canUndo } ?? false
                    receipt.checks["correct_editor_row_24_"+label] = sample["expected_index"] as? Int == 24 && sample["actual_row_for_view"] as? Int == 24 && sample["expected_cell_is_actual"] as? Bool == true && sample["cell_post_id"] as? Int64 == 120
                    receipt.checks["actual_row_view_matches_committed_"+label] = sample["actual_row_matches_committed"] as? Bool == true
                    receipt.checks["committed_offset_one_pixel_"+label] = (sample["row_offset"] as? CGFloat).map { abs($0-rowOffset) <= tolerance } ?? false
                    receipt.checks["actual_text_offset_one_pixel_"+label] = (sample["text_offset"] as? CGFloat).map { abs($0-textOffset) <= tolerance } ?? false
                    receipt.checks["same_scope_identity_"+label] = ObjectIdentifier(scroll) == scrollID && scroll.documentView.map { ObjectIdentifier($0) == tableID } == true && model.accountGeneration == account && model.historyViewportToken == token && model.activeMessageEditor == owner
                    receipt.checks["canonical_and_draft_unchanged_"+label] = model.posts.first(where:{ $0.id == 120 })?.message == original && model.draft == composerDraft
                    receipt.checks["window_hidden_"+label] = !window.isVisible
                    if useVirtual { receipt.checks["canonical_host_order_"+label] = host.diagnostics["host_order_is_canonical"] as? Bool == true }
                })
            }
            defer { for task in tasks { task.cancel() } }
            try await settle(host)
            receipt.samples.append(geometry(host,text:text,label:"after-prepend-unit-settle"))
            try capture(root,to:directory.appendingPathComponent("after-prepend-unit-settle.png"))
            try await Task.sleep(nanoseconds:800_000_000)
            receipt.samples.append(geometry(host,text:text,label:"after-prepend-unit-one-second"))
            for task in tasks { try await task.value }
            try capture(root,to:directory.appendingPathComponent("after-prepend-one-second.png"))
            receipt.checks["exact_post_ids_97_through_159"] = model.posts.map(\.id) == Array(Int64(97)...159)
            receipt.checks["exact_table_row_count_65"] = host.rowCount == 65
            let diagnostics = host.diagnostics
            let maxHosts = diagnostics["max_hosted_cells"] as? Int ?? Int.max
            receipt.checks["actual_weak_host_count_bounded"] = maxHosts > 0 && maxHosts <= 32
            receipt.checks["no_connected_api_account"] = !model.connected && model.userID == nil
            receipt.checks["window_never_visible"] = !window.isVisible
            // Persist observations before invoking the real undo manager, so an
            // AppKit exception also leaves the geometry evidence reviewable.
            try write(receipt:receipt,stage:stage,to:directory.appendingPathComponent("observations.json"))
            stage = "actual-undo-redo"
            undo.undo();try await settle(host)
            receipt.checks["actual_undo_original_exact"] = text.string == original && undo.canRedo
            receipt.samples.append(geometry(host,text:text,label:"after-actual-undo"))
            try capture(root,to:directory.appendingPathComponent("after-actual-undo.png"))
            undo.redo();try await settle(host)
            receipt.checks["actual_redo_unsaved_exact"] = Data(text.string.utf8) == content && undo.canUndo
            receipt.samples.append(geometry(host,text:text,label:"after-actual-redo"))
            try capture(root,to:directory.appendingPathComponent("after-actual-redo.png"))
            receipt.checks["final_canonical_original_draft_owner"] = model.posts.first(where:{ $0.id == 120 })?.message == original && model.draft == composerDraft && model.activeMessageEditor == owner
            guard receipt.checks.values.allSatisfy({ $0 }) else { throw ChatAPIError.invalidResponse }
            try write(receipt:receipt,stage:"passed",to:directory.appendingPathComponent("result.json"))
            return true
        } catch {
            try? write(receipt:receipt,stage:stage,to:directory.appendingPathComponent("failure.json"))
            return false
        }
    }
    private static func post(_ id:Int64,text:String? = nil) throws -> ChatPost {
        let object:[String:Any] = ["post_id":id,"channel_id":23,"creator_id":id%2+10,"type":"normal","message":text ?? "Synthetic adjacent row \(id)","create_at":1000+id]
        return try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:object))
    }
    private static func settle(_ host:Harness) async throws {
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds:15_000_000)
            host.window.contentView?.layoutSubtreeIfNeeded()
            host.window.contentView?.needsDisplay = true
            host.window.contentView?.displayIfNeeded()
        }
    }
    private static func editors(_ view:NSView)->[NSTextView] {
        let own = (view as? NSTextView).map { $0.isEditable && !$0.isFieldEditor ? [$0] : [] } ?? []
        return own+view.subviews.flatMap(editors)
    }
    private static func tableScroll(_ view:NSView)->NativeTableTimeline.Scroll? {
        if let value = view as? NativeTableTimeline.Scroll { return value }
        for child in view.subviews { if let value = tableScroll(child) { return value } }
        return nil
    }
    private static func geometry(_ host:Harness,text:NSTextView,label:String)->[String:Any] {
        let index = (host.model.posts.firstIndex(where:{ $0.id == 120 }) ?? -2)+1
        let attached = text.window === host.window && text.isDescendant(of:host.table)
        let row = host.rect(ofRow:index)
        var chain:[[String:String]] = [],view:NSView? = text
        var actualCell:NSView?,actualRow:NSView?,cellRow:NativeTableTimelineState.Row?
        while let current = view,current !== host.table {
            chain.append(["type":String(describing:type(of:current)),"frame":NSStringFromRect(current.frame),"bounds":NSStringFromRect(current.bounds)])
            if let cell = current as? NativeTableTimeline.Cell { actualCell = cell;cellRow = cell.row }
            if let cell = current as? NativeVirtualTimeline.Cell { actualCell = cell;actualRow = cell;cellRow = cell.row }
            if let rowView = current as? NSTableRowView { actualRow = rowView }
            view = current.superview
        }
        var postID:Int64?
        if case let .post(id)? = cellRow { postID = id }
        var value:[String:Any] = ["phase":label,"synthetic_only":true,"application_is_running":NSApplication.shared.isRunning,
            "activation_policy_raw_value":NSApplication.shared.activationPolicy().rawValue,
            "clip_y":host.scroll.documentVisibleRect.minY,"clip_bounds":NSStringFromRect(host.scroll.documentVisibleRect),"view_chain":chain,
            "expected_index":index,"actual_row_for_view":attached ? host.row(for:text) : -1,"cell_row":cellRow.map { String(describing:$0) } ?? "nil",
            "cell_post_id":postID.map { $0 as Any } ?? NSNull(),"expected_cell_is_actual":host.cell(at:index) === actualCell,
            "row_y":row.minY,"row_height":row.height,"row_offset":row.minY-host.scroll.documentVisibleRect.minY,
            "text_frame":NSStringFromRect(text.frame),"text_bounds":NSStringFromRect(text.bounds),
            "inner_visible":text.enclosingScrollView.map { NSStringFromRect($0.documentVisibleRect) } ?? "none",
            "text_identity":String(describing:ObjectIdentifier(text)),"editor_attached":attached,"first_responder":host.window.firstResponder === text,
            "content":text.string,"selection":["location":text.selectedRange().location,"length":text.selectedRange().length],
            "can_undo":text.undoManager?.canUndo ?? false,"can_redo":text.undoManager?.canRedo ?? false,
            "undo_grouping_level":text.undoManager?.groupingLevel ?? -1,"table":host.diagnostics]
        value["scroll_identity"] = String(describing:ObjectIdentifier(host.scroll))
        value["table_identity"] = String(describing:ObjectIdentifier(host.table))
        value["window_identity"] = String(describing:ObjectIdentifier(host.window))
        value["root_identity"] = String(describing:ObjectIdentifier(host.root))
        value["account_generation"] = host.model.accountGeneration
        value["viewport_token"] = host.model.historyViewportToken.uuidString
        value["main_draft"] = host.model.draft
        value["canonical_120_message"] = host.model.posts.first(where:{ $0.id == 120 })?.message as Any? ?? NSNull()
        value["active_edit_owner"] = host.model.activeMessageEditor?.uuidString as Any? ?? NSNull()
        if attached {
            let frame = text.convert(text.bounds,to:host.table)
            value["text_y"] = frame.minY;value["text_offset"] = frame.minY-host.scroll.documentVisibleRect.minY
            value["text_rect_in_table"] = NSStringFromRect(frame)
        }
        if let actualRow,actualRow.window === host.window,actualRow.isDescendant(of:host.table) {
            let frame = actualRow.convert(actualRow.bounds,to:host.table),tolerance = 1/host.window.backingScaleFactor
            value["actual_row_view_frame"] = NSStringFromRect(actualRow.frame)
            value["actual_row_view_identity"] = String(describing:ObjectIdentifier(actualRow))
            value["actual_row_view_rect_in_table"] = NSStringFromRect(frame)
            value["actual_row_minus_committed_y"] = frame.minY-row.minY
            value["actual_row_minus_committed_height"] = frame.height-row.height
            value["actual_row_matches_committed"] = abs(frame.minY-row.minY) <= tolerance && abs(frame.height-row.height) <= tolerance
        }
        return value
    }
    private static func capture(_ root:NSView,to url:URL) throws {
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in:root.bounds) else { throw ChatAPIError.invalidResponse }
        root.cacheDisplay(in:root.bounds,to:bitmap)
        guard let data = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
        try data.write(to:url,options:.withoutOverwriting)
    }
    private static func write(receipt:Receipt,stage:String,to url:URL) throws {
        let value:[String:Any] = ["synthetic_only":true,"normal_startup":false,"no_api_client_or_session_created":true,"visible_window_opened":false,
            "layout_backend":receipt.backend,
            "application_is_running":NSApplication.shared.isRunning,"activation_policy_raw_value":NSApplication.shared.activationPolicy().rawValue,
            "stage":stage,"checks":receipt.checks,"samples":receipt.samples,
            "limits":"Exact installed-host unit data/view/window/mutation and12x15ms settle loops in application runloop; additional read-only100/200/1sec geometry observations and whole-root PNG capture. No activation, API, authentication, save, menu authorization or live-app acceptance; environment differences are observations, not established causes."]
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.withoutOverwriting)
    }
}
#endif
