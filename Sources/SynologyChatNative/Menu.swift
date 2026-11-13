import AppKit

/// Localizes only the native client's menu titles. The wrapper keeps its
/// original English titles and does not perform catalog lookups.
struct NativeMenuText {
    let native:Bool
    let language:NativeInterfaceLanguage
    let bundle:Bundle?
    func text(_ key:String)->String {
        native ? NativeLocalizedStrings.text(key,language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle) : key
    }
    func application(_ key:String,name:String)->String {
        native ? NativeLocalizedStrings.object(key,name,language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle)
            : key.replacingOccurrences(of:"%@",with:name)
    }
}

enum MenuBuilder {
    static func install(language:NativeInterfaceLanguage = .system,bundle:Bundle? = nil) {
        let titles = NativeMenuText(native:NativeChatAppConfiguration.standalone,language:language,bundle:bundle)
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu
        let delegate = NSApp.delegate
        let appName = NativeChatAppConfiguration.standalone ? NativeChatAppConfiguration.productName : "Synology Chat Native"

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)

        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: titles.application("About %@",name:appName), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        do {
            let settingsItem = appMenu.addItem(withTitle: titles.text("Settings..."), action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
            settingsItem.target = delegate
            appMenu.addItem(NSMenuItem.separator())
        }
        if NativeChatAppConfiguration.standalone {
            let services = NSMenu(title: titles.text("Services"))
            let servicesItem = appMenu.addItem(withTitle: titles.text("Services"), action: nil, keyEquivalent: "")
            servicesItem.submenu = services; NSApp.servicesMenu = services
            appMenu.addItem(.separator())
            appMenu.addItem(withTitle: titles.application("Hide %@",name:appName), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h").target = NSApp
            let hideOthers = appMenu.addItem(withTitle: titles.text("Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            hideOthers.keyEquivalentModifierMask = [.command, .shift]; hideOthers.target = NSApp
            appMenu.addItem(withTitle: titles.text("Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "").target = NSApp
            appMenu.addItem(.separator())
        }
        let quitItem = appMenu.addItem(withTitle: titles.application("Quit %@",name:appName), action: #selector(AppDelegate.quitApplication(_:)), keyEquivalent: "q")
        quitItem.target = delegate

        if NativeChatAppConfiguration.standalone {
            let fileItem = NSMenuItem()
            mainMenu.addItem(fileItem)
            let fileMenu = NSMenu(title: titles.text("File"))
            fileItem.submenu = fileMenu
            fileMenu.addItem(withTitle: titles.text("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        }

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)

        let editMenu = NSMenu(title: titles.text("Edit"))
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: titles.text("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: titles.text("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: titles.text("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: titles.text("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: titles.text("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: titles.text("Paste and Match Style"), action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
        editMenu.addItem(withTitle: titles.text("Delete"), action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: titles.text("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        if NativeChatAppConfiguration.standalone {
            let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
            let viewMenu = NSMenu(title: titles.text("View")); viewItem.submenu = viewMenu
            viewMenu.addItem(withTitle: titles.text("Actual Size"), action: #selector(AppDelegate.resetNativeZoom(_:)), keyEquivalent: "0").target = delegate
            viewMenu.addItem(withTitle: titles.text("Zoom In"), action: #selector(AppDelegate.increaseNativeZoom(_:)), keyEquivalent: "+").target = delegate
            let equalZoom = viewMenu.addItem(withTitle: titles.text("Zoom In"), action: #selector(AppDelegate.increaseNativeZoom(_:)), keyEquivalent: "=")
            equalZoom.target = delegate; equalZoom.isHidden = true; equalZoom.allowsKeyEquivalentWhenHidden = true
            viewMenu.addItem(withTitle: titles.text("Zoom Out"), action: #selector(AppDelegate.decreaseNativeZoom(_:)), keyEquivalent: "-").target = delegate
            viewMenu.addItem(.separator())
            let fullscreen = viewMenu.addItem(withTitle: titles.text("Enter Full Screen"), action: #selector(AppDelegate.toggleNativeFullScreen(_:)), keyEquivalent: "f")
            fullscreen.keyEquivalentModifierMask = [.control, .command]; fullscreen.target = delegate
        }

        if NativeChatAppConfiguration.standalone {
            let windowItem = NSMenuItem()
            mainMenu.addItem(windowItem)
            let windowMenu = NSMenu(title: titles.text("Window"))
            windowItem.submenu = windowMenu
            NSApp.windowsMenu = windowMenu
            let show = windowMenu.addItem(withTitle: titles.application("Show %@",name:appName), action: #selector(AppDelegate.openNativePreview(_:)), keyEquivalent: "")
            show.target = delegate
            windowMenu.addItem(.separator())
            let compact = windowMenu.addItem(withTitle: titles.text("Compact Window"), action: #selector(AppDelegate.compactNativeWindow(_:)), keyEquivalent: "")
            let comfortable = windowMenu.addItem(withTitle: titles.text("Comfortable Window"), action: #selector(AppDelegate.comfortableNativeWindow(_:)), keyEquivalent: "")
            compact.target = delegate; comfortable.target = delegate
            windowMenu.addItem(.separator())
            windowMenu.addItem(withTitle: titles.text("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            windowMenu.addItem(withTitle: titles.text("Zoom Window"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
            windowMenu.addItem(.separator())
            windowMenu.addItem(withTitle: titles.text("Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "").target = NSApp
        } else {
            let navigationItem = NSMenuItem()
            mainMenu.addItem(navigationItem)

            let navigationMenu = NSMenu(title: titles.text("Navigation"))
            navigationItem.submenu = navigationMenu
            let homeItem = navigationMenu.addItem(withTitle: titles.text("Home"), action: #selector(AppDelegate.goHome(_:)), keyEquivalent: "0")
            let backItem = navigationMenu.addItem(withTitle: titles.text("Back"), action: #selector(AppDelegate.goBack(_:)), keyEquivalent: "[")
            let forwardItem = navigationMenu.addItem(withTitle: titles.text("Forward"), action: #selector(AppDelegate.goForward(_:)), keyEquivalent: "]")
            let reloadItem = navigationMenu.addItem(withTitle: titles.text("Reload"), action: #selector(AppDelegate.reload(_:)), keyEquivalent: "r")
            [homeItem, backItem, forwardItem, reloadItem].forEach { $0.target = delegate }
        }

        guard NativeChatAppConfiguration.developmentUI else { return }
        let developerItem = NSMenuItem()
        mainMenu.addItem(developerItem)

        let developerMenu = NSMenu(title: "Developer")
        developerItem.submenu = developerMenu
        let nativeItem = developerMenu.addItem(withTitle: "Open Native Chat Preview",
            action: #selector(AppDelegate.openNativePreview(_:)), keyEquivalent: "")
        nativeItem.target = delegate
        #if DEBUG
        if NativeChatAppConfiguration.standalone && NativeChatAppConfiguration.allowsOfficialSessionImport {
            developerMenu.addItem(withTitle:"Stage Synthetic Media",action:#selector(AppDelegate.stageSyntheticMedia(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Stage Synthetic Animated Image",action:#selector(AppDelegate.stageSyntheticAnimatedImage(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Stage Synthetic PDF",action:#selector(AppDelegate.stageSyntheticDocument(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Review Synthetic Pasted Image",
                action:#selector(AppDelegate.reviewSyntheticPastedImage(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Review Synthetic Dropped Files",
                action:#selector(AppDelegate.reviewSyntheticDroppedFiles(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Stage Synthetic Peter Files",
                action:#selector(AppDelegate.stageSyntheticAttachmentBatch(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Open Appearance Fixture", action:#selector(AppDelegate.openAppearanceFixture(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Toggle Appearance Fixture Size", action:#selector(AppDelegate.toggleAppearanceFixtureSize(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Open Read Details Fixture",
                action:#selector(AppDelegate.openReadStatusFixture(_:)),keyEquivalent:"").target = delegate
            let dropFixture = developerMenu.addItem(withTitle:"Open Conversation Drop Fixture",action:#selector(AppDelegate.openConversationDropFixture(_:)),keyEquivalent:"d")
            dropFixture.keyEquivalentModifierMask = [.control,.option,.command];dropFixture.target = delegate
            developerMenu.addItem(withTitle:"Open Screenshot Fixture",action:#selector(AppDelegate.openScreenshotFixture(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Open Bot Subscriptions Fixture",action:#selector(AppDelegate.openBotSubscriptionsFixture(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Open Bot Attachments Fixture",
                action:#selector(AppDelegate.openBotAttachmentsFixture(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Open Drive Files Fixture",
                action:#selector(AppDelegate.openDriveFilesFixture(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Open NAS Files Fixture",
                action:#selector(AppDelegate.openNASFilesFixture(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Open Application Launcher Fixture",
                action:#selector(AppDelegate.openApplicationLauncherFixture(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Open Regional Settings Fixture",
                action:#selector(AppDelegate.openRegionalSettingsFixture(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Open Paired Devices Fixture",
                action:#selector(AppDelegate.openPairedDevicesFixture(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Open Profile Photo Fixture",
                action:#selector(AppDelegate.openProfilePhotoFixture(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Open Profile Editor Fixture",
                action:#selector(AppDelegate.openProfileEditorFixture(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Open Availability Fixture",
                action:#selector(AppDelegate.openManualPresenceFixture(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Open Notification Preferences Fixture",
                action:#selector(AppDelegate.openNotificationSettingsFixture(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Open Channel Recovery Fixture",
                action:#selector(AppDelegate.openChannelRecoveryFixture(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle:"Open Archive Attachment Fixture",
                action:#selector(AppDelegate.openArchiveFixture(_:)),keyEquivalent:"").target = delegate
            developerMenu.addItem(withTitle: "Open Rich Links Fixture",
                action: #selector(AppDelegate.openRichLinksFixture(_:)), keyEquivalent: "").target = delegate
            developerMenu.addItem(withTitle: "Open Channel Guests Fixture",
                action: #selector(AppDelegate.openChannelGuestsFixture(_:)), keyEquivalent: "").target = delegate
            developerMenu.addItem(withTitle: "Open Office Preview Fixture",
                action: #selector(AppDelegate.openOfficePreviewFixture(_:)), keyEquivalent: "").target = delegate
            developerMenu.addItem(withTitle: "Open Encryption Management Fixture",
                action: #selector(AppDelegate.openEncryptionManagementFixture(_:)), keyEquivalent: "").target = delegate
            let fixture = developerMenu.addItem(withTitle: "Open Synthetic Encryption Fixture",
                action: #selector(AppDelegate.openEncryptedUIFixture(_:)), keyEquivalent: "")
            fixture.target = delegate
        }
        #endif
        developerMenu.addItem(.separator())
        let copyDOMItem = developerMenu.addItem(
            withTitle: "Copy DOM Snapshot",
            action: #selector(AppDelegate.copyDOMSnapshot(_:)),
            keyEquivalent: "d"
        )
        copyDOMItem.keyEquivalentModifierMask = [.command, .shift]
        copyDOMItem.target = delegate
    }
}
