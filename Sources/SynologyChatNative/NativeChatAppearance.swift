import AppKit
import SwiftUI
import Combine
import ImageIO

/// The native default remains dark unless this Mac explicitly follows the account.
@MainActor final class NativeAppearancePreferences: ObservableObject {
    static let shared = NativeAppearancePreferences(defaults: .standard)
    static let key = "nativeDesktop.followAccountAppearance"
    @Published var followsAccount: Bool { didSet { defaults?.set(followsAccount, forKey: Self.key) } }
    private let defaults: UserDefaults?
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        followsAccount = defaults?.bool(forKey: Self.key) ?? false
    }
}

private struct NativeChatStyleKey: EnvironmentKey { static let defaultValue = ChatAppearanceStyle.dark }
extension EnvironmentValues {
    var nativeChatStyle: ChatAppearanceStyle {
        get { self[NativeChatStyleKey.self] }
        set { self[NativeChatStyleKey.self] = newValue }
    }
}
extension ChatAppearanceStyle {
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}
private struct NativeChatAppearanceModifier: ViewModifier {
    @Environment(\.nativeChatStyle) private var style
    func body(content: Content) -> some View { content.preferredColorScheme(style.colorScheme) }
}
extension View {
    func nativeChatAppearance() -> some View { modifier(NativeChatAppearanceModifier()) }
}


struct NativeConversationWallpaper: View {
    @ObservedObject var model: NativeChatPreviewModel
    let settings: ChatAppearanceSettings?
    var behindMessages = false
    @State private var image: NSImage?
    private var identity: String { "\(model.accountGeneration):\(settings?.style.rawValue ?? "none"):\(settings?.background.rawValue ?? 0)" }
    var body: some View {
        GeometryReader { bounds in
            if let image {
                ZStack {
                    Image(nsImage: image).resizable().scaledToFill()
                    if behindMessages { NativeChatColors.canvas.opacity(0.9) }
                }.frame(width: bounds.size.width, height: bounds.size.height).clipped()
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
            .task(id: identity) {
                image = nil
                guard let settings, settings.background.rawValue != 0 else { return }
                do {
                    let bytes = try await model.loadAppearanceWallpaper(settings)
                    try Task.checkCancellation()
                    image = bytes.flatMap(NSImage.init(data:))
                } catch { /* Optional artwork never prevents reading messages. */ }
            }
    }
}

struct NativeAppearanceSettingsView: View {
    @ObservedObject var model: NativeChatPreviewModel
    @ObservedObject var preferences: NativeAppearancePreferences
    @Environment(\.dismiss) private var dismiss
    @State private var source: ChatAppearanceSettingsSnapshot?
    @State private var style = ChatAppearanceStyle.dark
    @State private var background = ChatAppearanceBackground.preset0
    @State private var busy = false
    @State private var failure: String?
    @State private var task: Task<Void, Never>?
    @State private var discard: String?
    @State private var epoch = -1
    private var desired: ChatAppearanceSettings { .init(style: style, background: background) }
    private var dirty: Bool { source.map { $0.settings != desired } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Appearance").font(.title2.bold())
                    Text("A space that feels like yours").font(.callout).foregroundColor(NativeChatColors.muted)
                }
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
            Toggle("Follow my Synology account’s appearance on this Mac", isOn: $preferences.followsAccount)
            Text(preferences.followsAccount ? "Your account theme and background are used here and in Synology Chat." : "This Mac keeps Chat Native’s dark appearance. Account choices below still apply to Synology Chat.")
                .font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal: false, vertical: true)
            Divider()
            if source != nil {
                HStack(spacing: 12) {
                    ForEach(ChatAppearanceStyle.allCases, id: \.self) { choice in
                        Button { style = choice } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 5) {
                                    RoundedRectangle(cornerRadius: 3).fill(choice == .dark ? Color(red: 0.25, green: 0.20, blue: 0.30) : Color(red: 0.88, green: 0.84, blue: 0.92)).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 7) {
                                        Capsule().fill(choice == .dark ? Color.gray : Color.gray.opacity(0.4)).frame(width: 64, height: 4)
                                        Capsule().fill(Color.gray.opacity(0.35)).frame(width: 95, height: 4)
                                        Capsule().fill(Color.gray.opacity(0.35)).frame(width: 72, height: 4)
                                    }.padding(10)
                                    Spacer()
                                }.frame(height: 62).background(choice == .dark ? Color(red: 0.12, green: 0.13, blue: 0.15) : .white).clipShape(RoundedRectangle(cornerRadius: 7))
                                HStack { Text(choice == .dark ? "Dark" : "Light"); Spacer(); Image(systemName: style == choice ? "checkmark.circle.fill" : "circle").foregroundColor(style == choice ? NativeChatColors.green : NativeChatColors.muted) }
                            }.padding(12).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(style == choice ? NativeChatColors.green : NativeChatColors.separator))
                        }.buttonStyle(.plain).accessibilityLabel((choice == .dark ? "Dark" : "Light") + " account theme").accessibilityAddTraits(style == choice ? .isSelected : [])
                    }
                }.disabled(busy)
                Text("Conversation background").font(.headline)
                HStack(spacing: 12) {
                    ForEach(ChatAppearanceBackground.allCases, id: \.self) { choice in
                        Button { background = choice } label: {
                            ZStack(alignment: .bottomTrailing) {
                                NativeConversationWallpaper(model: model, settings: .init(style: style, background: choice))
                                    .background(style == .dark ? Color(red: 26/255, green: 29/255, blue: 33/255) : Color(red: 250/255, green: 249/255, blue: 252/255)).frame(height: 80).clipped()
                                Text(choice.rawValue == 0 ? "Plain" : "\(choice.rawValue)").font(.caption.bold()).padding(5).background(NativeChatColors.surface.opacity(0.9)).clipShape(Capsule()).padding(6)
                            }.clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(background == choice ? NativeChatColors.green : NativeChatColors.separator, lineWidth: background == choice ? 2 : 1))
                        }.buttonStyle(.plain).accessibilityLabel(choice.rawValue == 0 ? "Plain account background" : "Account background \(choice.rawValue)").accessibilityAddTraits(background == choice ? .isSelected : [])
                    }
                }.disabled(busy)
                Text("These choices are saved to your Synology Chat account. Your messages and drafts stay in place.").font(.caption).foregroundColor(NativeChatColors.muted)
            }
            if busy { ProgressView("Checking account appearance…") }
            if let failure { Text(failure).font(.callout).foregroundColor(.orange) }
            HStack {
                Button("Refresh") { if dirty { discard = "refresh" } else { run() } }.disabled(busy)
                Spacer()
                Button("Save account appearance") { run(save: true) }.buttonStyle(NativeSendButtonStyle()).disabled(!dirty || busy || model.appearanceSettingsNeedRefresh)
            }
        }.padding(24).frame(width: 600).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas)
            .nativeChatAppearance().interactiveDismissDisabled(busy || dirty)
            .onAppear { epoch = model.accountGeneration; model.conversationLibraryVisible = true; run() }
            .onDisappear { task?.cancel(); model.conversationLibraryVisible = false }
            .onChange(of: model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of: model.connected) { if !$0 { dismiss() } }
            .alert("Discard appearance edits?", isPresented: Binding(get: { discard != nil }, set: { if !$0 { discard = nil } }),presenting:discard) { action in
                Button("Keep editing", role: .cancel) { discard = nil }
                Button("Discard edits", role: .destructive) { discard = nil; if action == "refresh" { run() } else { dismiss() } }
            } message: { _ in Text("Your unsaved account appearance choices will be discarded.") }
    }
    private func close() { if dirty { discard = "close" } else { dismiss() } }
    private func run(save: Bool = false) {
        guard !busy else { return }
        let requested = desired
        busy = true; failure = nil
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let updated: ChatAppearanceSettingsSnapshot
                if save, let source { updated = try await model.saveAppearanceSettings(original: source, desired: requested) }
                else { updated = try await model.loadAppearanceSettings() }
                try Task.checkCancellation()
                source = updated; style = updated.settings.style; background = updated.settings.background
            } catch is CancellationError { }
            catch { failure = (error as? ChatPreferenceUpdateFailure)?.message ?? "Could not verify account appearance. Refresh before saving again." }
        }
    }
}
