import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windowController: ChatWindowController?
    private var nativePreviewWindowController: NativeChatPreviewWindowController?
    private var nativeMenuBar: NativeMenuBarController?
    private var setupWindowController: SetupWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = NativeMediaTemporaryFiles.shared
        _ = NativeSnippetTemporaryFiles.shared
        UserDefaults.standard.register(defaults: [
            Defaults.theme: Theme.modernDark.rawValue
        ])

        if NativeChatAppConfiguration.standalone {
            if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
               let file = Bundle.main.url(forResource: name, withExtension: "icns"),
               let icon = NSImage(contentsOf: file) { NSApp.applicationIconImage = icon }
            nativeMenuBar = NativeMenuBarController(preferences: .shared, show: { [weak self] in self?.openNativePreview(nil) }, settings: { [weak self] in self?.openSettings(nil) }, quit: { [weak self] in self?.quitApplication(nil) })
            openNativePreview(nil)
            nativePreviewWindowController?.observeUnread { [weak self] in self?.nativeMenuBar?.updateUnread($0) }
            return
        }

        guard UserDefaults.standard.string(forKey: Defaults.chatURL)?.isEmpty == false else {
            showSetup()
            return
        }

        openChat()
    }

    func applicationWillTerminate(_ notification:Notification) {
        nativeMenuBar?.stop()
        nativePreviewWindowController?.prepareForTermination()
        NativeMediaTemporaryFiles.shared.removeAll()
        NativeSnippetTemporaryFiles.shared.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showPrimaryWindow()
        }
        return true
    }

    private func showSetup() {
        if let controller = setupWindowController {
            controller.showWindow(nil)
            return
        }

        let controller = SetupWindowController { [weak self] in
            self?.setupWindowController = nil
            self?.openChat()
        }
        controller.showWindow(nil)
        setupWindowController = controller
    }

    private func openChat() {
        if let controller = windowController {
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = ChatWindowController()
        controller.showWindow(nil)
        windowController = controller
    }

    private func showPrimaryWindow() {
        if NativeChatAppConfiguration.standalone {
            openNativePreview(nil)
            return
        }
        guard UserDefaults.standard.string(forKey: Defaults.chatURL)?.isEmpty == false else {
            showSetup()
            return
        }

        openChat()
    }

    @IBAction func openSettings(_ sender: Any?) {
        if NativeChatAppConfiguration.standalone {
            openNativePreview(nil); nativePreviewWindowController?.showDesktopSettings(); return
        }
        guard let controller = windowController else { return }
        SettingsWindowController.shared.show(for: controller)
    }

    @IBAction func goHome(_ sender: Any?) {
        windowController?.loadHome()
    }

    @IBAction func goBack(_ sender: Any?) {
        windowController?.goBack()
    }

    @IBAction func goForward(_ sender: Any?) {
        windowController?.goForward()
    }

    @IBAction func reload(_ sender: Any?) {
        windowController?.reload()
    }

    @IBAction func openNativePreview(_ sender: Any?) {
        if nativePreviewWindowController == nil {
            nativePreviewWindowController = NativeChatPreviewWindowController()
        }
        nativePreviewWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    #if DEBUG
    @IBAction func openEncryptedUIFixture(_ sender: Any?) { NativeEncryptedUIFixture.present() }
    @IBAction func stageSyntheticMedia(_ sender:Any?) { nativePreviewWindowController?.stageSyntheticMedia() }
    @IBAction func stageSyntheticAnimatedImage(_ sender:Any?) { nativePreviewWindowController?.stageSyntheticAnimatedImage() }
    @IBAction func stageSyntheticDocument(_ sender:Any?) { nativePreviewWindowController?.stageSyntheticDocument() }
    @IBAction func reviewSyntheticPastedImage(_ sender:Any?) { nativePreviewWindowController?.reviewSyntheticComposerInput(image:true) }
    @IBAction func reviewSyntheticDroppedFiles(_ sender:Any?) { nativePreviewWindowController?.reviewSyntheticComposerInput(image:false) }
    @IBAction func stageSyntheticAttachmentBatch(_ sender: Any?) { nativePreviewWindowController?.stageSyntheticAttachmentBatch() }
    @IBAction func openReadStatusFixture(_ sender: Any?) { NativeReadStatusFixture.present() }
    @IBAction func openArchiveFixture(_ sender:Any?) { NativeArchiveUIFixture.present() }
    @IBAction func openChannelRecoveryFixture(_ sender:Any?) { NativeArchiveUIFixture.present(recovery:true) }
    @IBAction func openNotificationSettingsFixture(_ sender:Any?) { NativeNotificationSettingsFixture.present() }
    @IBAction func openBotSubscriptionsFixture(_ sender: Any?) { NativeBotSubscriptionsFixture.present() }
    @IBAction func openBotAttachmentsFixture(_ sender: Any?) { NativeBotAttachmentsFixture.present() }
    @IBAction func openConversationDropFixture(_ sender:Any?) { NativeConversationDropFixture.present() }
    @IBAction func openScreenshotFixture(_ sender:Any?) { NativeScreenshotFixture.present() }
    @IBAction func openNASFilesFixture(_ sender:Any?) { NativeNASFilesFixture.present() }
    @IBAction func openDriveFilesFixture(_ sender:Any?) { NativeDriveFilesFixture.present() }
    @IBAction func openApplicationLauncherFixture(_ sender:Any?) { NativeNotificationSettingsFixture.present(launcher:true) }
    @IBAction func openRegionalSettingsFixture(_ sender:Any?) { NativeNotificationSettingsFixture.present(regional:true) }
    @IBAction func openPairedDevicesFixture(_ sender:Any?) { NativeNotificationSettingsFixture.present(devices:true) }
    @IBAction func openProfilePhotoFixture(_ sender:Any?) { NativeNotificationSettingsFixture.present(photo:true) }
    @IBAction func openProfileEditorFixture(_ sender:Any?) { NativeNotificationSettingsFixture.present(profile:true) }
    @IBAction func openManualPresenceFixture(_ sender:Any?) { NativeNotificationSettingsFixture.present(presence:true) }
    @IBAction func openRichLinksFixture(_ sender: Any?) { NativeRichLinksFixture.present() }
    @IBAction func openChannelGuestsFixture(_ sender: Any?) { NativeChannelGuestsFixture.present() }
    @IBAction func openOfficePreviewFixture(_ sender: Any?) { NativeOfficePreviewFixture.present() }
    @IBAction func openEncryptionManagementFixture(_ sender: Any?) { NativeEncryptionManagementFixture.present() }
    @IBAction func openAppearanceFixture(_ sender: Any?) { NativeAppearanceFixture.present() }
    @IBAction func toggleAppearanceFixtureSize(_ sender: Any?) { NativeAppearanceFixture.toggleSize() }
    #endif

    @IBAction func increaseNativeZoom(_ sender: Any?) { nativePreviewWindowController?.stepZoom(1) }
    @IBAction func decreaseNativeZoom(_ sender: Any?) { nativePreviewWindowController?.stepZoom(-1) }
    @IBAction func resetNativeZoom(_ sender: Any?) { nativePreviewWindowController?.resetInterfaceZoom() }
    @IBAction func toggleNativeFullScreen(_ sender: Any?) { nativePreviewWindowController?.toggleNativeFullScreen() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(increaseNativeZoom(_:)): return nativePreviewWindowController?.canStepZoom(1) == true
        case #selector(decreaseNativeZoom(_:)): return nativePreviewWindowController?.canStepZoom(-1) == true
        case #selector(toggleNativeFullScreen(_:)):
            menuItem.title = nativePreviewWindowController?.isNativeFullScreen == true ? "Exit Full Screen" : "Enter Full Screen"
            return nativePreviewWindowController?.canChangeInterfaceZoom == true
        case #selector(resetNativeZoom(_:)): return nativePreviewWindowController?.canChangeInterfaceZoom == true
        case #selector(compactNativeWindow(_:)), #selector(comfortableNativeWindow(_:)):
            return nativePreviewWindowController?.canChangeInterfaceZoom == true && nativePreviewWindowController?.isNativeFullScreen == false
        default: return true
        }
    }

    @IBAction func compactNativeWindow(_ sender: Any?) {
        openNativePreview(nil)
        nativePreviewWindowController?.setCompactSize(true)
    }

    @IBAction func comfortableNativeWindow(_ sender: Any?) {
        openNativePreview(nil)
        nativePreviewWindowController?.setCompactSize(false)
    }

    @IBAction func quitApplication(_ sender: Any?) {
        // AppKit does not route its default Quit action through an active modal sheet.
        // End sheets first so Quit works while search, threads or a file picker is open.
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        }
        if NSApp.modalWindow != nil { NSApp.abortModal() }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    @IBAction func copyDOMSnapshot(_ sender: Any?) {
        windowController?.copyDOMSnapshotToPasteboard()
    }
}
