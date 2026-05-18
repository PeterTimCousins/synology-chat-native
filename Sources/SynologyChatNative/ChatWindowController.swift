import AppKit
import WebKit

final class ChatWindowController: NSWindowController {
    private let webView: WKWebView
    private let progressIndicator = NSProgressIndicator()

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Synology Chat"
        window.minSize = NSSize(width: 760, height: 520)
        window.center()

        super.init(window: window)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        configureContentView()
        loadHome()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func loadHome() {
        guard let url = URL(string: UserDefaults.standard.string(forKey: Defaults.chatURL) ?? "") else {
            showInvalidURLAlert()
            return
        }
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        if webView.canGoBack {
            webView.goBack()
        }
    }

    func goForward() {
        if webView.canGoForward {
            webView.goForward()
        }
    }

    func reload() {
        webView.reload()
    }

    private func configureContentView() {
        guard let contentView = window?.contentView else { return }
        webView.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        contentView.addSubview(webView)
        contentView.addSubview(progressIndicator)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            progressIndicator.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            progressIndicator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        ])
    }

    private func showInvalidURLAlert() {
        let alert = NSAlert()
        alert.messageText = "Invalid Synology Chat URL"
        alert.informativeText = "Open Settings and enter a valid HTTPS URL."
        alert.alertStyle = .warning
        alert.runModal()
    }
}

extension ChatWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progressIndicator.startAnimation(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressIndicator.stopAnimation(nil)
        window?.title = webView.title?.isEmpty == false ? webView.title! : "Synology Chat"
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        progressIndicator.stopAnimation(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        progressIndicator.stopAnimation(nil)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if shouldOpenInBrowser(url: url, navigationAction: navigationAction) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    private func shouldOpenInBrowser(url: URL, navigationAction: WKNavigationAction) -> Bool {
        guard let host = url.host,
              let homeURL = URL(string: UserDefaults.standard.string(forKey: Defaults.chatURL) ?? ""),
              let homeHost = homeURL.host
        else {
            return false
        }

        if navigationAction.navigationType == .linkActivated && host != homeHost {
            return true
        }

        return false
    }
}

extension ChatWindowController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}
