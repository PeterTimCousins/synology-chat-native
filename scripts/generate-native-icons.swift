import AppKit
import Foundation

// Original vector artwork for the native client. The existing wrapper artwork
// is intentionally a separate asset and is never overwritten by this generator.
func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func bitmap(_ size: Int, draw: () -> Void) -> NSBitmapImageRep {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return image
}
func artwork(preview: Bool) -> NSBitmapImageRep {
    bitmap(1024) {
        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = color(0x17112B, alpha: 0.25); shadow.shadowBlurRadius = 26; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
        color(preview ? 0x0E344B : 0x5A2FA1).setFill(); tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: color(preview ? 0x197D96 : 0x9972EF), ending: color(preview ? 0x12394F : 0x512897))!.draw(in: tile, angle: -65)
        color(0xFFFFFF, alpha: 0.16).setStroke(); tile.lineWidth = 2; tile.stroke()

        let bubble = NSBezierPath(roundedRect: NSRect(x: 237, y: 332, width: 550, height: 420), xRadius: 108, yRadius: 108)
        let tail = NSBezierPath(); tail.move(to: NSPoint(x: 315, y: 360)); tail.line(to: NSPoint(x: 263, y: 236))
        tail.curve(to: NSPoint(x: 292, y: 223), controlPoint1: NSPoint(x: 253, y: 211), controlPoint2: NSPoint(x: 268, y: 209))
        tail.line(to: NSPoint(x: 475, y: 339)); tail.close(); bubble.append(tail)
        NSGraphicsContext.saveGraphicsState()
        let bubbleShadow = NSShadow(); bubbleShadow.shadowColor = color(0x1D1437, alpha: 0.2); bubbleShadow.shadowBlurRadius = 18; bubbleShadow.shadowOffset = NSSize(width: 0, height: -14); bubbleShadow.set()
        color(0xFCFAFF).setFill(); bubble.fill()
        NSGraphicsContext.restoreGraphicsState()
        color(preview ? 0x1E5C73 : 0x7750BE).setFill()
        NSBezierPath(roundedRect: NSRect(x: 348, y: 585, width: 325, height: 40), xRadius: 20, yRadius: 20).fill()
        NSBezierPath(roundedRect: NSRect(x: 348, y: 491, width: 224, height: 40), xRadius: 20, yRadius: 20).fill()

        let spark = NSBezierPath()
        for (index, point) in [(0.0, 70.0), (20.0, 20.0), (70.0, 0.0), (20.0, -20.0), (0.0, -70.0), (-20.0, -20.0), (-70.0, 0.0), (-20.0, 20.0)].enumerated() {
            let p = NSPoint(x: 772 + point.0, y: 774 + point.1); if index == 0 { spark.move(to: p) } else { spark.line(to: p) }
        }
        spark.close(); color(0x8DE5C7).setFill(); spark.fill()
        if preview {
            color(0xF5BD61).setFill(); NSBezierPath(ovalIn: NSRect(x: 685, y: 113, width: 212, height: 212)).fill()
            ("P" as NSString).draw(at: NSPoint(x: 751, y: 137), withAttributes: [.font: NSFont.systemFont(ofSize: 128, weight: .bold), .foregroundColor: color(0x163E53)])
        }
    }
}
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "packaging", isDirectory: true)
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("native-chat-icons-" + UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? FileManager.default.removeItem(at: scratch) }
for (name, preview) in [("NativeAppIcon", false), ("PreviewAppIcon", true)] {
    let full = artwork(preview: preview)
    try full.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    let image = NSImage(cgImage: full.cgImage!, size: NSSize(width: 1024, height: 1024))
    let iconset = scratch.appendingPathComponent(name + ".iconset", isDirectory: true)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: false)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = points * scale
            let representation = bitmap(pixels) { image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels)) }
            let filename = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
            try representation.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(filename))
        }
    }
    let tool = Process(); tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    tool.arguments = ["-c", "icns", "-o", output.appendingPathComponent(name + ".icns").path, iconset.path]
    try tool.run(); tool.waitUntilExit()
    guard tool.terminationStatus == 0 else { throw NSError(domain: "NativeIcon", code: Int(tool.terminationStatus)) }
    print("Generated \(name).png and \(name).icns")
}
