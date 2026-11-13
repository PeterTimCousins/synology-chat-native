import AppKit
import UserNotifications
import OSLog

struct ChatNotificationMessage: Equatable {
    let channelID: Int64
    let postID: Int64
    let threadID: Int64?
    let title: String
    let body: String
    let sound: Bool

    static func make(event: ChatLiveEvent, preferences: ChatNotificationPreferences?,
                     currentUserID: Int64?, visibleChannelID: Int64?, visibleThreadID: Int64? = nil, channelTitle: String, contentIsEncrypted: Bool = false, now:Date = Date(),accountTimeZone:TimeZone? = nil,personalReminderChannelID:Int64? = nil,language:NativeInterfaceLanguage = .system,bundle:Bundle? = nil) -> Self? {
        func text(_ key:String)->String { NativeLocalizedStrings.text(key,language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle) }
        func object(_ key:String,_ value:String)->String { NativeLocalizedStrings.object(key,value,language:language,bundle:bundle ?? NativeLocalizedStrings.resourceBundle) }
        if preferences?.pausesAlerts(at:now,timeZone:accountTimeZone) == true { return nil }
        let normalized = event.normalized
        guard let currentUserID, normalized.name == "client.notification.create", let value = normalized.payload["post"],
              let data = try? JSONEncoder().encode(value), let post = try? JSONDecoder().decode(ChatPost.self, from: data),
              post.id > 0,post.channel_id > 0,(post.delete_at ?? 0) == 0 else { return nil }
        let reminder = post.channel_id == personalReminderChannelID && post.props?.forward?.isReminder == true
        guard post.creator_id != currentUserID || reminder else { return nil }
        let isVisible = post.channel_id == visibleChannelID
            && (post.isReply ? post.thread_id == visibleThreadID : visibleThreadID == nil)
        if isVisible && preferences?.notification_browser_active != true { return nil }
        let preview = preferences?.notification_showmessage == true
        let body: String
        if preview && contentIsEncrypted {
            body = text(post.isReply ? "Encrypted reply" : "Encrypted message")
        } else if preview {
            switch post.type {
            case "normal": body = String(post.message.prefix(500))
            case "file": body = post.file_props?.name.map { object("Shared a file: %@",String($0.prefix(160))) } ?? text("Shared a file")
            case "sticker": body = text("Sent a sticker")
            case "vote": body = text("Created a poll")
            default: body = text("New activity")
            }
        } else { body = text(reminder ? "Message reminder" : post.isReply ? "New reply" : "New message") }
        return .init(channelID: post.channel_id, postID: post.id, threadID: post.isReply ? post.thread_id : nil,
                     title: preview ? (reminder ? object("Reminder · %@",channelTitle) : channelTitle) : "Synology Chat", body: body, sound: preferences?.notification_mute == false)
    }
}

struct ChatNotificationDestination: Equatable {
    let accountScope: String
    let channelID: Int64
    let postID: Int64
    let threadID: Int64?

    init?(userInfo: [AnyHashable: Any]) {
        guard let scope = userInfo["nativeAccountScope"] as? String, ChatNotificationAccountScope.isValid(scope),
              let channel = (userInfo["nativeChannelID"] as? String).flatMap(Int64.init), channel > 0,
              let post = (userInfo["nativePostID"] as? String).flatMap(Int64.init), post > 0 else { return nil }
        if let value = userInfo["nativeThreadID"], !(value is String) { return nil }
        let rawThread = userInfo["nativeThreadID"] as? String ?? ""
        let thread = Int64(rawThread)
        guard rawThread.isEmpty || (thread != nil && thread! > 0) else { return nil }
        accountScope = scope; channelID = channel; postID = post
        threadID = thread == post ? nil : thread
    }
}

@MainActor
final class NativeChatNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private enum Status:Equatable { case disabled,enabled,blocked,failed }
    @Published private var statusState = Status.disabled
    var status:String {
        let key:String
        switch statusState {
        case .disabled: key = "Enable notifications"
        case .enabled: key = "Notifications enabled"
        case .blocked: key = "Notifications blocked in System Settings"
        case .failed: key = "Could not enable notifications"
        }
        return NativeLocalizedStrings.text(key,language:interfaceLanguage,bundle:localizationBundle ?? NativeLocalizedStrings.resourceBundle)
    }
    var hasStatusNotice:Bool { statusState == .blocked || statusState == .failed }
    func diagnosticText(_ diagnostic:NativeNotificationDiagnostic)->String {
        diagnostic.text(language:interfaceLanguage,bundle:localizationBundle)
    }
    var testMessageBody:String {
        NativeLocalizedStrings.text("Notification delivery test",language:interfaceLanguage,bundle:localizationBundle ?? NativeLocalizedStrings.resourceBundle)
    }
    private let interfaceLanguage:NativeInterfaceLanguage
    private let localizationBundle:Bundle?
    private var initializedCenter: UNUserNotificationCenter?
    private var center: UNUserNotificationCenter {
        if let initializedCenter { return initializedCenter }
        let value = UNUserNotificationCenter.current()
        initializedCenter = value
        return value
    }
    private weak var previousDelegate: (any UNUserNotificationCenterDelegate)?
    private var enabled = false
    /// Local authorization/setting state, independent of presentation text and delivery scope.
    var isEnabled:Bool { enabled }
    private var authorizationAttempt = UUID()
    private var badgeCount = 0
    private var badgeTask: Task<Void, Never>?
    private let badgeLog = Logger(subsystem: "com.costwisegroup.synology-chat-native.api-preview", category: "native-badge")
    private let deliveryLog = Logger(subsystem: "com.costwisegroup.synology-chat-native.api", category: "native-delivery")
    private var deliverySession = ChatNotificationDeliverySession()
    private let submitOverride: ((UNNotificationRequest) async throws -> Void)?
    private let removeOverride: (([String]) -> Void)?
    private let authorizeOverride: (() async throws -> Bool)?
    var onDelivery: ((NativeNotificationDiagnostic) -> Void)?
    var onOpen: ((ChatNotificationDestination) -> Void)?

    init(submit: ((UNNotificationRequest) async throws -> Void)? = nil, remove: (([String]) -> Void)? = nil,
         authorize: (() async throws -> Bool)? = nil,language:NativeInterfaceLanguage = .system,bundle:Bundle? = nil) {
        interfaceLanguage = language;localizationBundle = bundle
        submitOverride = submit; removeOverride = remove
        authorizeOverride = authorize
        super.init()
    }

    func activateAccount(scope: String?) {
        authorizationAttempt = UUID()
        deliverySession.activate(scope: scope)
        removeObsoleteDelivered(keepSameAccount: true)
    }
    func suspendAccount() { authorizationAttempt = UUID(); deliverySession.suspend() }

    /// Install before authentication finishes so a launch triggered by a click can queue its destination.
    func prepareForResponses() {
        if center.delegate !== self { previousDelegate = center.delegate; center.delegate = self }
    }

    func enable(requestPermission: Bool = true) async {
        let attempt = UUID()
        authorizationAttempt = attempt
        do {
            let granted: Bool
            if let authorizeOverride { granted = try await authorizeOverride() }
            else if requestPermission {
                granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } else {
                let authorization = await center.notificationSettings().authorizationStatus
                granted = authorization == .authorized || authorization == .provisional
            }
            guard attempt == authorizationAttempt, !Task.isCancelled else { return }
            guard granted else {
                enabled = false
                statusState = .blocked; return
            }
            if submitOverride == nil { prepareForResponses() }
            enabled = true
            statusState = .enabled
        } catch {
            guard attempt == authorizationAttempt, !Task.isCancelled else { return }
            enabled = false
            statusState = .failed
        }
    }

    func disable() {
        enabled = false
        statusState = .disabled
        if let center = initializedCenter, center.delegate === self { center.delegate = previousDelegate }
        reset()
    }

    func reset() {
        authorizationAttempt = UUID()
        deliverySession.reset()
        removeObsoleteDelivered(keepSameAccount: false)
    }

    private func removeObsoleteDelivered(keepSameAccount: Bool) {
        // Headless API/model consumers never install a notification center.
        // Do not create one merely to clear notifications they could not deliver.
        guard let center = initializedCenter else { return }
        // Remove only this client's delivered notifications, preserving the wrapper's notifications.
        center.getDeliveredNotifications { [weak self] items in
            Task { @MainActor in
                guard let self else { return }
                let ids = items.filter { item in
                    self.deliverySession.shouldRemove(identifier: item.request.identifier,
                        userInfo: item.request.content.userInfo, keepSameAccount: keepSameAccount)
                }.map(\.request.identifier)
                self.removeRequests(ids)
            }
        }
    }

    private func removeRequests(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        if let removeOverride { removeOverride(identifiers); return }
        guard let center = initializedCenter else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func updateBadge(_ count: Int) {
        badgeCount = max(0, count)
        // AppKit's label and notification-service badge share this authoritative
        // unread count. Individual notifications must not capture a badge value.
        NSApp.dockTile.badgeLabel = badgeCount > 0 ? (badgeCount > 999 ? "999+" : String(badgeCount)) : nil
        NSApp.dockTile.display()
        guard badgeTask == nil else { return }
        badgeTask = Task { [weak self] in
            guard let self else { return }
            defer { badgeTask = nil }
            var submitted: Int
            repeat {
                submitted = badgeCount
                do {
                    try await center.setBadgeCount(submitted)
                    let settings = await center.notificationSettings()
                    badgeLog.notice("Unread badge: \(submitted, privacy: .public), permission: \(settings.badgeSetting.rawValue, privacy: .public)")
                } catch {
                    badgeLog.error("Badge update failed, code: \((error as NSError).code, privacy: .public)")
                    break
                }
            } while submitted != badgeCount
        }
    }

    func deliver(_ message: ChatNotificationMessage) {
        guard enabled else {
            deliveryLog.notice("Notification not submitted: local alerts disabled")
            return
        }
        guard let ticket = deliverySession.reserve(postID: message.postID) else {
            deliveryLog.notice("Notification not submitted: account inactive or event already reserved")
            return
        }
        let content = UNMutableNotificationContent()
        // nil leaves the badge unchanged. Delivery may finish after a newer
        // unread update, so a captured count here could restore stale state.
        content.title = message.title
        content.body = message.body
        if message.sound { content.sound = .default }
        content.userInfo = ["nativeChannelID": String(message.channelID), "nativePostID": String(message.postID),
                            "nativeThreadID": message.threadID.map(String.init) ?? "", "nativeAccountScope": ticket.scope,
                            "nativeDeliveryEpoch": ticket.epoch.uuidString]
        let request = UNNotificationRequest(identifier: ticket.identifier, content: content, trigger: nil)
        Task { [weak self] in
            guard let self else { return }
            guard deliverySession.isCurrent(ticket) else { return }
            do {
                if let submitOverride { try await submitOverride(request) }
                else { try await center.add(request) }
                guard deliverySession.complete(ticket) else { removeRequests([request.identifier]); return }
                deliveryLog.notice("Notification accepted by macOS")
                onDelivery?(.accepted)
            } catch {
                // Avoid logging message contents, credentials or server responses.
                guard deliverySession.isCurrent(ticket) else { return }
                deliverySession.fail(ticket)
                deliveryLog.error("Notification rejected by macOS; code=\((error as NSError).code, privacy: .public)")
                onDelivery?(.rejected((error as NSError).code))
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            if notification.request.identifier.hasPrefix("native-api:") {
                completionHandler(deliverySession.canPresent(userInfo: notification.request.content.userInfo) ? [.banner, .list, .sound, .badge] : [])
            }
            else if let previousDelegate, previousDelegate.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))) {
                previousDelegate.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
            } else { completionHandler([]) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        Task { @MainActor in
            if response.notification.request.identifier.hasPrefix("native-api:") {
                // Dismissal and unknown custom actions must never navigate or mark a conversation read.
                if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                   let destination = ChatNotificationDestination(userInfo: response.notification.request.content.userInfo) {
                    onOpen?(destination)
                }
                completionHandler()
            } else if let previousDelegate, previousDelegate.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))) {
                previousDelegate.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
            } else { completionHandler() }
        }
    }
}
