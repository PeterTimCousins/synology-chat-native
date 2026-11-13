import Foundation
import CoreGraphics

/// Zoom is relative to physical image pixels, independent of the fitted scale.
/// The decoded viewer image uses one logical image unit per source pixel.
struct NativeImageViewerZoom: Equatable {
    enum Mode: Equatable { case fit, percentage(CGFloat) }
    private(set) var mode: Mode = .fit
    static let steps: [CGFloat] = [0.05, 0.1, 0.125, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4]
    static let inset: CGFloat = 24

    mutating func fit() { mode = .fit }
    mutating func actualSize() { mode = .percentage(1) }
    var isFit: Bool { mode == .fit }

    func fraction(imageSize: CGSize, viewport: CGSize, displayScale: CGFloat) -> CGFloat {
        switch mode {
        case .fit: return Self.fitFraction(imageSize: imageSize, viewport: viewport, displayScale: displayScale)
        case .percentage(let value): return value
        }
    }

    /// A fraction of 1 maps each source pixel to one physical display pixel.
    func layoutSize(imageSize: CGSize, viewport: CGSize, displayScale: CGFloat) -> CGSize {
        guard Self.valid(imageSize) else { return .zero }
        let factor = fraction(imageSize: imageSize, viewport: viewport, displayScale: displayScale) / Self.screenScale(displayScale)
        return CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
    }

    func next(_ direction: Int, imageSize: CGSize, viewport: CGSize, displayScale: CGFloat) -> CGFloat? {
        guard direction != 0, Self.valid(imageSize), Self.valid(viewport) else { return nil }
        let current = fraction(imageSize: imageSize, viewport: viewport, displayScale: displayScale)
        // Include a fit smaller than 5% so very large images can always return to fit.
        let minimum = min(Self.steps[0], Self.fitFraction(imageSize: imageSize, viewport: viewport, displayScale: displayScale))
        let choices = ([minimum] + Self.steps).sorted()
        if direction > 0 { return choices.first { $0 > current + 0.000001 } }
        return choices.last { $0 < current - 0.000001 }
    }

    mutating func step(_ direction: Int, imageSize: CGSize, viewport: CGSize, displayScale: CGFloat) {
        if let value = next(direction, imageSize: imageSize, viewport: viewport, displayScale: displayScale) { mode = .percentage(value) }
    }

    /// Gesture values are cumulative from the beginning of a pinch. Return a
    /// derived zoom for live rendering; callers commit it only when the gesture ends.
    func magnified(_ factor: CGFloat, imageSize: CGSize, viewport: CGSize, displayScale: CGFloat) -> Self {
        guard factor.isFinite, factor > 0, factor != 1, Self.valid(imageSize), Self.valid(viewport) else { return self }
        let minimum = min(Self.steps[0], Self.fitFraction(imageSize:imageSize,viewport:viewport,displayScale:displayScale))
        let fraction = fraction(imageSize:imageSize,viewport:viewport,displayScale:displayScale)
        var result = self
        result.mode = .percentage(min(Self.steps.last!,max(minimum,fraction * factor)))
        return result
    }

    mutating func toggleActualSize() {
        if mode == .percentage(1) { fit() } else { actualSize() }
    }

    static func fitFraction(imageSize: CGSize, viewport: CGSize, displayScale: CGFloat) -> CGFloat {
        guard valid(imageSize), valid(viewport) else { return 1 }
        let available = CGSize(width: max(1, viewport.width - 2 * inset), height: max(1, viewport.height - 2 * inset))
        // Fit does not enlarge small images beyond their original physical pixels.
        return min(1, min(available.width / imageSize.width, available.height / imageSize.height) * screenScale(displayScale))
    }

    private static func screenScale(_ value: CGFloat) -> CGFloat { value.isFinite && value > 0 ? value : 1 }
    private static func valid(_ size: CGSize) -> Bool { size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 }
}
