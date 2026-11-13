import Foundation

/// Scalar geometry only. No model, message text, or offscreen hosting trees.
struct NativeTableTimelineState {
    struct Scope:Hashable { let account:Int;let channel:Int64?;let token:UUID;var rootID:Int64? = nil }
    enum Row:Hashable { case top,older,post(Int64),empty,newer,bottom,threadRoot(Int64),threadDivider,threadLatest }
    enum Anchor:Equatable { case bottom;case post(Int64,offset:Double) }
    struct Ticket:Equatable { let scope:Scope;let generation:UInt64;let input:UInt64 }
    private(set) var scope:Scope?
    private(set) var rows:[Row] = []
    private(set) var widthPixels:Int = 0
    private(set) var generation:UInt64 = 0
    private(set) var inputGeneration:UInt64 = 0
    private(set) var heights:[Row:Double] = [:]
    // Invalidating a measurement must not silently change the height that
    // AppKit has already laid out. Retain it until explicit remeasurement
    // publishes a replacement through noteHeightOfRows.
    private var publishedHeights:[Row:Double] = [:]
    private var presentations:[Int64:Int] = [:]
    var ticket:Ticket? { scope.map { Ticket(scope:$0,generation:generation,input:inputGeneration) } }
    mutating func replace(scope:Scope,postIDs:[Int64],older:Bool,newer:Bool,empty:Bool,presentations:[Int64:Int] = [:],threadRootID:Int64? = nil,threadLatest:Bool = false) {
        let replacement = self.scope != scope
        if replacement { self.scope = scope;heights = [:];publishedHeights = [:];self.presentations = [:];generation &+= 1;inputGeneration &+= 1 }
        var seen = Set<Int64>()
        let ids = postIDs.filter { $0 > 0 && $0 != threadRootID && seen.insert($0).inserted }
        let header:[Row] = threadRootID.flatMap { $0 > 0 ? [.threadRoot($0),.threadDivider] : nil } ?? []
        let next:[Row] = [.top] + header + (threadLatest ? [.threadLatest] : []) + (older ? [.older] : []) + ids.map(Row.post) + (empty && ids.isEmpty ? [.empty] : []) + (newer ? [.newer] : []) + [.bottom]
        if !replacement && (next != rows || presentations != self.presentations) { generation &+= 1 }
        let retained = Set(next)
        heights = heights.filter { retained.contains($0.key) }
        publishedHeights = publishedHeights.filter { retained.contains($0.key) }
        for id in ids where self.presentations[id] != presentations[id] { heights[.post(id)] = nil }
        if let id = threadRootID,self.presentations[id] != presentations[id] { heights[.threadRoot(id)] = nil }
        self.presentations = presentations;rows = next
    }
    mutating func setWidth(_ width:Double,scale:Double)->Bool {
        guard width.isFinite,scale.isFinite,width > 0,scale > 0 else { return false }
        let value = (width*scale).rounded()
        guard value.isFinite,value > 0,value < Double(Int.max) else { return false }
        let pixels = Int(value)
        guard pixels != widthPixels else { return false }
        widthPixels = pixels;heights = [:];generation &+= 1;return true
    }
    mutating func userInput() { inputGeneration &+= 1 }
    func accepts(_ ticket:Ticket)->Bool { self.ticket == ticket }
    func index(of id:Int64)->Int? { rows.firstIndex(of:.post(id)) ?? rows.firstIndex(of:.threadRoot(id)) }
    func height(of row:Row)->Double {
        if let value = heights[row] ?? publishedHeights[row] { return value }
        switch row { case .top:return 20;case .bottom:return 21;case .threadDivider:return 9;case .older,.newer,.empty,.threadLatest:return 40;case .post,.threadRoot:return 90 }
    }
    @discardableResult mutating func commit(height:Double,for row:Row,ticket:Ticket,scale:Double)->Bool {
        guard accepts(ticket),rows.contains(row),height.isFinite,height > 0,scale.isFinite,scale > 0 else { return false }
        let rounded = ceil(height*scale)/scale
        guard rounded.isFinite,rounded > 0 else { return false }
        let changed = abs(self.height(of:row)-rounded) >= 0.5/scale
        heights[row] = rounded;publishedHeights[row] = rounded
        return changed
    }
    static func target(for anchor:Anchor,rows:[Row],origins:[Double],viewport:Double,document:Double)->Double? {
        guard viewport.isFinite,document.isFinite,viewport > 0,document >= 0 else { return nil }
        let maximum = max(0,document-viewport)
        switch anchor {
        case .bottom:return maximum
        case let .post(id,offset):
            guard offset.isFinite,let index = rows.firstIndex(of:.post(id)) ?? rows.firstIndex(of:.threadRoot(id)),origins.indices.contains(index),origins[index].isFinite else { return nil }
            return min(maximum,max(0,origins[index]-offset))
        }
    }
}
