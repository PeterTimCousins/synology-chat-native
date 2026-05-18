import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: ChatWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            Defaults.chatURL: "https://costwisegroup.synology.me:2891/?launchApp=SYNO.SDS.Chat.Application#channels/11"
        ])

        let controller = ChatWindowController()
        controller.showWindow(nil)
        windowController = controller
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @IBAction func openSettings(_ sender: Any?) {
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
}
