import AppKit
import SwiftUI
import Combine
import ServiceManagement

@MainActor protocol NativeLoginItemService: AnyObject {
    var state: NativeLoginItemState { get }
    func setEnabled(_ enabled: Bool) async throws
}
enum NativeLoginItemState: Equatable {
    case disabled, enabled, requiresApproval, unavailable
    var requested: Bool { self == .enabled || self == .requiresApproval }
    var description: String {
        switch self {
        case .disabled: return "Off"
        case .enabled: return "On"
        case .requiresApproval: return "Waiting for approval in macOS Login Items"
        case .unavailable: return "macOS cannot find this app as a login item"
        }
    }
}
@MainActor final class NativeSystemLoginItem: NativeLoginItemService {
    var state: NativeLoginItemState {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .disabled
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }
    func setEnabled(_ enabled: Bool) async throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try await SMAppService.mainApp.unregister() }
    }
}
@MainActor final class NativeDesktopPreferences: ObservableObject {
    static let shared = NativeDesktopPreferences(defaults: .standard, loginItem: NativeSystemLoginItem())
    static let menuBarKey = "nativeDesktop.showMenuBarIcon"
    @Published private(set) var showMenuBarIcon: Bool
    @Published private(set) var loginState: NativeLoginItemState
    @Published private(set) var changingLoginItem = false
    @Published private(set) var loginError: String?
    private let defaults: UserDefaults?
    private let loginItem: NativeLoginItemService
    init(defaults: UserDefaults? = nil, loginItem: NativeLoginItemService) {
        self.defaults = defaults; self.loginItem = loginItem
        showMenuBarIcon = defaults?.bool(forKey: Self.menuBarKey) ?? false
        loginState = loginItem.state
    }
    func setMenuBarIcon(_ value: Bool) {
        guard value != showMenuBarIcon else { return }
        showMenuBarIcon = value; defaults?.set(value, forKey: Self.menuBarKey)
    }
    func refreshLoginItem() { guard !changingLoginItem else { return }; loginState = loginItem.state }
    func setOpenAtLogin(_ enabled: Bool) async {
        guard !changingLoginItem else { return }
        loginState = loginItem.state; loginError = nil
        guard enabled != loginState.requested else { return }
        changingLoginItem = true
        defer { loginState = loginItem.state; changingLoginItem = false }
        do { try await loginItem.setEnabled(enabled) }
        catch { loginError = "macOS could not change Open at Login. Check Login Items in System Settings and try again." }
    }
}

struct NativeDesktopSettingsView: View {
    @ObservedObject var model: NativeChatPreviewModel
    @ObservedObject var preferences: NativeDesktopPreferences
    @ObservedObject private var downloadPreferences:ChatDownloadPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var downloads = false
    @State private var notificationPreferences = false
    @State private var calendarPreferences = false
    init(model:NativeChatPreviewModel,preferences:NativeDesktopPreferences) {
        self.model = model;self.preferences = preferences;self.downloadPreferences = model.downloadPreferences
    }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"gearshape").font(.system(size:22)).foregroundColor(NativeChatColors.green)
                Text("Settings").font(.system(size:20,weight:.bold));Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            Divider().overlay(NativeChatColors.separator)
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    settingsCard("General",icon:"macwindow") {
                        HStack(alignment:.top,spacing:16) {
                            VStack(alignment:.leading,spacing:5) {
                                Text("Open at login").font(.callout.weight(.medium))
                                Text(preferences.changingLoginItem ? "Updating macOS Login Items…" : preferences.loginState.description)
                                    .font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                                    .accessibilityLabel("Open at login: " + preferences.loginState.description)
                            }
                            Spacer(minLength:12)
                            Toggle("Open at login",isOn:Binding(get:{ preferences.loginState.requested },set:{ value in Task { await preferences.setOpenAtLogin(value) } }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(preferences.changingLoginItem)
                        }
                        if let error = preferences.loginError { Text(error).font(.callout).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true) }
                        Button("Open macOS Login Items…") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(NativeToolbarButtonStyle())
                        Divider().overlay(NativeChatColors.separator)
                        HStack {
                            Text("Show in menu bar").font(.callout.weight(.medium));Spacer()
                            Toggle("Show in menu bar",isOn:Binding(get:{ preferences.showMenuBarIcon },set:{ preferences.setMenuBarIcon($0) }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                        Text("Closing the chat window keeps messages and notifications connected. Choose Quit to stop the app.")
                            .font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
                    }
                    settingsCard("Notifications",icon:"bell.badge") {
                        Text("Delivery on this Mac, account alerts and quiet hours.").font(.callout).foregroundColor(NativeChatColors.muted)
                        Button("Notification preferences…") { notificationPreferences = true }
                            .buttonStyle(NativeToolbarButtonStyle()).disabled(!model.connected)
                    }
                    settingsCard("Calendar",icon:"calendar") {
                        Text("Recognise dates in messages and review calendar events.").font(.callout).foregroundColor(NativeChatColors.muted)
                        Button("Calendar preferences…") { calendarPreferences = true }.buttonStyle(NativeToolbarButtonStyle()).disabled(!model.connected)
                    }
                    settingsCard("Downloads",icon:"arrow.down.to.line") {
                        Text(downloadPreferences.lastFolder?.path ?? "Default Downloads folder")
                            .font(.callout).foregroundColor(NativeChatColors.muted).lineLimit(2).truncationMode(.middle)
                            .help(downloadPreferences.lastFolder?.path ?? "Default Downloads folder")
                        Button("Download settings…") { downloads = true }.buttonStyle(NativeToolbarButtonStyle())
                    }
                }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
            }
        }.frame(width:600,height:600).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .onAppear { model.conversationLibraryVisible = true; preferences.refreshLoginItem() }
            .onDisappear { model.conversationLibraryVisible = false }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in preferences.refreshLoginItem() }
            .sheet(isPresented: $downloads,onDismiss:{ model.conversationLibraryVisible = true }) { NativeDownloadSettingsView(preferences: downloadPreferences) }
            .sheet(isPresented:$notificationPreferences,onDismiss:{ model.conversationLibraryVisible = true }) { NativeNotificationSettingsView(model:model) }
            .sheet(isPresented:$calendarPreferences,onDismiss:{ model.conversationLibraryVisible = true }) { NativeCalendarPreferencesView(model:model) }
    }
    private func settingsCard<Content:View>(_ title:String,icon:String,@ViewBuilder content:()->Content)->some View {
        VStack(alignment:.leading,spacing:12) {
            Label(title,systemImage:icon).font(.system(size:14,weight:.semibold))
            content()
        }.frame(maxWidth:.infinity,alignment:.leading).padding(16)
            .background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(NativeChatColors.separator))
    }
}

@MainActor final class NativeMenuBarController: NSObject {
    private var item: NSStatusItem?
    private var observation: AnyCancellable?
    private let show: () -> Void
    private let settings: () -> Void
    private let quit: () -> Void
    private var unread = 0
    init(preferences: NativeDesktopPreferences, show: @escaping () -> Void, settings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.show = show; self.settings = settings; self.quit = quit
        super.init()
        observation = preferences.$showMenuBarIcon.removeDuplicates().sink { [weak self] in self?.setVisible($0) }
    }
    private func setVisible(_ visible: Bool) {
        if visible, item == nil {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            for (title, action) in [("Show Synology Chat", #selector(showChat)), ("Settings…", #selector(showSettings)), ("Quit Synology Chat", #selector(quitChat))] {
                let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); entry.target = self
            }
            item?.menu = menu; updateUnread(unread)
        } else if !visible, let existing = item { NSStatusBar.system.removeStatusItem(existing); item = nil }
    }
    static func unreadLabel(_ count: Int) -> String { count > 0 ? count > 99 ? "99+" : String(count) : "" }
    func updateUnread(_ count: Int) {
        unread = max(0, count)
        let image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Synology Chat")
        image?.isTemplate = true; item?.button?.image = image
        item?.button?.title = Self.unreadLabel(unread)
        item?.button?.imagePosition = .imageLeading
        item?.button?.toolTip = unread > 0 ? "Synology Chat · \(unread) unread messages" : "Synology Chat"
        item?.button?.setAccessibilityLabel(item?.button?.toolTip)
    }
    @objc private func showChat() { show() }
    @objc private func showSettings() { settings() }
    @objc private func quitChat() { quit() }
    func stop() { observation?.cancel(); observation = nil; setVisible(false) }
    deinit { if let item { NSStatusBar.system.removeStatusItem(item) } }
}
