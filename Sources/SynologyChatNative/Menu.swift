import AppKit

enum MenuBuilder {
    static func install() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu
        let delegate = NSApp.delegate

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)

        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Synology Chat Native", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings...", action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = delegate
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Synology Chat Native", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)

        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let navigationItem = NSMenuItem()
        mainMenu.addItem(navigationItem)

        let navigationMenu = NSMenu(title: "Navigation")
        navigationItem.submenu = navigationMenu
        let homeItem = navigationMenu.addItem(withTitle: "Home", action: #selector(AppDelegate.goHome(_:)), keyEquivalent: "0")
        let backItem = navigationMenu.addItem(withTitle: "Back", action: #selector(AppDelegate.goBack(_:)), keyEquivalent: "[")
        let forwardItem = navigationMenu.addItem(withTitle: "Forward", action: #selector(AppDelegate.goForward(_:)), keyEquivalent: "]")
        let reloadItem = navigationMenu.addItem(withTitle: "Reload", action: #selector(AppDelegate.reload(_:)), keyEquivalent: "r")
        [homeItem, backItem, forwardItem, reloadItem].forEach { $0.target = delegate }

        let developerItem = NSMenuItem()
        mainMenu.addItem(developerItem)

        let developerMenu = NSMenu(title: "Developer")
        developerItem.submenu = developerMenu
        let copyDOMItem = developerMenu.addItem(
            withTitle: "Copy DOM Snapshot",
            action: #selector(AppDelegate.copyDOMSnapshot(_:)),
            keyEquivalent: "d"
        )
        copyDOMItem.keyEquivalentModifierMask = [.command, .shift]
        copyDOMItem.target = delegate
    }
}
