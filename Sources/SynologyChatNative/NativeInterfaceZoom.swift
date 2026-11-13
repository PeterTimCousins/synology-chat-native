import AppKit
import SwiftUI

@MainActor final class NativeInterfaceZoom: ObservableObject {
    static let key = "nativeDesktop.interfaceZoom"
    static let levels: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
    static let logicalMinimum = CGSize(width: 800, height: 560)
    @Published private(set) var effective: Double = 1
    private(set) var requested: Double
    private let defaults: UserDefaults?
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        let value = defaults?.object(forKey: Self.key) as? Double ?? 1
        requested = Self.valid(value) ? value : 1
    }
    static func valid(_ value: Double) -> Bool { value.isFinite && value >= levels[0] && value <= levels.last! }
    static func capacity(contentSize: CGSize) -> Double {
        guard contentSize.width.isFinite, contentSize.height.isFinite, contentSize.width > 0, contentSize.height > 0 else { return 1 }
        // A small display may still be below the app's minimum at 50%; use the
        // minimum level in that case, rather than making text arbitrarily tiny.
        return max(levels[0], min(levels.last!, Double(contentSize.width / logicalMinimum.width), Double(contentSize.height / logicalMinimum.height)))
    }
    func fit(contentSize: CGSize) { effective = min(requested, Self.capacity(contentSize: contentSize)) }
    func next(_ direction: Int, maximum: Double) -> Double? {
        guard maximum.isFinite, maximum > 0 else { return nil }
        if direction > 0 { return Self.levels.first { $0 > effective + 0.001 && $0 <= maximum + 0.001 } }
        if direction < 0 { return Self.levels.last { $0 < effective - 0.001 } }
        return nil
    }
    func set(_ value: Double) {
        guard Self.valid(value) else { return }
        requested = value
        if value == 1 { defaults?.removeObject(forKey: Self.key) } else { defaults?.set(value, forKey: Self.key) }
    }
}

/// Scale a stable SwiftUI hierarchy and its layout together. Keeping the same
/// root identity preserves composer text, selection and in-flight tasks.
struct NativeChatZoomRoot: View {
    let model: NativeChatPreviewModel
    @ObservedObject var zoom: NativeInterfaceZoom
    var body: some View {
        GeometryReader { viewport in
            NativeChatPreviewView(model: model)
                .frame(width: viewport.size.width / zoom.effective, height: viewport.size.height / zoom.effective)
                .scaleEffect(zoom.effective, anchor: .topLeading)
        }.background(NativeChatColors.canvas)
    }
}
