import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: ChatWindowController?
    private var setupWindowController: SetupWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            Defaults.theme: Theme.modernDark.rawValue
        ])

        guard UserDefaults.standard.string(forKey: Defaults.chatURL)?.isEmpty == false else {
            showSetup()
            return
        }

        openChat()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func showSetup() {
        let controller = SetupWindowController { [weak self] in
            self?.setupWindowController = nil
            self?.openChat()
        }
        controller.showWindow(nil)
        setupWindowController = controller
    }

    private func openChat() {
        let controller = ChatWindowController()
        controller.showWindow(nil)
        windowController = controller
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

    @IBAction func copyDOMSnapshot(_ sender: Any?) {
        windowController?.copyDOMSnapshotToPasteboard()
    }
}
