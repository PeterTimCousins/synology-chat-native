#if DEBUG
import AppKit
import SwiftUI
import ImageIO

/// Production timeline/cards, synthetic account and strictly intercepted reads.
/// No window is ordered onscreen; a caller owns the process watchdog.
@MainActor enum NativeRichHistoryChecks {
    nonisolated static let host = "rich-history-checks.invalid"
    private static let draft = "Unsent synthetic rich-history draft — retained."

    static func render(to directory:URL) async -> Bool {
        var stage = "prepare"
        do {
            guard !FileManager.default.fileExists(atPath:directory.path) else { return false }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            NSApplication.shared.setActivationPolicy(.prohibited)
            try RichHistoryProtocol.reset()
            let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
                guard session.baseURL.scheme == "https",session.baseURL.host == host else { throw ChatAPIError.invalidResponse }
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [RichHistoryProtocol.self];config.httpShouldSetCookies = false;config.urlCache = nil
                return try ChatAPIClient(session:session,network:URLSession(configuration:config))
            },downloadPreferences:.init(defaults:nil),emojiPreferences:.init(defaults:nil),notificationDefaults:nil)
            defer { RichHistoryProtocol.cancelPending();model.signOutLocally() }
            await model.connect(using:.init(session:.init(baseURL:URL(string:"https://"+host)!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic-rich",importedFromOfficialApp:false))
            guard model.connected,model.userID == 10 else { throw ChatAPIError.invalidResponse }
            model.suspendLiveForProbe();model.liveStatus = .live;model.selection = 23
            model.loadSelection();await model.historyTask?.value
            guard model.posts.count == 4,let pngPost = model.posts.first(where:{ $0.id == 4001 }),
                  let gifPost = model.posts.first(where:{ $0.id == 4002 }),
                  let pollPost = model.posts.first(where:{ $0.id == 4003 }),
                  let linkPost = model.posts.first(where:{ $0.id == 4004 }),
                  pollPost.props?.vote?.choices.count == 2,
                  let item = model.linkPreviews(for:linkPost).first else { throw ChatAPIError.invalidResponse }
            model.error = nil;model.draft = draft
            let appearance = NativeAppearancePreferences();appearance.followsAccount = true
            let timeline = NSHostingView(rootView:NativeChatPreviewView(model:model,appearancePreferences:appearance)
                .environment(\.nativeChatStyle,ChatAppearanceStyle.dark).preferredColorScheme(.dark))
            timeline.appearance = NSAppearance(named:.darkAqua)
            let timelineWindow = makeWindow(content:timeline,width:1120,height:2000)
            defer { timelineWindow.contentView = nil;timelineWindow.close() }
            let card = NSHostingView(rootView:NativeLinkPreviewCard(post:linkPost,item:item,model:model)
                .environment(\.nativeChatStyle,ChatAppearanceStyle.dark).preferredColorScheme(.dark))
            card.appearance = NSAppearance(named:.darkAqua)
            let cardWindow = makeWindow(content:card,width:400,height:500)
            defer { cardWindow.contentView = nil;cardWindow.close() }
            stage = "wait-for-real-view-asset-requests"
            for _ in 0..<100 {
                try await settle([timeline,card],nanoseconds:25_000_000)
                if RichHistoryProtocol.completed["thumbnail:4001",default:0] > 0,
                   RichHistoryProtocol.completed["thumbnail:4002",default:0] > 0,
                   !RichHistoryProtocol.pendingOG.isEmpty { break }
            }
            guard RichHistoryProtocol.completed["thumbnail:4001",default:0] > 0,
                  RichHistoryProtocol.completed["thumbnail:4002",default:0] > 0,
                  RichHistoryProtocol.completed["og:favicon",default:0] > 0,
                  !RichHistoryProtocol.pendingOG.isEmpty else { throw ChatAPIError.invalidResponse }
            for _ in 0..<40 {
                try await settle([timeline,card],nanoseconds:25_000_000)
                let images = inlineRasters(in:timeline).compactMap(\.image)
                if images.count >= 2,images.contains(where:{ NativeInlineImagePreview.frameCount($0) == 2 }) { break }
            }
            // These cache reads must not cause the first successful asset request.
            let beforeCacheProbe = RichHistoryProtocol.requested
            guard let png = await model.thumbnail(for:pngPost),let gif = await model.thumbnail(for:gifPost),
                  png.size.width > 0,png.size.height > 0,NativeInlineImagePreview.frameCount(gif) == 2,
                  RichHistoryProtocol.requested == beforeCacheProbe else { throw ChatAPIError.invalidResponse }
            for _ in 0..<10 { try await settle([timeline,card],nanoseconds:25_000_000) }
            let rasters = inlineRasters(in:timeline)
            guard rasters.filter({ $0.image != nil }).count >= 2,
                  rasters.contains(where:{ $0.image.map(NativeInlineImagePreview.frameCount) == 2 }) else { throw ChatAPIError.invalidResponse }
            let beforeHeight = card.fittingSize.height
            guard beforeHeight.isFinite,beforeHeight > 20,beforeHeight < 1500,
                  !timelineWindow.isVisible,!cardWindow.isVisible else { throw ChatAPIError.invalidResponse }
            card.frame.size.height = beforeHeight;cardWindow.setContentSize(NSSize(width:400,height:beforeHeight))
            try await settle([timeline,card],nanoseconds:50_000_000)
            let beforeGeometry = scrollGeometry(in:timeline)
            try capture(timeline,to:directory.appendingPathComponent("timeline-before-og.png"))
            try capture(card,to:directory.appendingPathComponent("url-card-before-og.png"))
            let beforeCardPNG = try Data(contentsOf:directory.appendingPathComponent("url-card-before-og.png"))
            try record(["synthetic_only":true,"stage":stage,"card_height":beforeHeight,"timeline_geometry":beforeGeometry,
                        "requests":RichHistoryProtocol.requested,"completed":RichHistoryProtocol.completed,
                        "held_og_requests":RichHistoryProtocol.pendingOG.count],to:directory.appendingPathComponent("before.json"))
            stage = "release-delayed-og-image"
            RichHistoryProtocol.releaseOG()
            var cardPixelsChanged = false
            for _ in 0..<100 {
                try await settle([timeline,card],nanoseconds:25_000_000)
                if RichHistoryProtocol.completed["og:image",default:0] > 0,try snapshotPNG(card) != beforeCardPNG { cardPixelsChanged = true;break }
            }
            let afterHeight = card.fittingSize.height
            let beforeOGCacheProbe = RichHistoryProtocol.requested
            guard RichHistoryProtocol.completed["og:image",default:0] > 0,
                  let ogImage = await model.linkPreviewImage(for:linkPost,preview:item.preview),
                  ogImage.size.width > 0,ogImage.size.height > 0,
                  RichHistoryProtocol.requested == beforeOGCacheProbe,
                  cardPixelsChanged,afterHeight.isFinite,abs(afterHeight-beforeHeight) <= 1,afterHeight < 1500 else { throw ChatAPIError.invalidResponse }
            card.frame.size.height = afterHeight;cardWindow.setContentSize(NSSize(width:400,height:afterHeight))
            try await settle([timeline,card],nanoseconds:80_000_000)
            try capture(timeline,to:directory.appendingPathComponent("timeline-after-og.png"))
            try capture(card,to:directory.appendingPathComponent("url-card-after-og.png"))
            let afterGeometry = scrollGeometry(in:timeline)
            let beforeDocumentHeights = documentHeights(beforeGeometry),afterDocumentHeights = documentHeights(afterGeometry)
            guard model.draft == draft,model.posts.count == 4,model.posts.first(where:{ $0.id == 4003 })?.props?.vote?.choices.count == 2,
                  RichHistoryProtocol.deniedWrites == 0,RichHistoryProtocol.unknownReads.isEmpty,
                  RichHistoryProtocol.deniedRuntime == 1,!timelineWindow.isVisible,!cardWindow.isVisible,
                  beforeDocumentHeights.contains(where:{ $0 > 500 }),beforeDocumentHeights.count == afterDocumentHeights.count,
                  zip(beforeDocumentHeights,afterDocumentHeights).allSatisfy({ abs($0.0-$0.1) <= 1 }) else { throw ChatAPIError.invalidResponse }
            try record(["synthetic_only":true,"normal_startup":false,"real_account":false,"visible_window_opened":false,
                        "writes":0,"draft_retained":true,"posts":model.posts.map(\.id),"poll_decoded_choices":2,
                        "inline_rasters_with_image":rasters.filter({ $0.image != nil }).count,"gif_decoded_frames":NativeInlineImagePreview.frameCount(gif),
                        "decoded_og_size":[ogImage.size.width,ogImage.size.height],"card_height_before":beforeHeight,"card_height_after":afterHeight,
                        "card_height_delta":afterHeight-beforeHeight,"known_metadata_card_height_stable":true,"card_pixels_changed":cardPixelsChanged,
                        "timeline_document_heights_stable":true,"timeline_geometry_before":beforeGeometry,
                        "timeline_geometry_after":afterGeometry,"requests":RichHistoryProtocol.requested,
                        "completed":RichHistoryProtocol.completed,"runtime_config_denied":RichHistoryProtocol.deniedRuntime,
                        "H4_reproduced":false,"limits":"Own hidden production views with four rich rows; no rapid-scroll or optimized/live/AX acceptance. GIF decoded frame count does not prove foreground playback."],to:directory.appendingPathComponent("result.json"))
            return true
        } catch {
            try? record(["synthetic_only":true,"status":"failed","stage":stage,"requests":RichHistoryProtocol.requested,
                         "completed":RichHistoryProtocol.completed,"unknown_reads":RichHistoryProtocol.unknownReads,
                         "denied_writes":RichHistoryProtocol.deniedWrites,"runtime_config_denied":RichHistoryProtocol.deniedRuntime],to:directory.appendingPathComponent("failure.json"))
            return false
        }
    }

    /// Larger independent run; uses the real 30-row paging contract and clip geometry.
    enum PagedNavigation:String { case directClip = "direct-clip",anchors = "production-anchors",sequential = "sequential-clip",resizing = "production-resize" }
    enum TableProbe:String { case none,cache,anchor,editor,editorMicro }
    static func renderPaged(to directory:URL,navigation:PagedNavigation = .directClip,useNativeTable:Bool = false,useNativeVirtual:Bool = false,probe:TableProbe = .none) async -> Bool {
        var stage = "prepare-paged"
        let requestedBackend = useNativeVirtual ? "native-virtual-timeline" : useNativeTable ? "native-table-timeline" : "swiftui-lazy"
        let diagnosticStarted = Date()
        var samples:[[String:Any]] = []
        var probeSamples:[[String:Any]] = [],probeChecks:[String:Bool] = [:]
        var probeHeldAtRelease = 0
        var probeReleasedOG = false
        var firstBlankCycle:Int?
        var sequentialPasses = 0
        var scrollbackResizeStarted = true,scrollbackResizePreserved = true
        var assertions:[String:Bool] = [:],assetDiagnostics:[String:Any] = [:]
        do {
            guard !FileManager.default.fileExists(atPath:directory.path) else { return false }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            NSApplication.shared.setActivationPolicy(.prohibited)
            if useNativeTable && useNativeVirtual {
                assertions["backend_flags_mutually_exclusive"] = false
                throw ChatAPIError.invalidResponse
            }
            try RichHistoryProtocol.reset();RichHistoryProtocol.paged = true;RichHistoryProtocol.unknownOGGeometry = probe == .anchor
            let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
                guard session.baseURL.scheme == "https",session.baseURL.host == host else { throw ChatAPIError.invalidResponse }
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [RichHistoryProtocol.self];config.httpShouldSetCookies = false;config.urlCache = nil
                return try ChatAPIClient(session:session,network:URLSession(configuration:config))
            },downloadPreferences:.init(defaults:nil),emojiPreferences:.init(defaults:nil),notificationDefaults:nil)
            defer { RichHistoryProtocol.cancelPending();model.signOutLocally() }
            await model.connect(using:.init(session:.init(baseURL:URL(string:"https://"+host)!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic-rich",importedFromOfficialApp:false))
            guard model.connected,model.userID == 10 else { throw ChatAPIError.invalidResponse }
            model.suspendLiveForProbe();model.liveStatus = .live;model.selection = 23
            model.loadSelection();await model.historyTask?.value
            guard model.posts.map(\.id) == Array(Int64(5091)...5120),model.canLoadOlder else { throw ChatAPIError.invalidResponse }
            model.error = nil;model.draft = draft
            let appearance = NativeAppearancePreferences();appearance.followsAccount = true
            let preview = NativeChatPreviewView(model:model,appearancePreferences:appearance)
            let editorOwner = UUID()
            var fixtureEditors:[Int64:NativeMessageEditorFixture] = [:]
            if (probe == .editor || probe == .editorMicro),let post = model.posts.first(where:{ $0.id == 5105 }) {
                fixtureEditors[5105] = .init(owner:editorOwner,text:model.messageText(post))
            }
            let configured = useNativeVirtual ? preview.usingNativeVirtualTimeline(fixtureEditors:fixtureEditors) : useNativeTable ? preview.usingNativeTableTimeline(fixtureEditors:fixtureEditors) : preview
            let timeline = NSHostingView(rootView:configured
                .environment(\.nativeChatStyle,ChatAppearanceStyle.dark).preferredColorScheme(.dark))
            timeline.appearance = NSAppearance(named:.darkAqua)
            let window = makeWindow(content:timeline,width:1120,height:840)
            defer { window.contentView = nil;window.close() }
            stage = "real-older-pagination"
            var pageCounts = [model.posts.count]
            if probe == .anchor {
                stage = "table-prepend-and-async-anchor-probes"
                guard useNativeTable || useNativeVirtual else { throw ChatAPIError.invalidResponse }
                let receipt = try await runTableAnchorProbe(model:model,timeline:timeline,window:window,directory:directory,backend:requestedBackend,
                    samples:&probeSamples,checks:&probeChecks)
                pageCounts.append(model.posts.count)
                probeHeldAtRelease = receipt;probeReleasedOG = receipt > 0
            }
            if probe == .editor || probe == .editorMicro {
                stage = "table-editor-prepend-probe"
                guard useNativeTable || useNativeVirtual else { throw ChatAPIError.invalidResponse }
                try await runTableEditorProbe(model:model,timeline:timeline,window:window,owner:editorOwner,directory:directory,backend:requestedBackend,
                    samples:&probeSamples,checks:&probeChecks,microPrepend:probe == .editorMicro)
                pageCounts.append(model.posts.count)
            }
            for expectedFirst in (probe == .anchor || probe == .editor || probe == .editorMicro ? [5031,5001] : [5061,5031,5001]) {
                await model.loadOlder();try await settle([timeline],nanoseconds:60_000_000)
                guard model.error == nil,model.posts.first?.id == Int64(expectedFirst) else { throw ChatAPIError.invalidResponse }
                pageCounts.append(model.posts.count)
            }
            guard pageCounts == [30,60,90,120],model.posts.map(\.id) == Array(Int64(5001)...5120),
                  RichHistoryProtocol.pageCursors == ["latest","5091","5061","5031"] else { throw ChatAPIError.invalidResponse }
            stage = "rapid-hidden-viewport-cycling"
            for _ in 0..<40 {
                try await settle([timeline],nanoseconds:25_000_000)
                if mainTimelineScroll(in:timeline) != nil { break }
            }
            guard let scroll = mainTimelineScroll(in:timeline),let document = scroll.documentView,
                  document.bounds.height > scroll.contentView.bounds.height*4,
                  scroll.contentView.bounds.height > 300,scroll.contentView.bounds.height < 840 else { throw ChatAPIError.invalidResponse }
            if useNativeTable || useNativeVirtual {
                guard probeBackendMatches(scroll,backend:requestedBackend) else { throw ChatAPIError.invalidResponse }
            }
            let scrollIdentity = ObjectIdentifier(scroll),documentIdentity = ObjectIdentifier(document)
            if probe == .cache {
                stage = "table-cache-admission-probe"
                guard useNativeTable || useNativeVirtual else { throw ChatAPIError.invalidResponse }
                probeHeldAtRelease = try await runTableCacheProbe(model:model,timeline:timeline,window:window,directory:directory,backend:requestedBackend,
                    samples:&probeSamples,checks:&probeChecks)
                probeReleasedOG = probeHeldAtRelease > 0
            }
            var viewportPNGs:[Data] = []
            var observed = Set<Int64>(),decodedPNG = false,decodedGIF = false
            let fractions:[CGFloat] = [1,0,0.75,0.25,1,0.5,0,1,0.25,0.75,0.5,1,0,0.5,1,0.25,0.75,0,1,0.5,0,1,0.5,1]
            let anchors:[Int64] = [5120,5001,5088,5027,5120,5061,5001,5120,5027,5088,5061,5120,5001,5061,5120,5027,5088,5001,5120,5061,5001,5120,5061,5120]
            let viewportToken = model.historyViewportToken
            var heldAtRelease = 0
            var sequentialDirection:CGFloat = 1
            let cycleLimit = navigation == .resizing ? 15 : navigation == .sequential ? 100 : fractions.count
            let resizeSizes:[NSSize] = [NSSize(width:1000,height:720),NSSize(width:1280,height:940),NSSize(width:1120,height:840)]
            for index in 0..<cycleLimit {
                let fraction = fractions[index % fractions.count]
                let beforeDocument = document.bounds,beforeClip = scroll.contentView.bounds
                let height = max(0,beforeDocument.height-beforeClip.height)
                let requestedAnchor:Int64? = navigation == .resizing ? (index < 3 ? [Int64(5088),5027,5120][index] : nil) : navigation == .anchors ? anchors[index] : nil
                let expectedAssetFrames:Int? = (navigation == .resizing || navigation == .anchors) ? (requestedAnchor == 5088 ? 2 : requestedAnchor == 5027 ? 1 : nil) : nil
                let requestedSize:NSSize? = navigation == .resizing && requestedAnchor == nil ? resizeSizes[(index-3)%resizeSizes.count] : nil
                let target:CGFloat
                if navigation == .sequential {
                    target = index == 0 ? beforeDocument.minY : min(beforeDocument.minY+height,max(beforeDocument.minY,beforeClip.minY+beforeClip.height*0.8*sequentialDirection))
                } else { target = beforeDocument.minY+height*fraction }
                let revisionBeforeInput = model.historyScrollRevision
                if let requestedAnchor { model.scrollPostID = requestedAnchor }
                else if let requestedSize { window.setContentSize(requestedSize) }
                else { scroll.contentView.scroll(to:NSPoint(x:0,y:target));scroll.reflectScrolledClipView(scroll.contentView) }
                let revisionAfterAssignment = model.historyScrollRevision
                let immediate = scroll.contentView.bounds.origin.y
                if let requestedAnchor {
                    for _ in 0..<(expectedAssetFrames == nil ? 20 : 40) {
                        try await settle([timeline],nanoseconds:25_000_000)
                        let rowVisible = visibleRows(in:scroll).contains(where:{ $0["post_id"] as? Int64 == requestedAnchor })
                        let assetReady = expectedAssetFrames.map { !decodedRasters(for:requestedAnchor,frames:$0,in:scroll).isEmpty } ?? true
                        if rowVisible && assetReady { break }
                    }
                } else { try await settle([timeline],nanoseconds:navigation == .resizing ? 100_000_000 : 45_000_000) }
                guard finiteRect(scroll.contentView.bounds),finiteRect(document.bounds) else { throw ChatAPIError.invalidResponse }
                let rows = visibleRows(in:scroll)
                observed.formUnion(rows.compactMap { $0["post_id"] as? Int64 })
                let rasters = inlineRasters(in:timeline).compactMap(\.image)
                decodedPNG = decodedPNG || rasters.contains { NativeInlineImagePreview.frameCount($0) == 1 }
                decodedGIF = decodedGIF || rasters.contains { NativeInlineImagePreview.frameCount($0) == 2 }
                let warmedRasters:[[String:Any]] = requestedAnchor.flatMap { id in expectedAssetFrames.map { decodedRasters(for:id,frames:$0,in:scroll) } } ?? []
                let resizeSizeApplied = requestedSize.map { abs(timeline.bounds.width-$0.width) <= 1 && abs(timeline.bounds.height-$0.height) <= 1 } ?? true
                var sample = pagedGeometry(scroll:scroll,timeline:timeline,scrollIdentity:scrollIdentity,documentIdentity:documentIdentity)
                let navigationFields:[String:Any] = ["navigation_mode":navigation.rawValue,"history_viewport_token":model.historyViewportToken.uuidString,
                              "history_viewport_token_stable":model.historyViewportToken == viewportToken,
                              "post_didset_revision":revisionAfterAssignment.uuidString,"revision_still_current":model.historyScrollRevision == revisionAfterAssignment,
                              "input_kind":requestedAnchor != nil ? "model-scrollPostID" : navigation == .resizing ? "NSWindow-setContentSize" : "direct-clip",
                              "model_scroll_post_id":model.scrollPostID.map { $0 as Any } ?? NSNull(),
                              "resize_did_not_write_scroll_revision":requestedAnchor == nil && model.historyScrollRevision == revisionBeforeInput,
                              "window_content_size":[timeline.bounds.width,timeline.bounds.height],
                              "requested_size":requestedSize.map { [$0.width,$0.height] as Any } ?? NSNull(),"resize_size_applied":resizeSizeApplied]
                sample.merge(navigationFields,uniquingKeysWith:{ _,new in new })
                let assetFields:[String:Any] = ["asset_warmup_required":expectedAssetFrames != nil,"asset_expected_frames":expectedAssetFrames.map { $0 as Any } ?? NSNull(),
                              "asset_readied":!warmedRasters.isEmpty,"asset_matching_decoded_rasters":warmedRasters,
                              "latest_5120_visible":rows.contains(where:{ $0["post_id"] as? Int64 == 5120 }),
                              "at_bottom_geometry":NativeScrollVisibility.isAtBottom(content:document.bounds,visible:scroll.documentVisibleRect,flipped:document.isFlipped),
                              "requested_anchor":requestedAnchor.map { $0 as Any } ?? NSNull(),
                              "requested_anchor_visible":requestedAnchor.map { anchor in rows.contains(where:{ $0["post_id"] as? Int64 == anchor }) } ?? false]
                sample.merge(assetFields,uniquingKeysWith:{ _,new in new })
                let viewportFields:[String:Any] = ["elapsed_ms":Date().timeIntervalSince(diagnosticStarted)*1000,"cycle":index,"phase":"navigation-cycle","fraction":fraction,"requested_y":target,"immediate_actual_y":immediate,
                              "immediate_target_error":immediate-target,"immediate_target_within_one_point":abs(immediate-target) <= 1,
                              "settled_target_error":scroll.contentView.bounds.origin.y-target,
                              "recomputed_fraction_target_y":document.bounds.minY+max(0,document.bounds.height-scroll.contentView.bounds.height)*fraction,
                              "document_before_request":rect(beforeDocument),"clip_before_request":rect(beforeClip),
                              "decoded_rasters":rasters.count,"requests":RichHistoryProtocol.requested,"completed":RichHistoryProtocol.completed]
                sample.merge(viewportFields,uniquingKeysWith:{ _,new in new })
                samples.append(sample)
                if rows.isEmpty,firstBlankCycle == nil {
                    firstBlankCycle = index
                    try record(["finding":"No production row-marker intersects viewport after "+navigation.rawValue, "first_blank_cycle":index,
                                "sample":sample,"model_post_count":model.posts.count,"exact_model_ids":model.posts.map(\.id),
                                "draft_retained":model.draft == draft,"H4_same_cause_established":false],to:directory.appendingPathComponent("first-blank.json"))
                    try capture(scroll,to:directory.appendingPathComponent("first-blank-viewport.png"))
                    if navigation == .resizing {
                        var delayed:[[String:Any]] = []
                        for (label,delay) in [("resize-first-blank-200ms",UInt64(200_000_000)),("resize-first-blank-1sec",UInt64(800_000_000))] {
                            try await settle([timeline],nanoseconds:delay)
                            var observation = pagedGeometry(scroll:scroll,timeline:timeline,scrollIdentity:scrollIdentity,documentIdentity:documentIdentity)
                            observation["phase"] = label;observation["elapsed_ms"] = Date().timeIntervalSince(diagnosticStarted)*1000
                            delayed.append(observation)
                            try capture(scroll,to:directory.appendingPathComponent(label+"-viewport.png"))
                        }
                        try record(["navigation_mode":navigation.rawValue,"first_blank_cycle":index,"observations":delayed,"blank_remains_failure":true],to:directory.appendingPathComponent("resize-first-blank-settling.json"))
                    }
                }
                if [0,2,3,5,11,12,23].contains(index) || (navigation == .resizing && [1,14].contains(index)) {
                    try capture(timeline,to:directory.appendingPathComponent("paged-cycle-\(index).png"))
                    let pixels = try snapshotPNG(scroll);viewportPNGs.append(pixels)
                    try pixels.write(to:directory.appendingPathComponent("viewport-cycle-\(index).png"),options:.withoutOverwriting)
                }
                if index == 11 {
                    if probeReleasedOG {
                        heldAtRelease = probeHeldAtRelease
                        guard heldAtRelease > 0 else { throw ChatAPIError.invalidResponse }
                    } else {
                        heldAtRelease = RichHistoryProtocol.pendingOG.count
                        guard heldAtRelease > 0 else { throw ChatAPIError.invalidResponse }
                        RichHistoryProtocol.releaseOG()
                    }
                }
                if navigation == .sequential,index > 0 {
                    let currentMax = document.bounds.minY+max(0,document.bounds.height-scroll.contentView.bounds.height)
                    if sequentialDirection > 0,target >= beforeDocument.minY+height-1,abs(scroll.contentView.bounds.minY-currentMax) <= 1 {
                        sequentialPasses += 1;sequentialDirection = -1
                    } else if sequentialDirection < 0,target <= beforeDocument.minY+1,abs(scroll.contentView.bounds.minY-document.bounds.minY) <= 1 {
                        sequentialPasses += 1;sequentialDirection = 1
                    }
                    if sequentialPasses >= 2 {
                        try capture(scroll,to:directory.appendingPathComponent("sequential-two-passes-viewport.png"));break
                    }
                }
            }
            let navigationSampleCount = samples.count
            // Preserve every transient blank, even if later settling/recovery succeeds.
            // These observations do not turn the failed cycle into a passing run.
            for (label,delay) in [("final-200ms",UInt64(200_000_000)),("final-1sec",UInt64(800_000_000))] {
                try await settle([timeline],nanoseconds:delay)
                var sample = pagedGeometry(scroll:scroll,timeline:timeline,scrollIdentity:scrollIdentity,documentIdentity:documentIdentity)
                sample["phase"] = label;sample["elapsed_ms"] = Date().timeIntervalSince(diagnosticStarted)*1000;samples.append(sample)
                try capture(scroll,to:directory.appendingPathComponent(label+"-viewport.png"))
            }
            if navigation == .resizing {
                model.scrollPostID = 5027
                try await settle([timeline],nanoseconds:150_000_000)
                func readerVisible()->Bool {
                    visibleRows(in:scroll).contains { row in
                        row["post_id"] as? Int64 == 5027 && ((row["visible_intersection"] as? [String:CGFloat])?["height"] ?? 0) >= 20
                    }
                }
                var start = pagedGeometry(scroll:scroll,timeline:timeline,scrollIdentity:scrollIdentity,documentIdentity:documentIdentity)
                scrollbackResizeStarted = readerVisible() && start["at_bottom_geometry"] as? Bool == false && start["latest_5120_visible"] as? Bool == false
                start["phase"] = "scrollback-resize-baseline";start["reader_5027_visible"] = readerVisible();samples.append(start)
                try capture(scroll,to:directory.appendingPathComponent("scrollback-resize-baseline.png"))
                for (index,size) in resizeSizes.enumerated() {
                    window.setContentSize(size)
                    try await settle([timeline],nanoseconds:100_000_000)
                    var sample = pagedGeometry(scroll:scroll,timeline:timeline,scrollIdentity:scrollIdentity,documentIdentity:documentIdentity)
                    let applied = abs(timeline.bounds.width-size.width) <= 1 && abs(timeline.bounds.height-size.height) <= 1
                    let retained = readerVisible() && sample["at_bottom_geometry"] as? Bool == false && sample["latest_5120_visible"] as? Bool == false && applied
                    scrollbackResizePreserved = scrollbackResizePreserved && retained
                    sample["phase"] = "scrollback-resize-\(index)";sample["requested_size"] = [size.width,size.height]
                    sample["reader_5027_visible"] = readerVisible();sample["reading_position_retained"] = retained;samples.append(sample)
                    try capture(scroll,to:directory.appendingPathComponent("scrollback-resize-\(index).png"))
                }
            }
            for (label,fraction) in [("recovery-midpoint",CGFloat(0.5)),("recovery-top",CGFloat(0)),("recovery-bottom",CGFloat(1))] {
                let target = document.bounds.minY+max(0,document.bounds.height-scroll.contentView.bounds.height)*fraction
                scroll.contentView.scroll(to:NSPoint(x:0,y:target));scroll.reflectScrolledClipView(scroll.contentView)
                let immediate = scroll.contentView.bounds.origin.y
                try await settle([timeline],nanoseconds:150_000_000)
                var sample = pagedGeometry(scroll:scroll,timeline:timeline,scrollIdentity:scrollIdentity,documentIdentity:documentIdentity)
                sample.merge(["phase":label,"elapsed_ms":Date().timeIntervalSince(diagnosticStarted)*1000,"requested_y":target,"immediate_actual_y":immediate,"immediate_target_error":immediate-target,
                              "immediate_target_within_one_point":abs(immediate-target) <= 1,"settled_target_error":scroll.contentView.bounds.origin.y-target],uniquingKeysWith:{ _,new in new })
                samples.append(sample)
                try capture(scroll,to:directory.appendingPathComponent(label+"-viewport.png"))
            }
            stage = "assert-paged-assets-and-visible-content"
            for _ in 0..<40 {
                try await settle([timeline],nanoseconds:25_000_000)
                if RichHistoryProtocol.completed["og:image",default:0] > 0 { break }
            }
            let rapidSamples = Array(samples.prefix(navigationSampleCount))
            let resizedSamples = rapidSamples.filter { $0["input_kind"] as? String == "NSWindow-setContentSize" }
            let settledSamples = samples.filter { ($0["phase"] as? String ?? "").hasPrefix("final-") }
            let uniqueActualOffsets = Set(rapidSamples.compactMap { ($0["clip_bounds"] as? [String:CGFloat])?["y"] }.map { Int($0.rounded()) })
            let uniqueVisibleIDSets = Set(rapidSamples.map { sample in
                (sample["visible_rows"] as? [[String:Any]] ?? []).compactMap { $0["post_id"] as? Int64 }.map(String.init).joined(separator:",")
            })
            // Stable geometry has one actual offset per requested fraction.
            // Requiring more would accidentally make height drift necessary.
            let requiredDistinctPositions:Int
            switch navigation {
            case .directClip:requiredDistinctPositions = Set(fractions).count
            case .anchors:requiredDistinctPositions = Set(anchors).count
            case .resizing:requiredDistinctPositions = 3
            case .sequential:
                let inputs = Set(rapidSamples.compactMap { $0["requested_y"] as? CGFloat }.map { Int($0.rounded()) })
                requiredDistinctPositions = min(Set(fractions).count,inputs.count)
            }
            let tableDiagnostics = probeDocumentDiagnostics(document)
            let boundedTable = tableDiagnostics.flatMap { $0["max_hosted_cells"] as? Int }.map { $0 > 0 && $0 <= 32 && $0 < model.posts.count } ?? false
            assertions = [
                "requested_table_backend_selected":!useNativeTable || probeBackendMatches(scroll,backend:"native-table-timeline"),
                "requested_virtual_backend_selected":!useNativeVirtual || probeBackendMatches(scroll,backend:"native-virtual-timeline"),
                "marker_horizontal_padding_matches_timeline":samples.allSatisfy { observation in
                    guard let clip = observation["clip_bounds"] as? [String:CGFloat],let width = clip["width"],
                          let rows = observation["visible_rows"] as? [[String:Any]],!rows.isEmpty else { return false }
                    return rows.allSatisfy { row in
                        guard let frame = row["frame"] as? [String:CGFloat],let x = frame["x"],let rowWidth = frame["width"] else { return false }
                        return abs(x-16) <= 1 && abs((x+rowWidth)-(width-16)) <= 1
                    }
                },
                "prototype_host_count_bounded":!(useNativeTable || useNativeVirtual) || boundedTable,
                "decoded_png_raster_observed":decodedPNG,"decoded_two_frame_gif_raster_observed":decodedGIF,
                "target_assets_ready_in_viewport":rapidSamples.allSatisfy({ $0["asset_warmup_required"] as? Bool != true || $0["asset_readied"] as? Bool == true }),
                "scrollback_resize_started_away_from_latest":scrollbackResizeStarted,
                "scrollback_resize_preserves_reader":scrollbackResizePreserved,
                "requested_resize_sizes_applied":rapidSamples.allSatisfy({ $0["resize_size_applied"] as? Bool == true }),
                "og_response_completed":RichHistoryProtocol.completed["og:image",default:0] > 0,
                "distinct_viewport_pngs":Set(viewportPNGs).count >= 3,
                "distinct_actual_offsets":uniqueActualOffsets.count >= requiredDistinctPositions,
                "distinct_visible_id_sets":uniqueVisibleIDSets.count >= requiredDistinctPositions,
                "sequential_two_passes":navigation != .sequential || sequentialPasses >= 2,
                "resize_final_latest_visible_and_bottom":navigation != .resizing || (rapidSamples.last?["latest_5120_visible"] as? Bool == true && rapidSamples.last?["at_bottom_geometry"] as? Bool == true),
                "resize_twelve_size_changes":navigation != .resizing || resizedSamples.count == 12,
                "resize_started_at_latest_bottom":navigation != .resizing || rapidSamples.contains(where:{ $0["requested_anchor"] as? Int64 == 5120 && $0["latest_5120_visible"] as? Bool == true && $0["at_bottom_geometry"] as? Bool == true }),
                "resize_settled_latest_and_bottom":navigation != .resizing || (settledSamples.count == 2 && settledSamples.allSatisfy({ $0["latest_5120_visible"] as? Bool == true && $0["at_bottom_geometry"] as? Bool == true })),
                "navigation_tokens_stable":rapidSamples.allSatisfy({ $0["history_viewport_token_stable"] as? Bool == true && $0["revision_still_current"] as? Bool == true }),
                "no_first_blank":firstBlankCycle == nil,
                "identity_and_finite_geometry":samples.allSatisfy({ $0["scroll_identity_stable"] as? Bool == true && $0["document_identity_stable"] as? Bool == true && $0["finite_clip_and_document"] as? Bool == true }),
                "requested_navigation_reached":rapidSamples.allSatisfy({ sample in
                    if navigation == .resizing {
                        if sample["input_kind"] as? String == "model-scrollPostID" { return sample["requested_anchor_visible"] as? Bool == true }
                        return sample["latest_5120_visible"] as? Bool == true && sample["at_bottom_geometry"] as? Bool == true && sample["resize_did_not_write_scroll_revision"] as? Bool == true
                    }
                    return navigation == .anchors ? sample["requested_anchor_visible"] as? Bool == true : sample["immediate_target_within_one_point"] as? Bool == true
                }),
                "enough_observed_ids":observed.count >= 8,"all_samples_have_visible_rows":samples.allSatisfy({ !($0["visible_rows"] as? [[String:Any]] ?? []).isEmpty }),
                "exact_post_ids":model.posts.map(\.id) == Array(Int64(5001)...5120),"draft_retained":model.draft == draft,"no_model_error":model.error == nil,
                "twelve_decoded_polls":model.posts.filter({ $0.props?.vote?.choices.count == 2 }).count == 12,
                "zero_writes":RichHistoryProtocol.deniedWrites == 0,"no_unknown_reads":RichHistoryProtocol.unknownReads.isEmpty,
                "runtime_denied_once":RichHistoryProtocol.deniedRuntime == 1,"window_hidden":!window.isVisible,
                "decoded_og_probe":false,"gif_cache_probe_two_frames":false,"cache_probes_no_new_requests":false]
            assetDiagnostics = ["native_table_requested":useNativeTable,"native_virtual_requested":useNativeVirtual,"requested_backend":requestedBackend,"native_table_diagnostics":tableDiagnostics as Any? ?? NSNull(),"required_distinct_positions":requiredDistinctPositions,"actual_distinct_offsets":uniqueActualOffsets.count,
                                "actual_distinct_visible_id_sets":uniqueVisibleIDSets.count,"observed_ids":observed.sorted(),"distinct_pngs":Set(viewportPNGs).count,
                                "requests_before_cache_probes":RichHistoryProtocol.requested]
            let requestsBeforeCache = RichHistoryProtocol.requested
            guard let loadedLink = model.posts.reversed().first(where:{ RichHistoryProtocol.completed["og:image:"+String($0.id),default:0] > 0 }),
                  let preview = model.linkPreviews(for:loadedLink).first else { throw ChatAPIError.invalidResponse }
            assetDiagnostics["og_cache_probe_post"] = loadedLink.id
            guard let decodedOG = await model.linkPreviewImage(for:loadedLink,preview:preview.preview) else { throw ChatAPIError.invalidResponse }
            assertions["decoded_og_probe"] = decodedOG.size.width > 0 && decodedOG.size.height > 0
            assetDiagnostics["decoded_og_size"] = [decodedOG.size.width,decodedOG.size.height]
            // Probe the GIF explicitly visited by this input mode. An unrelated
            // prefetched GIF is not reliable evidence of the anchor's cache.
            let gifProbeID:Int64 = navigation == .anchors || navigation == .resizing ? 5088 : 5118
            assetDiagnostics["gif_cache_probe_post"] = gifProbeID
            guard let gifPost = model.posts.first(where:{ $0.id == gifProbeID }),let gif = await model.thumbnail(for:gifPost) else { throw ChatAPIError.invalidResponse }
            assertions["gif_cache_probe_two_frames"] = NativeInlineImagePreview.frameCount(gif) == 2
            assertions["cache_probes_no_new_requests"] = RichHistoryProtocol.requested == requestsBeforeCache
            assetDiagnostics["gif_cache_probe_frames"] = NativeInlineImagePreview.frameCount(gif)
            assetDiagnostics["requests_after_cache_probes"] = RichHistoryProtocol.requested
            guard assertions.values.allSatisfy({ $0 }),probeChecks.values.allSatisfy({ $0 }) else { throw ChatAPIError.invalidResponse }
            try record(["synthetic_only":true,"normal_startup":false,"real_account":false,"visible_window_opened":false,
                        "writes":0,"draft_retained":true,"posts":model.posts.map(\.id),"page_counts":pageCounts,
                        "requested_backend":requestedBackend,"table_probe":probe.rawValue,"probe_samples":probeSamples,"probe_checks":probeChecks,"probe_held_at_release":probeHeldAtRelease,
                        "exact_page_cursors":RichHistoryProtocol.pageCursors,"window_height":840,"samples":samples,"navigation_mode":navigation.rawValue,"navigation_sample_count":navigationSampleCount,"sequential_passes":sequentialPasses,"assertions":assertions,"asset_diagnostics":assetDiagnostics,
                        "observed_visible_ids":observed.sorted(),"held_og_at_release":heldAtRelease,"distinct_viewport_pngs":Set(viewportPNGs).count,"finite_clip_document_geometry":true,
                        "unique_actual_clip_offsets":uniqueActualOffsets.count,"unique_visible_id_sets":uniqueVisibleIDSets.count,"blank_observed":false,
                        "navigation_blank_observed":false,"settling_blank_observed":false,"recovery_blank_observed":false,
                        "decoded_png_raster":decodedPNG,"decoded_two_frame_gif_raster":decodedGIF,"decoded_og_post":loadedLink.id,"decoded_og_size":[decodedOG.size.width,decodedOG.size.height],"asset_cache_probes_added_requests":false,
                        "requests":RichHistoryProtocol.requested,"completed":RichHistoryProtocol.completed,
                        "H4_reproduced":false,"limits":"DEBUG hidden production view, 120 synthetic posts over four contract-sized pages using \(navigation.rawValue); no live/optimized app or human scroll acceptance. Nonempty visible marker geometry does not alone prove every rendered glyph or image."],to:directory.appendingPathComponent("result.json"))
            return true
        } catch {
            try? record(["status":"failed","synthetic_only":true,"requested_backend":requestedBackend,"table_probe":probe.rawValue,"probe_samples":probeSamples,"probe_checks":probeChecks,"probe_held_at_release":probeHeldAtRelease,"navigation_mode":navigation.rawValue,"sequential_passes":sequentialPasses,"stage":stage,"page_cursors":RichHistoryProtocol.pageCursors,"samples":samples,"assertions":assertions,"asset_diagnostics":assetDiagnostics,
                         "blank_observed":samples.contains(where:{ ($0["visible_rows"] as? [[String:Any]] ?? []).isEmpty }),
                         "navigation_blank_observed":samples.contains(where:{ $0["phase"] as? String == "navigation-cycle" && ($0["visible_rows"] as? [[String:Any]] ?? []).isEmpty }),
                         "settling_blank_observed":samples.contains(where:{ ($0["phase"] as? String ?? "").hasPrefix("final-") && ($0["visible_rows"] as? [[String:Any]] ?? []).isEmpty }),
                         "recovery_blank_observed":samples.contains(where:{ ($0["phase"] as? String ?? "").hasPrefix("recovery-") && ($0["visible_rows"] as? [[String:Any]] ?? []).isEmpty }),
                         "first_blank_cycle":firstBlankCycle.map { $0 as Any } ?? NSNull(),
                         "requests":RichHistoryProtocol.requested,"completed":RichHistoryProtocol.completed,
                         "unknown_reads":RichHistoryProtocol.unknownReads,"denied_writes":RichHistoryProtocol.deniedWrites],to:directory.appendingPathComponent("failure.json"))
            return false
        }
    }
    /// Read-only adapters; all hosted-cell reads explicitly avoid creating views.
    private static func isProbeDocument(_ view:NSView)->Bool { view is NativeTableTimeline.Table || view is NativeVirtualTimeline.Document }
    private static func probeBackendMatches(_ scroll:NSScrollView,backend:String)->Bool {
        guard scroll is NativeTableTimeline.Scroll,scroll.identifier?.rawValue == backend,let document = scroll.documentView,document.identifier?.rawValue == backend else { return false }
        switch backend {
        case "native-table-timeline":return document is NativeTableTimeline.Table
        case "native-virtual-timeline":return document is NativeVirtualTimeline.Document
        default:return false
        }
    }
    private static func probeDocumentDiagnostics(_ view:NSView)->[String:Any]? {
        if let table = view as? NativeTableTimeline.Table { return table.debugDiagnostics }
        if let document = view as? NativeVirtualTimeline.Document { return document.debugDiagnostics }
        return nil
    }
    private static func probeRowIndex(_ document:NSView,view:NSView)->Int {
        if let table = document as? NativeTableTimeline.Table { return table.row(for:view) }
        if let document = document as? NativeVirtualTimeline.Document { return document.row(for:view) }
        return -1
    }
    private static func probeRowCount(_ document:NSView)->Int {
        if let table = document as? NativeTableTimeline.Table { return table.numberOfRows }
        if let document = document as? NativeVirtualTimeline.Document { return document.numberOfRows }
        return 0
    }
    private static func probeRowRect(_ document:NSView,index:Int)->NSRect {
        if let table = document as? NativeTableTimeline.Table { return table.rect(ofRow:index) }
        if let document = document as? NativeVirtualTimeline.Document { return document.rect(ofRow:index) }
        return .zero
    }
    private static func probeHostedCell(_ document:NSView,index:Int)->NSView? {
        if let table = document as? NativeTableTimeline.Table { return table.view(atColumn:0,row:index,makeIfNecessary:false) }
        if let document = document as? NativeVirtualTimeline.Document { return document.hostedView(forRow:index) }
        return nil
    }
    private static func probeCellRow(_ view:NSView?)->NativeTableTimelineState.Row? {
        if let cell = view as? NativeTableTimeline.Cell { return cell.row }
        if let cell = view as? NativeVirtualTimeline.Cell { return cell.row }
        return nil
    }
    private static func probeCellHasHost(_ view:NSView?)->Bool {
        if let cell = view as? NativeTableTimeline.Cell { return cell.host != nil }
        if let cell = view as? NativeVirtualTimeline.Cell { return cell.host != nil }
        return false
    }

    private static func editorTextViews(in view:NSView)->[NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { editorTextViews(in:$0) }
    }
    private static func editorCell(_ view:NSView)->NSView? {
        var candidate:NSView? = view
        while let value = candidate {
            if value is NativeTableTimeline.Cell || value is NativeVirtualTimeline.Cell { return value }
            candidate = value.superview
        }
        return nil
    }
    private static func editorRowView(_ view:NSView)->NSView? {
        var candidate:NSView? = view
        while let value = candidate {
            if value is NSTableRowView || value is NativeVirtualTimeline.Cell { return value }
            candidate = value.superview
        }
        return nil
    }
    private static func editorGeometry(_ phase:String,editor:NSTextView,model:NativeChatPreviewModel,timeline:NSView,scroll:NSScrollView,table:NSView,window:NSWindow,scrollID:ObjectIdentifier,documentID:ObjectIdentifier,account:Int,token:UUID,expectedText:String,expectedSelection:NSRange)->[String:Any] {
        var result = probeRecord(phase,postID:5105,reference:5105,model:model,timeline:timeline,scroll:scroll,scrollID:scrollID,documentID:documentID,account:account,token:token)
        let attached = editor.window === window && editor.isDescendant(of:table)
        let cell = attached ? editorCell(editor) : nil
        let rowView = attached ? editorRowView(editor) : nil
        let actualRow = attached ? probeRowIndex(table,view:editor) : -1
        let expectedRow = probePostGeometry(5105,in:scroll)?["table_row"] as? Int ?? -1
        let selected = editor.selectedRange()
        var cellPost:Int64?
        if case let .post(id)? = probeCellRow(cell) { cellPost = id }
        result["editor_identity"] = String(describing:ObjectIdentifier(editor))
        result["editor_attached_to_expected_table"] = attached
        result["editor_first_responder"] = window.firstResponder === editor
        result["editor_cell_post_id"] = cellPost.map { $0 as Any } ?? NSNull()
        result["editor_actual_row_index"] = actualRow;result["editor_expected_5105_row_index"] = expectedRow
        result["editor_mapped_to_correct_5105_cell"] = cellPost == 5105 && actualRow >= 0 && actualRow == expectedRow
        result["editor_content"] = editor.string;result["editor_content_exact"] = editor.string == expectedText
        result["editor_selection"] = ["location":selected.location,"length":selected.length]
        result["editor_selection_exact"] = selected == expectedSelection
        result["editor_can_undo"] = editor.undoManager?.canUndo ?? false
        result["editor_can_redo"] = editor.undoManager?.canRedo ?? false
        result["editor_undo_manager_identity"] = editor.undoManager.map { String(describing:ObjectIdentifier($0)) } as Any? ?? NSNull()
        result["editor_bounds"] = rect(editor.bounds);result["editor_frame_in_parent"] = rect(editor.frame)
        if attached {
            let frame = editor.convert(editor.bounds,to:table)
            result["editor_actual_text_rect_in_table"] = rect(frame)
            result["editor_actual_text_offset"] = frame.minY-scroll.documentVisibleRect.minY
        }
        if actualRow >= 0,actualRow < probeRowCount(table) {
            let committed = probeRowRect(table,index:actualRow)
            result["editor_committed_table_row_rect"] = rect(committed)
            result["editor_committed_row_offset"] = committed.minY-scroll.documentVisibleRect.minY
        }
        if let rowView {
            result["editor_actual_row_view_frame"] = rect(rowView.frame)
            let actualRect = rowView.convert(rowView.bounds,to:table)
            result["editor_actual_row_view_rect_in_table"] = rect(actualRect)
            if actualRow >= 0,actualRow < probeRowCount(table) {
                let committed = probeRowRect(table,index:actualRow),tolerance = 1/max(1,window.backingScaleFactor)
                result["editor_actual_row_view_minus_committed_y"] = actualRect.minY-committed.minY
                result["editor_actual_row_view_minus_committed_height"] = actualRect.height-committed.height
                result["editor_actual_row_view_matches_committed"] = abs(actualRect.minY-committed.minY) <= tolerance && abs(actualRect.height-committed.height) <= tolerance
            }
            result["editor_row_view_identity"] = String(describing:ObjectIdentifier(rowView))
        }
        if let cell { result["editor_cell_identity"] = String(describing:ObjectIdentifier(cell)) }
        return result
    }
    private static func runTableEditorProbe(model:NativeChatPreviewModel,timeline:NSView,window:NSWindow,owner:UUID,directory:URL,backend:String,samples:inout [[String:Any]],checks:inout [String:Bool],microPrepend:Bool = false) async throws {
        let scroll = try await probeTable(in:timeline,backend:backend)
        guard let table = scroll.documentView,isProbeDocument(table),let post = model.posts.first(where:{ $0.id == 5105 }) else { throw ChatAPIError.invalidResponse }
        let scrollID = ObjectIdentifier(scroll),documentID = ObjectIdentifier(table),account = model.accountGeneration,token = model.historyViewportToken
        let tolerance = 1/max(1,window.backingScaleFactor)
        let originalText = model.messageText(post)
        try await probeJump(5105,model:model,timeline:timeline,scroll:scroll)
        model.scrollPostID = nil
        try await settle([timeline],nanoseconds:100_000_000)
        model.beginMessageEditing(owner:owner)
        defer { model.endMessageEditing(owner:owner) }
        var candidate:NSTextView?
        for _ in 0..<40 {
            try await settle([timeline],nanoseconds:20_000_000)
            candidate = editorTextViews(in:table).first { editor in
                guard editor.isEditable,case .post(5105)? = probeCellRow(editorCell(editor)) else { return false }
                return true
            }
            if candidate != nil { break }
        }
        checks["editor_setup_real_table_text_view_found"] = candidate != nil
        guard let editor = candidate else { throw ChatAPIError.invalidResponse }
        checks["editor_setup_initial_seed_text_exact"] = editor.string == originalText
        checks["editor_setup_first_responder_succeeded"] = window.makeFirstResponder(editor)
        checks["editor_setup_has_real_undo_manager"] = editor.undoManager != nil
        guard editor.string == originalText,window.firstResponder === editor,let undo = editor.undoManager else { throw ChatAPIError.invalidResponse }
        let groupsByEvent = undo.groupsByEvent
        undo.groupsByEvent = false
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        defer { undo.groupsByEvent = groupsByEvent }
        let suffix = " 🧪 unsaved café 漢字"
        editor.setSelectedRange(NSRange(location:originalText.utf16.count,length:0))
        editor.breakUndoCoalescing();undo.beginUndoGrouping()
        editor.insertText(suffix,replacementRange:editor.selectedRange())
        undo.endUndoGrouping();editor.breakUndoCoalescing()
        let expectedText = originalText+suffix
        let expectedSelection = NSRange(location:originalText.utf16.count+1,length:2)
        editor.setSelectedRange(expectedSelection)
        try await settle([timeline],nanoseconds:100_000_000)
        var baseline = editorGeometry("editor-before-prepend",editor:editor,model:model,timeline:timeline,scroll:scroll,table:table,window:window,scrollID:scrollID,documentID:documentID,account:account,token:token,expectedText:expectedText,expectedSelection:expectedSelection)
        baseline["backing_pixel_tolerance"] = tolerance;baseline["seeded_editor_not_menu_authorization"] = true
        samples.append(baseline)
        try capture(scroll,to:directory.appendingPathComponent("editor-before-prepend-viewport.png"))
        checks["editor_baseline_unsaved_unicode_and_selection"] = editor.string == expectedText && editor.selectedRange() == expectedSelection
        checks["editor_baseline_correct_mapping_and_first_responder"] = baseline["editor_mapped_to_correct_5105_cell"] as? Bool == true && window.firstResponder === editor
        checks["editor_baseline_real_undo_available"] = undo.canUndo
        guard checks["editor_baseline_unsaved_unicode_and_selection"] == true,checks["editor_baseline_correct_mapping_and_first_responder"] == true,undo.canUndo,
              let initialCommittedOffset = baseline["editor_committed_row_offset"] as? CGFloat,let initialTextOffset = baseline["editor_actual_text_offset"] as? CGFloat else { throw ChatAPIError.invalidResponse }
        var committedOffset = initialCommittedOffset,textOffset = initialTextOffset
        let undoID = ObjectIdentifier(undo)
        if microPrepend {
            let originalPosts = model.posts
            let timestamp = originalPosts.first?.create_at ?? 0
            let values:[[String:Any]] = (5088...5090).map { id in
                ["post_id":id,"channel_id":23,"creator_id":20,"thread_id":0,"type":"normal",
                 "message":"Synthetic editor micro row \(id)","create_at":timestamp-Double(5091-id)*60_000]
            }
            let added = try JSONDecoder().decode([ChatPost].self,from:JSONSerialization.data(withJSONObject:values))
            checks["editor_micro_synthetic_plain_three_precondition"] = originalPosts.map(\.id) == Array(Int64(5091)...5120) && added.map(\.id) == [5088,5089,5090] && added.allSatisfy({ $0.channel_id == 23 && $0.type == "normal" && $0.file_props == nil && $0.url_props == nil })
            guard checks["editor_micro_synthetic_plain_three_precondition"] == true else { throw ChatAPIError.invalidResponse }
            var microInserted = true
            defer { if microInserted { model.posts = originalPosts } }
            model.posts = added+originalPosts
            checks["editor_micro_exact_direct_prepend_no_api_page"] = model.posts.map(\.id) == Array(Int64(5088)...5120) && RichHistoryProtocol.pageCursors == ["latest"]
            for (operation,expectedIDs) in [("prepend",Array(Int64(5088)...5120)),("restore",Array(Int64(5091)...5120))] {
                if operation == "restore" { model.posts = originalPosts;microInserted = false }
                for (label,delay) in [("100ms",UInt64(100_000_000)),("200ms",UInt64(100_000_000)),("1sec",UInt64(800_000_000))] {
                    try await settle([timeline],nanoseconds:delay)
                    var observation = editorGeometry("editor-micro-after-"+operation+"-"+label,editor:editor,model:model,timeline:timeline,scroll:scroll,table:table,window:window,scrollID:scrollID,documentID:documentID,account:account,token:token,expectedText:expectedText,expectedSelection:expectedSelection)
                    let committedAfter = observation["editor_committed_row_offset"] as? CGFloat,textAfter = observation["editor_actual_text_offset"] as? CGFloat
                    observation["committed_offset_before_micro"] = initialCommittedOffset;observation["actual_text_offset_before_micro"] = initialTextOffset
                    observation["committed_offset_delta"] = committedAfter.map { $0-initialCommittedOffset } as Any? ?? NSNull()
                    observation["actual_text_offset_delta"] = textAfter.map { $0-initialTextOffset } as Any? ?? NSNull()
                    observation["backing_pixel_tolerance"] = tolerance;observation["direct_seeded_mutation_not_pagination"] = true
                    samples.append(observation)
                    let key = "editor_micro_"+operation+"_"
                    checks[key+"same_editor_first_responder_"+label] = editor.window === window && editor.isDescendant(of:table) && editorTextViews(in:table).contains(where:{ $0 === editor }) && window.firstResponder === editor
                    checks[key+"correct_row_mapping_"+label] = observation["editor_mapped_to_correct_5105_cell"] as? Bool == true
                    checks[key+"actual_row_view_matches_committed_"+label] = observation["editor_actual_row_view_matches_committed"] as? Bool == true
                    checks[key+"content_selection_"+label] = editor.string == expectedText && editor.selectedRange() == expectedSelection
                    checks[key+"same_undo_manager_"+label] = editor.undoManager.map { ObjectIdentifier($0) == undoID && $0.canUndo } ?? false
                    checks[key+"committed_offset_one_backing_pixel_"+label] = committedAfter.map { abs($0-initialCommittedOffset) <= tolerance } ?? false
                    checks[key+"actual_text_offset_one_backing_pixel_"+label] = textAfter.map { abs($0-initialTextOffset) <= tolerance } ?? false
                    checks[key+"scope_identity_"+label] = mainTimelineScroll(in:timeline) === scroll && scroll.documentView === table && model.accountGeneration == account && model.historyViewportToken == token && model.activeMessageEditor == owner
                    checks[key+"exact_array_no_api_page_"+label] = model.posts.map(\.id) == expectedIDs && RichHistoryProtocol.pageCursors == ["latest"]
                    try capture(scroll,to:directory.appendingPathComponent("editor-micro-after-"+operation+"-"+label+"-viewport.png"))
                }
            }
            var restored = editorGeometry("editor-real-prepend-rebaseline-after-micro",editor:editor,model:model,timeline:timeline,scroll:scroll,table:table,window:window,scrollID:scrollID,documentID:documentID,account:account,token:token,expectedText:expectedText,expectedSelection:expectedSelection)
            restored["original_micro_committed_offset"] = initialCommittedOffset;restored["original_micro_text_offset"] = initialTextOffset
            restored["rebaseline_does_not_clear_micro_failures"] = true;samples.append(restored)
            guard let restoredCommitted = restored["editor_committed_row_offset"] as? CGFloat,let restoredText = restored["editor_actual_text_offset"] as? CGFloat else { throw ChatAPIError.invalidResponse }
            committedOffset = restoredCommitted;textOffset = restoredText
            try capture(scroll,to:directory.appendingPathComponent("editor-real-prepend-rebaseline-after-micro-viewport.png"))
        }
        await model.loadOlder()
        checks["editor_actual_model_prepend_30_to_60"] = model.posts.map(\.id) == Array(Int64(5061)...5120) && RichHistoryProtocol.pageCursors == ["latest","5091"]
        for (label,delay) in [("100ms",UInt64(100_000_000)),("200ms",UInt64(100_000_000)),("1sec",UInt64(800_000_000))] {
            try await settle([timeline],nanoseconds:delay)
            var observation = editorGeometry("editor-after-prepend-"+label,editor:editor,model:model,timeline:timeline,scroll:scroll,table:table,window:window,scrollID:scrollID,documentID:documentID,account:account,token:token,expectedText:expectedText,expectedSelection:expectedSelection)
            let committedAfter = observation["editor_committed_row_offset"] as? CGFloat,textAfter = observation["editor_actual_text_offset"] as? CGFloat
            observation["committed_offset_before"] = committedOffset;observation["actual_text_offset_before"] = textOffset
            observation["committed_offset_delta"] = committedAfter.map { $0-committedOffset } as Any? ?? NSNull()
            observation["actual_text_offset_delta"] = textAfter.map { $0-textOffset } as Any? ?? NSNull()
            observation["backing_pixel_tolerance"] = tolerance;samples.append(observation)
            let attachedSame = editor.window === window && editor.isDescendant(of:table) && editorTextViews(in:table).contains(where:{ $0 === editor })
            checks["editor_same_object_first_responder_"+label] = attachedSame && window.firstResponder === editor
            checks["editor_correct_row_mapping_"+label] = observation["editor_mapped_to_correct_5105_cell"] as? Bool == true
            checks["editor_actual_row_view_matches_committed_"+label] = observation["editor_actual_row_view_matches_committed"] as? Bool == true
            checks["editor_unsaved_content_selection_"+label] = editor.string == expectedText && editor.selectedRange() == expectedSelection
            checks["editor_same_undo_manager_"+label] = editor.undoManager.map { ObjectIdentifier($0) == undoID && $0.canUndo } ?? false
            checks["editor_committed_offset_one_backing_pixel_"+label] = committedAfter.map { abs($0-committedOffset) <= tolerance } ?? false
            checks["editor_actual_text_offset_one_backing_pixel_"+label] = textAfter.map { abs($0-textOffset) <= tolerance } ?? false
            checks["editor_scope_identity_"+label] = mainTimelineScroll(in:timeline) === scroll && scroll.documentView === table && model.accountGeneration == account && model.historyViewportToken == token && model.activeMessageEditor == owner
            try capture(scroll,to:directory.appendingPathComponent("editor-after-prepend-"+label+"-viewport.png"))
        }
        undo.undo();try await settle([timeline],nanoseconds:50_000_000)
        checks["editor_actual_undo_restores_original"] = editor.string == originalText && undo.canRedo
        samples.append(editorGeometry("editor-after-actual-undo",editor:editor,model:model,timeline:timeline,scroll:scroll,table:table,window:window,scrollID:scrollID,documentID:documentID,account:account,token:token,expectedText:originalText,expectedSelection:editor.selectedRange()))
        undo.redo();try await settle([timeline],nanoseconds:50_000_000)
        checks["editor_actual_redo_restores_unsaved"] = editor.string == expectedText && undo.canUndo
        samples.append(editorGeometry("editor-after-actual-redo",editor:editor,model:model,timeline:timeline,scroll:scroll,table:table,window:window,scrollID:scrollID,documentID:documentID,account:account,token:token,expectedText:expectedText,expectedSelection:editor.selectedRange()))
        model.endMessageEditing(owner:owner)
        try await settle([timeline],nanoseconds:50_000_000)
        let modelTextUnchanged = model.posts.first(where:{ $0.id == 5105 }).map { model.messageText($0) == originalText } == true
        checks["editor_cleanup_ended_without_api_write"] = model.activeMessageEditor == nil && RichHistoryProtocol.deniedWrites == 0 && model.draft == draft && modelTextUnchanged
    }

    private static func probePostGeometry(_ postID:Int64,in scroll:NSScrollView)->[String:Any]? {
        guard let table = scroll.documentView,isProbeDocument(table),
              let marker = markers(in:table).first(where:{ $0.postID == postID }) else { return nil }
        let index = probeRowIndex(table,view:marker)
        guard index >= 0,index < probeRowCount(table) else { return nil }
        let row = probeRowRect(table,index:index),frame = marker.convert(marker.bounds,to:table),visible = scroll.documentVisibleRect
        let overlap = frame.intersection(visible),rowOverlap = row.intersection(visible)
        let cell = probeHostedCell(table,index:index)
        return ["post_id":postID,"table_row":index,"committed_row_rect":rect(row),"marker_rect":rect(frame),
            "marker_offset":frame.minY-visible.minY,"row_offset":row.minY-visible.minY,
            "marker_visible_height":overlap.isNull ? 0 : overlap.height,"committed_row_visible_height":rowOverlap.isNull ? 0 : rowOverlap.height,
            "host_attached":probeCellHasHost(cell)]
    }
    private static func probeOffset(_ id:Int64,in scroll:NSScrollView)->CGFloat? { probePostGeometry(id,in:scroll)?["marker_offset"] as? CGFloat }
    private static func probeCommittedRect(_ id:Int64,in scroll:NSScrollView)->NSRect? {
        guard let data = probePostGeometry(id,in:scroll)?["committed_row_rect"] as? [String:CGFloat],let x = data["x"],let y = data["y"],let w = data["width"],let h = data["height"] else { return nil }
        return NSRect(x:x,y:y,width:w,height:h)
    }
    private static func probeRecord(_ phase:String,postID:Int64,reference:Int64?,model:NativeChatPreviewModel,timeline:NSView,scroll:NSScrollView,scrollID:ObjectIdentifier,documentID:ObjectIdentifier,account:Int,token:UUID)->[String:Any] {
        var value = pagedGeometry(scroll:scroll,timeline:timeline,scrollIdentity:scrollID,documentIdentity:documentID)
        value["phase"] = phase;value["model_post_count"] = model.posts.count;value["model_post_ids"] = model.posts.map(\.id)
        value["draft_retained"] = model.draft == draft
        value["post_geometry"] = probePostGeometry(postID,in:scroll) as Any? ?? NSNull()
        if let reference { value["reference_geometry"] = probePostGeometry(reference,in:scroll) as Any? ?? NSNull() }
        value["account_token_stable"] = model.accountGeneration == account && model.historyViewportToken == token && model.selection == 23
        value["model_link_preview_counts"] = model.debugLinkPreviewCounts(postID:postID,asset:.image)
        value["asset_requested"] = RichHistoryProtocol.requested["og:image:"+String(postID),default:0]
        value["asset_completed"] = RichHistoryProtocol.completed["og:image:"+String(postID),default:0]
        value["active_pending_og"] = RichHistoryProtocol.activePendingOG(postID:Int(postID))
        return value
    }
    private static func probeJump(_ postID:Int64,model:NativeChatPreviewModel,timeline:NSView,scroll:NSScrollView) async throws {
        model.scrollPostID = postID
        for _ in 0..<30 {
            try await settle([timeline],nanoseconds:20_000_000)
            if visibleRows(in:scroll).contains(where:{ $0["post_id"] as? Int64 == postID }) { return }
        }
        throw ChatAPIError.invalidResponse
    }
    private static func probeTable(in timeline:NSView,backend:String) async throws -> NSScrollView {
        for _ in 0..<40 {
            try await settle([timeline],nanoseconds:20_000_000)
            if let scroll = mainTimelineScroll(in:timeline),probeBackendMatches(scroll,backend:backend) { return scroll }
        }
        throw ChatAPIError.invalidResponse
    }
    /// Production-hosted card pixels cropped from the real, composited viewport.
    private static func probeRowPNG(_ id:Int64,in scroll:NSScrollView) throws -> Data {
        guard let row = probeCommittedRect(id,in:scroll),let image = NSBitmapImageRep(data:try snapshotPNG(scroll))?.cgImage else { throw ChatAPIError.invalidResponse }
        let visible = scroll.documentVisibleRect,region = row.intersection(visible)
        guard finiteRect(region) else { throw ChatAPIError.invalidResponse }
        let sx = CGFloat(image.width)/visible.width,sy = CGFloat(image.height)/visible.height
        let crop = CGRect(x:(region.minX-visible.minX)*sx,y:(region.minY-visible.minY)*sy,width:region.width*sx,height:region.height*sy).integral
        guard let result = image.cropping(to:crop.intersection(CGRect(x:0,y:0,width:image.width,height:image.height))),
              let data = NSBitmapImageRep(cgImage:result).representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
        return data
    }
    private static func runTableCacheProbe(model:NativeChatPreviewModel,timeline:NSView,window:NSWindow,directory:URL,backend:String,samples:inout [[String:Any]],checks:inout [String:Bool]) async throws -> Int {
        let scroll = try await probeTable(in:timeline,backend:backend)
        guard let document = scroll.documentView else { throw ChatAPIError.invalidResponse }
        let scrollID = ObjectIdentifier(scroll),documentID = ObjectIdentifier(document),account = model.accountGeneration,token = model.historyViewportToken
        try await probeJump(5120,model:model,timeline:timeline,scroll:scroll)
        for _ in 0..<40 {
            try await settle([timeline],nanoseconds:20_000_000)
            if RichHistoryProtocol.activePendingOG(postID:5120) > 0,RichHistoryProtocol.completed["og:favicon:5120",default:0] > 0 { break }
        }
        let held = RichHistoryProtocol.activePendingOG(postID:5120)
        let initialRow = probeCommittedRect(5120,in:scroll)
        let fullyVisible = initialRow.map { $0.intersection(scroll.documentVisibleRect).height >= $0.height-1/max(1,window.backingScaleFactor) } ?? false
        checks["cache_5120_visible_held_route"] = held > 0 && fullyVisible && probePostGeometry(5120,in:scroll)?["host_attached"] as? Bool == true && visibleRows(in:scroll).contains(where:{ $0["post_id"] as? Int64 == 5120 })
        samples.append(probeRecord("cache-held-before-release",postID:5120,reference:nil,model:model,timeline:timeline,scroll:scroll,scrollID:scrollID,documentID:documentID,account:account,token:token))
        guard checks["cache_5120_visible_held_route"] == true else { throw ChatAPIError.invalidResponse }
        let before = try probeRowPNG(5120,in:scroll);try before.write(to:directory.appendingPathComponent("cache-5120-before.png"),options:.withoutOverwriting)
        RichHistoryProtocol.releaseOG()
        var continuouslyVisible = true
        for _ in 0..<60 {
            try await settle([timeline],nanoseconds:20_000_000)
            continuouslyVisible = continuouslyVisible && visibleRows(in:scroll).contains(where:{ $0["post_id"] as? Int64 == 5120 })
            if model.debugLinkPreviewCounts(postID:5120,asset:.image)["cache_admit",default:0] > 0 { break }
        }
        try await settle([timeline],nanoseconds:40_000_000)
        let admitted = model.debugLinkPreviewCounts(postID:5120,asset:.image)
        checks["cache_5120_continuously_visible_until_admission"] = continuouslyVisible
        checks["cache_5120_admitted_not_merely_transferred"] = admitted["cache_admit",default:0] > 0 && admitted["transport_return",default:0] > 0
        samples.append(probeRecord("cache-after-admission-wait",postID:5120,reference:nil,model:model,timeline:timeline,scroll:scroll,scrollID:scrollID,documentID:documentID,account:account,token:token))
        guard checks["cache_5120_admitted_not_merely_transferred"] == true,
              let post = model.posts.first(where:{ $0.id == 5120 }),let preview = model.linkPreviews(for:post).first else { throw ChatAPIError.invalidResponse }
        let readsBefore = RichHistoryProtocol.requested["og:image:5120",default:0],startsBefore = admitted["start",default:0]
        let hitBefore = admitted["cache_hit",default:0]
        let image = await model.linkPreviewImage(for:post,preview:preview.preview)
        checks["cache_immediate_probe_decoded_without_transfer"] = image.map { $0.size.width > 0 && $0.size.height > 0 } == true && RichHistoryProtocol.requested["og:image:5120",default:0] == readsBefore && model.debugLinkPreviewCounts(postID:5120,asset:.image)["cache_hit",default:0] > hitBefore
        let after = try probeRowPNG(5120,in:scroll);try after.write(to:directory.appendingPathComponent("cache-5120-after.png"),options:.withoutOverwriting)
        checks["cache_production_card_pixels_changed"] = before != after
        let hitAfterImmediateProbe = model.debugLinkPreviewCounts(postID:5120,asset:.image)["cache_hit",default:0]
        try await probeJump(5001,model:model,timeline:timeline,scroll:scroll)
        samples.append(probeRecord("cache-jump-away",postID:5120,reference:5001,model:model,timeline:timeline,scroll:scroll,scrollID:scrollID,documentID:documentID,account:account,token:token))
        try await probeJump(5120,model:model,timeline:timeline,scroll:scroll)
        try await settle([timeline],nanoseconds:100_000_000)
        let countsAfterReturn = model.debugLinkPreviewCounts(postID:5120,asset:.image)
        let decodedReturn = await model.linkPreviewImage(for:post,preview:preview.preview)
        checks["cache_jump_return_decoded_without_extra_og_transfer"] = decodedReturn.map { $0.size.width > 0 && $0.size.height > 0 } == true && RichHistoryProtocol.requested["og:image:5120",default:0] == readsBefore && countsAfterReturn["start",default:0] == startsBefore && countsAfterReturn["cache_hit",default:0] > hitAfterImmediateProbe
        checks["cache_return_5120_visible"] = visibleRows(in:scroll).contains(where:{ $0["post_id"] as? Int64 == 5120 })
        let returnPixels = try probeRowPNG(5120,in:scroll)
        try returnPixels.write(to:directory.appendingPathComponent("cache-5120-return.png"),options:.withoutOverwriting)
        checks["cache_return_card_pixels_remain_changed_from_placeholder"] = returnPixels != before
        samples.append(probeRecord("cache-jump-return",postID:5120,reference:nil,model:model,timeline:timeline,scroll:scroll,scrollID:scrollID,documentID:documentID,account:account,token:token))
        try capture(scroll,to:directory.appendingPathComponent("cache-return-viewport.png"))
        let currentDocumentID = scroll.documentView.map { ObjectIdentifier($0) }
        checks["cache_scope_scroll_document_identity"] = ObjectIdentifier(scroll) == scrollID && currentDocumentID == documentID && mainTimelineScroll(in:timeline) === scroll && model.accountGeneration == account && model.historyViewportToken == token
        return held
    }
    private static func runTableAnchorProbe(model:NativeChatPreviewModel,timeline:NSView,window:NSWindow,directory:URL,backend:String,samples:inout [[String:Any]],checks:inout [String:Bool]) async throws -> Int {
        let scroll = try await probeTable(in:timeline,backend:backend)
        guard let table = scroll.documentView,isProbeDocument(table) else { throw ChatAPIError.invalidResponse }
        let scrollID = ObjectIdentifier(scroll),documentID = ObjectIdentifier(table),account = model.accountGeneration,token = model.historyViewportToken
        let tolerance = 1/max(1,window.backingScaleFactor)
        try await probeJump(5105,model:model,timeline:timeline,scroll:scroll)
        // End the explicit centred navigation before establishing a reader's
        // manual position. This is setup only, never a post-operation fixup.
        model.scrollPostID = nil
        try await settle([timeline],nanoseconds:40_000_000)
        guard let marker = markers(in:table).first(where:{ $0.postID == 5105 }) else { throw ChatAPIError.invalidResponse }
        let markerFrame = marker.convert(marker.bounds,to:table)
        scroll.contentView.scroll(to:NSPoint(x:0,y:markerFrame.minY));scroll.reflectScrolledClipView(scroll.contentView)
        try await settle([timeline],nanoseconds:100_000_000)
        guard let referenceBefore = probeOffset(5105,in:scroll) else { throw ChatAPIError.invalidResponse }
        checks["prepend_reference_real_plain_post_at_top"] = model.posts.first(where:{ $0.id == 5105 })?.type == "normal" && abs(referenceBefore) <= tolerance && visibleRows(in:scroll).first?["post_id"] as? Int64 == 5105
        var baseline = probeRecord("prepend-before-30",postID:5105,reference:5105,model:model,timeline:timeline,scroll:scroll,scrollID:scrollID,documentID:documentID,account:account,token:token)
        baseline["reference_offset"] = referenceBefore;baseline["backing_pixel_tolerance"] = tolerance;samples.append(baseline)
        try capture(scroll,to:directory.appendingPathComponent("prepend-before-viewport.png"))
        guard checks["prepend_reference_real_plain_post_at_top"] == true else { throw ChatAPIError.invalidResponse }
        await model.loadOlder()
        checks["prepend_real_model_older_read_30_to_60"] = model.posts.count == 60 && model.posts.first?.id == 5061 && RichHistoryProtocol.pageCursors == ["latest","5091"]
        for (label,delay) in [("100ms",UInt64(100_000_000)),("200ms",UInt64(100_000_000)),("1sec",UInt64(800_000_000))] {
            try await settle([timeline],nanoseconds:delay)
            let offset = probeOffset(5105,in:scroll)
            var observation = probeRecord("prepend-after-"+label,postID:5105,reference:5105,model:model,timeline:timeline,scroll:scroll,scrollID:scrollID,documentID:documentID,account:account,token:token)
            observation["reference_offset_before"] = referenceBefore;observation["reference_offset_after"] = offset as Any? ?? NSNull()
            observation["reference_offset_delta"] = offset.map { $0-referenceBefore } as Any? ?? NSNull();observation["backing_pixel_tolerance"] = tolerance;samples.append(observation)
            checks["prepend_reference_pixel_stable_"+label] = offset.map { abs($0-referenceBefore) <= tolerance } ?? false
            try capture(scroll,to:directory.appendingPathComponent("prepend-after-"+label+"-viewport.png"))
        }
        // Deliberately leave only an eight-point committed-row tail of 5100.
        // Its marker can be fully clipped because the table row includes bottom padding.
        try await probeJump(5100,model:model,timeline:timeline,scroll:scroll)
        for _ in 0..<40 {
            try await settle([timeline],nanoseconds:20_000_000)
            if RichHistoryProtocol.activePendingOG(postID:5100) > 0,probePostGeometry(5101,in:scroll) != nil { break }
        }
        guard let beforeRow = probeCommittedRect(5100,in:scroll) else { throw ChatAPIError.invalidResponse }
        model.scrollPostID = nil
        try await settle([timeline],nanoseconds:40_000_000)
        scroll.contentView.scroll(to:NSPoint(x:0,y:beforeRow.maxY-8));scroll.reflectScrolledClipView(scroll.contentView)
        try await settle([timeline],nanoseconds:100_000_000)
        let held = RichHistoryProtocol.activePendingOG(postID:5100)
        let linkGeometry = probePostGeometry(5100,in:scroll),followingGeometry = probePostGeometry(5101,in:scroll)
        let tail = linkGeometry?["committed_row_visible_height"] as? CGFloat ?? -1
        let markerTail = linkGeometry?["marker_visible_height"] as? CGFloat ?? -1
        let reference = probeOffset(5101,in:scroll)
        let committedHeight = probeCommittedRect(5100,in:scroll)?.height
        checks["async_unknown_metadata_only_for_5100"] = model.posts.first(where:{ $0.id == 5100 }).flatMap { model.linkPreviews(for:$0).first?.preview.image_prop } == nil && RichHistoryProtocol.unknownOGGeometry
        checks["async_link_committed_tail_eight_points"] = abs(tail-8) <= tolerance && markerTail >= 0 && markerTail < 20
        checks["async_5101_first_significant_visible"] = visibleRows(in:scroll).first?["post_id"] as? Int64 == 5101 && (followingGeometry?["marker_visible_height"] as? CGFloat ?? 0) >= 20
        checks["async_5100_host_and_real_held_request_alive"] = held > 0 && linkGeometry?["host_attached"] as? Bool == true
        var before = probeRecord("async-image-held-before",postID:5100,reference:5101,model:model,timeline:timeline,scroll:scroll,scrollID:scrollID,documentID:documentID,account:account,token:token)
        before["backing_pixel_tolerance"] = tolerance;before["reference_offset"] = reference as Any? ?? NSNull();samples.append(before)
        try capture(scroll,to:directory.appendingPathComponent("async-image-before-viewport.png"))
        guard checks["async_link_committed_tail_eight_points"] == true,checks["async_5101_first_significant_visible"] == true,
              checks["async_5100_host_and_real_held_request_alive"] == true,let reference,let committedHeight else { throw ChatAPIError.invalidResponse }
        RichHistoryProtocol.releaseOG()
        var grew = false
        for (label,delay) in [("100ms",UInt64(100_000_000)),("200ms",UInt64(100_000_000)),("1sec",UInt64(800_000_000))] {
            try await settle([timeline],nanoseconds:delay)
            let afterHeight = probeCommittedRect(5100,in:scroll)?.height,offset = probeOffset(5101,in:scroll)
            grew = grew || afterHeight.map { $0-committedHeight >= 20 } == true
            var observation = probeRecord("async-image-after-"+label,postID:5100,reference:5101,model:model,timeline:timeline,scroll:scroll,scrollID:scrollID,documentID:documentID,account:account,token:token)
            observation["committed_height_before"] = committedHeight;observation["committed_height_after"] = afterHeight as Any? ?? NSNull()
            observation["reference_offset_before"] = reference;observation["reference_offset_after"] = offset as Any? ?? NSNull()
            observation["reference_offset_delta"] = offset.map { $0-reference } as Any? ?? NSNull();observation["backing_pixel_tolerance"] = tolerance;samples.append(observation)
            checks["async_reference_pixel_stable_"+label] = offset.map { abs($0-reference) <= tolerance } ?? false
            try capture(scroll,to:directory.appendingPathComponent("async-image-after-"+label+"-viewport.png"))
        }
        checks["async_actual_committed_row_height_grew_twenty"] = grew
        checks["async_5100_image_admitted"] = model.debugLinkPreviewCounts(postID:5100,asset:.image)["cache_admit",default:0] > 0
        checks["anchor_scope_scroll_document_account_token_identity"] = mainTimelineScroll(in:timeline) === scroll && scroll.documentView === table && model.accountGeneration == account && model.historyViewportToken == token && model.selection == 23
        return held
    }

    private static func pagedGeometry(scroll:NSScrollView,timeline:NSView,scrollIdentity:ObjectIdentifier,documentIdentity:ObjectIdentifier)->[String:Any] {
        guard let document = scroll.documentView else { return ["document_missing":true,"visible_rows":[[String:Any]]()] }
        let actualMarkers = markers(in:document)
        let frames = actualMarkers.map { $0.convert($0.bounds,to:document) }.filter { finiteRect($0) }
        let extent = frames.reduce(NSRect.null) { $0.union($1) }
        let visible = visibleRows(in:scroll)
        var result:[String:Any] = ["visible_rows":visible,"visible_inline_rasters":visibleRasters(in:scroll),
            "latest_5120_visible":visible.contains(where:{ $0["post_id"] as? Int64 == 5120 }),
            "at_bottom_geometry":NativeScrollVisibility.isAtBottom(content:document.bounds,visible:scroll.documentVisibleRect,flipped:document.isFlipped),
            "clip_bounds":rect(scroll.contentView.bounds),"document_bounds":rect(document.bounds),"document_frame":rect(document.frame),
            "scroll_identity":String(describing:ObjectIdentifier(scroll)),"document_identity":String(describing:ObjectIdentifier(document)),
            "scroll_identity_stable":ObjectIdentifier(scroll) == scrollIdentity && allScrolls(in:timeline).contains(where:{ $0 === scroll }),
            "document_identity_stable":ObjectIdentifier(document) == documentIdentity,"materialized_marker_count":actualMarkers.count,
            "materialized_marker_ids":actualMarkers.map(\.postID).sorted(),"finite_clip_and_document":finiteRect(scroll.contentView.bounds) && finiteRect(document.bounds)]
        let resizeObservers = scrollVisibilityObservers(in:document).filter { $0.enclosingScrollView === scroll }
        result["resize_observer_count"] = resizeObservers.count
        result["resize_observer_diagnostics"] = resizeObservers.map { observer -> [String:Any] in
            ["observer_identity":String(describing:ObjectIdentifier(observer)),
             "debug_resize_callback_count":observer.debugResizeCallbackCount,
             "debug_resize_events":observer.debugResizeEvents,
             "debug_resize_state":observer.debugResizeState]
        }
        if let diagnostics = probeDocumentDiagnostics(document) { result["native_table_diagnostics"] = diagnostics }
        result["actual_backend"] = document is NativeVirtualTimeline.Document ? "native-virtual-timeline" : document is NativeTableTimeline.Table ? "native-table-timeline" : "swiftui-lazy"
        if !extent.isNull,finiteRect(extent) {
            result["materialized_row_extent"] = rect(extent)
            result["document_minus_materialized_height"] = document.bounds.height-extent.height
            result["clip_past_materialized_max_y"] = scroll.documentVisibleRect.minY-extent.maxY
        }
        return result
    }
    private static func scrollVisibilityObservers(in view:NSView)->[NativeScrollVisibility.Observer] {
        (view as? NativeScrollVisibility.Observer).map { [$0] } ?? view.subviews.flatMap { scrollVisibilityObservers(in:$0) }
    }
    private static func finiteRect(_ rect:NSRect)->Bool {
        [rect.minX,rect.minY,rect.width,rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }
    /// Match the decoded raster to the requested production row and current viewport.
    private static func decodedRasters(for postID:Int64,frames:Int,in scroll:NSScrollView)->[[String:Any]] {
        guard let document = scroll.documentView,let marker = markers(in:document).first(where:{ $0.postID == postID }) else { return [] }
        let row = marker.convert(marker.bounds,to:document),visible = scroll.documentVisibleRect
        guard finiteRect(row),row.intersects(visible) else { return [] }
        return inlineRasters(in:document).compactMap { raster -> [String:Any]? in
            guard let image = raster.image,NativeInlineImagePreview.frameCount(image) == frames else { return nil }
            let frame = raster.convert(raster.bounds,to:document),intersection = frame.intersection(row).intersection(visible)
            guard finiteRect(frame),!intersection.isNull,intersection.width > 0,intersection.height > 0 else { return nil }
            return ["post_id":postID,"decoded_frames":frames,"raster_frame":rect(frame),"row_frame":rect(row),"visible_intersection":rect(intersection)]
        }
    }
    private static func visibleRasters(in scroll:NSScrollView)->[[String:Any]] {
        guard let document = scroll.documentView else { return [] }
        return inlineRasters(in:document).compactMap { raster -> [String:Any]? in
            let frame = raster.convert(raster.bounds,to:document)
            guard frame.intersects(scroll.documentVisibleRect) else { return nil }
            return ["frame":rect(frame),"decoded_image":raster.image != nil,"decoded_frames":raster.image.map(NativeInlineImagePreview.frameCount) ?? 0]
        }
    }
    private static func mainTimelineScroll(in view:NSView)->NSScrollView? {
        let candidates = allScrolls(in:view).filter { scroll in
            guard let document = scroll.documentView else { return false }
            return !markers(in:document).isEmpty && scroll.contentView.bounds.width > 400
        }
        return candidates.max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }
    }
    private static func allScrolls(in view:NSView)->[NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { allScrolls(in:$0) }
    }
    private static func markers(in view:NSView)->[NativeTimelineRowMarker.Marker] {
        (view as? NativeTimelineRowMarker.Marker).map { [$0] } ?? view.subviews.flatMap { markers(in:$0) }
    }
    private static func visibleRows(in scroll:NSScrollView)->[[String:Any]] {
        guard let document = scroll.documentView else { return [] }
        let visible = scroll.documentVisibleRect
        return markers(in:document).compactMap { marker -> [String:Any]? in
            let frame = marker.convert(marker.bounds,to:document),intersection = frame.intersection(visible)
            guard frame.height > 0,intersection.height >= min(20,frame.height),intersection.width > 0 else { return nil }
            return ["post_id":marker.postID,"frame":rect(frame),"visible_intersection":rect(intersection)]
        }.sorted { ($0["post_id"] as? Int64 ?? 0) < ($1["post_id"] as? Int64 ?? 0) }
    }

    private static func makeWindow(content:NSView,width:CGFloat,height:CGFloat)->NSWindow {
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:width,height:height),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = content;content.frame = NSRect(x:0,y:0,width:width,height:height)
        return window
    }
    private static func settle(_ views:[NSView],nanoseconds:UInt64) async throws {
        try await Task.sleep(nanoseconds:nanoseconds)
        for view in views { view.layoutSubtreeIfNeeded();view.needsDisplay = true;view.displayIfNeeded() }
    }
    private static func capture(_ view:NSView,to url:URL) throws {
        try snapshotPNG(view).write(to:url,options:.withoutOverwriting)
    }
    private static func snapshotPNG(_ view:NSView) throws -> Data {
        // A transparent scroll subview can cache text without its ancestor's
        // background. Composite the attached root first, then crop its pixels.
        let source = view is NSScrollView ? view.window?.contentView ?? view : view
        guard finiteRect(source.bounds),let bitmap = source.bitmapImageRepForCachingDisplay(in:source.bounds) else { throw ChatAPIError.invalidResponse }
        source.cacheDisplay(in:source.bounds,to:bitmap)
        if source !== view {
            guard let full = bitmap.cgImage else { throw ChatAPIError.invalidResponse }
            let frame = view.convert(view.bounds,to:source)
            let sx = CGFloat(full.width)/source.bounds.width,sy = CGFloat(full.height)/source.bounds.height
            let y = source.isFlipped ? frame.minY-source.bounds.minY : source.bounds.maxY-frame.maxY
            let pixels = CGRect(x:(frame.minX-source.bounds.minX)*sx,y:y*sy,width:frame.width*sx,height:frame.height*sy).integral
            let imageBounds = CGRect(x:0,y:0,width:full.width,height:full.height)
            guard finiteRect(pixels),pixels.minX >= -1,pixels.minY >= -1,pixels.maxX <= imageBounds.maxX+1,pixels.maxY <= imageBounds.maxY+1,
                  let cropped = full.cropping(to:pixels.intersection(imageBounds)),
                  let bytes = NSBitmapImageRep(cgImage:cropped).representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
            return bytes
        }
        guard let bytes = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
        return bytes
    }
    private static func record(_ value:[String:Any],to url:URL) throws {
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.withoutOverwriting)
    }
    private static func inlineRasters(in view:NSView)->[NativeInlineImageRaster] {
        (view as? NativeInlineImageRaster).map { [$0] } ?? view.subviews.flatMap { inlineRasters(in:$0) }
    }
    private static func scrollGeometry(in view:NSView)->[[String:Any]] {
        if let scroll = view as? NSScrollView {
            let document = scroll.documentView
            return [["frame":rect(scroll.frame),"clip_bounds":rect(scroll.contentView.bounds),
                     "document_frame":document.map { rect($0.frame) } ?? [:],"document_bounds":document.map { rect($0.bounds) } ?? [:]]]
        }
        return view.subviews.flatMap { scrollGeometry(in:$0) }
    }
    private static func rect(_ value:NSRect)->[String:CGFloat] { ["x":value.minX,"y":value.minY,"width":value.width,"height":value.height] }
    private static func documentHeights(_ geometry:[[String:Any]])->[CGFloat] {
        geometry.compactMap { ($0["document_frame"] as? [String:CGFloat])?["height"] }
    }
}

private final class RichHistoryProtocol:URLProtocol {
    @MainActor static var requested:[String:Int] = [:],completed:[String:Int] = [:]
    @MainActor static var unknownReads:[String] = []
    @MainActor static var deniedWrites = 0,deniedRuntime = 0
    @MainActor static var pendingOG:[RichHistoryProtocol] = []
    @MainActor private static var png = Data(),gif = Data(),og = Data(),favicon = Data()
    @MainActor private static var ogReleased = false
    @MainActor static var paged = false,pageCursors:[String] = []
    @MainActor static var unknownOGGeometry = false
    @MainActor static func activePendingOG(postID:Int)->Int { pendingOG.filter { !$0.isStopped && $0.ogPostID == postID }.count }
    private let stopLock = NSLock()
    private var stopped = false
    private var ogPostID:Int?
    private var isStopped:Bool { stopLock.lock();defer { stopLock.unlock() };return stopped }

    @MainActor static func reset() throws {
        cancelPending();requested = [:];completed = [:];unknownReads = [];deniedWrites = 0;deniedRuntime = 0;ogReleased = false;paged = false;pageCursors = [];unknownOGGeometry = false
        let blue = try bitmap(width:48,height:32,color:NSColor.systemBlue)
        guard let bytes = blue.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse };png = bytes
        let green = try bitmap(width:400,height:200,color:NSColor.systemTeal)
        guard let bytes = green.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse };og = bytes
        let icon = try bitmap(width:16,height:16,color:NSColor.systemOrange)
        guard let bytes = icon.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse };favicon = bytes
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output,"com.compuserve.gif" as CFString,2,nil) else { throw ChatAPIError.invalidResponse }
        for color in [NSColor.systemPink,NSColor.systemGreen] {
            guard let image = try bitmap(width:32,height:24,color:color).cgImage else { throw ChatAPIError.invalidResponse }
            CGImageDestinationAddImage(destination,image,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.2]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination),let source = CGImageSourceCreateWithData(output as CFData,nil),CGImageSourceGetCount(source) == 2 else { throw ChatAPIError.invalidResponse }
        gif = output as Data
    }
    @MainActor private static func bitmap(width:Int,height:Int,color:NSColor) throws -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
              let context = NSGraphicsContext(bitmapImageRep:bitmap) else { throw ChatAPIError.invalidResponse }
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = context
        color.setFill();NSRect(x:0,y:0,width:CGFloat(width),height:CGFloat(height)).fill();NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
    @MainActor static func cancelPending() { let pending = pendingOG;pendingOG = [];for item in pending { item.fail() } }
    @MainActor static func releaseOG() { ogReleased = true;let pending = pendingOG;pendingOG = [];for item in pending { item.sendImage(og,key:"og:image",mime:"image/png") } }

    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.scheme == "https",request.url?.host == NativeRichHistoryChecks.host else { fail();return }
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty,let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048)
            while bytes.count < 16_384,stream.hasBytesAvailable {
                let count = stream.read(&buffer,maxLength:min(buffer.count,16_384-bytes.count));if count <= 0 { break };bytes.append(contentsOf:buffer.prefix(count))
            }
        }
        guard bytes.count < 16_384 else { fail();return }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
        let fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        DispatchQueue.main.async { self.route(fields:fields) }
    }
    override func stopLoading() { stopLock.lock();stopped = true;stopLock.unlock() }
    @MainActor private func route(fields:[String:String]) {
        guard !isStopped,let url = request.url else { return }
        if url.path == "/webman/3rdparty/Chat/config" { Self.deniedRuntime += 1;fail();return }
        guard url.path.hasPrefix("/webapi/") else { Self.unknownReads.append(url.path);fail();return }
        func field(_ key:String)->String {
            let raw = fields[key] ?? ""
            return (try? JSONSerialization.jsonObject(with:Data(raw.utf8),options:.fragmentsAllowed) as? String) ?? raw
        }
        let endpoint = url.lastPathComponent,method = field("method")
        let postID = Int(field("post_id")) ?? 0
        let isPNG = Self.paged ? (5001...5120).contains(postID) && (postID-5001)%10 == 6 : postID == 4001
        let isGIF = Self.paged ? (5001...5120).contains(postID) && (postID-5001)%10 == 7 : postID == 4002
        let isLink = Self.paged ? (5001...5120).contains(postID) && (postID-5001)%10 == 9 : postID == 4004
        if endpoint == "SYNO.Chat.Post.File",method == "thumbnail",isPNG || isGIF {
            let key = "thumbnail:"+field("post_id");Self.requested[key,default:0] += 1
            sendImage(isPNG ? Self.png : Self.gif,key:key,mime:isPNG ? "image/png" : "image/gif");return
        }
        if endpoint == "SYNO.Chat.Post.File",method == "og",isLink {
            ogPostID = postID
            if field("url") == "https://assets.example.invalid/rich-history.png" {
                Self.requested["og:image",default:0] += 1;Self.requested["og:image:"+String(postID),default:0] += 1
                if Self.ogReleased { sendImage(Self.og,key:"og:image",mime:"image/png") } else { Self.pendingOG.append(self) };return
            }
            if field("url") == "https://assets.example.invalid/icon.png" {
                Self.requested["og:favicon",default:0] += 1;Self.requested["og:favicon:"+String(postID),default:0] += 1;sendImage(Self.favicon,key:"og:favicon",mime:"image/png");return
            }
        }
        let payload:[String:Any]
        switch (endpoint,method) {
        case ("SYNO.API.Info","query"):
            let endpoints = ["SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Channel.Member","SYNO.Chat.Misc","SYNO.Chat.Post","SYNO.Chat.Post.File","SYNO.Chat.Admin.Setting","SYNO.Chat.User.Preference","SYNO.Chat.Post.Subscribe"]
            payload = Dictionary(uniqueKeysWithValues:endpoints.map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"] as [String:Any]) })
        case ("SYNO.Chat.User","list"):payload = ["users":[["user_id":10,"username":"synthetic-rich","nickname":"Synthetic Alex","type":"human","human_type":"dsm"],["user_id":20,"username":"synthetic-peer","nickname":"Synthetic Jordan","type":"human","human_type":"dsm"]]]
        case ("SYNO.Chat.Channel","list"):payload = ["channels":[["channel_id":23,"name":"Synthetic rich history","type":"private","encrypted":false,"is_joined":true,"creator_id":10,"unread":0]]]
        case ("SYNO.Chat.Channel.Member","get"):payload = ["user_ids":[10,20]]
        case ("SYNO.Chat.Misc","acl"):payload = ["acls":[]]
        case ("SYNO.Chat.Admin.Setting","get"):payload = ["hide_post_url_preview":false,"allow_read_status":false,"file_size_limit":0]
        case ("SYNO.Chat.User.Preference","get"):payload = ["preferences":["theme_style":"dark","theme_background":0,"prefer_user_name_format":"nickname","sidebar_pinning_unread":false,"notification_showmessage":false,"notification_browser_active":false,"notification_mute":true,"calendar_enable":false,"recent_emoji":[]]]
        case ("SYNO.Chat.Post.Subscribe","get"):payload = ["subscribes":[]]
        case ("SYNO.Chat.Post","list"):
            guard field("channel_id") == "23" else { Self.unknownReads.append(endpoint+":"+method);fail();return }
            if Self.paged {
                let cursor = field("post_id").isEmpty ? "latest" : field("post_id")
                let expected = ["latest","5091","5061","5031"]
                guard Self.pageCursors.count < expected.count,cursor == expected[Self.pageCursors.count],
                      field("prev_count") == "30",field("next_count") == "0" else {
                    Self.unknownReads.append("unexpected-page:"+cursor);fail();return
                }
                let upper = 5120-Self.pageCursors.count*30
                Self.pageCursors.append(cursor)
                payload = ["posts":Self.pagedPosts.filter { ($0["post_id"] as? Int ?? 0) > upper-30 && ($0["post_id"] as? Int ?? 0) <= upper }]
            } else { payload = ["posts":Self.posts] }
        default:
            if ["create","set","update","delete","read","vote","hide"].contains(method) { Self.deniedWrites += 1 }
            else { Self.unknownReads.append(endpoint+":"+method) }
            fail();return
        }
        guard let data = try? JSONSerialization.data(withJSONObject:["success":true,"data":payload]) else { fail();return }
        send(data,mime:"application/json")
    }
    @MainActor private func sendImage(_ data:Data,key:String,mime:String) {
        guard !isStopped else { return };Self.completed[key,default:0] += 1
        if let id = ogPostID { Self.completed[key+":"+String(id),default:0] += 1 }
        send(data,mime:mime)
    }
    private func send(_ data:Data,mime:String) {
        guard !isStopped,let url = request.url,let response = HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":mime]) else { return }
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    private func fail() { guard !isStopped else { return };client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL)) }
    @MainActor private static var pagedPosts:[[String:Any]] {
        let rich = posts
        return (5001...5120).map { id in
            let kind = (id-5001)%10
            var value:[String:Any]
            if kind >= 6 {
                value = rich[kind-6]
                if var file = value["file_props"] as? [String:Any] { file["id"] = id;value["file_props"] = file }
            } else {
                value = ["channel_id":23,"creator_id":id%2 == 0 ? 10 : 20,"type":"normal","message":"Synthetic paged row \(id): readable history content for viewport geometry. Additional text keeps row wrapping realistic without copying account data.","thread_id":0]
            }
            if unknownOGGeometry,id == 5100,var previews = value["url_props"] as? [[String:Any]] {
                for index in previews.indices { previews[index]["image_prop"] = nil }
                value["url_props"] = previews
            }
            value["post_id"] = id;value["create_at"] = Int64(1_794_481_200_000)+Int64(id-5001)*60_000
            return value
        }
    }
    @MainActor private static var posts:[[String:Any]] {
        let base:Int64 = 1_794_481_200_000
        func post(_ id:Int,_ creator:Int,_ text:String,_ extra:[String:Any] = [:])->[String:Any] {
            var value:[String:Any] = ["post_id":id,"channel_id":23,"creator_id":creator,"type":"normal","message":text,"create_at":base+Int64(id-4001)*60_000,"thread_id":0]
            value.merge(extra,uniquingKeysWith:{ _,new in new });return value
        }
        return [post(4001,20,"Synthetic PNG attachment",["type":"file","file_props":["id":4001,"name":"Synthetic image.png","is_image":true,"size":png.count]]),
                post(4002,10,"Synthetic two-frame GIF attachment",["type":"file","file_props":["id":4002,"name":"Synthetic animation.gif","is_image":true,"size":gif.count]]),
                post(4003,20,"Which synthetic layout should this fixture retain?",["type":"vote","props":["vote":["state":"open","options":["multiple":false,"anonymous":false,"add_option":false,"expire_at":0],"choices":[["id":"a","text":"Stable geometry","count":2,"voters":[10,20]],["id":"b","text":"Readable content","count":0,"voters":[]]]]]]),
                post(4004,10,"Synthetic link: https://example.invalid/story",["props":["safe_url":true],"url_props":[["url":"https://example.invalid/story","title":"Synthetic delayed preview","description":"A generated image arrives after this card is first laid out.","image":"https://assets.example.invalid/rich-history.png","favicon":"https://assets.example.invalid/icon.png","image_prop":["width":400,"height":200]]]])]
    }
}
#endif
