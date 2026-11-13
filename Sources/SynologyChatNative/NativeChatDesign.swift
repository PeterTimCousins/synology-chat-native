import AppKit
import SwiftUI

/// Shared native chat surfaces. Kept separate from the preserved wrapper's CSS.
enum NativeChatColors {
    private static func adaptive(_ name: String, dark: (Double, Double, Double), light: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("ChatNative." + name)) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0/255, green: rgb.1/255, blue: rgb.2/255, alpha: 1)
        })
    }
    static let canvas = adaptive("canvas", dark: (26,29,33), light: (250,249,252))
    static let sidebar = adaptive("sidebar", dark: (29,26,36), light: (242,238,247))
    static let surface = adaptive("surface", dark: (34,37,42), light: (255,255,255))
    static let elevated = adaptive("elevated", dark: (45,49,55), light: (234,232,239))
    static let selected = adaptive("selected", dark: (71,56,87), light: (222,210,238))
    static let text = adaptive("text", dark: (232,234,238), light: (37,31,46))
    static let muted = adaptive("muted", dark: (164,171,183), light: (101,94,112))
    static let green = adaptive("accent", dark: (113,210,183), light: (21,113,90))
    static let separator = adaptive("separator", dark: (44,47,51), light: (223,219,229))
    static let messageHover = adaptive("messageHover", dark: (32,35,40), light: (241,239,245))
}

struct NativeMessageQuickActionStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration)->some View {
        configuration.label.font(.system(size:13,weight:.medium))
            .frame(width:28,height:28)
            .background(configuration.isPressed ? NativeChatColors.elevated : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius:5))
            .contentShape(RoundedRectangle(cornerRadius:5))
            .opacity(enabled ? 1 : 0.4)
    }
}

struct NativeToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .frame(minWidth: 30, minHeight: 30)
            .foregroundColor(NativeChatColors.muted)
            .background(configuration.isPressed ? NativeChatColors.elevated : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.4)
    }
}

struct NativeSendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundColor(enabled ? NativeChatColors.canvas : NativeChatColors.muted)
            .background(enabled ? NativeChatColors.green.opacity(configuration.isPressed ? 0.75 : 1) : NativeChatColors.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct NativeChatAvatar: View {
    let name: String
    var size: CGFloat = 34
    var hexColor:String? = nil
    private var initials: String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
    private var color: Color {
        if let hexColor,hexColor.count == 7,hexColor.first == "#",let rgb = UInt32(hexColor.dropFirst(),radix:16) { return Color(red:Double((rgb >> 16) & 255)/255,green:Double((rgb >> 8) & 255)/255,blue:Double(rgb & 255)/255) }
        let colors = [Color(red: 0.34, green: 0.44, blue: 0.55), Color(red: 0.45, green: 0.37, blue: 0.54),
                      Color(red: 0.28, green: 0.47, blue: 0.43), Color(red: 0.52, green: 0.38, blue: 0.32)]
        return colors[name.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % colors.count }]
    }
    var body: some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.34, weight: .semibold))
            .foregroundColor(.white).frame(width: size, height: size)
            .background(color).clipShape(RoundedRectangle(cornerRadius: size * 0.23))
            .accessibilityHidden(true)
    }
}
