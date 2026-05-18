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

        let navigationItem = NSMenuItem()
        mainMenu.addItem(navigationItem)

        let navigationMenu = NSMenu(title: "Navigation")
        navigationItem.submenu = navigationMenu
        let homeItem = navigationMenu.addItem(withTitle: "Home", action: #selector(AppDelegate.goHome(_:)), keyEquivalent: "0")
        let backItem = navigationMenu.addItem(withTitle: "Back", action: #selector(AppDelegate.goBack(_:)), keyEquivalent: "[")
        let forwardItem = navigationMenu.addItem(withTitle: "Forward", action: #selector(AppDelegate.goForward(_:)), keyEquivalent: "]")
        let reloadItem = navigationMenu.addItem(withTitle: "Reload", action: #selector(AppDelegate.reload(_:)), keyEquivalent: "r")
        [homeItem, backItem, forwardItem, reloadItem].forEach { $0.target = delegate }
    }
}
