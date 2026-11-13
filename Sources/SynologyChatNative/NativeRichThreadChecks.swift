#if DEBUG
import AppKit
import SwiftUI
import Combine
import ImageIO

/// Isolated production thread/composer, synthetic seeded history, intercepted reads only.
@MainActor enum NativeRichThreadChecks {
    nonisolated static let host = "rich-thread-checks.invalid"
    private static let mainDraft = "Unsent synthetic main draft — retained exactly."
    private static let threadDraft = "Unsent synthetic thread draft."
    private static let multiline = (1...10).map { "Synthetic composer line \($0)" }.joined(separator:"\n")
    static func render(to directory:URL,inThread:Bool = true) async -> Bool {
        var stage = "prepare",samples:[[String:Any]] = [],checks:[String:Bool] = [:]
        do {
            guard !FileManager.default.fileExists(atPath:directory.path) else { return false }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            NSApplication.shared.setActivationPolicy(.prohibited)
            try ThreadFixtureProtocol.reset();ThreadFixtureProtocol.releaseOG()
            let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
                guard session.baseURL.scheme == "https",session.baseURL.host == host else { throw ChatAPIError.invalidResponse }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [ThreadFixtureProtocol.self];configuration.httpShouldSetCookies = false;configuration.urlCache = nil
                return try ChatAPIClient(session:session,network:URLSession(configuration:configuration))
            },downloadPreferences:.init(defaults:nil),emojiPreferences:.init(defaults:nil),notificationDefaults:nil)
            defer { ThreadFixtureProtocol.cancelPending();model.signOutLocally() }
            await model.connect(using:.init(session:.init(baseURL:URL(string:"https://"+host)!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic-thread",importedFromOfficialApp:false))
            guard model.connected,model.userID == 10 else { throw ChatAPIError.invalidResponse }
            model.suspendLiveForProbe();model.liveStatus = .live;model.selection = 23;model.error = nil
            let values = ThreadFixtureProtocol.seededPosts.map { value -> [String:Any] in
                var value = value;if !inThread { value["thread_id"] = 0 };return value
            }
            let seeded = try JSONDecoder().decode([ChatPost].self,from:JSONSerialization.data(withJSONObject:values))
            guard let root = seeded.first,root.id == 7000 else { throw ChatAPIError.invalidResponse }
            model.posts = inThread ? [root] : [];model.threadRoot = inThread ? root : nil
            model.loadingThread = false;model.canLoadOlderReplies = false
            model.draft = mainDraft;model.threadDrafts[root.id] = threadDraft
            defer { model.draft = mainDraft;model.threadDrafts[root.id] = threadDraft }
            @MainActor func setComposer(_ text:String) { if inThread { model.replyDraft = text } else { model.draft = text } }
            @MainActor func composerText()->String { inThread ? model.replyDraft : model.draft }
            @MainActor func displayedPosts()->[ChatPost] { inThread ? model.replies : model.posts.filter { $0.id != root.id } }
            let initialComposerDraft = inThread ? threadDraft : mainDraft
            let appearance = NativeAppearancePreferences(defaults:nil)
            let content:AnyView
            if inThread { content = AnyView(NativeThreadView(appearancePreferences:appearance,model:model)) }
            else { content = AnyView(NativeChatPreviewView(model:model,appearancePreferences:appearance)) }
            let hostView = NSHostingView(rootView:content.environment(\.nativeChatStyle,ChatAppearanceStyle.dark).preferredColorScheme(.dark))
            hostView.appearance = NSAppearance(named:.darkAqua)
            let size = inThread ? NSSize(width:640,height:680) : NSSize(width:1120,height:840)
            let window = NSWindow(contentRect:NSRect(origin:NSPoint(x:-10000,y:-10000),size:size),styleMask:[],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = hostView;hostView.frame = NSRect(origin:.zero,size:size)
            defer { window.contentView = nil;window.close() }
            try await settle(hostView,delay:50_000_000)
            // The actual production last-ID onChange now performs its initial jump.
            if inThread { model.replies = Array(seeded.dropFirst()) } else { model.posts = seeded }
            stage = "seeded-rich-asset-warmup"
            var threadScroll:NSScrollView?
            for _ in 0..<40 {
                try await settle(hostView,delay:25_000_000)
                threadScroll = scrolls(in:hostView).first(where:{ scroll in
                    guard let doc = scroll.documentView else { return false }
                    return scroll.contentView.bounds.width > 500 && !observers(in:doc).filter({ $0.enclosingScrollView === scroll }).isEmpty
                })
                if threadScroll != nil { break }
            }
            guard let scroll = threadScroll,let document = scroll.documentView else { throw ChatAPIError.invalidResponse }
            let scrollID = ObjectIdentifier(scroll),documentID = ObjectIdentifier(document),account = model.accountGeneration,token = model.historyViewportToken
            var decodedGIF = false,decodedPNG = false
            for (index,fraction) in [CGFloat(0),0.25,0.5,0.75,1].enumerated() {
                scroll.contentView.scroll(to:NSPoint(x:0,y:document.bounds.minY+max(0,document.bounds.height-scroll.contentView.bounds.height)*fraction))
                scroll.reflectScrolledClipView(scroll.contentView)
                for _ in 0..<12 { try await settle(hostView,delay:25_000_000) }
                let images = rasters(in:document).compactMap(\.image)
                decodedGIF = decodedGIF || images.contains(where:{ NativeInlineImagePreview.frameCount($0) == 2 })
                decodedPNG = decodedPNG || images.contains(where:{ NativeInlineImagePreview.frameCount($0) == 1 })
                samples.append(sample("warmup-\(index)",scroll:scroll,scrollID:scrollID,documentID:documentID))
                try capture(hostView,to:directory.appendingPathComponent("warmup-\(index).png"))
            }
            // Actual viewport traversal warms a real OG route before a cache-only probe.
            var warmupOGDecoded = ThreadFixtureProtocol.completed["og:image",default:0] > 0
            var warmupProbeAddedRequests = false
            if !warmupOGDecoded {
                for step in 0..<60 {
                    let maximum = document.bounds.minY+max(0,document.bounds.height-scroll.contentView.bounds.height)
                    let target = step == 0 ? document.bounds.minY : min(maximum,scroll.contentView.bounds.minY+scroll.contentView.bounds.height*0.8)
                    scroll.contentView.scroll(to:NSPoint(x:0,y:target));scroll.reflectScrolledClipView(scroll.contentView)
                    applyLayout(hostView);try await settle(hostView,delay:75_000_000)
                    let images = rasters(in:document).compactMap(\.image)
                    decodedGIF = decodedGIF || images.contains(where:{ NativeInlineImagePreview.frameCount($0) == 2 })
                    decodedPNG = decodedPNG || images.contains(where:{ NativeInlineImagePreview.frameCount($0) == 1 })
                    samples.append(sample("sequential-asset-warmup-\(step)",scroll:scroll,scrollID:scrollID,documentID:documentID))
                    if step == 0 { try capture(hostView,to:directory.appendingPathComponent("sequential-asset-warmup-start.png")) }
                    if let post = displayedPosts().first(where:{ ThreadFixtureProtocol.completed["og:image:"+String($0.id),default:0] > 0 }),let preview = model.linkPreviews(for:post).first {
                        let reads = ThreadFixtureProtocol.requested
                        let decoded = await model.linkPreviewImage(for:post,preview:preview.preview)
                        warmupProbeAddedRequests = ThreadFixtureProtocol.requested != reads
                        warmupOGDecoded = decoded.map { $0.size.width > 0 && $0.size.height > 0 } ?? false
                        try capture(hostView,to:directory.appendingPathComponent("sequential-asset-warmup-og.png"));break
                    }
                }
            }
            // Establish latest through production navigation, never repeated raw bottom offsets.
            // Reseeding is synthetic initialization, not API/pagination acceptance.
            stage = "production-baseline-navigation"
            let baselineStarted = ProcessInfo.processInfo.systemUptime
            let revisionBeforeBaseline = model.historyScrollRevision
            if inThread {
                model.replies = [];model.loadingThread = true
                applyLayout(hostView);try await settle(hostView,delay:50_000_000)
                model.replies = Array(seeded.dropFirst());model.loadingThread = false
            } else { model.scrollPostID = 7060 }
            applyLayout(hostView)
            var baselineTrace:[[String:Any]] = []
            for attempt in 0..<40 {
                try await settle(hostView,delay:25_000_000)
                let latest = latestVisible(in:scroll),actualBottom = bottom(scroll),cachedBottom = observerCachedBottom(scroll)
                baselineTrace.append(["attempt":attempt,"elapsed_ms":(ProcessInfo.processInfo.systemUptime-baselineStarted)*1000,
                    "latest_visible":latest,"actual_bottom":actualBottom,"observer_cached_bottom":cachedBottom,
                    "clip_bounds":rect(scroll.contentView.bounds),"document_bounds":rect(document.bounds),
                    "observer_callback_counts":observers(in:document).filter({ $0.enclosingScrollView === scroll }).map(\.debugResizeCallbackCount)])
                if latest && actualBottom && cachedBottom { break }
            }
            let baselineHeight = scroll.contentView.bounds.height
            var baseline = sample("single-line-baseline",scroll:scroll,scrollID:scrollID,documentID:documentID)
            baseline["initialization_mode"] = inThread ? "seeded-replies-reset-production-last-ID-onChange" : "production-scrollPostID-7060"
            baseline["seeded_reinitialization_not_pagination"] = inThread
            baseline["baseline_navigation_wait_trace"] = baselineTrace
            baseline["baseline_resolved"] = latestVisible(in:scroll) && bottom(scroll) && observerCachedBottom(scroll)
            baseline["history_scroll_revision_before"] = revisionBeforeBaseline.uuidString
            baseline["history_scroll_revision_after"] = model.historyScrollRevision.uuidString
            baseline["composer_draft_exact"] = composerText() == initialComposerDraft;samples.append(baseline)
            try capture(hostView,to:directory.appendingPathComponent("single-line-baseline.png"))
            stage = inThread ? "actual-thread-composer-resize" : "actual-main-composer-resize"
            for (phase,text) in [("multiline",multiline),("single-line-restored",initialComposerDraft)] {
                let inputTime = ProcessInfo.processInfo.systemUptime
                let beforeInputHeight = scroll.contentView.bounds.height
                setComposer(text);applyLayout(hostView)
                var inputSample = sample("composer-input-"+phase,scroll:scroll,scrollID:scrollID,documentID:documentID)
                inputSample["input_elapsed_ms"] = (ProcessInfo.processInfo.systemUptime-inputTime)*1000
                inputSample["viewport_height_before_input"] = beforeInputHeight
                inputSample["viewport_height_after_immediate_layout"] = scroll.contentView.bounds.height
                samples.append(inputSample)
                for (label,delay) in [("100ms",UInt64(100_000_000)),("200ms",UInt64(100_000_000)),("1sec",UInt64(800_000_000))] {
                    try await Task.sleep(nanoseconds:delay)
                    let beforeLayoutHeight = scroll.contentView.bounds.height
                    applyLayout(hostView)
                    var observation = sample(phase+"-"+label,scroll:scroll,scrollID:scrollID,documentID:documentID)
                    observation["input_elapsed_ms"] = (ProcessInfo.processInfo.systemUptime-inputTime)*1000
                    observation["viewport_height_before_sample_layout"] = beforeLayoutHeight
                    observation["viewport_height_after_sample_layout"] = scroll.contentView.bounds.height
                    observation["viewport_changed_during_sample_layout"] = abs(beforeLayoutHeight-scroll.contentView.bounds.height) > 0.1
                    observation["composer_draft_exact"] = composerText() == text
                    observation["main_draft_exact"] = model.draft == (inThread ? mainDraft : text)
                    observation["thread_draft_exact"] = model.threadDrafts[root.id] == (inThread ? text : threadDraft)
                    samples.append(observation)
                    try capture(hostView,to:directory.appendingPathComponent(phase+"-"+label+".png"))
                }
            }
            stage = "user-scrollback-composer-resize"
            // Main uses its actual message-navigation path; thread retains isolated
            // clip input. Neither path claims physical wheel/trackpad acceptance.
            if inThread {
                scroll.contentView.scroll(to:NSPoint(x:0,y:document.bounds.minY+max(0,document.bounds.height-scroll.contentView.bounds.height)*0.3))
                scroll.reflectScrolledClipView(scroll.contentView)
            } else { model.scrollPostID = 7027 }
            try await settle(hostView,delay:200_000_000)
            func mainReaderVisible()->Bool {
                inThread || rowMarkers(in:document).contains { marker in
                    marker.postID == 7027 && marker.token == token && marker.convert(marker.bounds,to:document).intersection(scroll.documentVisibleRect).height >= 20
                }
            }
            let scrollbackStarted = !bottom(scroll) && !latestVisible(in:scroll) && mainReaderVisible()
            let scrollbackY = scroll.contentView.bounds.minY
            var scrollbackBaseline = sample("scrollback-before",scroll:scroll,scrollID:scrollID,documentID:documentID)
            scrollbackBaseline["input"] = inThread ? "isolated-direct-clip" : "production-scrollPostID-7027"
            scrollbackBaseline["away_from_latest_precondition"] = scrollbackStarted
            scrollbackBaseline["main_reference_post_visible"] = mainReaderVisible();samples.append(scrollbackBaseline)
            for (phase,text) in [("scrollback-multiline",multiline),("scrollback-restored",initialComposerDraft)] {
                let inputTime = ProcessInfo.processInfo.systemUptime
                let beforeInputHeight = scroll.contentView.bounds.height
                setComposer(text);applyLayout(hostView)
                var inputSample = sample("composer-input-"+phase,scroll:scroll,scrollID:scrollID,documentID:documentID)
                inputSample["input_elapsed_ms"] = (ProcessInfo.processInfo.systemUptime-inputTime)*1000
                inputSample["viewport_height_before_input"] = beforeInputHeight
                inputSample["viewport_height_after_immediate_layout"] = scroll.contentView.bounds.height
                samples.append(inputSample)
                for (label,delay) in [("100ms",UInt64(100_000_000)),("200ms",UInt64(100_000_000)),("1sec",UInt64(800_000_000))] {
                    try await Task.sleep(nanoseconds:delay)
                    let beforeLayoutHeight = scroll.contentView.bounds.height
                    applyLayout(hostView)
                    var observation = sample(phase+"-"+label,scroll:scroll,scrollID:scrollID,documentID:documentID)
                    observation["input_elapsed_ms"] = (ProcessInfo.processInfo.systemUptime-inputTime)*1000
                    observation["viewport_height_before_sample_layout"] = beforeLayoutHeight
                    observation["viewport_height_after_sample_layout"] = scroll.contentView.bounds.height
                    observation["viewport_changed_during_sample_layout"] = abs(beforeLayoutHeight-scroll.contentView.bounds.height) > 0.1
                    observation["not_forced_latest"] = !bottom(scroll) && !latestVisible(in:scroll)
                    observation["scrollback_origin_delta"] = scroll.contentView.bounds.minY-scrollbackY
                    observation["main_reference_post_visible"] = mainReaderVisible()
                    samples.append(observation)
                    try capture(hostView,to:directory.appendingPathComponent(phase+"-"+label+".png"))
                }
            }
            var arrivalValue = values[0]
            arrivalValue["post_id"] = 7061;arrivalValue["creator_id"] = 20
            arrivalValue["thread_id"] = inThread ? 7000 : 0
            arrivalValue["message"] = "Synthetic incoming update while reading earlier messages"
            arrivalValue["create_at"] = Int64(1_794_481_200_000)+61*60_000
            let arrival = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:arrivalValue))
            var arrivalRetained = true
            for appended in [true,false] {
                if inThread {
                    if appended { model.replies.append(arrival) } else { model.replies.removeAll { $0.id == arrival.id } }
                } else {
                    if appended { model.posts.append(arrival) } else { model.posts.removeAll { $0.id == arrival.id } }
                }
                try await settle(hostView,delay:100_000_000)
                let retained = !bottom(scroll) && !latestVisible(in:scroll) && mainReaderVisible()
                arrivalRetained = arrivalRetained && retained
                let phase = appended ? "scrollback-incoming-added" : "scrollback-incoming-removed"
                var observation = sample(phase,scroll:scroll,scrollID:scrollID,documentID:documentID)
                observation["not_forced_latest"] = retained;observation["main_reference_post_visible"] = mainReaderVisible()
                samples.append(observation);try capture(hostView,to:directory.appendingPathComponent(phase+".png"))
            }
            setComposer(initialComposerDraft)
            let resize = samples.filter { ($0["phase"] as? String ?? "").hasPrefix("multiline-") || ($0["phase"] as? String ?? "").hasPrefix("single-line-restored-") }
            let scrollback = samples.filter { ($0["phase"] as? String ?? "").hasPrefix("scrollback-multiline-") || ($0["phase"] as? String ?? "").hasPrefix("scrollback-restored-") }
            let heights = resize.filter { ($0["phase"] as? String ?? "").hasPrefix("multiline-") }.compactMap { ($0["clip_bounds"] as? [String:CGFloat])?["height"] }
            checks = ["seeded_ids_exact":displayedPosts().map(\.id) == Array(Int64(7001)...7060),"root_exact":inThread ? model.threadRoot?.id == 7000 : model.threadRoot == nil && model.posts.first?.id == 7000,
                "ordinary_main_posts":inThread || model.posts.allSatisfy({ $0.thread_id == 0 }),
                "main_draft_retained":model.draft == mainDraft,"thread_draft_restored":model.threadDrafts[root.id] == threadDraft,
                "same_account_viewport":model.connected && model.userID == 10 && model.accountGeneration == account && model.historyViewportToken == token,
                "restored_single_line_viewport":resize.filter({ ($0["phase"] as? String ?? "").hasPrefix("single-line-restored-") }).allSatisfy({ abs((($0["clip_bounds"] as? [String:CGFloat])?["height"] ?? -1)-baselineHeight) <= 1 }),
                "actual_composer_reduced_viewport":heights.count == 3 && heights.allSatisfy({ baselineHeight-$0 >= 20 }),
                "baseline_latest_visible_bottom":baseline["latest_visible"] as? Bool == true && baseline["at_bottom"] as? Bool == true && baseline["observer_cached_bottom"] as? Bool == true,
                "sequential_warmup_og_decoded":warmupOGDecoded,"warmup_cache_probe_no_new_request":!warmupProbeAddedRequests,
                "latest_visible_bottom_after_resize":resize.allSatisfy({ $0["latest_visible"] as? Bool == true && $0["at_bottom"] as? Bool == true }),
                "scrollback_started_away_from_latest":scrollbackStarted,
                "scrollback_main_reference_retained":scrollback.allSatisfy { $0["main_reference_post_visible"] as? Bool == true },
                "scrollback_incoming_update_retained":arrivalRetained,
                "scrollback_not_forced_latest":scrollback.count == 6 && scrollback.allSatisfy({ $0["not_forced_latest"] as? Bool == true }),
                "stable_scroll_document":samples.allSatisfy({ $0["identity_stable"] as? Bool == true }),
                "finite_geometry":samples.allSatisfy({ $0["finite_geometry"] as? Bool == true }),
                "decoded_png":decodedPNG,"decoded_two_frame_gif":decodedGIF,
                "og_completed":ThreadFixtureProtocol.completed["og:image",default:0] > 0,
                "six_polls_decoded":displayedPosts().filter({ $0.props?.vote?.choices.count == 2 }).count == 6,
                "no_model_error":model.error == nil,"zero_writes":ThreadFixtureProtocol.deniedWrites == 0,
                "no_unknown_reads":ThreadFixtureProtocol.unknownReads.isEmpty,"runtime_denied_once":ThreadFixtureProtocol.deniedRuntime == 1,"hidden_window":!window.isVisible]
            let beforeProbe = ThreadFixtureProtocol.requested
            guard let ogPost = displayedPosts().reversed().first(where:{ ThreadFixtureProtocol.completed["og:image:"+String($0.id),default:0] > 0 }),
                  let preview = model.linkPreviews(for:ogPost).first,
                  let ogImage = await model.linkPreviewImage(for:ogPost,preview:preview.preview) else { throw ChatAPIError.invalidResponse }
            checks["og_cached_and_decoded"] = ogImage.size.width > 0 && ogImage.size.height > 0 && ThreadFixtureProtocol.requested == beforeProbe
            guard let latestPost = displayedPosts().last,let image = await model.thumbnail(for:latestPost) else { throw ChatAPIError.invalidResponse }
            checks["latest_cached_decoded_unique_asset"] = image.size == NSSize(width:80,height:40) && ThreadFixtureProtocol.requested == beforeProbe
            guard checks.values.allSatisfy({ $0 }) else { throw ChatAPIError.invalidResponse }
            try record(["synthetic_only":true,"normal_startup":false,"seeded_history":true,"pagination_verified":false,"writes":0,
                "composer_mode":inThread ? "thread" : "main","host_size":[size.width,size.height],"root_id":7000,"post_ids":displayedPosts().map(\.id),"checks":checks,"samples":samples,"requests":ThreadFixtureProtocol.requested,"completed":ThreadFixtureProtocol.completed,
                "latest_attribution":"Only post7060 has generated80x40PNG; actual decoded raster intersects viewport", "H4_reproduced":false,
                "limits":"DEBUG hidden \(inThread ? "NativeThreadView" : "NativeChatPreviewView"); synthetic seeded60rows, main production message navigation/thread direct-clip scrollback and model-bound composer/incoming-array changes. Main reference7027 marker and unique latest raster/geometry/captured content; no per-text-row thread markers, physical input, live NAS, actual socket, optimized app or pagination acceptance."],to:directory.appendingPathComponent("result.json"))
            return true
        } catch {
            try? record(["status":"failed","composer_mode":inThread ? "thread" : "main","stage":stage,"synthetic_only":true,"seeded_history":true,"checks":checks,"samples":samples,
                "requests":ThreadFixtureProtocol.requested,"completed":ThreadFixtureProtocol.completed,"unknown_reads":ThreadFixtureProtocol.unknownReads,"writes":ThreadFixtureProtocol.deniedWrites],to:directory.appendingPathComponent("failure.json"))
            return false
        }
    }
    private static func sample(_ phase:String,scroll:NSScrollView,scrollID:ObjectIdentifier,documentID:ObjectIdentifier)->[String:Any] {
        guard let document = scroll.documentView else { return ["phase":phase,"document_missing":true] }
        let images = rasters(in:document).compactMap { raster -> [String:Any]? in
            let frame = raster.convert(raster.bounds,to:document)
            guard let image = raster.image,frame.intersects(scroll.documentVisibleRect) else { return nil }
            return ["frame":rect(frame),"decoded_size":[image.size.width,image.size.height],"frames":NativeInlineImagePreview.frameCount(image)]
        }
        return ["phase":phase,"clip_bounds":rect(scroll.contentView.bounds),"document_bounds":rect(document.bounds),"at_bottom":bottom(scroll),
            "latest_visible":latestVisible(in:scroll),"observer_cached_bottom":observerCachedBottom(scroll),"visible_decoded_rasters":images,
            "identity_stable":ObjectIdentifier(scroll) == scrollID && ObjectIdentifier(document) == documentID,
            "finite_geometry":[scroll.contentView.bounds.minY,scroll.contentView.bounds.width,scroll.contentView.bounds.height,document.bounds.width,document.bounds.height].allSatisfy(\.isFinite) && scroll.contentView.bounds.width > 0 && scroll.contentView.bounds.height > 0 && document.bounds.width > 0 && document.bounds.height > 0,
            "resize_observers":observers(in:document).filter({ $0.enclosingScrollView === scroll }).map { ["observer_identity":String(describing:ObjectIdentifier($0)),"callbacks":$0.debugResizeCallbackCount,"state":$0.debugResizeState,"events":$0.debugResizeEvents] as [String:Any] }]
    }
    /// Private editor-state seed in the actual whole thread. This exercises
    /// native editing continuity, never edit-menu authorization or API saving.
    static func renderVirtualThreadEditor(to directory:URL) async -> Bool {
        var stage = "prepare-virtual-thread-editor",samples:[[String:Any]] = [],checks:[String:Bool] = [:]
        do {
            guard !FileManager.default.fileExists(atPath:directory.path) else { return false }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            NSApplication.shared.setActivationPolicy(.prohibited)
            try ThreadFixtureProtocol.reset();ThreadFixtureProtocol.virtualViewportMode = true;ThreadFixtureProtocol.releaseOG()
            let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
                guard session.baseURL.scheme == "https",session.baseURL.host == host else { throw ChatAPIError.invalidResponse }
                let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ThreadFixtureProtocol.self]
                config.httpShouldSetCookies = false;config.urlCache = nil
                return try ChatAPIClient(session:session,network:URLSession(configuration:config))
            },downloadPreferences:.init(defaults:nil),emojiPreferences:.init(defaults:nil),notificationDefaults:nil)
            defer { ThreadFixtureProtocol.cancelPending();model.signOutLocally();ThreadFixtureProtocol.virtualViewportMode = false }
            await model.connect(using:.init(session:.init(baseURL:URL(string:"https://"+host)!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic-thread",importedFromOfficialApp:false))
            guard model.connected,model.userID == 10 else { throw ChatAPIError.invalidResponse }
            model.suspendLiveForProbe();model.liveStatus = .live;model.selection = 23;model.error = nil
            let root = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:ThreadFixtureProtocol.virtualPosts[0]))
            model.posts = [root];model.draft = mainDraft;model.threadDrafts[7000] = threadDraft
            defer { model.draft = mainDraft;model.threadDrafts[7000] = threadDraft }
            stage = "actual-editor-thread-first-page"
            await model.openThread(root)
            guard model.replies.map(\.id) == Array(Int64(7091)...7120),ThreadFixtureProtocol.threadPageCursors == ["latest"],
                  let own = model.replies.first(where:{ $0.id == 7104 }),own.creator_id == model.userID,own.type == "normal" else { throw ChatAPIError.invalidResponse }
            let original = model.messageText(own),owner = UUID(),account = model.accountGeneration,token = model.nativeThreadViewportToken,mainToken = model.historyViewportToken
            model.nativeThreadScrollPostID = own.id;model.beginMessageEditing(owner:owner)
            defer { model.endMessageEditing(owner:owner) }
            let content = NativeThreadView(appearancePreferences:NativeAppearancePreferences(defaults:nil),model:model).usingNativeVirtualTimeline(fixtureEditors:[7104:.init(owner:owner,text:original)])
            let view = NSHostingView(rootView:content.environment(\.nativeChatStyle,ChatAppearanceStyle.dark).preferredColorScheme(.dark))
            view.appearance = NSAppearance(named:.darkAqua)
            let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:640,height:680),styleMask:[],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = view
            defer { window.contentView = nil;window.close() }
            var candidate:NSScrollView?
            for _ in 0..<40 {
                try await settle(view,delay:20_000_000)
                candidate = scrolls(in:view).first { $0.documentView is NativeVirtualTimeline.Document && $0.documentView?.identifier?.rawValue == "native-virtual-timeline" }
                if candidate != nil { break }
            }
            guard let scroll = candidate,let document = scroll.documentView as? NativeVirtualTimeline.Document else { throw ChatAPIError.invalidResponse }
            let scrollID = ObjectIdentifier(scroll),documentID = ObjectIdentifier(document),tolerance = 1/max(1,window.backingScaleFactor)
            @MainActor func editorCandidates()->[NSTextView] {
                guard let index = document.canonicalRows.firstIndex(of:.post(7104)),let cell = document.hostedView(forRow:index) as? NativeVirtualTimeline.Cell else { return [] }
                return editableThreadTexts(in:cell)
            }
            @MainActor func currentScope()->Bool {
                virtualThreadScope(document:document,model:model,account:account,token:token) && model.historyViewportToken == mainToken
                    && ObjectIdentifier(scroll) == scrollID && ObjectIdentifier(document) == documentID
            }
            for _ in 0..<40 {
                if editorCandidates().count == 1 { break }
                try await settle(view,delay:20_000_000)
            }
            guard editorCandidates().count == 1,let editor = editorCandidates().first,editor.string == original,editor.allowsUndo,
                  let undo = editor.undoManager,window.makeFirstResponder(editor) else { throw ChatAPIError.invalidResponse }
            model.nativeThreadScrollPostID = nil;model.objectWillChange.send()
            try await settle(view,delay:100_000_000)
            stage = "actual-native-thread-editor-input"
            let groupsByEvent = undo.groupsByEvent
            undo.groupsByEvent = false
            while undo.groupingLevel > 0 { undo.endUndoGrouping() }
            undo.removeAllActions()
            defer { undo.groupsByEvent = groupsByEvent }
            let suffix = " e\u{301} 🧪"
            editor.setSelectedRange(NSRange(location:original.utf16.count,length:0))
            editor.breakUndoCoalescing();undo.beginUndoGrouping();editor.insertText(suffix,replacementRange:editor.selectedRange());undo.endUndoGrouping();editor.breakUndoCoalescing()
            let expected = original+suffix,selection = NSRange(location:original.utf16.count+1,length:2)
            editor.setSelectedRange(selection)
            try await settle(view,delay:100_000_000)
            @MainActor func geometry(_ phase:String)->[String:Any]? {
                guard let index = document.canonicalRows.firstIndex(of:.post(7104)),let cell = document.hostedView(forRow:index) as? NativeVirtualTimeline.Cell,
                      editor.isDescendant(of:cell),cell.host != nil else { return nil }
                let committed = document.rect(ofRow:index),actual = cell.convert(cell.bounds,to:document),text = editor.convert(editor.bounds,to:document),clip = scroll.documentVisibleRect
                return ["phase":phase,"canonical_row":rect(committed),"actual_cell":rect(actual),"actual_text":rect(text),"clip_bounds":rect(clip),
                        "committed_offset":committed.minY-clip.minY,"actual_text_offset":text.minY-clip.minY,"actual_cell_matches_canonical":abs(actual.minY-committed.minY) <= tolerance && abs(actual.height-committed.height) <= tolerance,
                        "editor_identity":String(describing:ObjectIdentifier(editor)),"undo_identity":String(describing:ObjectIdentifier(undo)),"selection":["location":editor.selectedRange().location,"length":editor.selectedRange().length],"diagnostics":document.debugDiagnostics]
            }
            guard Data(editor.string.utf8) == Data(expected.utf8),editor.selectedRange() == selection,window.firstResponder === editor,undo.canUndo,
                  let baseline = geometry("thread-editor-before-paging"),let rowOffset = baseline["committed_offset"] as? CGFloat,let textOffset = baseline["actual_text_offset"] as? CGFloat,
                  baseline["actual_cell_matches_canonical"] as? Bool == true,currentScope() else { throw ChatAPIError.invalidResponse }
            checks["native_thread_editor_seed_and_actual_input"] = true
            checks["actual_open_thread_first30"] = model.replies.map(\.id) == Array(Int64(7091)...7120)
            samples.append(baseline);try capture(scroll,to:directory.appendingPathComponent("thread-editor-before-paging.png"))
            for (page,first) in [7061,7031,7001].enumerated() {
                stage = "thread-editor-actual-older-page-\(page+1)"
                let started = ProcessInfo.processInfo.systemUptime
                await model.loadOlderReplies()
                for (label,delay) in [("100ms",UInt64(100_000_000)),("200ms",UInt64(100_000_000)),("1sec",UInt64(800_000_000))] {
                    try await settle(view,delay:delay)
                    let phase = "thread-editor-page-\(page+1)-"+label
                    guard var sample = geometry(phase) else { throw ChatAPIError.invalidResponse }
                    let rowAfter = sample["committed_offset"] as? CGFloat,textAfter = sample["actual_text_offset"] as? CGFloat
                    let same = editorCandidates().count == 1 && editorCandidates().first === editor && window.firstResponder === editor
                        && Data(editor.string.utf8) == Data(expected.utf8) && editor.selectedRange() == selection && editor.undoManager === undo && undo.canUndo && model.activeMessageEditor == owner
                    let retained = rowAfter.map { abs($0-rowOffset) <= tolerance } == true && textAfter.map { abs($0-textOffset) <= tolerance } == true && sample["actual_cell_matches_canonical"] as? Bool == true
                    let exact = model.replies.map(\.id) == Array(Int64(first)...7120) && model.replies.allSatisfy { $0.thread_id == 7000 && $0.id != 7000 }
                    let scope = currentScope() && model.posts.map(\.id) == [7000] && model.draft == mainDraft && model.replyDraft == threadDraft
                        && model.replies.first(where:{ $0.id == 7104 }).map { Data(model.messageText($0).utf8) == Data(original.utf8) } == true
                    let safe = document.debugDiagnostics["host_order_is_canonical"] as? Bool == true && (document.debugDiagnostics["max_hosted_cells"] as? Int).map { $0 > 0 && $0 <= 32 } == true
                        && !window.isVisible && model.error == nil && ThreadFixtureProtocol.deniedWrites == 0 && ThreadFixtureProtocol.unknownReads.isEmpty
                    checks[phase+"-same-editor-focus-content-selection-undo-owner"] = same
                    checks[phase+"-actual-and-committed-offset-one-pixel"] = retained
                    checks[phase+"-actual-page-ids-exact"] = exact
                    checks[phase+"-scope-canonical-and-drafts"] = scope
                    checks[phase+"-hidden-order-host-bound-zero-writes"] = safe
                    sample["elapsed_ms"] = (ProcessInfo.processInfo.systemUptime-started)*1000
                    sample["baseline_committed_offset"] = rowOffset;sample["baseline_actual_text_offset"] = textOffset
                    sample["committed_offset_delta"] = rowAfter.map { ($0-rowOffset) as Any } ?? NSNull();sample["actual_text_offset_delta"] = textAfter.map { ($0-textOffset) as Any } ?? NSNull()
                    sample["reply_count"] = model.replies.count;sample["thread_page_cursors"] = ThreadFixtureProtocol.threadPageCursors;sample["viewport_png"] = phase+".png"
                    samples.append(sample);try capture(scroll,to:directory.appendingPathComponent(phase+".png"))
                    guard same,retained,exact,scope,safe else { throw ChatAPIError.invalidResponse }
                }
            }
            checks["exact_four_thread_page_cursors"] = ThreadFixtureProtocol.threadPageCursors == ["latest","7091","7061","7031"]
            checks["exact120_reply_ids"] = model.replies.map(\.id) == Array(Int64(7001)...7120)
            stage = "actual-thread-editor-undo-redo"
            @MainActor func checkpoint(_ name:String) throws {
                try record(["synthetic_only":true,"stage":stage,"checks":checks,"samples":samples,
                            "grouping_level":undo.groupingLevel,"can_undo":undo.canUndo,"can_redo":undo.canRedo,
                            "reply_count":model.replies.count],to:directory.appendingPathComponent("checkpoint-"+name+".json"))
            }
            try checkpoint("before-undo")
            undo.undo();try checkpoint("undo-returned");try await settle(view,delay:100_000_000)
            try checkpoint("undo-settled")
            checks["actual_native_undo_original"] = editorCandidates().first === editor && Data(editor.string.utf8) == Data(original.utf8) && editor.undoManager === undo && undo.canRedo
            if let sample = geometry("thread-editor-after-undo") { samples.append(sample) }
            try checkpoint("before-redo")
            undo.redo();try checkpoint("redo-returned");try await settle(view,delay:100_000_000)
            try checkpoint("redo-settled")
            checks["actual_native_redo_unsaved"] = editorCandidates().first === editor && Data(editor.string.utf8) == Data(expected.utf8) && editor.undoManager === undo && undo.canUndo
            if let sample = geometry("thread-editor-after-redo") { samples.append(sample) }
            guard checks["actual_native_undo_original"] == true,checks["actual_native_redo_unsaved"] == true else { throw ChatAPIError.invalidResponse }
            stage = "native-marked-text-neighbor-update"
            guard let priorIndex = model.replies.firstIndex(where:{ $0.id == 7103 }),var changed = ThreadFixtureProtocol.virtualPosts.first(where:{ $0["post_id"] as? Int == 7103 }) else { throw ChatAPIError.invalidResponse }
            let savedPrior = model.replies[priorIndex]
            changed["message"] = "Synthetic predecessor content changed for native thread editor identity and composition continuity."
            let replacement = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:changed))
            try checkpoint("before-marked-text")
            // This fixture disables event grouping for deterministic undo above.
            // Composition is another native text mutation and needs its own group.
            undo.beginUndoGrouping()
            defer { while undo.groupingLevel > 0 { undo.endUndoGrouping() } }
            editor.setSelectedRange(NSRange(location:0,length:0));editor.setMarkedText("にほ",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:0,length:0))
            try checkpoint("marked-text-returned")
            try await settle(view,delay:50_000_000)
            let marked = editor.markedRange(),markedSelection = editor.selectedRange(),markedContent = Data(editor.string.utf8)
            guard editor.hasMarkedText() else { throw ChatAPIError.invalidResponse }
            model.replies[priorIndex] = replacement
            try await settle(view,delay:100_000_000)
            checks["marked_text_neighbor_refresh_same_editor"] = editorCandidates().count == 1 && editorCandidates().first === editor && window.firstResponder === editor && editor.undoManager === undo && model.activeMessageEditor == owner
            checks["marked_text_range_selection_content_retained"] = editor.hasMarkedText() && editor.markedRange() == marked && editor.selectedRange() == markedSelection && Data(editor.string.utf8) == markedContent
            checks["marked_text_canonical_and_drafts_unchanged"] = model.replies.first(where:{ $0.id == 7104 }).map { Data(model.messageText($0).utf8) == Data(original.utf8) } == true && model.draft == mainDraft && model.replyDraft == threadDraft
            if var sample = geometry("thread-editor-marked-neighbor-refresh") { sample["marked_range"] = ["location":editor.markedRange().location,"length":editor.markedRange().length];samples.append(sample) }
            try capture(scroll,to:directory.appendingPathComponent("thread-editor-marked-neighbor-refresh.png"))
            editor.unmarkText();undo.endUndoGrouping();model.replies[priorIndex] = savedPrior
            try await settle(view,delay:50_000_000)
            guard checks["marked_text_neighbor_refresh_same_editor"] == true,checks["marked_text_range_selection_content_retained"] == true,checks["marked_text_canonical_and_drafts_unchanged"] == true else { throw ChatAPIError.invalidResponse }
            checks["final_editor_retained_after_predecessor_restore"] = model.activeMessageEditor == owner && editorCandidates().count == 1 && editorCandidates().first === editor && window.firstResponder === editor && editor.undoManager === undo
            checks["final_scope_and_safety"] = currentScope() && document.debugDiagnostics["host_order_is_canonical"] as? Bool == true && (document.debugDiagnostics["max_hosted_cells"] as? Int).map { $0 > 0 && $0 <= 32 } == true
                && model.posts.map(\.id) == [7000] && model.draft == mainDraft && model.replyDraft == threadDraft && model.error == nil && !window.isVisible && ThreadFixtureProtocol.deniedWrites == 0 && ThreadFixtureProtocol.unknownReads.isEmpty
            checks["runtime_denied_once"] = ThreadFixtureProtocol.deniedRuntime == 1
            let result:[String:Any] = ["synthetic_only":true,"prototype_only":true,"private_seed_not_edit_authorization":true,"checks":checks,"samples":samples,"reply_ids":model.replies.map(\.id),"root_id":7000,"edited_reply_id":7104,"thread_page_cursors":ThreadFixtureProtocol.threadPageCursors,"requests":ThreadFixtureProtocol.requested,"completed":ThreadFixtureProtocol.completed,"unknown_reads":ThreadFixtureProtocol.unknownReads,"writes":ThreadFixtureProtocol.deniedWrites,
                "limits":"Whole hidden virtual thread, fixed footer composer, actual4page API path and native editor continuity/undo/marked-text API only. No edit-menu/auth/save/updatePost, physical IME, official comparison or adoption claim." ]
            guard checks.values.allSatisfy({ $0 }) else { try record(result,to:directory.appendingPathComponent("failure.json"));return false }
            try capture(view,to:directory.appendingPathComponent("whole-thread-editor-final.png"));try record(result,to:directory.appendingPathComponent("result.json"));return true
        } catch {
            try? record(["synthetic_only":true,"prototype_only":true,"private_seed_not_edit_authorization":true,"stage":stage,"error":String(describing:error),"checks":checks,"samples":samples,"thread_page_cursors":ThreadFixtureProtocol.threadPageCursors,"requests":ThreadFixtureProtocol.requested,"completed":ThreadFixtureProtocol.completed,"unknown_reads":ThreadFixtureProtocol.unknownReads,"writes":ThreadFixtureProtocol.deniedWrites],to:directory.appendingPathComponent("failure.json"))
            return false
        }
    }
    private static func editableThreadTexts(in view:NSView)->[NSTextView] {
        let own = (view as? NSTextView).map { $0.isEditable && !$0.isFieldEditor ? [$0] : [] } ?? []
        return own+view.subviews.flatMap { editableThreadTexts(in:$0) }
    }
    /// Whole main preview with the default sixty-reply synthetic asset set
    /// remapped to ordinary posts. Separate from the legacy renderer above.
    static func renderVirtualMainComposer(to directory:URL) async -> Bool {
        var stage = "prepare-virtual-main-composer",samples:[[String:Any]] = [],checks:[String:Bool] = [:]
        do {
            guard !FileManager.default.fileExists(atPath:directory.path) else { return false }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            NSApplication.shared.setActivationPolicy(.prohibited)
            try ThreadFixtureProtocol.reset();ThreadFixtureProtocol.releaseOG()
            let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
                guard session.baseURL.scheme == "https",session.baseURL.host == host else { throw ChatAPIError.invalidResponse }
                let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ThreadFixtureProtocol.self]
                config.httpShouldSetCookies = false;config.urlCache = nil
                return try ChatAPIClient(session:session,network:URLSession(configuration:config))
            },downloadPreferences:.init(defaults:nil),emojiPreferences:.init(defaults:nil),notificationDefaults:nil)
            defer { ThreadFixtureProtocol.cancelPending();model.signOutLocally() }
            await model.connect(using:.init(session:.init(baseURL:URL(string:"https://"+host)!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic-thread",importedFromOfficialApp:false))
            guard model.connected,model.userID == 10 else { throw ChatAPIError.invalidResponse }
            model.suspendLiveForProbe();model.liveStatus = .live;model.selection = 23;model.error = nil
            let values = ThreadFixtureProtocol.seededPosts.map { value -> [String:Any] in var value = value;value["thread_id"] = 0;return value }
            model.posts = try JSONDecoder().decode([ChatPost].self,from:JSONSerialization.data(withJSONObject:values))
            model.threadRoot = nil;model.replies = [];model.loadingHistory = false;model.canLoadOlder = false
            model.draft = mainDraft;model.threadDrafts[7000] = threadDraft
            defer { model.draft = mainDraft;model.threadDrafts[7000] = threadDraft }
            let account = model.accountGeneration,token = model.historyViewportToken
            let content = NativeChatPreviewView(model:model,appearancePreferences:NativeAppearancePreferences(defaults:nil)).usingNativeVirtualTimeline(automaticallySizesComposer:true)
            let view = NSHostingView(rootView:content.environment(\.nativeChatStyle,ChatAppearanceStyle.dark).preferredColorScheme(.dark))
            view.appearance = NSAppearance(named:.darkAqua)
            let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:1120,height:840),styleMask:[],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = view
            defer { window.contentView = nil;window.close() }
            var candidate:NSScrollView?
            for _ in 0..<40 {
                try await settle(view,delay:20_000_000)
                candidate = scrolls(in:view).first { $0.documentView is NativeVirtualTimeline.Document && $0.documentView?.identifier?.rawValue == "native-virtual-timeline" }
                if candidate != nil { break }
            }
            guard let scroll = candidate,let document = scroll.documentView as? NativeVirtualTimeline.Document else { throw ChatAPIError.invalidResponse }
            let scrollID = ObjectIdentifier(scroll),documentID = ObjectIdentifier(document),tolerance = 1/max(1,window.backingScaleFactor)
            @MainActor func scopeCurrent()->Bool {
                let data = document.debugDiagnostics
                return model.accountGeneration == account && model.historyViewportToken == token && model.selection == 23 && model.threadRoot == nil
                    && data["account"] as? Int == account && data["channel"] as? String == "23" && data["token"] as? String == token.uuidString
                    && data["root_id"] as? String == "nil" && data["in_thread"] as? Bool == false
                    && ObjectIdentifier(scroll) == scrollID && ObjectIdentifier(document) == documentID
            }
            @MainActor func visiblePost(_ id:Int64)->Bool {
                guard let index = document.canonicalRows.firstIndex(of:.post(id)),let cell = document.hostedView(forRow:index) as? NativeVirtualTimeline.Cell,cell.host != nil else { return false }
                return cell.convert(cell.bounds,to:document).intersection(scroll.documentVisibleRect).height >= min(20,cell.bounds.height)
            }
            stage = "virtual-main-initial-document-publication"
            var publication:[[String:Any]] = []
            let expectedIDs = Array(Int64(7000)...7060)
            for attempt in 0..<40 {
                let ids = document.canonicalRows.compactMap { row -> Int64? in if case let .post(id) = row { return id };return nil }
                publication.append(["attempt":attempt,"model_post_ids":model.posts.map(\.id),"published_post_ids":ids,"viewport":rect(scroll.documentVisibleRect),"diagnostics":document.debugDiagnostics])
                guard model.posts.map(\.id) == expectedIDs else { break }
                if ids == expectedIDs,scroll.documentVisibleRect.width > 0,scroll.documentVisibleRect.height > 0,scopeCurrent() { break }
                try await settle(view,delay:20_000_000)
            }
            samples.append(["phase":"main-initial-document-publication","attempts":publication])
            checks["main_initial_61_posts_published_in_real_viewport"] = document.canonicalRows.compactMap { row -> Int64? in if case let .post(id) = row { return id };return nil } == expectedIDs && model.posts.map(\.id) == expectedIDs && scroll.documentVisibleRect.width > 0 && scroll.documentVisibleRect.height > 0 && scopeCurrent()
            guard checks["main_initial_61_posts_published_in_real_viewport"] == true else { throw ChatAPIError.invalidResponse }
            var pngSeen = false,gifSeen = false,ogSeen = false,pollSeen = false
            stage = "virtual-main-real-asset-warmup"
            for (index,target) in [Int64(7006),7007,7008,7009,7026,7027,7028,7029,7046,7047,7056,7057,7058,7059,7060].enumerated() {
                guard let row = document.canonicalRows.firstIndex(of:.post(target)) else { throw ChatAPIError.invalidResponse }
                scroll.contentView.scroll(to:NSPoint(x:0,y:min(max(0,document.bounds.height-scroll.documentVisibleRect.height),document.rect(ofRow:row).minY)))
                scroll.reflectScrolledClipView(scroll.contentView);try await settle(view,delay:100_000_000)
                let images = rasters(in:document).compactMap { raster -> NSImage? in
                    guard raster.convert(raster.bounds,to:document).intersects(scroll.documentVisibleRect) else { return nil };return raster.image
                }
                pngSeen = pngSeen || images.contains { $0.size == NSSize(width:48,height:32) }
                gifSeen = gifSeen || images.contains { NativeInlineImagePreview.frameCount($0) == 2 }
                if let post = model.posts.first(where:{ $0.id == target }),post.props?.vote?.choices.count == 2 { pollSeen = pollSeen || visiblePost(target) }
                var links:[[String:Any]] = []
                for marker in loadedLinkMarkers(in:document) where marker.kind.hasPrefix("link-image:") {
                    let frame = marker.convert(marker.bounds,to:document),overlap = frame.intersection(scroll.documentVisibleRect)
                    guard !overlap.isNull,overlap.width > 0,overlap.height > 0 else { continue }
                    let row = document.row(for:marker)
                    guard document.canonicalRows.indices.contains(row),document.canonicalRows[row] == .post(marker.postID),
                          let cell = document.hostedView(forRow:row) as? NativeVirtualTimeline.Cell,marker.isDescendant(of:cell),
                          let post = model.posts.first(where:{ $0.id == marker.postID }),let item = model.linkPreviews(for:post).first(where:{ "link-image:"+String($0.index) == marker.kind }),
                          ThreadFixtureProtocol.completed["og:image:"+String(post.id),default:0] > 0 else { throw ChatAPIError.invalidResponse }
                    let before = ThreadFixtureProtocol.requested
                    guard let image = await model.linkPreviewImage(for:post,preview:item.preview),image.size == NSSize(width:400,height:200),ThreadFixtureProtocol.requested == before else { throw ChatAPIError.invalidResponse }
                    links.append(["post_id":post.id,"loaded_image_frame":rect(frame),"visible_intersection":rect(overlap),"decoded_cache_probe400x200_without_new_request":true]);ogSeen = true
                }
                let phase = "main-asset-warmup-\(index)"
                checks[phase+"-target-visible"] = visiblePost(target)
                checks[phase+"-scope-current"] = scopeCurrent()
                checks[phase+"-native-order-and-host-bound"] = document.debugDiagnostics["host_order_is_canonical"] as? Bool == true && (document.debugDiagnostics["max_hosted_cells"] as? Int).map { $0 > 0 && $0 <= 32 } == true
                samples.append(["phase":phase,"target_post_id":target,"clip_bounds":rect(scroll.documentVisibleRect),"diagnostics":document.debugDiagnostics,"visible_loaded_link_images":links,"viewport_png":phase+".png"])
                try capture(scroll,to:directory.appendingPathComponent(phase+".png"))
                guard checks[phase+"-target-visible"] == true,scopeCurrent(),checks[phase+"-native-order-and-host-bound"] == true else { throw ChatAPIError.invalidResponse }
            }
            checks["real_png_visible"] = pngSeen;checks["real_two_frame_gif_visible"] = gifSeen
            checks["real_og_loaded_branch_and_cache_visible"] = ogSeen;checks["real_poll_visible"] = pollSeen
            checks["exact61_ordinary_main_posts"] = model.posts.map(\.id) == Array(Int64(7000)...7060) && model.posts.allSatisfy { $0.thread_id == 0 }
            checks["exact61_canonical_posts"] = document.canonicalRows.compactMap { row -> Int64? in if case let .post(id) = row { return id };return nil } == Array(Int64(7000)...7060)
            guard pngSeen,gifSeen,ogSeen,pollSeen,checks["exact61_ordinary_main_posts"] == true,checks["exact61_canonical_posts"] == true else { throw ChatAPIError.invalidResponse }
            let composers = composerViews(in:view)
            guard composers.count == 1,let composer = composers.first,let editorScroll = composer.enclosingScrollView,let undo = composer.undoManager,
                  composer.string == mainDraft else { throw ChatAPIError.invalidResponse }
            let selection = NSRange(location:3,length:5)
            composer.setSelectedRange(selection);guard window.makeFirstResponder(composer) else { throw ChatAPIError.invalidResponse }
            try await settle(view,delay:50_000_000)
            let growth = (1...38).map { "Synthetic main native composer line \($0)" }.joined(separator:"\n")
            guard ChatMessageText.isAllowed(growth),composer.selectedRange() == selection else { throw ChatAPIError.invalidResponse }
            for older in [false,true] {
                stage = older ? "main-composer-older-baseline" : "main-composer-latest-baseline"
                // These are setup scrolls only; input below is followed solely
                // by observations, never by test anchor/scroll corrections.
                if older {
                    guard let row = document.canonicalRows.firstIndex(of:.post(7027)) else { throw ChatAPIError.invalidResponse }
                    scroll.contentView.scroll(to:NSPoint(x:0,y:document.rect(ofRow:row).minY+17.5))
                } else { scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,document.bounds.height-scroll.documentVisibleRect.height))) }
                scroll.reflectScrolledClipView(scroll.contentView);try await settle(view,delay:100_000_000)
                let baselineHeight = editorScroll.frame.height,baselineViewport = scroll.documentVisibleRect.height
                let anchor = older ? virtualReplyOffsets(7027,document:document,scroll:scroll) : nil
                let prefix = "main-composer-\(older ? "older" : "latest")"
                checks[prefix+"-baseline-height64"] = abs(baselineHeight-64) <= tolerance
                checks[prefix+"-baseline-editor"] = composer.string == mainDraft && composer.selectedRange() == selection && window.firstResponder === composer
                if older { checks[prefix+"-baseline-reader"] = firstSignificantVirtualReply(document:document,scroll:scroll) == 7027 && anchor.map { abs($0.0+17.5) <= tolerance } == true }
                else { checks[prefix+"-baseline-reader"] = visiblePost(7060) && latestVisible(in:scroll) && abs(document.bounds.maxY-scroll.documentVisibleRect.maxY) <= tolerance }
                samples.append(["phase":prefix+"-before-input","actual_editor_height":baselineHeight,"timeline_viewport":rect(scroll.documentVisibleRect),"committed_anchor_offset":anchor.map { $0.0 as Any } ?? NSNull(),"marker_offset":anchor.map { $0.1 as Any } ?? NSNull(),"diagnostics":document.debugDiagnostics])
                guard checks[prefix+"-baseline-height64"] == true,checks[prefix+"-baseline-editor"] == true,checks[prefix+"-baseline-reader"] == true else { throw ChatAPIError.invalidResponse }
                for grow in [true,false] {
                    let text = grow ? growth : mainDraft,expectedHeight:CGFloat = grow ? 180 : 64
                    let started = ProcessInfo.processInfo.systemUptime
                    model.draft = text
                    for (label,delay) in [("100ms",UInt64(100_000_000)),("200ms",UInt64(100_000_000)),("1sec",UInt64(800_000_000))] {
                        try await settle(view,delay:delay)
                        let phase = prefix+"-\(grow ? "grow" : "shrink")-"+label,clip = scroll.documentVisibleRect
                        stage = phase
                        let offsets = older ? virtualReplyOffsets(7027,document:document,scroll:scroll) : nil
                        let retained:Bool
                        if older,let offsets,let anchor { retained = firstSignificantVirtualReply(document:document,scroll:scroll) == 7027 && abs(offsets.0-anchor.0) <= tolerance && abs(offsets.1-anchor.1) <= tolerance && !latestVisible(in:scroll) }
                        else { retained = !older && visiblePost(7060) && latestVisible(in:scroll) && abs(document.bounds.maxY-clip.maxY) <= tolerance }
                        let editorSame = composerViews(in:view).count == 1 && composerViews(in:view).first === composer && composer.enclosingScrollView === editorScroll && composer.undoManager === undo && window.firstResponder === composer && Data(composer.string.utf8) == Data(text.utf8) && composer.selectedRange() == selection
                        let heightCorrect = abs(editorScroll.frame.height-expectedHeight) <= tolerance
                        let viewportCorrect = abs(clip.height-(baselineViewport-(grow ? 116 : 0))) <= tolerance
                        let safe = scopeCurrent() && model.draft == text && model.threadDrafts[7000] == threadDraft && model.replies.isEmpty
                            && model.posts.map(\.id) == Array(Int64(7000)...7060) && model.posts.allSatisfy({ $0.thread_id == 0 })
                            && document.debugDiagnostics["host_order_is_canonical"] as? Bool == true && (document.debugDiagnostics["max_hosted_cells"] as? Int).map { $0 > 0 && $0 <= 32 } == true
                            && !window.isVisible && model.error == nil && ThreadFixtureProtocol.deniedWrites == 0 && ThreadFixtureProtocol.unknownReads.isEmpty
                        checks[phase+"-native-editor64-180-cap"] = heightCorrect
                        checks[phase+"-actual-viewport116-change"] = viewportCorrect
                        checks[phase+"-reader-one-pixel-no-correction"] = retained
                        checks[phase+"-same-editor-text-selection-focus-undo"] = editorSame
                        checks[phase+"-scope-drafts-order-host-bound-zero-writes"] = safe
                        var sample:[String:Any] = ["phase":phase,"elapsed_ms":(ProcessInfo.processInfo.systemUptime-started)*1000,"actual_native_editor_height":editorScroll.frame.height,"expected_editor_height":expectedHeight,"native_text_document_height":composer.frame.height,"baseline_editor_height":baselineHeight,"baseline_viewport_height":baselineViewport,"actual_viewport":rect(clip),"document":rect(document.bounds),"end_gap":document.bounds.maxY-clip.maxY,"editor_identity":String(describing:ObjectIdentifier(composer)),"editor_scroll_identity":String(describing:ObjectIdentifier(editorScroll)),"undo_identity":String(describing:ObjectIdentifier(undo)),"selection":["location":composer.selectedRange().location,"length":composer.selectedRange().length],"diagnostics":document.debugDiagnostics,"viewport_png":phase+".png"]
                        sample["committed_anchor_offset"] = offsets.map { $0.0 as Any } ?? NSNull();sample["actual_marker_offset"] = offsets.map { $0.1 as Any } ?? NSNull()
                        sample["baseline_committed_offset"] = anchor.map { $0.0 as Any } ?? NSNull();sample["baseline_marker_offset"] = anchor.map { $0.1 as Any } ?? NSNull()
                        samples.append(sample);try capture(view,to:directory.appendingPathComponent(phase+".png"))
                        guard heightCorrect,viewportCorrect,retained,editorSame,safe else { throw ChatAPIError.invalidResponse }
                    }
                }
            }
            checks["final_drafts_restored"] = model.draft == mainDraft && model.threadDrafts[7000] == threadDraft && composer.string == mainDraft
            checks["runtime_denied_once"] = ThreadFixtureProtocol.deniedRuntime == 1
            checks["default60_protocol_mode_preserved"] = !ThreadFixtureProtocol.virtualViewportMode
            let result:[String:Any] = ["synthetic_only":true,"prototype_only":true,"checks":checks,"samples":samples,"post_ids":model.posts.map(\.id),"requests":ThreadFixtureProtocol.requested,"completed":ThreadFixtureProtocol.completed,"unknown_reads":ThreadFixtureProtocol.unknownReads,"writes":ThreadFixtureProtocol.deniedWrites,
                "composer_mode":"Explicit DEBUG main native auto-height64...180,38-line model-bound draft and restore; actual whole main preview.",
                "limits":"Seeded61ordinary posts using existing default60 asset protocol. No paging, API jump proof, thread adoption, physical input, AX, official comparison or production-adoption claim." ]
            guard checks.values.allSatisfy({ $0 }) else { try record(result,to:directory.appendingPathComponent("failure.json"));return false }
            try capture(view,to:directory.appendingPathComponent("whole-main-final.png"));try record(result,to:directory.appendingPathComponent("result.json"));return true
        } catch {
            try? record(["synthetic_only":true,"prototype_only":true,"stage":stage,"error":String(describing:error),"checks":checks,"samples":samples,"requests":ThreadFixtureProtocol.requested,"completed":ThreadFixtureProtocol.completed,"unknown_reads":ThreadFixtureProtocol.unknownReads,"writes":ThreadFixtureProtocol.deniedWrites],to:directory.appendingPathComponent("failure.json"))
            return false
        }
    }
    enum VirtualViewportProbe:String { case none,resize,asyncImage,composer }
    @MainActor private final class VirtualThreadSizing:ObservableObject {
        @Published var size = NSSize(width:640,height:680)
    }
    @MainActor private struct VirtualThreadViewportContent:View {
        @ObservedObject var model:NativeChatPreviewModel
        let appearance:NativeAppearancePreferences
        @ObservedObject var sizing:VirtualThreadSizing
        var automaticallySizesComposer = false
        var body:some View {
            NativeThreadView(appearancePreferences:appearance,model:model).usingNativeVirtualTimeline(fixtureSize:sizing.size,automaticallySizesComposer:automaticallySizesComposer)
        }
    }
    /// Independent real paging/virtual-thread check; the original composer
    /// renderer above remains unchanged and keeps its original protocol mode.
    static func renderVirtualViewport(to directory:URL,probe:VirtualViewportProbe = .none) async -> Bool {
        var stage = "prepare-virtual-thread",samples:[[String:Any]] = [],checks:[String:Bool] = [:]
        do {
            guard !FileManager.default.fileExists(atPath:directory.path) else { return false }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            NSApplication.shared.setActivationPolicy(.prohibited)
            try ThreadFixtureProtocol.reset();ThreadFixtureProtocol.virtualViewportMode = true
            ThreadFixtureProtocol.unknownOG7109 = probe == .asyncImage;ThreadFixtureProtocol.holdOG7109 = probe == .asyncImage
            let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
                guard session.baseURL.scheme == "https",session.baseURL.host == host else { throw ChatAPIError.invalidResponse }
                let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ThreadFixtureProtocol.self]
                config.httpShouldSetCookies = false;config.urlCache = nil
                return try ChatAPIClient(session:session,network:URLSession(configuration:config))
            },downloadPreferences:.init(defaults:nil),emojiPreferences:.init(defaults:nil),notificationDefaults:nil)
            defer { ThreadFixtureProtocol.cancelPending();model.signOutLocally();ThreadFixtureProtocol.virtualViewportMode = false }
            await model.connect(using:.init(session:.init(baseURL:URL(string:"https://"+host)!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic-thread",importedFromOfficialApp:false))
            guard model.connected,model.userID == 10 else { throw ChatAPIError.invalidResponse }
            model.suspendLiveForProbe();model.liveStatus = .live;model.selection = 23;model.error = nil
            let root = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:ThreadFixtureProtocol.virtualPosts[0]))
            model.posts = [root];model.draft = mainDraft;model.threadDrafts[root.id] = threadDraft
            stage = "actual-open-thread-first-page"
            await model.openThread(root)
            guard model.error == nil,model.replies.map(\.id) == Array(Int64(7091)...7120),model.canLoadOlderReplies,
                  ThreadFixtureProtocol.threadPageCursors == ["latest"] else { throw ChatAPIError.invalidResponse }
            let account = model.accountGeneration,token = model.nativeThreadViewportToken,mainToken = model.historyViewportToken
            let sizing = VirtualThreadSizing()
            let content = VirtualThreadViewportContent(model:model,appearance:NativeAppearancePreferences(defaults:nil),sizing:sizing,automaticallySizesComposer:probe == .composer)
            let view = NSHostingView(rootView:content.environment(\.nativeChatStyle,ChatAppearanceStyle.dark).preferredColorScheme(.dark))
            view.appearance = NSAppearance(named:.darkAqua)
            let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:640,height:680),styleMask:[],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = view
            defer { window.contentView = nil;window.close() }
            var candidate:NSScrollView?
            for _ in 0..<40 {
                try await settle(view,delay:20_000_000)
                candidate = scrolls(in:view).first { $0.documentView is NativeVirtualTimeline.Document && $0.documentView?.identifier?.rawValue == "native-virtual-timeline" }
                if candidate != nil { break }
            }
            guard let scroll = candidate,let document = scroll.documentView as? NativeVirtualTimeline.Document else { throw ChatAPIError.invalidResponse }
            guard let composer = composerViews(in:view).first(where:{ $0.accessibilityLabel() == "Reply to thread" }),composer.string == threadDraft else { throw ChatAPIError.invalidResponse }
            composer.setSelectedRange(NSRange(location:3,length:5))
            try await settle(view,delay:50_000_000)
            let composerSelection = composer.selectedRange()
            checks["native_reply_composer_selection_precondition"] = composerSelection == NSRange(location:3,length:5)
            let scrollID = ObjectIdentifier(scroll),documentID = ObjectIdentifier(document),tolerance = 1/max(1,window.backingScaleFactor)
            @MainActor func currentScope()->Bool {
                let diagnostic = document.debugDiagnostics
                return diagnostic["in_thread"] as? Bool == true && diagnostic["root_id"] as? String == "7000"
                    && diagnostic["account"] as? Int == account && diagnostic["channel"] as? String == "23"
                    && diagnostic["token"] as? String == token.uuidString && model.accountGeneration == account
                    && model.nativeThreadViewportToken == token && model.historyViewportToken == mainToken
                    && model.threadRoot?.id == 7000 && model.selection == 23
            }
            @MainActor func visiblePost(_ id:Int64)->Bool {
                guard let index = document.canonicalRows.firstIndex(of:.post(id)),let cell = document.hostedView(forRow:index) as? NativeVirtualTimeline.Cell,
                      cell.host != nil else { return false }
                return cell.convert(cell.bounds,to:document).intersection(scroll.documentVisibleRect).height >= min(20,cell.bounds.height)
            }
            @MainActor func snapshot(_ phase:String)->[String:Any] {
                let clip = scroll.documentVisibleRect
                let visible = document.canonicalRows.enumerated().compactMap { index,row -> Int64? in
                    if case let .post(id) = row,document.rect(ofRow:index).intersection(clip).height >= min(20,document.rect(ofRow:index).height),visiblePost(id) { return id }
                    return nil
                }
                return ["phase":phase,"visible_reply_ids":visible,"clip_bounds":rect(clip),"document_bounds":rect(document.bounds),
                        "scope_current":currentScope(),"identity_stable":ObjectIdentifier(scroll) == scrollID && ObjectIdentifier(document) == documentID,
                        "finite_geometry":[clip.minY,clip.height,clip.width,document.bounds.height,document.bounds.width].allSatisfy(\.isFinite) && clip.width > 0 && clip.height > 0 && document.bounds.width > 0 && document.bounds.height > 0,
                        "diagnostics":document.debugDiagnostics,"replies":model.replies.count,"main_draft":model.draft,"reply_draft":model.replyDraft]
            }
            // This DEBUG setter prepares a viewport; it does not claim API jump
            // navigation coverage. Raw clip offset is then adopted as user input.
            model.nativeThreadScrollPostID = 7105;model.objectWillChange.send()
            try await settle(view,delay:100_000_000)
            model.nativeThreadScrollPostID = nil;model.objectWillChange.send()
            try await settle(view,delay:50_000_000)
            guard let anchorIndex = document.canonicalRows.firstIndex(of:.post(7105)) else { throw ChatAPIError.invalidResponse }
            scroll.contentView.scroll(to:NSPoint(x:0,y:document.rect(ofRow:anchorIndex).minY+17.5));scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(view,delay:100_000_000)
            @MainActor func anchorGeometry()->(CGFloat,CGFloat)? {
                guard let index = document.canonicalRows.firstIndex(of:.post(7105)),let marker = rowMarkers(in:document).first(where:{ $0.postID == 7105 }),visiblePost(7105) else { return nil }
                return (document.rect(ofRow:index).minY-scroll.documentVisibleRect.minY,marker.convert(marker.bounds,to:document).minY-scroll.documentVisibleRect.minY)
            }
            guard currentScope(),let baseline = anchorGeometry() else { throw ChatAPIError.invalidResponse }
            samples.append(snapshot("before-prepend"));try capture(scroll,to:directory.appendingPathComponent("before-prepend.png"))
            checks["first_page_actual_open_thread"] = true
            for (index,first) in [7061,7031,7001].enumerated() {
                stage = "actual-thread-prepend-\(index+1)"
                await model.loadOlderReplies();try await settle(view,delay:100_000_000)
                let offsets = anchorGeometry()
                let stable = offsets.map { abs($0.0-baseline.0) <= tolerance && abs($0.1-baseline.1) <= tolerance } ?? false
                checks["prepend_anchor_one_pixel_\(index+1)"] = stable
                checks["prepend_ids_exact_\(index+1)"] = model.replies.map(\.id) == Array(Int64(first)...7120)
                var sample = snapshot("after-prepend-\(index+1)")
                sample["baseline_committed_offset"] = baseline.0;sample["baseline_marker_offset"] = baseline.1
                sample["committed_offset"] = offsets.map { $0.0 as Any } ?? NSNull();sample["marker_offset"] = offsets.map { $0.1 as Any } ?? NSNull()
                samples.append(sample);try capture(scroll,to:directory.appendingPathComponent("after-prepend-\(index+1).png"))
                guard stable,checks["prepend_ids_exact_\(index+1)"] == true,currentScope(),model.error == nil else { throw ChatAPIError.invalidResponse }
            }
            checks["four_exact_thread_cursors"] = ThreadFixtureProtocol.threadPageCursors == ["latest","7091","7061","7031"]
            checks["all_120_reply_ids_exact"] = model.replies.map(\.id) == Array(Int64(7001)...7120) && Set(model.replies.map(\.id)).count == 120
            checks["root_not_repeated_as_reply"] = !model.replies.contains { $0.id == root.id } && document.canonicalRows.filter { $0 == .threadRoot(7000) }.count == 1
            // Visit the actual root/header and a bounded set of representative
            // rich rows. No offscreen roots are created merely for measurement.
            var pngSeen = false,gifSeen = false,ogSeen = false,pollSeen = false,rootSeen = false
            for (index,target) in [Int64(7000),7006,7007,7008,7009,7036,7037,7066,7067,7096,7097,7108,7119,7120].enumerated() {
                stage = "virtual-thread-traversal-\(index)"
                let row:NativeTableTimelineState.Row = target == 7000 ? .threadRoot(target) : .post(target)
                guard let rowIndex = document.canonicalRows.firstIndex(of:row) else { throw ChatAPIError.invalidResponse }
                scroll.contentView.scroll(to:NSPoint(x:0,y:min(max(0,document.bounds.height-scroll.documentVisibleRect.height),document.rect(ofRow:rowIndex).minY)))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await settle(view,delay:100_000_000)
                if !ThreadFixtureProtocol.pendingOG.isEmpty { ThreadFixtureProtocol.releaseOG();try await settle(view,delay:50_000_000) }
                let visibleImages = rasters(in:document).compactMap { raster -> NSImage? in
                    guard raster.convert(raster.bounds,to:document).intersects(scroll.documentVisibleRect) else { return nil };return raster.image
                }
                pngSeen = pngSeen || visibleImages.contains { $0.size == NSSize(width:48,height:32) }
                gifSeen = gifSeen || visibleImages.contains { NativeInlineImagePreview.frameCount($0) == 2 }
                var loadedLinks:[[String:Any]] = []
                for marker in loadedLinkMarkers(in:document) where marker.kind.hasPrefix("link-image:") {
                    let frame = marker.convert(marker.bounds,to:document),intersection = frame.intersection(scroll.documentVisibleRect)
                    guard !intersection.isNull,intersection.width > 0,intersection.height > 0 else { continue }
                    let index = document.row(for:marker)
                    guard document.canonicalRows.indices.contains(index),document.canonicalRows[index] == .post(marker.postID),
                          let cell = document.hostedView(forRow:index) as? NativeVirtualTimeline.Cell,marker.isDescendant(of:cell),
                          let post = model.replies.first(where:{ $0.id == marker.postID }),
                          let preview = model.linkPreviews(for:post).first(where:{ "link-image:"+String($0.index) == marker.kind }),
                          ThreadFixtureProtocol.completed["og:image:"+String(post.id),default:0] > 0 else { throw ChatAPIError.invalidResponse }
                    let requestsBefore = ThreadFixtureProtocol.requested
                    guard let decoded = await model.linkPreviewImage(for:post,preview:preview.preview),decoded.size == NSSize(width:400,height:200),
                          ThreadFixtureProtocol.requested == requestsBefore else { throw ChatAPIError.invalidResponse }
                    loadedLinks.append(["post_id":post.id,"loaded_image_marker_frame":rect(frame),"canonical_cell_frame":rect(cell.frame),
                        "visible_image_intersection":rect(intersection),"cache_probe_decoded_size":[decoded.size.width,decoded.size.height],"cache_probe_added_request":false])
                    ogSeen = true
                }
                if target == 7000,let cell = document.hostedView(forRow:rowIndex) as? NativeVirtualTimeline.Cell { rootSeen = cell.host != nil && cell.frame.intersects(scroll.documentVisibleRect) }
                if let post = model.replies.first(where:{ $0.id == target }),post.props?.vote?.choices.count == 2 { pollSeen = pollSeen || visiblePost(target) }
                var sample = snapshot("traversal-\(index)");sample["requested_post_id"] = target
                sample["visible_loaded_link_images"] = loadedLinks;sample["viewport_png"] = "traversal-\(index).png";samples.append(sample)
                checks["traversal_target_visible_\(index)"] = target == 7000 ? rootSeen : visiblePost(target)
                let visible = sample["visible_reply_ids"] as? [Int64] ?? []
                checks["traversal_nonblank_\(index)"] = rootSeen && target == 7000 || !visible.isEmpty
                checks["traversal_finite_\(index)"] = sample["finite_geometry"] as? Bool == true
                checks["traversal_scope_\(index)"] = currentScope()
                checks["traversal_order_\(index)"] = document.debugDiagnostics["host_order_is_canonical"] as? Bool == true
                try capture(scroll,to:directory.appendingPathComponent("traversal-\(index).png"))
                guard checks["traversal_target_visible_\(index)"] == true,checks["traversal_nonblank_\(index)"] == true,checks["traversal_finite_\(index)"] == true,currentScope() else { throw ChatAPIError.invalidResponse }
            }
            stage = "final-latest-and-assets"
            scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,document.bounds.height-scroll.documentVisibleRect.height)));scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(view,delay:100_000_000)
            samples.append(snapshot("final-latest"))
            let diagnostics = document.debugDiagnostics,maxHosts = diagnostics["max_hosted_cells"] as? Int
            checks["png_decoded_in_viewport"] = pngSeen;checks["two_frame_gif_decoded_in_viewport"] = gifSeen
            checks["og_decoded_in_viewport"] = ogSeen;checks["real_poll_row_visible"] = pollSeen;checks["actual_root_header_visible"] = rootSeen
            checks["latest_unique_png_visible"] = visiblePost(7120) && latestVisible(in:scroll) && bottom(scroll)
            checks["bounded_weak_hosts"] = maxHosts.map { $0 > 0 && $0 <= 32 } ?? false
            checks["canonical_native_order"] = diagnostics["host_order_is_canonical"] as? Bool == true
            checks["scope_and_identity_current"] = currentScope() && ObjectIdentifier(scroll) == scrollID && ObjectIdentifier(document) == documentID
            checks["main_root_only"] = model.posts.map(\.id) == [7000]
            checks["canonical_reply_ids_exact"] = document.canonicalRows.compactMap { row -> Int64? in if case let .post(id) = row { return id };return nil } == Array(Int64(7001)...7120)
            checks["drafts_exact"] = model.draft == mainDraft && model.replyDraft == threadDraft
            checks["native_reply_composer_identity_text_and_selection_retained"] = composerViews(in:view).contains { $0 === composer } && composer.string == threadDraft && composer.selectedRange() == composerSelection
            checks["no_model_error"] = model.error == nil;checks["zero_writes"] = ThreadFixtureProtocol.deniedWrites == 0
            checks["no_unknown_reads"] = ThreadFixtureProtocol.unknownReads.isEmpty;checks["runtime_denied_once"] = ThreadFixtureProtocol.deniedRuntime == 1
            checks["window_never_visible"] = !window.isVisible
            if probe == .resize {
                stage = "virtual-thread-resize-probe"
                try await probeVirtualThreadResize(model:model,view:view,window:window,scroll:scroll,document:document,sizing:sizing,directory:directory,samples:&samples,checks:&checks)
            } else if probe == .asyncImage {
                stage = "virtual-thread-async-image-probe"
                try await probeVirtualThreadAsyncImage(model:model,view:view,window:window,scroll:scroll,document:document,directory:directory,samples:&samples,checks:&checks)
            } else if probe == .composer {
                stage = "virtual-thread-growing-composer-probe"
                try await probeVirtualThreadComposer(model:model,view:view,window:window,scroll:scroll,document:document,directory:directory,samples:&samples,checks:&checks)
            }
            let result:[String:Any] = ["synthetic_only":true,"prototype_only":true,"probe":probe.rawValue,"checks":checks,"samples":samples,"post_ids":model.replies.map(\.id),"root_id":root.id,
                "thread_page_cursors":ThreadFixtureProtocol.threadPageCursors,"requests":ThreadFixtureProtocol.requested,"completed":ThreadFixtureProtocol.completed,
                "unknown_reads":ThreadFixtureProtocol.unknownReads,"writes":ThreadFixtureProtocol.deniedWrites,"no_live_account":true,"composer_mode":probe == .composer ? "Explicit DEBUG native auto-height opt-in,60...180; model-bound38-line growth and restore." : "Existing fixed composer; growth is not exercised.",
                "og_observation_method":"Visible passive marker exists only in actual loaded SwiftUI image Button; owning canonical cell and nonzero viewport intersection checked, completed fake OG transfer observed, real model cache probe decodes400x200 with no added request; traversal screenshots retain visible branch.",
                "limits":probe == .composer ? "Hidden DEBUG virtual-thread120/composer opt-in only; no API jump proof, physical input, AX, official comparison or adoption claim." : "Hidden DEBUG virtual-thread120 fixture only; no growing composer, API jump proof, physical input, AX, official comparison or adoption claim."]
            guard checks.values.allSatisfy({ $0 }) else { try record(result,to:directory.appendingPathComponent("failure.json"));return false }
            try capture(scroll,to:directory.appendingPathComponent(probe == .none ? "final-latest.png" : "probe-final-viewport.png"))
            try capture(view,to:directory.appendingPathComponent("whole-thread-and-composer.png"))
            try record(result,to:directory.appendingPathComponent("result.json"));return true
        } catch {
            try? record(["synthetic_only":true,"prototype_only":true,"stage":stage,"probe":probe.rawValue,"error":String(describing:error),"checks":checks,"samples":samples,
                "thread_page_cursors":ThreadFixtureProtocol.threadPageCursors,"requests":ThreadFixtureProtocol.requested,"completed":ThreadFixtureProtocol.completed,
                "unknown_reads":ThreadFixtureProtocol.unknownReads,"writes":ThreadFixtureProtocol.deniedWrites],to:directory.appendingPathComponent("failure.json"))
            return false
        }
    }
    private static func virtualReplyOffsets(_ id:Int64,document:NativeVirtualTimeline.Document,scroll:NSScrollView)->(CGFloat,CGFloat)? {
        guard let index = document.canonicalRows.firstIndex(of:.post(id)),let marker = rowMarkers(in:document).first(where:{ $0.postID == id }),
              let cell = document.hostedView(forRow:index) as? NativeVirtualTimeline.Cell,marker.isDescendant(of:cell),cell.host != nil else { return nil }
        return (document.rect(ofRow:index).minY-scroll.documentVisibleRect.minY,marker.convert(marker.bounds,to:document).minY-scroll.documentVisibleRect.minY)
    }
    private static func firstSignificantVirtualReply(document:NativeVirtualTimeline.Document,scroll:NSScrollView)->Int64? {
        for (index,row) in document.canonicalRows.enumerated() {
            if case let .post(id) = row {
                let frame = document.rect(ofRow:index)
                if frame.intersection(scroll.documentVisibleRect).height >= min(20,frame.height) { return id }
            }
        }
        return nil
    }
    private static func virtualThreadScope(document:NativeVirtualTimeline.Document,model:NativeChatPreviewModel,account:Int,token:UUID)->Bool {
        let diagnostic = document.debugDiagnostics
        return model.accountGeneration == account && model.nativeThreadViewportToken == token && model.selection == 23 && model.threadRoot?.id == 7000
            && diagnostic["account"] as? Int == account && diagnostic["channel"] as? String == "23" && diagnostic["root_id"] as? String == "7000"
            && diagnostic["in_thread"] as? Bool == true && diagnostic["token"] as? String == token.uuidString
    }
    private static func threadComposers(in view:NSView)->[NativeComposerText.ComposerTextView] {
        (view as? NativeComposerText.ComposerTextView).map { [$0] } ?? view.subviews.flatMap { threadComposers(in:$0) }
    }
    private static func probeVirtualThreadComposer(model:NativeChatPreviewModel,view:NSView,window:NSWindow,scroll:NSScrollView,document:NativeVirtualTimeline.Document,directory:URL,samples:inout [[String:Any]],checks:inout [String:Bool]) async throws {
        let account = model.accountGeneration,token = model.nativeThreadViewportToken,mainToken = model.historyViewportToken
        let scrollID = ObjectIdentifier(scroll),documentID = ObjectIdentifier(document),tolerance = 1/max(1,window.backingScaleFactor)
        let candidates = composerViews(in:view).filter { $0.accessibilityLabel() == "Reply to thread" }
        guard candidates.count == 1,let composer = candidates.first,let editorScroll = composer.enclosingScrollView,let undo = composer.undoManager,
              composer.string == threadDraft,model.replyDraft == threadDraft else { throw ChatAPIError.invalidResponse }
        defer { model.replyDraft = threadDraft;model.draft = mainDraft }
        let selection = NSRange(location:3,length:5)
        composer.setSelectedRange(selection)
        guard window.makeFirstResponder(composer) else { throw ChatAPIError.invalidResponse }
        try await settle(view,delay:50_000_000)
        let multiline = (1...38).map { "Synthetic native composer line \($0)" }.joined(separator:"\n")
        guard ChatMessageText.isAllowed(multiline),composer.selectedRange() == selection else { throw ChatAPIError.invalidResponse }
        for older in [false,true] {
            // Every viewport setup occurs before model-bound text input. There
            // are no scroll, anchor or retry corrections afterward.
            if older {
                guard let index = document.canonicalRows.firstIndex(of:.post(7105)) else { throw ChatAPIError.invalidResponse }
                scroll.contentView.scroll(to:NSPoint(x:0,y:document.rect(ofRow:index).minY+17.5))
            } else { scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,document.bounds.height-scroll.documentVisibleRect.height))) }
            scroll.reflectScrolledClipView(scroll.contentView);try await settle(view,delay:100_000_000)
            let baselineEditorHeight = editorScroll.frame.height,baselineViewportHeight = scroll.documentVisibleRect.height
            let anchor = older ? virtualReplyOffsets(7105,document:document,scroll:scroll) : nil
            let prefix = "composer-\(older ? "older" : "latest")"
            checks[prefix+"-baseline-native-height60"] = abs(baselineEditorHeight-60) <= tolerance
            checks[prefix+"-baseline-focused-selection"] = window.firstResponder === composer && composer.selectedRange() == selection && composer.string == threadDraft
            if older { checks[prefix+"-baseline-reader"] = firstSignificantVirtualReply(document:document,scroll:scroll) == 7105 && anchor.map { abs($0.0+17.5) <= tolerance } == true }
            else { checks[prefix+"-baseline-reader"] = latestVisible(in:scroll) && abs(document.bounds.maxY-scroll.documentVisibleRect.maxY) <= tolerance }
            samples.append(["phase":prefix+"-before-input","native_editor_height":baselineEditorHeight,"timeline_viewport":rect(scroll.documentVisibleRect),"committed_anchor_offset":anchor.map { $0.0 as Any } ?? NSNull(),"actual_marker_offset":anchor.map { $0.1 as Any } ?? NSNull(),"diagnostics":document.debugDiagnostics])
            guard checks[prefix+"-baseline-native-height60"] == true,checks[prefix+"-baseline-focused-selection"] == true,checks[prefix+"-baseline-reader"] == true else { throw ChatAPIError.invalidResponse }
            for grow in [true,false] {
                let expectedText = grow ? multiline : threadDraft,expectedHeight:CGFloat = grow ? 180 : 60
                let started = ProcessInfo.processInfo.systemUptime
                model.replyDraft = expectedText
                for (label,delay) in [("100ms",UInt64(100_000_000)),("200ms",UInt64(100_000_000)),("1sec",UInt64(800_000_000))] {
                    try await settle(view,delay:delay)
                    let phase = prefix+"-\(grow ? "grow" : "shrink")-"+label,clip = scroll.documentVisibleRect
                    let offsets = older ? virtualReplyOffsets(7105,document:document,scroll:scroll) : nil
                    let retained:Bool
                    if older,let offsets,let anchor { retained = firstSignificantVirtualReply(document:document,scroll:scroll) == 7105 && abs(offsets.0-anchor.0) <= tolerance && abs(offsets.1-anchor.1) <= tolerance && !latestVisible(in:scroll) }
                    else { retained = !older && latestVisible(in:scroll) && abs(document.bounds.maxY-clip.maxY) <= tolerance }
                    let sameEditor = composerViews(in:view).filter { $0.accessibilityLabel() == "Reply to thread" }.count == 1 && composerViews(in:view).contains { $0 === composer }
                        && composer.enclosingScrollView === editorScroll && composer.undoManager === undo && window.firstResponder === composer
                        && Data(composer.string.utf8) == Data(expectedText.utf8) && composer.selectedRange() == selection
                    let actualHeight = editorScroll.frame.height
                    let heightCorrect = abs(actualHeight-expectedHeight) <= tolerance
                    let viewportCorrect = abs(clip.height-(baselineViewportHeight-(grow ? 120 : 0))) <= tolerance
                    let scope = virtualThreadScope(document:document,model:model,account:account,token:token) && model.historyViewportToken == mainToken && ObjectIdentifier(scroll) == scrollID && ObjectIdentifier(document) == documentID
                    let safe = !window.isVisible && ThreadFixtureProtocol.deniedWrites == 0 && ThreadFixtureProtocol.unknownReads.isEmpty
                        && document.debugDiagnostics["host_order_is_canonical"] as? Bool == true && (document.debugDiagnostics["max_hosted_cells"] as? Int).map { $0 > 0 && $0 <= 32 } == true
                    checks[phase+"-actual-native-height-and-cap"] = heightCorrect
                    checks[phase+"-actual-timeline-viewport-change"] = viewportCorrect
                    checks[phase+"-reader-one-pixel-no-correction"] = retained
                    checks[phase+"-same-editor-focus-selection-undo"] = sameEditor
                    checks[phase+"-scope-model-drafts"] = scope && model.replyDraft == expectedText && model.draft == mainDraft
                    checks[phase+"-hidden-order-host-bound-zero-writes"] = safe
                    var sample:[String:Any] = ["phase":phase,"elapsed_ms":(ProcessInfo.processInfo.systemUptime-started)*1000,"expected_native_editor_height":expectedHeight,"actual_native_editor_height":actualHeight,"native_text_document_height":composer.frame.height,"baseline_native_editor_height":baselineEditorHeight,"baseline_timeline_viewport_height":baselineViewportHeight,"actual_timeline_viewport":rect(clip),"document":rect(document.bounds),"end_gap":document.bounds.maxY-clip.maxY,"editor_identity":String(describing:ObjectIdentifier(composer)),"editor_scroll_identity":String(describing:ObjectIdentifier(editorScroll)),"undo_manager_identity":String(describing:ObjectIdentifier(undo)),"allows_undo":composer.allowsUndo,"can_undo":undo.canUndo,"selection":["location":composer.selectedRange().location,"length":composer.selectedRange().length],"text_exact":composer.string == expectedText,"diagnostics":document.debugDiagnostics,"viewport_png":phase+".png"]
                    sample["committed_anchor_offset"] = offsets.map { $0.0 as Any } ?? NSNull();sample["actual_marker_offset"] = offsets.map { $0.1 as Any } ?? NSNull()
                    sample["baseline_committed_offset"] = anchor.map { $0.0 as Any } ?? NSNull();sample["baseline_marker_offset"] = anchor.map { $0.1 as Any } ?? NSNull()
                    samples.append(sample);try capture(view,to:directory.appendingPathComponent(phase+".png"))
                    guard heightCorrect,viewportCorrect,retained,sameEditor,scope,safe,checks[phase+"-scope-model-drafts"] == true else { throw ChatAPIError.invalidResponse }
                }
            }
        }
        checks["composer-final-restored-drafts"] = model.replyDraft == threadDraft && model.draft == mainDraft && composer.string == threadDraft
    }
    private static func probeVirtualThreadResize(model:NativeChatPreviewModel,view:NSView,window:NSWindow,scroll:NSScrollView,document:NativeVirtualTimeline.Document,sizing:VirtualThreadSizing,directory:URL,samples:inout [[String:Any]],checks:inout [String:Bool]) async throws {
        let account = model.accountGeneration,token = model.nativeThreadViewportToken,scrollID = ObjectIdentifier(scroll),documentID = ObjectIdentifier(document)
        let tolerance = 1/max(1,window.backingScaleFactor)
        let composers = threadComposers(in:view)
        guard composers.count == 1,let composer = composers.first,composer.string == threadDraft else { throw ChatAPIError.invalidResponse }
        let selection = NSRange(location:4,length:6)
        composer.setSelectedRange(selection)
        guard window.makeFirstResponder(composer) else { throw ChatAPIError.invalidResponse }
        try await settle(view,delay:50_000_000)
        guard composer.selectedRange() == selection else { throw ChatAPIError.invalidResponse }
        let sizes = [NSSize(width:760,height:760),NSSize(width:610,height:640),NSSize(width:640,height:680)]
        for older in [false,true] {
            if older {
                guard let index = document.canonicalRows.firstIndex(of:.post(7105)) else { throw ChatAPIError.invalidResponse }
                scroll.contentView.scroll(to:NSPoint(x:0,y:document.rect(ofRow:index).minY+17.5))
            } else { scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,document.bounds.height-scroll.documentVisibleRect.height))) }
            scroll.reflectScrolledClipView(scroll.contentView);try await settle(view,delay:100_000_000)
            let anchor = older ? virtualReplyOffsets(7105,document:document,scroll:scroll) : nil
            if older { guard firstSignificantVirtualReply(document:document,scroll:scroll) == 7105,anchor != nil else { throw ChatAPIError.invalidResponse } }
            else { guard latestVisible(in:scroll),abs(document.bounds.maxY-scroll.documentVisibleRect.maxY) <= tolerance else { throw ChatAPIError.invalidResponse } }
            for (index,size) in sizes.enumerated() {
                let before = scroll.documentVisibleRect.size,started = ProcessInfo.processInfo.systemUptime
                sizing.size = size;window.setContentSize(size)
                for (label,delay) in [("100ms",UInt64(100_000_000)),("200ms",UInt64(100_000_000)),("1sec",UInt64(800_000_000))] {
                    try await settle(view,delay:delay)
                    let phase = "resize-\(older ? "older" : "latest")-\(index)-\(label)",clip = scroll.documentVisibleRect
                    let offsets = older ? virtualReplyOffsets(7105,document:document,scroll:scroll) : nil
                    let retained:Bool
                    if older,let offsets,let anchor { retained = firstSignificantVirtualReply(document:document,scroll:scroll) == 7105 && abs(offsets.0-anchor.0) <= tolerance && abs(offsets.1-anchor.1) <= tolerance }
                    else { retained = !older && latestVisible(in:scroll) && abs(document.bounds.maxY-clip.maxY) <= tolerance }
                    let sameComposer = threadComposers(in:view).count == 1 && threadComposers(in:view).first === composer && composer.string == threadDraft && composer.selectedRange() == selection && window.firstResponder === composer
                    let scope = virtualThreadScope(document:document,model:model,account:account,token:token) && ObjectIdentifier(scroll) == scrollID && ObjectIdentifier(document) == documentID
                    let viewportChanged = abs(clip.width-before.width) > tolerance && abs(clip.height-before.height) > tolerance
                    checks[phase+"-viewport-really-resized"] = viewportChanged
                    checks[phase+"-reader-retained-one-pixel"] = retained
                    checks[phase+"-composer-identity-selection-drafts"] = sameComposer && model.draft == mainDraft && model.replyDraft == threadDraft
                    checks[phase+"-scope"] = scope
                    checks[phase+"-order-host-bound"] = document.debugDiagnostics["host_order_is_canonical"] as? Bool == true && (document.debugDiagnostics["max_hosted_cells"] as? Int).map { $0 > 0 && $0 <= 32 } == true
                    checks[phase+"-hidden-zero-writes"] = !window.isVisible && ThreadFixtureProtocol.deniedWrites == 0 && ThreadFixtureProtocol.unknownReads.isEmpty
                    var sample:[String:Any] = ["phase":phase,"elapsed_ms":(ProcessInfo.processInfo.systemUptime-started)*1000,"requested_size":[size.width,size.height],"previous_viewport":[before.width,before.height],"actual_viewport":rect(clip),"document":rect(document.bounds),"end_gap":document.bounds.maxY-clip.maxY,"diagnostics":document.debugDiagnostics,"composer_identity":String(describing:ObjectIdentifier(composer)),"composer_selection":["location":composer.selectedRange().location,"length":composer.selectedRange().length],"viewport_png":phase+".png"]
                    sample["committed_anchor_offset"] = offsets.map { $0.0 as Any } ?? NSNull();sample["actual_marker_offset"] = offsets.map { $0.1 as Any } ?? NSNull()
                    sample["baseline_committed_offset"] = anchor.map { $0.0 as Any } ?? NSNull();sample["baseline_marker_offset"] = anchor.map { $0.1 as Any } ?? NSNull()
                    samples.append(sample);try capture(scroll,to:directory.appendingPathComponent(phase+".png"))
                    guard viewportChanged,retained,sameComposer,scope,checks[phase+"-order-host-bound"] == true,checks[phase+"-hidden-zero-writes"] == true else { throw ChatAPIError.invalidResponse }
                }
            }
        }
    }
    private static func probeVirtualThreadAsyncImage(model:NativeChatPreviewModel,view:NSView,window:NSWindow,scroll:NSScrollView,document:NativeVirtualTimeline.Document,directory:URL,samples:inout [[String:Any]],checks:inout [String:Bool]) async throws {
        let account = model.accountGeneration,token = model.nativeThreadViewportToken,tolerance = 1/max(1,window.backingScaleFactor)
        let scrollID = ObjectIdentifier(scroll),documentID = ObjectIdentifier(document)
        guard let linkIndex = document.canonicalRows.firstIndex(of:.post(7109)),
              let link = model.replies.first(where:{ $0.id == 7109 }),let item = model.linkPreviews(for:link).first,item.preview.image_prop == nil else { throw ChatAPIError.invalidResponse }
        scroll.contentView.scroll(to:NSPoint(x:0,y:document.rect(ofRow:linkIndex).maxY-19));scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(view,delay:100_000_000)
        // Establish the deliberately clipped predecessor using its measured
        // placeholder height, not an unmeasured offscreen estimate.
        guard let measuredLinkIndex = document.canonicalRows.firstIndex(of:.post(7109)) else { throw ChatAPIError.invalidResponse }
        scroll.contentView.scroll(to:NSPoint(x:0,y:document.rect(ofRow:measuredLinkIndex).maxY-19));scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(view,delay:100_000_000)
        guard let baseline = virtualReplyOffsets(7110,document:document,scroll:scroll),firstSignificantVirtualReply(document:document,scroll:scroll) == 7110,
              ThreadFixtureProtocol.activeHeldOG7109 > 0,ThreadFixtureProtocol.completed["og:image:7109",default:0] == 0,
              !loadedLinkMarkers(in:document).contains(where:{ $0.postID == 7109 && $0.kind.hasPrefix("link-image:") }) else { throw ChatAPIError.invalidResponse }
        let baselineHeight = document.rect(ofRow:measuredLinkIndex).height
        let baselineTail = document.rect(ofRow:measuredLinkIndex).intersection(scroll.documentVisibleRect).height
        checks["async-baseline-clipped-predecessor"] = baselineTail > 0 && baselineTail < 20
        checks["async-baseline-first-significant-7110"] = true
        samples.append(["phase":"async-before-release","link_height":baselineHeight,"predecessor_visible_tail":baselineTail,"first_significant_reply":7110,"committed_offset":baseline.0,"actual_marker_offset":baseline.1,"active_held_og":ThreadFixtureProtocol.activeHeldOG7109,"diagnostics":document.debugDiagnostics])
        try capture(scroll,to:directory.appendingPathComponent("async-before-release.png"))
        guard checks["async-baseline-clipped-predecessor"] == true else { throw ChatAPIError.invalidResponse }
        let started = ProcessInfo.processInfo.systemUptime
        ThreadFixtureProtocol.releaseOG7109()
        for (label,delay) in [("100ms",UInt64(100_000_000)),("200ms",UInt64(100_000_000)),("1sec",UInt64(800_000_000))] {
            try await settle(view,delay:delay)
            let phase = "async-after-release-"+label
            guard let index = document.canonicalRows.firstIndex(of:.post(7109)),let offsets = virtualReplyOffsets(7110,document:document,scroll:scroll) else { throw ChatAPIError.invalidResponse }
            let marker = loadedLinkMarkers(in:document).first(where:{ $0.postID == 7109 && $0.kind == "link-image:"+String(item.index) })
            let rowCell = document.hostedView(forRow:index) as? NativeVirtualTimeline.Cell
            let loadedBranch = marker.map { marker in rowCell.map { marker.isDescendant(of:$0) && marker.window === window && marker.bounds.width > 0 && marker.bounds.height > 0 } ?? false } ?? false
            let requestsBefore = ThreadFixtureProtocol.requested
            let decoded:NSImage?
            if loadedBranch { decoded = await model.linkPreviewImage(for:link,preview:item.preview) } else { decoded = nil }
            let cacheConfirmed = decoded?.size == NSSize(width:400,height:200) && ThreadFixtureProtocol.requested == requestsBefore && ThreadFixtureProtocol.completed["og:image:7109",default:0] > 0
            let retained = firstSignificantVirtualReply(document:document,scroll:scroll) == 7110 && abs(offsets.0-baseline.0) <= tolerance && abs(offsets.1-baseline.1) <= tolerance
            let growth = document.rect(ofRow:index).height-baselineHeight
            checks[phase+"-height-grew"] = growth > tolerance
            checks[phase+"-actual-loaded-branch-cache"] = loadedBranch && cacheConfirmed
            checks[phase+"-reader-retained-one-pixel"] = retained
            checks[phase+"-scope-drafts-order-bound"] = virtualThreadScope(document:document,model:model,account:account,token:token) && ObjectIdentifier(scroll) == scrollID && ObjectIdentifier(document) == documentID && model.draft == mainDraft && model.replyDraft == threadDraft && document.debugDiagnostics["host_order_is_canonical"] as? Bool == true && (document.debugDiagnostics["max_hosted_cells"] as? Int).map { $0 > 0 && $0 <= 32 } == true
            checks[phase+"-hidden-zero-writes"] = !window.isVisible && ThreadFixtureProtocol.deniedWrites == 0 && ThreadFixtureProtocol.unknownReads.isEmpty
            var sample:[String:Any] = ["phase":phase,"elapsed_ms":(ProcessInfo.processInfo.systemUptime-started)*1000,"baseline_link_height":baselineHeight,"link_height":document.rect(ofRow:index).height,"height_growth":growth,"first_significant_reply":firstSignificantVirtualReply(document:document,scroll:scroll).map { $0 as Any } ?? NSNull(),"committed_offset":offsets.0,"actual_marker_offset":offsets.1,"baseline_committed_offset":baseline.0,"baseline_marker_offset":baseline.1,"diagnostics":document.debugDiagnostics,"loaded_image_branch_attached":loadedBranch,"cache_probe_decoded400x200_without_request":cacheConfirmed,"viewport_png":phase+".png"]
            sample["loaded_image_frame"] = marker.map { rect($0.convert($0.bounds,to:document)) as Any } ?? NSNull()
            sample["loaded_image_intersects_viewport"] = marker.map { $0.convert($0.bounds,to:document).intersects(scroll.documentVisibleRect) } ?? false
            samples.append(sample);try capture(scroll,to:directory.appendingPathComponent(phase+".png"))
            guard growth > tolerance,loadedBranch,cacheConfirmed,retained,checks[phase+"-scope-drafts-order-bound"] == true,checks[phase+"-hidden-zero-writes"] == true else { throw ChatAPIError.invalidResponse }
        }
    }
    private static func loadedLinkMarkers(in view:NSView)->[NativeMessageActionMarker.Marker] {
        (view as? NativeMessageActionMarker.Marker).map { [$0] } ?? view.subviews.flatMap { loadedLinkMarkers(in:$0) }
    }
    private static func latestVisible(in scroll:NSScrollView)->Bool {
        guard let document = scroll.documentView else { return false }
        return rasters(in:document).contains { raster in
            guard let image = raster.image,image.size == NSSize(width:80,height:40) else { return false }
            let intersection = raster.convert(raster.bounds,to:document).intersection(scroll.documentVisibleRect)
            return !intersection.isNull && intersection.width > 0 && intersection.height > 0
        }
    }
    private static func observerCachedBottom(_ scroll:NSScrollView)->Bool {
        guard let document = scroll.documentView else { return false }
        let matched = observers(in:document).filter { $0.enclosingScrollView === scroll }
        return !matched.isEmpty && matched.allSatisfy { $0.debugResizeState["last_value_before"] as? Bool == true }
    }
    private static func applyLayout(_ view:NSView) { view.needsLayout = true;view.layoutSubtreeIfNeeded();view.needsDisplay = true;view.displayIfNeeded() }
    private static func bottom(_ scroll:NSScrollView)->Bool { guard let doc = scroll.documentView else { return false };return NativeScrollVisibility.isAtBottom(content:doc.bounds,visible:scroll.documentVisibleRect,flipped:doc.isFlipped) }
    private static func rect(_ rect:NSRect)->[String:CGFloat] { ["x":rect.minX,"y":rect.minY,"width":rect.width,"height":rect.height] }
    private static func scrolls(in view:NSView)->[NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls(in:$0) } }
    private static func composerViews(in view:NSView)->[NativeComposerText.ComposerTextView] { (view as? NativeComposerText.ComposerTextView).map { [$0] } ?? view.subviews.flatMap { composerViews(in:$0) } }
    private static func rasters(in view:NSView)->[NativeInlineImageRaster] { (view as? NativeInlineImageRaster).map { [$0] } ?? view.subviews.flatMap { rasters(in:$0) } }
    private static func rowMarkers(in view:NSView)->[NativeTimelineRowMarker.Marker] { (view as? NativeTimelineRowMarker.Marker).map { [$0] } ?? view.subviews.flatMap { rowMarkers(in:$0) } }
    private static func observers(in view:NSView)->[NativeScrollVisibility.Observer] { (view as? NativeScrollVisibility.Observer).map { [$0] } ?? view.subviews.flatMap { observers(in:$0) } }
    private static func settle(_ view:NSView,delay:UInt64) async throws { try await Task.sleep(nanoseconds:delay);applyLayout(view) }
    private static func capture(_ view:NSView,to url:URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw ChatAPIError.invalidResponse }
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let data = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
        try data.write(to:url,options:.withoutOverwriting)
    }
    private static func record(_ value:[String:Any],to url:URL) throws { try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.withoutOverwriting) }
}

private final class ThreadFixtureProtocol:URLProtocol {
    @MainActor static var requested:[String:Int] = [:],completed:[String:Int] = [:]
    @MainActor static var unknownReads:[String] = []
    @MainActor static var deniedWrites = 0,deniedRuntime = 0
    @MainActor static var pendingOG:[ThreadFixtureProtocol] = []
    @MainActor static var virtualViewportMode = false
    @MainActor static var threadPageCursors:[String] = []
    @MainActor static var unknownOG7109 = false,holdOG7109 = false
    @MainActor private static var pendingOG7109:[ThreadFixtureProtocol] = []
    @MainActor static var activeHeldOG7109:Int { pendingOG7109.filter { !$0.isStopped }.count }
    @MainActor private static var png = Data(),gif = Data(),og = Data(),favicon = Data(),latest = Data()
    @MainActor private static var ogReleased = false
    private let stopLock = NSLock()
    private var stopped = false
    private var ogPostID:Int?
    private var isStopped:Bool { stopLock.lock();defer { stopLock.unlock() };return stopped }

    @MainActor static func reset() throws {
        cancelPending();requested = [:];completed = [:];unknownReads = [];deniedWrites = 0;deniedRuntime = 0;ogReleased = false
        virtualViewportMode = false;threadPageCursors = [];unknownOG7109 = false;holdOG7109 = false
        let blue = try bitmap(width:48,height:32,color:NSColor.systemBlue)
        guard let bytes = blue.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse };png = bytes
        let latestBitmap = try bitmap(width:80,height:40,color:NSColor.systemPurple)
        guard let latestBytes = latestBitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse };latest = latestBytes
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
    @MainActor static func cancelPending() { let pending = pendingOG+pendingOG7109;pendingOG = [];pendingOG7109 = [];for item in pending { item.fail() } }
    @MainActor static func releaseOG7109() { holdOG7109 = false;let pending = pendingOG7109;pendingOG7109 = [];for item in pending { item.sendImage(og,key:"og:image",mime:"image/png") } }
    @MainActor static func releaseOG() { ogReleased = true;let pending = pendingOG;pendingOG = [];for item in pending { item.sendImage(og,key:"og:image",mime:"image/png") } }

    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.scheme == "https",request.url?.host == NativeRichThreadChecks.host else { fail();return }
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
        let latestID = Self.virtualViewportMode ? 7120 : 7060
        let isPNG = postID == latestID || (7001..<latestID).contains(postID) && (postID-7001)%10 == 5
        let isGIF = (7001..<latestID).contains(postID) && (postID-7001)%10 == 6
        let isLink = (7001..<latestID).contains(postID) && (postID-7001)%10 == 8
        if endpoint == "SYNO.Chat.Post.File",method == "thumbnail",isPNG || isGIF {
            let key = "thumbnail:"+field("post_id");Self.requested[key,default:0] += 1
            sendImage(postID == latestID ? Self.latest : isPNG ? Self.png : Self.gif,key:key,mime:isPNG ? "image/png" : "image/gif");return
        }
        if endpoint == "SYNO.Chat.Post.File",method == "og",isLink {
            ogPostID = postID
            if field("url") == "https://assets.example.invalid/rich-history.png" {
                Self.requested["og:image",default:0] += 1;Self.requested["og:image:"+String(postID),default:0] += 1
                if Self.virtualViewportMode,Self.holdOG7109,postID == 7109 { Self.pendingOG7109.append(self);return }
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
        case ("SYNO.Chat.User","list"):payload = ["users":[["user_id":10,"username":"synthetic-thread","nickname":"Synthetic Alex","type":"human","human_type":"dsm"],["user_id":20,"username":"synthetic-peer","nickname":"Synthetic Jordan","type":"human","human_type":"dsm"]]]
        case ("SYNO.Chat.Channel","list"):payload = ["channels":[["channel_id":23,"name":"Synthetic rich history","type":"private","encrypted":false,"is_joined":true,"creator_id":10,"unread":0]]]
        case ("SYNO.Chat.Channel.Member","get"):payload = ["user_ids":[10,20]]
        case ("SYNO.Chat.Misc","acl"):payload = ["acls":[]]
        case ("SYNO.Chat.Admin.Setting","get"):payload = ["hide_post_url_preview":false,"allow_read_status":false,"file_size_limit":0]
        case ("SYNO.Chat.User.Preference","get"):payload = ["preferences":["theme_style":"dark","theme_background":0,"prefer_user_name_format":"nickname","sidebar_pinning_unread":false,"notification_showmessage":false,"notification_browser_active":false,"notification_mute":true,"calendar_enable":false,"recent_emoji":[]]]
        case ("SYNO.Chat.Post.Subscribe","get"):payload = ["subscribes":[]]
        case ("SYNO.Chat.Post","list"):
            guard field("channel_id") == "23" else { Self.unknownReads.append(endpoint+":"+method);fail();return }
            if Self.virtualViewportMode,!field("thread_id").isEmpty {
                let cursor = field("post_id").isEmpty ? "latest" : field("post_id")
                let expected = ["latest","7091","7061","7031"]
                guard field("thread_id") == "7000",field("prev_count") == "30",field("next_count") == "0",
                      Self.threadPageCursors.count < expected.count,cursor == expected[Self.threadPageCursors.count] else {
                    Self.unknownReads.append("unexpected-virtual-thread-page:"+cursor);fail();return
                }
                let upper = 7120-Self.threadPageCursors.count*30
                Self.threadPageCursors.append(cursor)
                payload = ["posts":Self.virtualPosts.filter { ($0["post_id"] as? Int ?? 0) > upper-30 && ($0["post_id"] as? Int ?? 0) <= upper }]
            } else {
                guard field("post_id").isEmpty else { Self.unknownReads.append("unexpected-thread-page");fail();return }
                payload = ["posts":[Self.seededPosts[0]]]
            }

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
    @MainActor static var seededPosts:[[String:Any]] {
        let rich = posts
        let root:[String:Any] = ["post_id":7000,"channel_id":23,"creator_id":10,"type":"normal","message":"Synthetic thread root","thread_id":0,"create_at":Int64(1_794_481_200_000)]
        return [root]+(7001...7060).map { id -> [String:Any] in
            let kind = (id-7001)%10
            var value:[String:Any]
            if id == 7060 || (5...8).contains(kind) {
                value = rich[id == 7060 ? 0 : kind-5]
                if var file = value["file_props"] as? [String:Any] { file["id"] = id;value["file_props"] = file }
            } else { value = ["channel_id":23,"creator_id":id%2 == 0 ? 10 : 20,"type":"normal","message":"Synthetic thread reply \(id), readable seeded content with sufficient wrapping to exercise real history layout."] }
            value["post_id"] = id;value["thread_id"] = 7000;value["create_at"] = Int64(1_794_481_200_000)+Int64(id-7000)*60_000
            return value
        }
    }
    @MainActor static var virtualPosts:[[String:Any]] {
        let rich = posts
        return [seededPosts[0]]+(7001...7120).map { id -> [String:Any] in
            let kind = (id-7001)%10
            var value:[String:Any]
            if id == 7120 || (5...8).contains(kind) {
                value = rich[id == 7120 ? 0 : kind-5]
                if var file = value["file_props"] as? [String:Any] { file["id"] = id;value["file_props"] = file }
            } else { value = ["channel_id":23,"creator_id":id%2 == 0 ? 10 : 20,"type":"normal","message":"Synthetic paged thread reply \(id): readable content with bounded native row wrapping."] }
            if unknownOG7109,id == 7109,var previews = value["url_props"] as? [[String:Any]] {
                for index in previews.indices { previews[index]["image_prop"] = nil };value["url_props"] = previews
            }
            value["post_id"] = id;value["thread_id"] = 7000;value["create_at"] = Int64(1_794_481_200_000)+Int64(id-7000)*60_000
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
