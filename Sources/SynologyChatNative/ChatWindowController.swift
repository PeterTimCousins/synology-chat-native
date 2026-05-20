import AppKit
import UserNotifications
import WebKit

final class ChatWindowController: NSWindowController {
    private let webView: WKWebView
    private let progressIndicator = NSProgressIndicator()
    private let normalMessageSound = NSSound(named: NSSound.Name("Glass"))
    private let softMessageSound = NSSound(named: NSSound.Name("Tink"))
    private var activeDownloads: [ObjectIdentifier: WKDownload] = [:]
    private var lastInactiveAt: Date?
    private var lastConnectionRecoveryAt: Date?
    private let connectionRecoveryInactiveThreshold: TimeInterval = 60
    private let connectionRecoveryThrottle: TimeInterval = 20

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.addUserScript(Theme.current.userScript)
        configuration.userContentController.addUserScript(WebNotificationBridge.userScript)

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1494, height: 968),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Synology Chat"
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        window.delegate = self
        configuration.userContentController.add(
            WeakScriptMessageHandler(delegate: self),
            name: WebNotificationBridge.handlerName
        )
        webView.navigationDelegate = self
        webView.uiDelegate = self
        UNUserNotificationCenter.current().delegate = self
        requestNotificationAuthorization()
        configureContentView()
        configureConnectionRecoveryObservers()
        loadHome()
        syncWindowActiveStateToWeb()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: WebNotificationBridge.handlerName
        )
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

    func applyTheme() {
        webView.evaluateJavaScript(Theme.current.installScript)
        switch Theme.current {
        case .original, .modernLight:
            window?.appearance = NSAppearance(named: .aqua)
        case .modernDark:
            window?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func copyDOMSnapshotToPasteboard() {
        webView.evaluateJavaScript(Self.domSnapshotScript) { result, error in
            guard error == nil, let snapshot = result as? String else {
                self.showSnapshotAlert(
                    title: "Could Not Copy DOM Snapshot",
                    message: error?.localizedDescription ?? "The page did not return a snapshot."
                )
                return
            }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snapshot, forType: .string)
            self.showSnapshotAlert(
                title: "DOM Snapshot Copied",
                message: "The live DOM and layout probe data are now on the clipboard."
            )
        }
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

    private func configureConnectionRecoveryObservers() {
        let appCenter = NotificationCenter.default
        appCenter.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        appCenter.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(screenDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    private func showInvalidURLAlert() {
        let alert = NSAlert()
        alert.messageText = "Invalid Synology Chat URL"
        alert.informativeText = "Open Settings and enter a valid HTTPS URL."
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showSnapshotAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, error in
            if let error {
                NSLog("Synology Chat notification permission error: \(error.localizedDescription)")
            }
        }
    }

    private func showNativeNotification(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Synology Chat" : title
        content.body = body
        content.userInfo = ["scnNotificationID": id]

        let request = UNNotificationRequest(
            identifier: nativeNotificationIdentifier(for: id),
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Synology Chat notification delivery error: \(error.localizedDescription)")
            }
        }
    }

    private func closeNativeNotification(id: String) {
        let identifier = nativeNotificationIdentifier(for: id)
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [identifier])
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private func nativeNotificationIdentifier(for id: String) -> String {
        "synology-chat-\(id)"
    }

    private func focusWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private var isNativeWindowActive: Bool {
        NSApp.isActive && window?.isKeyWindow == true && window?.isMiniaturized == false
    }

    private func handleChatEvent(payload: [String: Any]) {
        guard let id = payload["id"] as? String else { return }

        let muted = payload["muted"] as? Bool ?? false
        let title = payload["title"] as? String ?? "Chat"
        let body = payload["body"] as? String ?? ""
        let isCurrentChannel = payload["isCurrentChannel"] as? Bool ?? false

        if isNativeWindowActive && isCurrentChannel {
            playMessageSound(soft: true, muted: muted)
            return
        }

        playMessageSound(soft: false, muted: muted)
        showNativeNotification(id: id, title: title, body: body)
    }

    private func handleBrowserNotification(payload: [String: Any]) {
        guard let id = payload["id"] as? String else { return }

        let muted = payload["muted"] as? Bool ?? false
        let title = payload["title"] as? String ?? "Chat"
        let body = payload["body"] as? String ?? ""

        playMessageSound(soft: false, muted: muted)
        showNativeNotification(id: id, title: title, body: body)
    }

    private func handleUnreadCount(payload: [String: Any]) {
        let count = payload["count"] as? Int ?? (payload["count"] as? NSNumber)?.intValue ?? 0
        DispatchQueue.main.async {
            self.updateDockBadge(count: count)
        }
    }

    private func updateDockBadge(count: Int) {
        if count > 0 {
            let badgeView = DockBadgeView(
                frame: NSRect(x: 0, y: 0, width: 128, height: 128),
                icon: NSApp.applicationIconImage,
                count: count
            )
            NSApp.dockTile.contentView = badgeView
            NSApp.dockTile.badgeLabel = nil
        } else {
            NSApp.dockTile.contentView = nil
            NSApp.dockTile.badgeLabel = nil
        }

        NSApp.dockTile.display()
    }

    private func playMessageSound(soft: Bool, muted: Bool) {
        guard !muted else { return }

        let sound = soft ? softMessageSound : normalMessageSound
        guard let sound else {
            NSSound.beep()
            return
        }

        sound.stop()
        sound.volume = soft ? 0.35 : 0.85
        sound.play()
    }

    private func syncWindowActiveStateToWeb() {
        let active = isNativeWindowActive ? "true" : "false"
        webView.evaluateJavaScript(
            "window.__scnSetNativeWindowActive && window.__scnSetNativeWindowActive(\(active));"
        )
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        lastInactiveAt = Date()
        syncWindowActiveStateToWeb()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        syncWindowActiveStateToWeb()
        recoverConnectionAfterLifecycleResume(reason: "application became active", requireLongInactivePeriod: true)
    }

    @objc private func sessionDidResignActive(_ notification: Notification) {
        lastInactiveAt = Date()
        syncWindowActiveStateToWeb()
    }

    @objc private func sessionDidBecomeActive(_ notification: Notification) {
        recoverConnectionAfterLifecycleResume(reason: "session unlocked", requireLongInactivePeriod: false)
    }

    @objc private func systemDidWake(_ notification: Notification) {
        recoverConnectionAfterLifecycleResume(reason: "system woke", requireLongInactivePeriod: false)
    }

    @objc private func screenDidWake(_ notification: Notification) {
        recoverConnectionAfterLifecycleResume(reason: "screen woke", requireLongInactivePeriod: false)
    }

    private func recoverConnectionAfterLifecycleResume(reason: String, requireLongInactivePeriod: Bool) {
        if requireLongInactivePeriod {
            guard let lastInactiveAt,
                  Date().timeIntervalSince(lastInactiveAt) >= connectionRecoveryInactiveThreshold
            else {
                return
            }
        }

        if let lastConnectionRecoveryAt,
           Date().timeIntervalSince(lastConnectionRecoveryAt) < connectionRecoveryThrottle {
            return
        }

        lastConnectionRecoveryAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            NSLog("Synology Chat refreshing after %@", reason)
            if self.webView.url == nil {
                self.loadHome()
            } else {
                self.webView.reload()
            }
        }
    }
}

private extension ChatWindowController {
    static func javascriptStringLiteral(_ value: String) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
            let encoded = String(data: data, encoding: .utf8)
        else {
            return "''"
        }

        return String(encoded.dropFirst().dropLast())
    }

    static let domSnapshotScript = """
(() => {
  const selectors = [
    'html',
    'body',
    '.chat-content-panel',
    '.channel-list-main',
    '.chat-center-content-panel',
    '.chat-center-content-panel.collapsed',
    '.chat-center-content-panel.collapsed .msg-panel',
    '.chat-center-content-panel.collapsed .chat-msgview',
    '.chat-center-content-panel.collapsed .chat-msgview .scrollwrapper',
    '.chat-center-content-panel.collapsed .chat-msgview .vscrollerbase',
    '.chat-center-content-panel.collapsed .chat-msgview .vscrollerbar',
    '.chat-right-content-panel',
    '.chat-summary-tab-panel',
    '.summary-item',
    '.summary-item .post-list-view',
    '.summary-item .item-wrap'
  ];

  const styleFields = [
    'display',
    'position',
    'left',
    'right',
    'top',
    'width',
    'height',
    'boxSizing',
    'overflow',
    'overflowX',
    'overflowY',
    'backgroundColor',
    'backgroundImage',
    'borderTopColor',
    'borderRightColor',
    'borderBottomColor',
    'borderLeftColor',
    'borderTopWidth',
    'borderRightWidth',
    'borderBottomWidth',
    'borderLeftWidth',
    'borderTopLeftRadius',
    'borderTopRightRadius',
    'borderBottomRightRadius',
    'borderBottomLeftRadius',
    'boxShadow',
    'zIndex'
  ];

  const describe = (element) => {
    if (!element) return null;
    const rect = element.getBoundingClientRect();
    const styles = getComputedStyle(element);
    const computed = {};
    for (const field of styleFields) computed[field] = styles[field];
    return {
      tag: element.tagName.toLowerCase(),
      id: element.id || '',
      className: String(element.className || ''),
      inlineStyle: element.getAttribute('style') || '',
      rect: {
        x: Math.round(rect.x * 100) / 100,
        y: Math.round(rect.y * 100) / 100,
        width: Math.round(rect.width * 100) / 100,
        height: Math.round(rect.height * 100) / 100,
        right: Math.round(rect.right * 100) / 100,
        bottom: Math.round(rect.bottom * 100) / 100
      },
      computed
    };
  };

  const selectorSnapshots = selectors.map((selector) => ({
    selector,
    matches: Array.from(document.querySelectorAll(selector)).slice(0, 20).map(describe)
  }));

  const center = document.querySelector('.chat-center-content-panel.collapsed') || document.querySelector('.chat-center-content-panel');
  const right = document.querySelector('.chat-right-content-panel');
  const probeRects = [center, right].filter(Boolean).map(describe);
  const edgeProbe = [];
  if (center) {
    const rect = center.getBoundingClientRect();
    const yValues = [
      rect.top + 12,
      rect.top + 80,
      rect.top + rect.height / 2,
      rect.bottom - 120,
      rect.bottom - 24
    ].filter((y) => y >= 0 && y <= window.innerHeight);
    const xValues = [rect.right - 6, rect.right - 2, rect.right + 2, rect.right + 6]
      .filter((x) => x >= 0 && x <= window.innerWidth);
    for (const y of yValues) {
      for (const x of xValues) {
        edgeProbe.push({
          x: Math.round(x * 100) / 100,
          y: Math.round(y * 100) / 100,
          stack: document.elementsFromPoint(x, y).slice(0, 12).map(describe)
        });
      }
    }
  }

  const payload = {
    url: location.href,
    title: document.title,
    timestamp: new Date().toISOString(),
    viewport: {
      width: window.innerWidth,
      height: window.innerHeight,
      devicePixelRatio: window.devicePixelRatio
    },
    theme: document.documentElement.getAttribute('data-scn-theme'),
    bodyClass: document.body.className,
    probeRects,
    selectorSnapshots,
    edgeProbe,
    html: document.documentElement.outerHTML
  };

  return JSON.stringify(payload, null, 2);
})();
"""
}

extension ChatWindowController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WebNotificationBridge.handlerName,
              let payload = message.body as? [String: Any],
              let kind = payload["kind"] as? String
        else {
            return
        }

        switch kind {
        case "requestPermission":
            requestNotificationAuthorization()
        case "chatEvent":
            handleChatEvent(payload: payload)
        case "browserNotification":
            handleBrowserNotification(payload: payload)
        case "unreadCount":
            guard message.frameInfo.isMainFrame else { return }
            handleUnreadCount(payload: payload)
        case "close":
            guard let id = payload["id"] as? String else { return }
            closeNativeNotification(id: id)
        default:
            break
        }
    }
}

extension ChatWindowController: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        syncWindowActiveStateToWeb()
    }

    func windowDidResignKey(_ notification: Notification) {
        syncWindowActiveStateToWeb()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        syncWindowActiveStateToWeb()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        syncWindowActiveStateToWeb()
    }
}

extension ChatWindowController: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            self.focusWindow()

            guard let id = response.notification.request.content.userInfo["scnNotificationID"] as? String else {
                return
            }

            self.webView.evaluateJavaScript(
                """
                window.__scnDispatchNativeNotificationClick && window.__scnDispatchNativeNotificationClick(\(Self.javascriptStringLiteral(id)));
                """
            )
        }
        completionHandler()
    }
}

private final class DockBadgeView: NSView {
    private let icon: NSImage?
    private let count: Int

    init(frame: NSRect, icon: NSImage?, count: Int) {
        self.icon = icon
        self.count = count
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let icon {
            icon.draw(in: bounds)
        }

        let label = count > 99 ? "99+" : String(count)
        let fontSize: CGFloat = label.count > 2 ? 24 : 30
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let labelSize = label.size(withAttributes: attributes)
        let badgeHeight: CGFloat = 42
        let badgeWidth = max(badgeHeight, labelSize.width + 22)
        let badgeRect = NSRect(
            x: bounds.maxX - badgeWidth - 2,
            y: bounds.maxY - badgeHeight - 2,
            width: badgeWidth,
            height: badgeHeight
        )

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 4
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()

        NSColor.systemRed.setFill()
        NSBezierPath(
            roundedRect: badgeRect,
            xRadius: badgeHeight / 2,
            yRadius: badgeHeight / 2
        ).fill()
        NSGraphicsContext.restoreGraphicsState()

        let labelRect = NSRect(
            x: badgeRect.midX - labelSize.width / 2,
            y: badgeRect.midY - labelSize.height / 2,
            width: labelSize.width,
            height: labelSize.height
        )
        label.draw(in: labelRect, withAttributes: attributes)
    }
}

extension ChatWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progressIndicator.startAnimation(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressIndicator.stopAnimation(nil)
        applyTheme()
        syncWindowActiveStateToWeb()
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

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard navigationResponse.canShowMIMEType,
              !navigationResponse.response.isAttachment
        else {
            decisionHandler(.download)
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        track(download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        track(download)
    }

    fileprivate func shouldOpenInBrowser(url: URL, navigationAction: WKNavigationAction) -> Bool {
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

    private func track(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        activeDownloads[id] = download
        download.delegate = self
    }
}

extension ChatWindowController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.resolvesAliases = true

        let handleResult = { (response: NSApplication.ModalResponse) in
            completionHandler(response == .OK ? panel.urls : nil)
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handleResult)
        } else {
            handleResult(panel.runModal())
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            if shouldOpenInBrowser(url: url, navigationAction: navigationAction) {
                NSWorkspace.shared.open(url)
            } else {
                webView.load(navigationAction.request)
            }
        }
        return nil
    }
}

extension ChatWindowController: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        let handleResult = { (response: NSApplication.ModalResponse) in
            completionHandler(response == .OK ? panel.url : nil)
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handleResult)
        } else {
            handleResult(panel.runModal())
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        activeDownloads[ObjectIdentifier(download)] = nil
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        activeDownloads[ObjectIdentifier(download)] = nil
    }
}

private extension URLResponse {
    var isAttachment: Bool {
        guard let response = self as? HTTPURLResponse,
              let disposition = response.value(forHTTPHeaderField: "Content-Disposition")
        else {
            return false
        }

        return disposition.localizedCaseInsensitiveContains("attachment")
    }
}
