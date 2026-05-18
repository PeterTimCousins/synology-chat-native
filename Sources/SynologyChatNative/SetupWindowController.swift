import AppKit

final class SetupWindowController: NSWindowController {
    private let addressField = NSTextField()
    private let errorLabel = NSTextField(labelWithString: "")
    private let onComplete: () -> Void

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up Synology Chat"
        super.init(window: window)
        configureContentView()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureContentView() {
        guard let contentView = window?.contentView else { return }

        let titleLabel = NSTextField(labelWithString: "Connect to Synology Chat")
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)

        let bodyLabel = NSTextField(wrappingLabelWithString: "Enter your Synology server address or QuickConnect ID. You can use a full Chat URL, example.synology.me:5001, or a bare QuickConnect ID.")
        bodyLabel.textColor = .secondaryLabelColor

        addressField.placeholderString = "example.synology.me:5001 or QuickConnectID"
        addressField.target = self
        addressField.action = #selector(connect)

        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let connectButton = NSButton(title: "Connect", target: self, action: #selector(connect))
        connectButton.keyEquivalent = "\r"

        let quitButton = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))

        for view in [titleLabel, bodyLabel, addressField, errorLabel, connectButton, quitButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),

            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),

            addressField.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            addressField.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            addressField.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 18),

            errorLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            errorLabel.topAnchor.constraint(equalTo: addressField.bottomAnchor, constant: 8),

            connectButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            connectButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22),

            quitButton.trailingAnchor.constraint(equalTo: connectButton.leadingAnchor, constant: -10),
            quitButton.centerYAnchor.constraint(equalTo: connectButton.centerYAnchor)
        ])
    }

    @objc private func connect() {
        do {
            let normalizedURL = try ServerAddress.normalizedChatURL(from: addressField.stringValue)
            UserDefaults.standard.set(normalizedURL, forKey: Defaults.chatURL)
            onComplete()
            close()
        } catch {
            errorLabel.stringValue = (error as? LocalizedError)?.errorDescription ?? "Invalid server address."
            errorLabel.isHidden = false
        }
    }
}
