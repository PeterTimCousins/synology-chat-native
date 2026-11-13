import AppKit
import SwiftUI

/// Native viewport with one owner for document and hosted-row geometry.
@MainActor struct NativeVirtualTimeline:NSViewRepresentable {
    @ObservedObject var model:NativeChatPreviewModel
    var onBottomChanged:(Bool)->Void
#if DEBUG
    var fixtureEditors:[Int64:NativeMessageEditorFixture] = [:]
    var fixtureActionPosts:Set<Int64> = []
#endif
    var inThread = false
#if DEBUG
    var traceViewportGeometry = false
#endif
    @Environment(\.nativeChatStyle) private var style
    @Environment(\.colorScheme) private var colorScheme
    /// A small data adapter keeps the geometry owner identical for both readers.
    @MainActor private struct Source {
        let model:NativeChatPreviewModel
        let inThread:Bool
        var items:[ChatPost] {
            inThread ? model.replies.filter { $0.id != model.threadRoot?.id } : model.posts
        }
        var loading:Bool { inThread ? model.loadingThread : model.loadingHistory }
        var viewingContext:Bool { inThread ? model.threadViewingContext : model.viewingMessageContext }
        var target:Int64? { inThread ? model.nativeThreadScrollPostID : model.scrollPostID }
        var root:ChatPost? { inThread ? model.threadRoot : nil }
        var older:Bool { inThread ? model.canLoadOlderReplies : model.canLoadOlder }
        var newer:Bool { inThread ? model.threadViewingContext && model.canLoadNewerReplies : model.viewingMessageContext && model.canLoadNewer }
        var empty:Bool { items.isEmpty && !loading && (inThread || model.error == nil) }
        var scope:NativeTableTimelineState.Scope {
            .init(account:model.accountGeneration,channel:model.selection,
                  token:inThread ? model.nativeThreadViewportToken : model.historyViewportToken,rootID:root?.id)
        }
    }
    private var source:Source { Source(model:model,inThread:inThread) }
    func makeCoordinator()->Coordinator { Coordinator() }
    func makeNSView(context:Context)->NSScrollView { makeTimelineView(coordinator:context.coordinator) }
    func updateNSView(_ view:NSScrollView,context:Context) { context.coordinator.update(self) }
    static func dismantleNSView(_ view:NSScrollView,coordinator:Coordinator) { coordinator.detach() }

    func makeTimelineView(coordinator:Coordinator)->NativeTimelineScrollView {
        let scroll = NativeTimelineScrollView(frame:.zero)
        scroll.drawsBackground = false;scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true;scroll.autohidesScrollers = true
        scroll.identifier = .init("native-virtual-timeline")
        let document = Document(frame:.zero);document.identifier = .init("native-virtual-timeline")
        scroll.documentView = document
        coordinator.attach(scroll:scroll,document:document);coordinator.update(self)
        return scroll
    }

    final class Document:NSView {
        override var isFlipped:Bool { true }
        override var acceptsFirstResponder:Bool { true }
        override func keyDown(with event:NSEvent) {
            if let scroll = enclosingScrollView as? NativeTimelineScrollView,scroll.handleNavigation(event) { return }
            super.keyDown(with:event)
        }
        private(set) var canonicalRows:[NativeTableTimelineState.Row] = []
        private var rectangles:[NSRect] = []
        fileprivate var containers:[NativeTableTimelineState.Row:Cell] = [:]
#if DEBUG
        fileprivate var diagnostics:(()->[String:Any])?
        var debugDiagnostics:[String:Any] { diagnostics?() ?? [:] }
#endif
        var numberOfRows:Int { canonicalRows.count }
        func rect(ofRow index:Int)->NSRect { rectangles.indices.contains(index) ? rectangles[index] : .zero }
        func row(for view:NSView)->Int {
            var current:NSView? = view
            while let node = current,node !== self {
                if let container = node as? Cell { return canonicalRows.firstIndex(of:container.identity) ?? -1 }
                current = node.superview
            }
            return -1
        }
        func hostedView(forRow index:Int)->NSView? {
            guard canonicalRows.indices.contains(index) else { return nil }
            return containers[canonicalRows[index]]
        }
        fileprivate func publish(rows:[NativeTableTimelineState.Row],heights:[CGFloat],width:CGFloat,viewportHeight:CGFloat) {
            var y:CGFloat = 0
            var frames:[NSRect] = [];frames.reserveCapacity(rows.count)
            for height in heights { frames.append(NSRect(x:0,y:y,width:width,height:height));y += height }
            canonicalRows = rows;rectangles = frames
            let size = NSSize(width:width,height:max(y,viewportHeight))
            if frame.size != size { setFrameSize(size) }
            for (row,container) in containers {
                if let index = rows.firstIndex(of:row),container.frame != frames[index] { container.frame = frames[index] }
            }
        }
        fileprivate func intersecting(_ visible:NSRect)->[Int] {
            guard visible.minY.isFinite,visible.maxY.isFinite,visible.height > 0,!rectangles.isEmpty else { return [] }
            // Binary search the canonical prefix sums; no message hosts are
            // created to discover the viewport's row range.
            var low = 0,high = rectangles.count
            while low < high {
                let middle = (low+high)/2
                if rectangles[middle].maxY <= visible.minY { low = middle+1 } else { high = middle }
            }
            var result:[Int] = [],index = low
            while index < rectangles.count,rectangles[index].minY < visible.maxY {
                result.append(index);index += 1
            }
            return result
        }
    }
    final class Host:NSHostingView<AnyView> {
        var invalidated:(()->Void)?
        private var lastHeight:CGFloat?
        override func invalidateIntrinsicContentSize() { super.invalidateIntrinsicContentSize();invalidated?() }
        override func layout() {
            super.layout()
            let height = fittingSize.height,scale = max(1,window?.backingScaleFactor ?? 1)
            guard height.isFinite,height > 0 else { return }
            if lastHeight.map({ abs($0-height) >= 0.5/scale }) ?? true { lastHeight = height;invalidated?() }
        }
    }
    final class Cell:NSView {
        let identity:NativeTableTimelineState.Row
        var row:NativeTableTimelineState.Row? { identity }
        var host:NSHostingView<AnyView>?
        fileprivate var revision:Int?
        fileprivate var width:CGFloat = 0
        fileprivate var editorHostEpoch = UUID()
        fileprivate var editorChange:NativeMessageEditorHostingChange?
#if DEBUG
        var debugEditorChange:NativeMessageEditorHostingChange? { editorChange }
#endif
        init(row:NativeTableTimelineState.Row) { self.identity = row;super.init(frame:.zero) }
        required init?(coder:NSCoder) { fatalError("init(coder:) is unavailable") }
        override var isFlipped:Bool { true }
        override func layout() { super.layout();if host?.frame != bounds { host?.frame = bounds } }
        fileprivate func clear() {
            editorHostEpoch = UUID();editorChange = nil
            (host as? Host)?.invalidated = nil;host?.removeFromSuperview();host = nil;removeFromSuperview()
        }
    }
    @MainActor final class Coordinator:NSObject {
        private weak var scroll:NativeTimelineScrollView?
        private weak var document:Document?
        private var parent:NativeVirtualTimeline?
        private var state = NativeTableTimelineState()
        private var posts:[Int64:ChatPost] = [:]
        private var previous:[Int64:Int64] = [:]
        private var presentations:[Int64:Int] = [:]
        private var tokens:[NSObjectProtocol] = []
        private var queued = false,measuring = false,transaction = false
        private var lastClip:NSRect?
        private var retainedAnchor:NativeTableTimelineState.Anchor?
        private var pendingAnchor:NativeTableTimelineState.Anchor?
        private var navigation:Navigation?
        private var lastHistoryRevision:UUID?,lastLatestRevision:UUID?
        private var lastThreadTarget:Int64?
        private var initial = true
        private var lastReportedBottom:Bool?
        private var viewportResizing = false
        private struct EditorLease {
            let row:NativeTableTimelineState.Row
            let owner:UUID
            let scope:NativeTableTimelineState.Scope
            let cellID:ObjectIdentifier
            let hostID:ObjectIdentifier
            let epoch:UUID
        }
        private var editorLease:EditorLease?
#if DEBUG
        private var maxHosted = 0,heightCommits = 0
        private var viewportEvents:[[String:Any]] = []
        private let liveHosts = NSHashTable<Host>.weakObjects()
#endif
        private struct Navigation {
            let target:NativeTableTimelineState.Anchor
            let ticket:NativeTableTimelineState.Ticket
            let history:UUID,latest:UUID
            let centered:Bool
            var threadContext:Bool? = nil
        }
        func attach(scroll:NativeTimelineScrollView,document:Document) {
            self.scroll = scroll;self.document = document
#if DEBUG
            document.diagnostics = { [weak self] in self?.diagnostics() ?? [:] }
#endif
            scroll.input = { [weak self] in self?.adoptUserPosition() }
            scroll.viewportResize = { [weak self] starting in self?.viewportResize(starting) }
            scroll.contentView.postsBoundsChangedNotifications = true
            tokens.append(NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) { [weak self] _ in self?.boundsChanged() })
            // A sibling composer can change the clip's frame without a bounds
            // notification or a new timeline model value. Preserve its reader
            // through the same coalesced geometry path as ordinary resizing.
            for observed in [scroll,scroll.contentView] {
                observed.postsFrameChangedNotifications = true
                let event = observed === scroll ? "scroll-frame" : "clip-frame"
                tokens.append(NotificationCenter.default.addObserver(forName:NSView.frameDidChangeNotification,object:observed,queue:.main) { [weak self] _ in
                    self?.boundsChanged(event)
                })
            }
            for name in [NSScrollView.willStartLiveScrollNotification,NSScrollView.didLiveScrollNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName:name,object:scroll,queue:.main) { [weak self] _ in self?.adoptUserPosition() })
            }
        }
        func detach() {
            tokens.forEach(NotificationCenter.default.removeObserver);tokens = []
            scroll?.input = nil;scroll?.viewportResize = nil
#if DEBUG
            document?.diagnostics = nil
#endif
            editorLease = nil
            document?.containers.values.forEach { $0.clear() };document?.containers = [:]
            parent = nil;navigation = nil;pendingAnchor = nil;viewportResizing = false
        }
        func update(_ value:NativeVirtualTimeline) {
            guard let scroll,let document else { return }
            let source = value.source,scope = source.scope,items = source.items
            let replaced = state.scope != scope
            // Capture the published document snapshot, never the model's new
            // indexes before their geometry has been committed.
            let resized = lastClip.map { $0.size != scroll.documentVisibleRect.size } ?? false
            let anchor = replaced ? nil : (resized ? retainedAnchor ?? captureAnchor() : captureAnchor())
            let oldRows = state.rows
            let themeChanged = parent?.style != value.style || parent?.colorScheme != value.colorScheme
            parent = value
            posts = Dictionary(items.map { ($0.id,$0) },uniquingKeysWith:{ _,last in last })
            previous = [:];presentations = [:]
            for (index,post) in items.enumerated() {
                let prior = index > 0 ? items[index-1] : nil
                previous[post.id] = prior?.id
                var hash = Hasher();hash.combine(String(reflecting:post));hash.combine(prior.map { String(reflecting:$0) })
                if value.inThread,index == 0 { hash.combine(source.root.map { String(reflecting:$0) }) }
                presentations[post.id] = hash.finalize()
            }
            if let root = source.root {
                var hash = Hasher();hash.combine(String(reflecting:root));presentations[root.id] = hash.finalize()
            }
            state.replace(scope:scope,postIDs:items.map(\.id),older:source.older,
                          newer:source.newer,empty:source.empty,presentations:presentations,
                          threadRootID:source.root?.id,threadLatest:value.inThread && source.viewingContext)
            if replaced {
                editorLease = nil
                viewportResizing = false
#if DEBUG
                viewportEvents = []
#endif
                document.containers.values.forEach { $0.clear() };document.containers = [:]
                // Do not expose a previous account's canonical ID map while
                // the replacement reader is waiting for its first layout.
                transaction = true
                document.publish(rows:[],heights:[],width:max(1,scroll.contentSize.width),viewportHeight:max(0,scroll.contentSize.height))
                transaction = false;lastClip = scroll.documentVisibleRect
                pendingAnchor = nil;retainedAnchor = nil;navigation = nil;initial = true;lastReportedBottom = nil
                lastHistoryRevision = nil;lastLatestRevision = nil;lastThreadTarget = nil
            } else { pendingAnchor = pendingAnchor ?? anchor }
            if themeChanged { document.containers.values.forEach { $0.revision = nil } }
            if value.inThread,!replaced,oldRows != state.rows { navigation = nil }
            if let ticket = state.ticket,!source.loading,value.inThread {
                if let id = source.target,id != lastThreadTarget,state.index(of:id) != nil {
                    navigation = Navigation(target:.post(id,offset:0),ticket:ticket,history:scope.token,latest:scope.token,centered:true,threadContext:source.viewingContext)
                    initial = false;lastThreadTarget = id
                } else if initial,source.target == nil,!source.viewingContext,source.root != nil {
                    navigation = Navigation(target:.bottom,ticket:ticket,history:scope.token,latest:scope.token,centered:false,threadContext:source.viewingContext)
                    initial = false
                }
            } else if let ticket = state.ticket,!value.model.loadingHistory,!value.inThread {
                if value.model.historyScrollRevision != lastHistoryRevision,let id = value.model.scrollPostID,state.index(of:id) != nil {
                    let retained = value.model.scrollAnchorAtTop && oldRows != state.rows && oldRows.contains(.post(id)) ? anchor : nil
                    navigation = Navigation(target:retained ?? .post(id,offset:0),ticket:ticket,history:value.model.historyScrollRevision,latest:value.model.latestHistoryScrollRevision,centered:!value.model.scrollAnchorAtTop)
                    initial = false;lastHistoryRevision = value.model.historyScrollRevision
                } else if value.model.latestHistoryScrollRevision != lastLatestRevision && !value.model.viewingMessageContext && !posts.isEmpty {
                    navigation = Navigation(target:.bottom,ticket:ticket,history:value.model.historyScrollRevision,latest:value.model.latestHistoryScrollRevision,centered:false);initial = false
                } else if initial && !posts.isEmpty && value.model.scrollPostID == nil && !value.model.viewingMessageContext {
                    navigation = Navigation(target:.bottom,ticket:ticket,history:value.model.historyScrollRevision,latest:value.model.latestHistoryScrollRevision,centered:false);initial = false
                }
            }
            if !value.inThread { lastLatestRevision = value.model.latestHistoryScrollRevision }
            schedule()
        }
        private func current()->Bool {
            guard let parent,let document,let scroll,scroll.documentView === document else { return false }
            return state.scope == parent.source.scope
        }
        private func boundsChanged(_ event:String = "clip-bounds") {
#if DEBUG
            traceViewport(event)
#endif
            guard !transaction,let scroll else { return }
            let clip = scroll.documentVisibleRect
            if viewportResizing { lastClip = clip;return }
            if lastClip.map({ $0.size != clip.size }) == true { pendingAnchor = pendingAnchor ?? retainedAnchor ?? captureAnchor() }
            else if lastClip.map({ $0.origin != clip.origin }) == true { adoptUserPosition() }
            lastClip = clip;schedule()
        }
        private func viewportResize(_ starting:Bool) {
            // Releasing ownership is cleanup even if the originating reader
            // became stale during the native size setter.
            if !starting { viewportResizing = false }
            guard current() else { return }
            if starting {
                if !transaction { pendingAnchor = pendingAnchor ?? retainedAnchor ?? captureAnchor() }
                viewportResizing = true
#if DEBUG
                traceViewport("resize-begin")
#endif
            } else {
                viewportResizing = false
#if DEBUG
                traceViewport("resize-end")
#endif
                lastClip = scroll?.documentVisibleRect;schedule()
            }
        }
        private func adoptUserPosition() {
            guard !transaction,current() else { return }
            state.userInput();navigation = nil;pendingAnchor = nil
            retainedAnchor = captureAnchor();lastClip = scroll?.documentVisibleRect;schedule()
        }
        private func captureAnchor()->NativeTableTimelineState.Anchor? {
            guard let document,let scroll else { return nil }
            let clip = scroll.documentVisibleRect
            guard clip.minY.isFinite,clip.height.isFinite,clip.height > 0 else { return nil }
            let threadContext = parent?.inThread == true && parent?.source.viewingContext == true
            if !threadContext,NativeScrollVisibility.isAtBottom(content:document.bounds,visible:clip,flipped:true) { return .bottom }
            for index in document.intersecting(clip) {
                let rect = document.rect(ofRow:index)
                let id:Int64?
                switch document.canonicalRows[index] { case let .post(value),let .threadRoot(value):id = value;default:id = nil }
                if let id,rect.intersection(clip).height >= min(20,rect.height) {
                    return .post(id,offset:Double(rect.minY-clip.minY))
                }
            }
            return nil
        }
        private func schedule() {
            guard !queued else { return };queued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return };self.queued = false;self.commitGeometry()
            }
        }
        private func valid(_ request:Navigation)->Bool {
            guard let parent,current(),!parent.source.loading else { return false }
            if case let .post(id,_) = request.target,state.index(of:id) == nil { return false }
            guard request.ticket.scope == state.scope,request.ticket.input == state.inputGeneration else { return false }
            if parent.inThread { return request.threadContext == parent.source.viewingContext && request.history == parent.source.scope.token }
            return request.threadContext == nil && request.history == parent.model.historyScrollRevision && request.latest == parent.model.latestHistoryScrollRevision
        }
        private func publish(width:CGFloat) {
            guard let document,let scroll else { return }
            document.publish(rows:state.rows,heights:state.rows.map { CGFloat(state.height(of:$0)) },width:width,viewportHeight:max(0,scroll.contentSize.height))
        }
        private func restore(_ anchor:NativeTableTimelineState.Anchor,centered:Bool) {
            guard let document,let scroll else { return }
            let clip = scroll.documentVisibleRect
            var target = anchor
            if centered,case let .post(id,_) = anchor,let index = state.index(of:id) {
                target = .post(id,offset:Double((clip.height-document.rect(ofRow:index).height)/2))
            }
            let origins = document.canonicalRows.indices.map { Double(document.rect(ofRow:$0).minY) }
            guard let y = NativeTableTimelineState.target(for:target,rows:document.canonicalRows,origins:origins,viewport:Double(clip.height),document:Double(document.bounds.height)) else { return }
            scroll.contentView.scroll(to:NSPoint(x:0,y:CGFloat(y)));scroll.reflectScrolledClipView(scroll.contentView)
        }
        private func commitGeometry() {
            guard !measuring,current(),let scroll,let document else { return }
            let width = scroll.contentSize.width,scale = max(1,document.window?.backingScaleFactor ?? 1)
            guard width.isFinite,width > 0,scroll.contentSize.height.isFinite,scroll.contentSize.height > 0 else { return }
            let anchor = pendingAnchor ?? captureAnchor();pendingAnchor = nil
#if DEBUG
            traceViewport("commit-begin",anchor:anchor)
#endif
            measuring = true;transaction = true
            defer { measuring = false;transaction = false }
            _ = state.setWidth(Double(width),scale:Double(scale))
            guard let ticket = state.ticket else { return }
            publish(width:width)
            if let request = navigation,valid(request) { restore(request.target,centered:request.centered) }
            else { navigation = nil;if let anchor { restore(anchor,centered:false) } }
            reconcile(width:width)
            var changed = false
            // Snapshot only the hosted window. Measurement may invalidate a
            // host, but cannot mutate this dictionary while it is enumerated.
            for (row,container) in Array(document.containers) {
                guard current(),state.accepts(ticket),document.containers[row] === container,let host = container.host else { continue }
                container.layoutSubtreeIfNeeded();host.layoutSubtreeIfNeeded()
                changed = state.commit(height:Double(host.fittingSize.height),for:row,ticket:ticket,scale:Double(scale)) || changed
            }
            if changed {
#if DEBUG
                heightCommits += 1
#endif
                publish(width:width)
                if let request = navigation,valid(request) { restore(request.target,centered:request.centered) }
                else if let anchor { restore(anchor,centered:false) }
                reconcile(width:width)
            }
            lastClip = scroll.documentVisibleRect;retainedAnchor = captureAnchor()
#if DEBUG
            traceViewport("commit-end",anchor:anchor)
            maxHosted = max(maxHosted,liveHosts.allObjects.count)
#endif
            reportViewport()
            // A real height change can expose another row. This is driven by
            // geometry changes, not elapsed time or a fixed scroll retry loop.
            if changed { schedule() }
        }
        private func reconcile(width:CGFloat) {
            guard let document,let scroll else { return }
            let visible = document.intersecting(scroll.documentVisibleRect)
            var orderedRows:[NativeTableTimelineState.Row] = []
            if let first = visible.first,let last = visible.last {
                for index in max(0,first-1)...min(document.numberOfRows-1,last+1) { orderedRows.append(document.canonicalRows[index]) }
            }
            if let row = retainedEditorRow(),!orderedRows.contains(row) {
                // The viewport/overscan window is contiguous. Its one leased
                // row can only precede or follow it; do not allocate a second
                // rank map for every loaded post on each geometry pass.
                if let first = orderedRows.first,let leasedIndex = document.canonicalRows.firstIndex(of:row),
                   let firstIndex = document.canonicalRows.firstIndex(of:first),leasedIndex < firstIndex {
                    orderedRows.insert(row,at:0)
                } else { orderedRows.append(row) }
            }
            let wanted = Set(orderedRows)
            for row in Array(document.containers.keys) where !wanted.contains(row) {
                document.containers.removeValue(forKey:row)?.clear()
            }
            for row in orderedRows {
                guard let index = document.canonicalRows.firstIndex(of:row) else { continue }
                let container:Cell
                if let existing = document.containers[row] { container = existing }
                else { container = Cell(row:row);document.containers[row] = container;document.addSubview(container) }
                container.frame = document.rect(ofRow:index)
                configure(container,width:width)
                container.layoutSubtreeIfNeeded()
            }
            // Keep native child order chronological without detaching a host
            // (which would discard its editor, focus and undo state).
            var ranks = Dictionary(uniqueKeysWithValues:document.canonicalRows.enumerated().compactMap { index,row in
                document.containers[row].map { (ObjectIdentifier($0),index) }
            })
            withUnsafeMutablePointer(to:&ranks) { pointer in
                document.sortSubviews({ first,second,context in
                    guard let context else { return .orderedSame }
                    let ranks = context.assumingMemoryBound(to:[ObjectIdentifier:Int].self).pointee
                    let left = ranks[ObjectIdentifier(first)] ?? Int.max,right = ranks[ObjectIdentifier(second)] ?? Int.max
                    return left < right ? .orderedAscending : (left > right ? .orderedDescending : .orderedSame)
                },context:UnsafeMutableRawPointer(pointer))
            }
#if DEBUG
            maxHosted = max(maxHosted,liveHosts.allObjects.count)
#endif
        }
        private func retainedEditorRow()->NativeTableTimelineState.Row? {
            guard let lease = editorLease else { return nil }
            guard current(),let parent,let document,lease.scope == state.scope,
                  parent.model.activeMessageEditor == lease.owner,let channel = lease.scope.channel,parent.model.canRead(channel),
                  state.rows.contains(lease.row),document.canonicalRows.contains(lease.row),let cell = document.containers[lease.row],ObjectIdentifier(cell) == lease.cellID,
                  cell.editorHostEpoch == lease.epoch,let host = cell.host,ObjectIdentifier(host) == lease.hostID else {
                editorLease = nil;return nil
            }
            return lease.row
        }
        private func editorChanged(owner:UUID,active:Bool,row:NativeTableTimelineState.Row,scope:NativeTableTimelineState.Scope,
                                   cell:Cell,host:NSHostingView<AnyView>,epoch:UUID) {
            guard current(),let parent,let document,state.scope == scope,state.rows.contains(row),
                  document.containers[row] === cell,cell.editorHostEpoch == epoch,cell.host === host else { return }
            if active {
                guard parent.model.activeMessageEditor == owner,let channel = scope.channel,parent.model.canRead(channel) else { return }
                editorLease = EditorLease(row:row,owner:owner,scope:scope,cellID:ObjectIdentifier(cell),hostID:ObjectIdentifier(host),epoch:epoch)
            } else if parent.model.activeMessageEditor != owner,let lease = editorLease,lease.owner == owner,lease.row == row,
                      lease.cellID == ObjectIdentifier(cell),lease.hostID == ObjectIdentifier(host),lease.epoch == epoch {
                editorLease = nil
            } else { return }
            schedule()
        }
        private func configure(_ container:Cell,width:CGFloat) {
            guard let parent else { return }
            let source = parent.source
            let revision:Int
            switch container.identity { case let .post(id),let .threadRoot(id):revision = presentations[id] ?? 0;default:revision = source.loading.hashValue }
            guard container.host == nil || container.revision != revision || container.width != width else { return }
            let root:AnyView
            switch container.identity {
            case .top:root = AnyView(Color.clear.frame(height:20))
            case .bottom:root = AnyView(Color.clear.frame(height:21))
            case .older:
                if parent.inThread {
                    let scope = source.scope
                    root = AnyView(Button(source.loading ? "Loading…" : "Load earlier replies") { [weak model = parent.model] in
                        Task {
                            guard let model,model.accountGeneration == scope.account,model.selection == scope.channel,
                                  model.nativeThreadViewportToken == scope.token,model.threadRoot?.id == scope.rootID else { return }
                            await model.loadOlderReplies()
                        }
                    }.buttonStyle(.link).disabled(source.loading).frame(maxWidth:.infinity).padding(.horizontal,16).padding(.bottom,8))
                } else {
                    root = AnyView(Button("Load earlier messages") { [weak model = parent.model] in Task { await model?.loadOlder() } }.disabled(parent.model.loadingHistory).frame(maxWidth:.infinity).padding(.horizontal,16).padding(.bottom,8))
                }
            case .newer:
                if parent.inThread {
                    let scope = source.scope
                    root = AnyView(Button("Load newer replies") { [weak model = parent.model] in
                        Task {
                            guard let model,model.accountGeneration == scope.account,model.selection == scope.channel,
                                  model.nativeThreadViewportToken == scope.token,model.threadRoot?.id == scope.rootID else { return }
                            await model.loadNewerReplies()
                        }
                    }.buttonStyle(.link).disabled(source.loading).frame(maxWidth:.infinity).padding(.horizontal,16).padding(.bottom,8))
                } else {
                    root = AnyView(Button("Load newer messages") { [weak model = parent.model] in Task { await model?.loadNewer() } }.disabled(parent.model.loadingHistory).frame(maxWidth:.infinity).padding(.horizontal,16).padding(.bottom,8))
                }
            case .empty:
                if parent.inThread { root = AnyView(Text("No replies yet.").foregroundColor(.secondary).padding(.horizontal,16).padding(.bottom,8)) }
                else { root = AnyView(Text("No messages yet. Say hello below.").foregroundColor(NativeChatColors.muted).padding(.horizontal,16).padding(.bottom,8)) }
            case .threadDivider:root = AnyView(Divider().padding(.horizontal,16).padding(.bottom,8))
            case .threadLatest:
                let scope = source.scope
                root = AnyView(Button("Back to latest replies") { [weak model = parent.model] in
                    Task {
                        guard let model,model.accountGeneration == scope.account,model.selection == scope.channel,
                              model.nativeThreadViewportToken == scope.token,let thread = model.threadRoot,thread.id == scope.rootID else { return }
                        await model.openThread(thread)
                    }
                }.buttonStyle(.link).disabled(source.loading).frame(maxWidth:.infinity).padding(.horizontal,16).padding(.bottom,8))
            case let .threadRoot(id):
                guard parent.inThread,let thread = source.root,thread.id == id else { return }
                var content = NativeVirtualThreadRowContent(post:thread,previous:nil,root:thread,model:parent.model,isRoot:true)
#if DEBUG
                content.fixtureEditor = parent.fixtureEditors[id];content.fixtureShowActions = parent.fixtureActionPosts.contains(id)
#endif
                root = AnyView(content.environment(\.nativeContainedMessageActions,true).padding(.horizontal,16).padding(.bottom,8))
            case let .post(id):
                guard let post = posts[id] else { return }
                if parent.inThread {
                    var content = NativeVirtualThreadRowContent(post:post,previous:previous[id].flatMap { posts[$0] },root:source.root,model:parent.model)
#if DEBUG
                    content.fixtureEditor = parent.fixtureEditors[id];content.fixtureShowActions = parent.fixtureActionPosts.contains(id)
#endif
                    root = AnyView(content.environment(\.nativeContainedMessageActions,true).padding(.horizontal,16).padding(.bottom,8))
                } else {
                    var content = NativeTimelineRowContent(post:post,previous:previous[id].flatMap { posts[$0] },model:parent.model)
#if DEBUG
                    content.fixtureEditor = parent.fixtureEditors[id];content.fixtureShowActions = parent.fixtureActionPosts.contains(id)
#endif
                    root = AnyView(content.environment(\.nativeContainedMessageActions,true).padding(.horizontal,16).padding(.bottom,8))
                }
            }
            let host:NSHostingView<AnyView>
            if let existing = container.host { host = existing }
            else {
                let created = Host(rootView:AnyView(EmptyView()))
                created.invalidated = { [weak self,weak container,weak created] in
                    guard let self,let container,let created,self.current(),self.document?.containers[container.identity] === container,container.host === created else { return }
                    if !self.measuring { self.schedule() }
                }
#if DEBUG
                liveHosts.add(created)
#endif
                container.host = created;container.addSubview(created);host = created
            }
            let scope = source.scope,row = container.identity,epoch = container.editorHostEpoch
            let change:NativeMessageEditorHostingChange = { [weak self,weak container,weak host] owner,active in
                guard let self,let container,let host else { return }
                self.editorChanged(owner:owner,active:active,row:row,scope:scope,cell:container,host:host,epoch:epoch)
            }
            container.editorChange = change
            host.rootView = AnyView(root.environment(\.nativeMessageEditorHostingChanged,change)
                .environment(\.nativeChatStyle,parent.style).environment(\.colorScheme,parent.colorScheme).frame(width:width,alignment:.leading))
            container.revision = revision;container.width = width
            container.host?.frame = container.bounds
        }
        private func reportViewport() {
            guard current(),let parent,let document,let scroll,let scope = state.scope else { return }
            let source = parent.source
            let clip = scroll.documentVisibleRect
            let lastVisible = (source.items.last ?? source.root).map { post in
                let row:NativeTableTimelineState.Row = source.items.isEmpty && parent.inThread ? .threadRoot(post.id) : .post(post.id)
                guard let index = document.canonicalRows.firstIndex(of:row),state.heights[row] != nil else { return false }
                return document.rect(ofRow:index).intersects(clip) && document.containers[row]?.host != nil
            } ?? false
            let bottom = lastVisible && NativeScrollVisibility.isAtBottom(content:document.bounds,visible:clip,flipped:true)
            if lastReportedBottom != bottom { lastReportedBottom = bottom;parent.onBottomChanged(bottom) }
            for index in document.intersecting(clip) {
                let row = document.canonicalRows[index],rect = document.rect(ofRow:index)
                if case let .post(id) = row,rect.intersection(clip).height >= min(20,rect.height),document.containers[row]?.host != nil {
                    if parent.inThread {
                        guard let root = scope.rootID,let channel = scope.channel else { return }
                        parent.model.noteThreadViewport(postID:id,atBottom:bottom,token:scope.token,account:scope.account,channelID:channel,rootID:root)
                    } else {
                        parent.model.noteTimelineViewport(postID:id,atBottom:bottom,token:scope.token,account:scope.account,channelID:scope.channel)
                    }
                    break
                }
            }
        }
#if DEBUG
        private func diagnostics()->[String:Any] {
            let live = liveHosts.allObjects.count
            let order = document.map { document in document.subviews.compactMap { view in
                (view as? Cell).flatMap { document.canonicalRows.firstIndex(of:$0.identity) }
            } } ?? []
            return ["hosted_cells":live,"attached_hosted_cells":document?.containers.values.filter { $0.host != nil }.count ?? 0,"max_hosted_cells":max(maxHosted,live),
                    "height_commits":heightCommits,"cache_entries":state.heights.count,"row_count":state.rows.count,"width_pixels":state.widthPixels,
                    "account":state.scope?.account ?? -1,"channel":state.scope?.channel.map(String.init) ?? "nil","token":state.scope?.token.uuidString ?? "nil",
                    "root_id":state.scope?.rootID.map(String.init) ?? "nil","in_thread":parent?.inThread ?? false,
                    "input_generation":String(state.inputGeneration),"automatic_row_heights":false,"prototype_only":true,"geometry_owner":"prefix-sum-document",
                    "hosted_subview_order":order,"host_order_is_canonical":order == order.sorted(),"viewport_events":viewportEvents]
        }
        private func traceViewport(_ event:String,anchor:NativeTableTimelineState.Anchor? = nil) {
            guard parent?.traceViewportGeometry == true,let scroll,let document else { return }
            viewportEvents.append(["event":event,"time":ProcessInfo.processInfo.systemUptime,"transaction":transaction,
                "clip":NSStringFromRect(scroll.documentVisibleRect),"last_clip":lastClip.map(NSStringFromRect) ?? "nil", "document":NSStringFromRect(document.bounds),
                "anchor":String(describing:anchor),"retained":String(describing:retainedAnchor),"pending":String(describing:pendingAnchor),"input":String(state.inputGeneration)])
            if viewportEvents.count > 64 { viewportEvents.removeFirst(viewportEvents.count-64) }
        }
#endif
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}
