#if DEBUG
import AppKit
import SwiftUI

/// Isolated native virtualization experiment; production continues to use its
/// existing reader unless the DEBUG fixture explicitly selects this backend.
@MainActor struct NativeTableTimeline:NSViewRepresentable {
    @ObservedObject var model:NativeChatPreviewModel
    var onBottomChanged:(Bool)->Void
    var fixtureEditors:[Int64:NativeMessageEditorFixture] = [:]
    var traceRowFrames = false
    @Environment(\.nativeChatStyle) private var style
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator()->Coordinator { Coordinator() }
    func makeNSView(context:Context)->NSScrollView {
        makeTimelineView(coordinator:context.coordinator)
    }
    /// Shared construction lets hidden lifecycle checks exercise the exact
    /// same AppKit graph without manufacturing a representable context.
    func makeTimelineView(coordinator:Coordinator)->Scroll {
        let scroll = Scroll(frame:.zero)
        scroll.drawsBackground = false;scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true;scroll.autohidesScrollers = true
        scroll.identifier = NSUserInterfaceItemIdentifier("native-table-timeline")
        let table = Table(frame:.zero)
        table.identifier = NSUserInterfaceItemIdentifier("native-table-timeline")
        table.style = .plain
        table.headerView = nil;table.backgroundColor = .clear;table.gridStyleMask = []
        table.intercellSpacing = .zero;table.rowHeight = 90;table.usesAutomaticRowHeights = false
        table.autoresizingMask = [.width]
        table.selectionHighlightStyle = .none;table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier:.init("message"));column.resizingMask = .autoresizingMask
        column.minWidth = 1;table.addTableColumn(column)
        scroll.documentView = table
        coordinator.attach(scroll:scroll,table:table)
        coordinator.update(self)
        return scroll
    }
    func updateNSView(_ view:NSScrollView,context:Context) { context.coordinator.update(self) }
    static func dismantleNSView(_ view:NSScrollView,coordinator:Coordinator) { coordinator.detach() }

    final class Table:NSTableView {
        var geometryChanged:(()->Void)?
        var diagnostics:(()->[String:Any])?
        var debugDiagnostics:[String:Any] { diagnostics?() ?? [:] }
        var resetTrace:(()->Void)?
        override func keyDown(with event:NSEvent) {
            if let scroll = enclosingScrollView as? Scroll,scroll.handleNavigation(event) { return }
            super.keyDown(with:event)
        }
        override func setFrameSize(_ newSize:NSSize) {
            let previous = frame.size;super.setFrameSize(newSize)
            if previous != newSize { geometryChanged?() }
        }
    }
    typealias Scroll = NativeTimelineScrollView
    final class Host:NSHostingView<AnyView> {
        var invalidated:(()->Void)?
        private var lastLayoutHeight:CGFloat?
        override func invalidateIntrinsicContentSize() { super.invalidateIntrinsicContentSize();invalidated?() }
        override func layout() {
            super.layout()
            // SwiftUI can lay out an asynchronously loaded child without
            // invalidating this host's AppKit intrinsic size. Observe its
            // actual fitting height and notify only when that height changes.
            let height = fittingSize.height,scale = window?.backingScaleFactor ?? 1
            guard height.isFinite,height > 0 else { return }
            if lastLayoutHeight.map({ abs($0-height) >= 0.5/max(1,scale) }) ?? true {
                lastLayoutHeight = height;invalidated?()
            }
        }
    }
    final class Cell:NSTableCellView {
        var row:NativeTableTimelineState.Row?
        var contentRevision:Int?
        var contentWidth:CGFloat = 0
        var host:Host?
        func clear() {
            host?.invalidated = nil;host?.removeFromSuperview();host = nil
            row = nil;contentRevision = nil;contentWidth = 0
        }
        override func layout() { super.layout();host?.frame = bounds }
    }
    final class TracedRowView:NSTableRowView {
        var changed:((String)->Void)?
        override var frame:NSRect { didSet { changed?("frame") } }
        override func setFrameOrigin(_ newOrigin:NSPoint) { super.setFrameOrigin(newOrigin);changed?("origin") }
        override func setFrameSize(_ newSize:NSSize) { super.setFrameSize(newSize);changed?("size") }
    }
    @MainActor final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate {
        private weak var scroll:Scroll?
        private weak var table:Table?
        private var parent:NativeTableTimeline?
        private var state = NativeTableTimelineState()
        private var posts:[Int64:ChatPost] = [:]
        private var previous:[Int64:Int64] = [:]
        private var presentations:[Int64:Int] = [:]
        private var tokens:[NSObjectProtocol] = []
        private var queued = false
        private var transaction = false
        private var measuring = false
        private var lastClip:CGRect?
        private var retainedAnchor:NativeTableTimelineState.Anchor?
        private var pendingAnchor:NativeTableTimelineState.Anchor?
        private var navigation:Navigation?
        private var lastHistoryRevision:UUID?
        private var lastLatestRevision:UUID?
        private var initial = true
        private var maxHosted = 0
        private var heightCommits = 0
        private var lastReportedBottom:Bool?
        private var pendingRetile = IndexSet()
        private var rowFrameTrace:[[String:Any]] = []
        private var recordingRowFrame = false
        private var heightReadTrace:[[String:Any]] = []
        private let cells = NSHashTable<Cell>.weakObjects()
        private let liveHosts = NSHashTable<Host>.weakObjects()
        private struct Navigation { let target:NativeTableTimelineState.Anchor;let ticket:NativeTableTimelineState.Ticket;let history:UUID;let latest:UUID;let centered:Bool }

        func attach(scroll:Scroll,table:Table) {
            self.scroll = scroll;self.table = table
            table.delegate = self;table.dataSource = self
            table.geometryChanged = { [weak self] in self?.schedule() }
            table.diagnostics = { [weak self] in self?.diagnostics() ?? [:] }
            table.resetTrace = { [weak self] in self?.rowFrameTrace = [];self?.heightReadTrace = [] }
            scroll.input = { [weak self] in self?.adoptUserPosition() }
            scroll.contentView.postsBoundsChangedNotifications = true
            tokens.append(NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) { [weak self] _ in self?.boundsChanged() })
            for name in [NSScrollView.willStartLiveScrollNotification,NSScrollView.didLiveScrollNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName:name,object:scroll,queue:.main) { [weak self] _ in self?.adoptUserPosition() })
            }
        }
        func detach() {
            tokens.forEach(NotificationCenter.default.removeObserver);tokens = []
            scroll?.input = nil;table?.geometryChanged = nil;table?.diagnostics = nil;table?.resetTrace = nil
            table?.delegate = nil;table?.dataSource = nil
            cells.allObjects.forEach { $0.clear() };navigation = nil;parent = nil
        }
        func update(_ value:NativeTableTimeline) {
            guard let table,let scroll else { return }
            let scope = NativeTableTimelineState.Scope(account:value.model.accountGeneration,channel:value.model.selection,token:value.model.historyViewportToken)
            let replaced = state.scope != scope
            let resizedViewport = lastClip.map { $0.size != scroll.documentVisibleRect.size } ?? false
            let anchor = replaced ? nil : (resizedViewport ? retainedAnchor ?? captureAnchor() : captureAnchor())
            let oldRows = state.rows
            let oldPresentations = presentations
            let oldStyle = parent?.style,oldScheme = parent?.colorScheme
            parent = value
            posts = Dictionary(value.model.posts.map { ($0.id,$0) },uniquingKeysWith:{ _,last in last })
            previous = [:];presentations = [:]
            for (index,post) in value.model.posts.enumerated() {
                let prior = index > 0 ? value.model.posts[index-1].id : nil
                previous[post.id] = prior
                var hasher = Hasher();hasher.combine(String(reflecting:post));hasher.combine(prior)
                // Grouping/day-divider presentation also depends on the prior
                // post's content, not only its stable identifier.
                if index > 0 { hasher.combine(String(reflecting:value.model.posts[index-1])) }
                presentations[post.id] = hasher.finalize()
            }
            state.replace(scope:scope,postIDs:value.model.posts.map(\.id),older:value.model.canLoadOlder,
                          newer:value.model.viewingMessageContext && value.model.canLoadNewer,
                          empty:value.model.posts.isEmpty && !value.model.loadingHistory && value.model.error == nil,presentations:presentations)
            if replaced {
                initial = true;navigation = nil;pendingAnchor = nil;retainedAnchor = nil;lastReportedBottom = nil
                lastHistoryRevision = nil;lastLatestRevision = nil
                cells.allObjects.forEach { $0.clear() }
                transaction = true;table.reloadData();transaction = false
            } else if oldRows != state.rows {
                let delta = state.rows.difference(from:oldRows)
                var removed = IndexSet(),inserted = IndexSet()
                for change in delta { switch change { case let .remove(index,_,_):removed.insert(index);case let .insert(index,_,_):inserted.insert(index) } }
                transaction = true;table.beginUpdates()
                if !removed.isEmpty { table.removeRows(at:removed,withAnimation:[]) }
                if !inserted.isEmpty { table.insertRows(at:inserted,withAnimation:[]) }
                table.endUpdates();transaction = false
            }
            let width = max(1,scroll.contentSize.width)
            let changedWidth = state.setWidth(Double(width),scale:Double(table.window?.backingScaleFactor ?? 1))
            transaction = true
            table.tableColumns.first?.width = width
            transaction = false
            if !replaced { pendingAnchor = pendingAnchor ?? anchor }
            if changedWidth { pendingAnchor = pendingAnchor ?? retainedAnchor ?? anchor;pendingRetile = IndexSet(integersIn:0..<state.rows.count) }
            for (index,row) in state.rows.enumerated() {
                if case let .post(id) = row,oldPresentations[id] != presentations[id] { pendingRetile.insert(index) }
            }
            for cell in cells.allObjects where cell.row != nil {
                guard let row = cell.row,let index = state.rows.firstIndex(of:row) else { cell.clear();continue }
                configure(cell,row:row,index:index,force:oldStyle != value.style || oldScheme != value.colorScheme)
            }
            if let ticket = state.ticket {
                if !value.model.loadingHistory,value.model.historyScrollRevision != lastHistoryRevision,let id = value.model.scrollPostID,state.index(of:id) != nil {
                    let retained = value.model.scrollAnchorAtTop && oldRows != state.rows && oldRows.contains(.post(id)) ? anchor : nil
                    navigation = Navigation(target:retained ?? .post(id,offset:0),ticket:ticket,history:value.model.historyScrollRevision,latest:value.model.latestHistoryScrollRevision,centered:!value.model.scrollAnchorAtTop)
                    initial = false;lastHistoryRevision = value.model.historyScrollRevision
                } else if !value.model.loadingHistory && value.model.latestHistoryScrollRevision != lastLatestRevision && !value.model.viewingMessageContext && !posts.isEmpty {
                    navigation = Navigation(target:.bottom,ticket:ticket,history:value.model.historyScrollRevision,latest:value.model.latestHistoryScrollRevision,centered:false)
                    initial = false
                } else if initial && !posts.isEmpty && !value.model.loadingHistory && value.model.scrollPostID == nil && !value.model.viewingMessageContext {
                    navigation = Navigation(target:.bottom,ticket:ticket,history:value.model.historyScrollRevision,latest:value.model.latestHistoryScrollRevision,centered:false);initial = false
                }
            }
            lastLatestRevision = value.model.latestHistoryScrollRevision
            lastClip = scroll.documentVisibleRect
            schedule()
        }
        func numberOfRows(in tableView:NSTableView)->Int { state.rows.count }
        func tableView(_ tableView:NSTableView,heightOfRow row:Int)->CGFloat {
            guard state.rows.indices.contains(row) else { return 1 }
            let height = state.height(of:state.rows[row])
            if parent?.traceRowFrames == true {
                heightReadTrace.append(["time":ProcessInfo.processInfo.systemUptime,"index":row,"row":String(describing:state.rows[row]),"height":height,
                    "transaction":transaction,"measuring":measuring,"row_count":state.rows.count])
                if heightReadTrace.count > 512 { heightReadTrace.removeFirst(heightReadTrace.count-512) }
            }
            return CGFloat(height)
        }
        func tableView(_ tableView:NSTableView,shouldSelectRow row:Int)->Bool { false }
        func tableView(_ tableView:NSTableView,rowViewForRow row:Int)->NSTableRowView? {
            guard parent?.traceRowFrames == true else { return nil }
            let view = TracedRowView()
            view.changed = { [weak self,weak view] kind in
                guard let self,let view,!self.recordingRowFrame,self.rowFrameTrace.count < 256 else { return }
                self.recordingRowFrame = true;defer { self.recordingRowFrame = false }
                // Frame setters can run inside table layout. Inspect only the
                // receiver's stored frame; querying table/cell geometry here
                // re-enters AppKit before it has finished that layout.
                self.rowFrameTrace.append(["time":ProcessInfo.processInfo.systemUptime,"kind":kind,"created_index":row,
                    "row_view_identity":String(describing:ObjectIdentifier(view)),"frame":NSStringFromRect(view.frame),
                    "animation_duration":NSAnimationContext.current.duration,"implicit_animation":NSAnimationContext.current.allowsImplicitAnimation,
                    "stack":Array(Thread.callStackSymbols.prefix(16))])
            }
            return view
        }
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
            guard state.rows.indices.contains(row) else { return nil }
            let id = NSUserInterfaceItemIdentifier("native-message-cell")
            let cell = (tableView.makeView(withIdentifier:id,owner:nil) as? Cell) ?? Cell(frame:.zero)
            cell.identifier = id;cells.add(cell)
            configure(cell,row:state.rows[row],index:row,force:false)
            schedule();return cell
        }
        func tableView(_ tableView:NSTableView,didRemove rowView:NSTableRowView,forRow row:Int) {
            (rowView.view(atColumn:0) as? Cell)?.clear()
        }
        private func configure(_ cell:Cell,row:NativeTableTimelineState.Row,index:Int,force:Bool) {
            guard let parent,let table else { return }
            let width = max(1,table.tableColumns.first?.width ?? table.bounds.width)
            let revision:Int
            switch row { case let .post(id):revision = presentations[id] ?? 0;default:revision = parent.model.loadingHistory.hashValue }
            guard force || cell.row != row || cell.contentRevision != revision || cell.contentWidth != width else { return }
            let root:AnyView
            switch row {
            case .threadRoot,.threadDivider,.threadLatest:return // This rejected control remains main-only.
            case .top:root = AnyView(Color.clear.frame(height:20))
            case .bottom:root = AnyView(Color.clear.frame(height:21))
            case .older:
                root = AnyView(Button("Load earlier messages") { [weak model = parent.model] in Task { await model?.loadOlder() } }.disabled(parent.model.loadingHistory).frame(maxWidth:.infinity).padding(.horizontal,16).padding(.bottom,8))
            case .newer:
                root = AnyView(Button("Load newer messages") { [weak model = parent.model] in Task { await model?.loadNewer() } }.disabled(parent.model.loadingHistory).frame(maxWidth:.infinity).padding(.horizontal,16).padding(.bottom,8))
            case .empty:root = AnyView(Text("No messages yet. Say hello below.").foregroundColor(NativeChatColors.muted).padding(.horizontal,16).padding(.bottom,8))
            case let .post(id):
                guard let post = posts[id] else { return }
                let prior = previous[id].flatMap { posts[$0] }
                root = AnyView(NativeTimelineRowContent(post:post,previous:prior,model:parent.model,fixtureEditor:parent.fixtureEditors[id]).padding(.horizontal,16).padding(.bottom,8))
            }
            let content = AnyView(root.environment(\.nativeChatStyle,parent.style).environment(\.colorScheme,parent.colorScheme)
                .frame(width:width,alignment:.leading))
            if let host = cell.host { host.rootView = content }
            else {
                let host = Host(rootView:content);host.invalidated = { [weak self] in if self?.measuring != true { self?.schedule() } }
                liveHosts.add(host)
                cell.host = host;cell.addSubview(host)
                maxHosted = max(maxHosted,liveHosts.allObjects.count)
            }
            cell.row = row;cell.contentRevision = revision;cell.contentWidth = width
            cell.host?.frame = cell.bounds
        }
        private func boundsChanged() {
            guard !transaction,let scroll else { return }
            let current = scroll.documentVisibleRect
            if let previous = lastClip,current.size != previous.size {
                pendingAnchor = pendingAnchor ?? retainedAnchor ?? captureAnchor()
            } else if let previous = lastClip,current.origin != previous.origin {
                adoptUserPosition()
            }
            lastClip = current;schedule()
        }
        private func adoptUserPosition() {
            guard !transaction else { return }
            state.userInput();navigation = nil;pendingAnchor = nil
            retainedAnchor = captureAnchor();lastClip = scroll?.documentVisibleRect
            schedule()
        }
        private func captureAnchor()->NativeTableTimelineState.Anchor? {
            guard let table,let scroll else { return nil }
            let visible = scroll.documentVisibleRect
            guard visible.minY.isFinite,visible.height.isFinite,visible.height > 0 else { return nil }
            if NativeScrollVisibility.isAtBottom(content:table.bounds,visible:visible,flipped:true) { return .bottom }
            let range = table.rows(in:visible)
            guard range.location != NSNotFound,range.length > 0 else { return nil }
            for index in range.location..<min(state.rows.count,range.location+range.length) {
                if case let .post(id) = state.rows[index] {
                    let row = table.rect(ofRow:index)
                    // Match the standard reader: a clipped tail is not the
                    // message being read. Use committed row geometry so a
                    // child expanding before retiling cannot change ownership.
                    guard row.intersection(visible).height >= min(20,row.height) else { continue }
                    return .post(id,offset:Double(row.minY-visible.minY))
                }
            }
            return nil
        }
        private func schedule() {
            guard !queued else { return };queued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return };self.queued = false;self.commitVisibleGeometry()
            }
        }
        private func commitVisibleGeometry() {
            guard !measuring,let table,let scroll,let parent,state.scope == .init(account:parent.model.accountGeneration,channel:parent.model.selection,token:parent.model.historyViewportToken) else { return }
            measuring = true;defer { measuring = false }
            let anchor = pendingAnchor ?? captureAnchor();pendingAnchor = nil
            let width = max(1,scroll.contentSize.width),scale = table.window?.backingScaleFactor ?? 1
            let changedWidth = state.setWidth(Double(width),scale:Double(scale))
            guard let ticket = state.ticket else { return }
            transaction = true
            table.tableColumns.first?.width = width
            var changed = pendingRetile.intersection(IndexSet(integersIn:0..<state.rows.count));pendingRetile = []
            if changedWidth { changed = IndexSet(integersIn:0..<state.rows.count) }
            table.layoutSubtreeIfNeeded()
            let visible = table.rows(in:scroll.documentVisibleRect)
            if visible.location != NSNotFound,visible.length > 0 {
                for index in visible.location..<min(state.rows.count,visible.location+visible.length) {
                    guard let cell = table.view(atColumn:0,row:index,makeIfNecessary:true) as? Cell else { continue }
                    configure(cell,row:state.rows[index],index:index,force:false)
                    guard let host = cell.host else { continue }
                    host.layoutSubtreeIfNeeded()
                    let height = host.fittingSize.height
                    if state.commit(height:Double(height),for:state.rows[index],ticket:ticket,scale:Double(scale)) { changed.insert(index) }
                }
            }
            if !changed.isEmpty { table.noteHeightOfRows(withIndexesChanged:changed);heightCommits += 1;table.layoutSubtreeIfNeeded() }
            if let navigation,valid(navigation) { restore(navigation.target,centered:navigation.centered) }
            else { navigation = nil;if let anchor { restore(anchor,centered:false) } }
            transaction = false
            lastClip = scroll.documentVisibleRect;retainedAnchor = captureAnchor()
            let live = liveHosts.allObjects.count;maxHosted = max(maxHosted,live)
            reportViewport()
            // A changed row can expose its neighbor. Its creation/invalidation
            // queues the next measurement; stable cells never trigger a timer.
        }
        private func valid(_ navigation:Navigation)->Bool {
            guard let parent else { return false }
            // Width commits can advance geometry generation; reader and input
            // identity, not that retiling, decide whether explicit navigation lives.
            if case let .post(id,_) = navigation.target,state.index(of:id) == nil { return false }
            return !parent.model.loadingHistory && navigation.ticket.scope == state.scope && navigation.ticket.input == state.inputGeneration
                && parent.model.historyScrollRevision == navigation.history && parent.model.latestHistoryScrollRevision == navigation.latest
        }
        private func restore(_ anchor:NativeTableTimelineState.Anchor,centered:Bool) {
            guard let table,let scroll else { return }
            let visible = scroll.documentVisibleRect
            var target = anchor
            if centered,case let .post(id,_) = anchor,let row = state.index(of:id) {
                target = .post(id,offset:Double((visible.height-table.rect(ofRow:row).height)/2))
            }
            let origins = state.rows.indices.map { Double(table.rect(ofRow:$0).minY) }
            guard let y = NativeTableTimelineState.target(for:target,rows:state.rows,origins:origins,viewport:Double(visible.height),document:Double(table.bounds.height)) else { return }
            scroll.contentView.scroll(to:CGPoint(x:visible.minX,y:CGFloat(y)));scroll.reflectScrolledClipView(scroll.contentView)
        }
        private func reportViewport() {
            guard let parent,let table,let scroll,let scope = state.scope,
                  scope.account == parent.model.accountGeneration,scope.channel == parent.model.selection,scope.token == parent.model.historyViewportToken else { return }
            let visible = scroll.documentVisibleRect
            let lastID = parent.model.posts.last?.id
            let lastMeasuredVisible = lastID.flatMap { id -> Bool? in
                guard let index = state.index(of:id),state.heights[.post(id)] != nil,
                      table.rect(ofRow:index).intersects(visible),
                      let cell = table.view(atColumn:0,row:index,makeIfNecessary:false) as? Cell else { return false }
                return cell.host != nil
            } ?? false
            let bottom = lastMeasuredVisible && NativeScrollVisibility.isAtBottom(content:table.bounds,visible:visible,flipped:true)
            if lastReportedBottom != bottom { lastReportedBottom = bottom;parent.onBottomChanged(bottom) }
            let range = table.rows(in:visible)
            guard range.location != NSNotFound,range.length > 0 else { return }
            for index in range.location..<min(state.rows.count,range.location+range.length) {
                guard case let .post(id) = state.rows[index],let cell = table.view(atColumn:0,row:index,makeIfNecessary:false) as? Cell,cell.host != nil else { continue }
                let row = table.rect(ofRow:index)
                guard row.intersection(visible).height >= min(20,row.height) else { continue }
                parent.model.noteTimelineViewport(postID:id,atBottom:bottom,token:scope.token,account:scope.account,channelID:scope.channel)
                break
            }
        }
        private func diagnostics()->[String:Any] {
            let live = liveHosts.allObjects.count
            var liveRowFrames:[[String:Any]] = []
            if parent?.fixtureEditors.isEmpty == false,let table {
                table.enumerateAvailableRowViews { view,index in
                    guard index >= 0,index < table.numberOfRows else { return }
                    let actual = view.convert(view.bounds,to:table),native = table.rect(ofRow:index)
                    liveRowFrames.append(["index":index,"actual":NSStringFromRect(actual),"native":NSStringFromRect(native),"delta_y":actual.minY-native.minY,"delta_height":actual.height-native.height,
                        "wants_layer":view.wantsLayer,"has_layer":view.layer != nil,"presentation_frame":view.layer?.presentation().map { NSStringFromRect($0.frame) } ?? "none"])
                }
            }
            return ["hosted_cells":live,"max_hosted_cells":max(maxHosted,live),"attached_hosted_cells":cells.allObjects.filter { $0.host != nil }.count,"height_commits":heightCommits,
                    "cache_entries":state.heights.count,"row_count":state.rows.count,"width_pixels":state.widthPixels,
                    "account":state.scope?.account ?? -1,"channel":state.scope?.channel.map(String.init) ?? "nil",
                    "token":state.scope?.token.uuidString ?? "nil","input_generation":String(state.inputGeneration),
                    "automatic_row_heights":false,"prototype_only":true,"row_frame_trace":rowFrameTrace,"height_read_trace":heightReadTrace,
                    "height_policy":"published",
                    "native_height_rows":parent?.fixtureEditors.isEmpty == false ? (0..<(table?.numberOfRows ?? 0)).map { index in ["index":index,"rect":NSStringFromRect(table!.rect(ofRow:index))] as [String:Any] } : [],
                    "native_automatic_heights":table?.usesAutomaticRowHeights ?? false,
                    "table_wants_layer":table?.wantsLayer ?? false,"table_has_layer":table?.layer != nil,
                    "live_row_frames":liveRowFrames,
                    "animation_duration":NSAnimationContext.current.duration,"implicit_animation":NSAnimationContext.current.allowsImplicitAnimation,
                    "height_rows":parent?.fixtureEditors.isEmpty == false ? state.rows.map { ["row":String(describing:$0),"height":state.height(of:$0)] as [String:Any] } : []]
        }
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}
#endif
