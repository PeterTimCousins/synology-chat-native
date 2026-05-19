import AppKit

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let urlField = NSTextField()
    private let themePopup = NSPopUpButton()
    private weak var chatWindowController: ChatWindowController?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureContentView()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show(for controller: ChatWindowController) {
        chatWindowController = controller
        urlField.stringValue = UserDefaults.standard.string(forKey: Defaults.chatURL) ?? ""
        selectCurrentTheme()
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureContentView() {
        guard let contentView = window?.contentView else { return }

        let label = NSTextField(labelWithString: "Synology server address, QuickConnect ID, or Chat URL")
        let themeLabel = NSTextField(labelWithString: "Theme")
        let saveButton = NSButton(title: "Save and Reload", target: self, action: #selector(saveAndReload))
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))

        urlField.placeholderString = "example.synology.me:5001 or QuickConnectID"
        Theme.allCases.forEach { themePopup.addItem(withTitle: $0.title) }

        for view in [label, urlField, themeLabel, themePopup, saveButton, cancelButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            urlField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            urlField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            urlField.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),

            themeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            themeLabel.topAnchor.constraint(equalTo: urlField.bottomAnchor, constant: 18),

            themePopup.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 150),
            themePopup.centerYAnchor.constraint(equalTo: themeLabel.centerYAnchor),
            themePopup.widthAnchor.constraint(equalToConstant: 190),

            saveButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor)
        ])
    }

    @objc private func saveAndReload() {
        let normalizedURL: String
        do {
            normalizedURL = try ServerAddress.normalizedChatURL(from: urlField.stringValue)
        } catch {
            showInvalidURLAlert()
            return
        }

        UserDefaults.standard.set(normalizedURL, forKey: Defaults.chatURL)
        UserDefaults.standard.set(selectedTheme.rawValue, forKey: Defaults.theme)
        close()
        chatWindowController?.applyTheme()
        chatWindowController?.loadHome()
    }

    @objc private func cancel() {
        close()
    }

    private func showInvalidURLAlert() {
        let alert = NSAlert()
        alert.messageText = "Invalid Server Address"
        alert.informativeText = "Enter a full Synology Chat URL, a server address such as example.synology.me:5001, or a QuickConnect ID."
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window!)
    }

    private var selectedTheme: Theme {
        let index = themePopup.indexOfSelectedItem
        guard Theme.allCases.indices.contains(index) else {
            return .modernDark
        }
        return Theme.allCases[index]
    }

    private func selectCurrentTheme() {
        guard let index = Theme.allCases.firstIndex(of: Theme.current) else {
            themePopup.selectItem(at: 0)
            return
        }
        themePopup.selectItem(at: index)
    }
}
