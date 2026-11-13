import XCTest
import UserNotifications
@testable import SynologyChatNative

final class ChatNotificationSessionTests: XCTestCase {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)
    private func destination(_ scope: String) throws -> ChatNotificationDestination {
        try XCTUnwrap(ChatNotificationDestination(userInfo: ["nativeAccountScope": scope, "nativeChannelID": "23", "nativePostID": "100"]))
    }
    private func account(url: String = "https://synthetic.test", sid: String = "one", identity: String? = nil) -> ChatAccount {
        .init(session: .init(baseURL: URL(string: url)!, sid: sid, synoToken: "synthetic"), username: "Synthetic", importedFromOfficialApp: false, serverIdentity: identity)
    }

    func testScopeBindsServerAndUserRatherThanSessionToken() throws {
        let original = try XCTUnwrap(ChatNotificationAccountScope.make(account: account(), userID: 10))
        XCTAssertTrue(ChatNotificationAccountScope.isValid(original))
        XCTAssertEqual(original, ChatNotificationAccountScope.make(account: account(url: "https://SYNTHETIC.test:443/", sid: "rotated"), userID: 10))
        XCTAssertNotEqual(original, ChatNotificationAccountScope.make(account: account(url: "https://other.test"), userID: 10))
        XCTAssertNotEqual(original, ChatNotificationAccountScope.make(account: account(), userID: 6))
        XCTAssertNil(ChatNotificationAccountScope.make(account: account(), userID: nil))
        XCTAssertNil(ChatNotificationAccountScope.make(account: account(), userID: 0))
    }

    func testPinnedQuickConnectIdentitySurvivesEndpointChanges() {
        XCTAssertEqual(ChatNotificationAccountScope.make(account: account(url: "https://one.test:5001", identity: "synthetic-nas"), userID: 10),
                       ChatNotificationAccountScope.make(account: account(url: "https://two.test:5002", sid: "rotated", identity: "synthetic-nas"), userID: 10))
    }

    func testLegacyAndMalformedNotificationScopesCannotRoute() {
        let fields = ["nativeChannelID": "23", "nativePostID": "100"]
        XCTAssertNil(ChatNotificationDestination(userInfo: fields))
        for scope in ["", "short", String(repeating: "g", count: 64), String(repeating: "a", count: 65)] {
            XCTAssertNil(ChatNotificationDestination(userInfo: fields.merging(["nativeAccountScope": scope], uniquingKeysWith: { first, _ in first })))
        }
    }

    func testColdClickWaitsForMatchingAuthenticationAndIsConsumedOnce() throws {
        var route = ChatNotificationRouting()
        XCTAssertTrue(route.receive(try destination(a)))
        XCTAssertNil(route.takePending())
        route.activate(scope: a)
        XCTAssertEqual(route.takePending()?.accountScope, a)
        XCTAssertNil(route.takePending())
    }

    func testDifferentAccountAndExplicitSignOutRejectOldClicksDespiteMatchingPostIDs() throws {
        var route = ChatNotificationRouting()
        XCTAssertTrue(route.receive(try destination(a)))
        route.activate(scope: b)
        XCTAssertNil(route.takePending())
        XCTAssertFalse(route.receive(try destination(a)))
        route.signOut()
        XCTAssertFalse(route.receive(try destination(b)))
        route.activate(scope: a)
        XCTAssertTrue(route.receive(try destination(a)))
    }

    func testOldDeliveryCannotCompleteOrSuppressSamePostInAnotherAccount() throws {
        var session = ChatNotificationDeliverySession()
        session.activate(scope: a)
        let old = try XCTUnwrap(session.reserve(postID: 100))
        XCTAssertNil(session.reserve(postID: 100))
        session.activate(scope: b)
        let current = try XCTUnwrap(session.reserve(postID: 100))
        XCTAssertNotEqual(old.identifier, current.identifier)
        XCTAssertFalse(session.complete(old))
        session.fail(old)
        XCTAssertTrue(session.complete(current))
        XCTAssertNil(session.reserve(postID: 100))
    }

    func testSuccessfulDeliveryDeduplicatesAcrossSameAccountReconnectButPendingDeliveryCanRetry() throws {
        var session = ChatNotificationDeliverySession()
        session.activate(scope: a)
        let delivered = try XCTUnwrap(session.reserve(postID: 100))
        XCTAssertTrue(session.complete(delivered))
        let pending = try XCTUnwrap(session.reserve(postID: 101))
        session.suspend()
        XCTAssertFalse(session.isCurrent(pending))
        session.activate(scope: a)
        XCTAssertNil(session.reserve(postID: 100))
        XCTAssertNotNil(session.reserve(postID: 101))
    }

    func testPresentationAndCleanupCannotTouchNewEpochOrWrapperNotifications() throws {
        var session = ChatNotificationDeliverySession()
        session.activate(scope: a)
        let old = try XCTUnwrap(session.reserve(postID: 100))
        let oldInfo = ["nativeAccountScope": a, "nativeDeliveryEpoch": old.epoch.uuidString]
        XCTAssertTrue(session.canPresent(userInfo: oldInfo))
        session.reset(); session.activate(scope: a)
        let current = try XCTUnwrap(session.reserve(postID: 100))
        XCTAssertFalse(session.canPresent(userInfo: oldInfo))
        XCTAssertFalse(session.shouldRemove(identifier: current.identifier, userInfo: oldInfo, keepSameAccount: false))
        XCTAssertTrue(session.shouldRemove(identifier: old.identifier, userInfo: oldInfo, keepSameAccount: false))
        XCTAssertFalse(session.shouldRemove(identifier: old.identifier, userInfo: oldInfo, keepSameAccount: true))
        XCTAssertFalse(session.shouldRemove(identifier: "wrapper:100", userInfo: [:], keepSameAccount: false))
        session.activate(scope: b)
        XCTAssertTrue(session.shouldRemove(identifier: old.identifier, userInfo: oldInfo, keepSameAccount: true))
    }
}

@MainActor
final class NativeNotificationDeliveryTests: XCTestCase {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)
    private var message: ChatNotificationMessage {
        .init(channelID: 23, postID: 100, threadID: nil, title: "Synthetic", body: "Synthetic notification", sound: false)
    }

    func testDisableWhileAuthorizationPendingCannotReenableDelivery() async throws {
        let started = expectation(description: "Authorization pending")
        let submitted = expectation(description: "Disabled request must not submit")
        submitted.isInverted = true
        var resume: CheckedContinuation<Bool, Error>?
        let notifications = NativeChatNotifications(submit: { _ in submitted.fulfill() }, authorize: {
            try await withCheckedThrowingContinuation { resume = $0; started.fulfill() }
        })
        notifications.activateAccount(scope:a)
        let enabling = Task { await notifications.enable() }
        await fulfillment(of:[started],timeout:2)
        notifications.disable()
        notifications.activateAccount(scope:a)
        resume?.resume(returning:true)
        await enabling.value
        XCTAssertEqual(notifications.status,"Enable notifications")
        XCTAssertFalse(notifications.isEnabled)
        notifications.deliver(message)
        await fulfillment(of:[submitted],timeout:0.03)
    }

    func testOldAuthorizationFailureCannotDisableNewAccountPermission() async throws {
        let started = expectation(description: "Old authorization pending")
        let delivered = expectation(description: "New account delivery accepted")
        var resume: CheckedContinuation<Bool, Error>?
        var calls = 0
        let notifications = NativeChatNotifications(submit: { request in
            XCTAssertEqual(request.content.userInfo["nativeAccountScope"] as? String,self.b)
        }, authorize: {
            calls += 1
            if calls == 1 { return try await withCheckedThrowingContinuation { resume = $0; started.fulfill() } }
            return true
        })
        notifications.activateAccount(scope:a)
        let first = Task { await notifications.enable() }
        await fulfillment(of:[started],timeout:2)
        notifications.reset(); notifications.activateAccount(scope:b)
        await notifications.enable()
        resume?.resume(throwing:ChatSignInError.storage)
        await first.value
        XCTAssertEqual(notifications.status,"Notifications enabled")
        XCTAssertTrue(notifications.isEnabled)
        notifications.onDelivery = { _ in delivered.fulfill() }
        notifications.deliver(message)
        await fulfillment(of:[delivered],timeout:2)
    }

    func testAccountSwitchInvalidatesPendingAuthorization() async throws {
        let started = expectation(description: "Authorization pending before account switch")
        let submitted = expectation(description: "Old authorization cannot enable new account")
        submitted.isInverted = true
        var resume: CheckedContinuation<Bool, Error>?
        let notifications = NativeChatNotifications(submit: { _ in submitted.fulfill() }, authorize: {
            try await withCheckedThrowingContinuation { resume = $0; started.fulfill() }
        })
        notifications.activateAccount(scope:a)
        let first = Task { await notifications.enable() }
        await fulfillment(of:[started],timeout:2)
        notifications.activateAccount(scope:b)
        resume?.resume(returning:true)
        await first.value
        XCTAssertEqual(notifications.status,"Enable notifications")
        XCTAssertFalse(notifications.isEnabled)
        notifications.deliver(message)
        await fulfillment(of:[submitted],timeout:0.03)
    }

    func testNewerAuthorizationDenialWinsOverOlderApproval() async throws {
        let started = expectation(description: "First authorization pending")
        var resume: CheckedContinuation<Bool, Error>?
        var calls = 0
        let notifications = NativeChatNotifications(submit: { _ in XCTFail("Denied delivery") }, authorize: {
            calls += 1
            if calls == 1 { return try await withCheckedThrowingContinuation { resume = $0; started.fulfill() } }
            return false
        })
        notifications.activateAccount(scope:a)
        let first = Task { await notifications.enable() }
        await fulfillment(of:[started],timeout:2)
        await notifications.enable()
        resume?.resume(returning:true)
        await first.value
        XCTAssertEqual(notifications.status,"Notifications blocked in System Settings")
        XCTAssertFalse(notifications.isEnabled)
    }

    func testResetDuringSubmissionRemovesOnlyItsStaleRequest() async throws {
        let started = expectation(description: "Old submission suspended")
        let removed = expectation(description: "Stale accepted request removed")
        var resume: CheckedContinuation<Void, Error>?
        var submitted: [UNNotificationRequest] = []
        var removedIDs: [String] = []
        var accepted = 0
        let notifications = NativeChatNotifications(submit: { request in
            submitted.append(request)
            try await withCheckedThrowingContinuation { resume = $0; started.fulfill() }
        }, remove: { ids in removedIDs += ids; removed.fulfill() }, authorize: { true })
        notifications.onDelivery = { _ in accepted += 1 }
        notifications.activateAccount(scope: a)
        await notifications.enable()
        notifications.deliver(message)
        await fulfillment(of: [started], timeout: 2)
        notifications.reset()
        resume?.resume(returning: ())
        await fulfillment(of: [removed], timeout: 2)
        XCTAssertEqual(removedIDs, submitted.map(\.identifier))
        XCTAssertEqual(accepted, 0)
        // Removing a retired account's delivered request cannot undo a badge
        // value macOS already applied; the request must never carry one.
        XCTAssertNil(try XCTUnwrap(submitted.first).content.badge)
    }

    func testStaleSubmissionCannotRemoveNewAccountNotificationWithSamePostID() async throws {
        let started = expectation(description: "Old submission suspended")
        let accepted = expectation(description: "New account notification accepted")
        let removed = expectation(description: "Old request removed")
        var resume: CheckedContinuation<Void, Error>?
        var submitted: [UNNotificationRequest] = []
        var removedIDs: [String] = []
        let notifications = NativeChatNotifications(submit: { request in
            submitted.append(request)
            if submitted.count == 1 { try await withCheckedThrowingContinuation { resume = $0; started.fulfill() } }
        }, remove: { ids in removedIDs += ids; removed.fulfill() }, authorize: { true })
        notifications.onDelivery = { _ in accepted.fulfill() }
        notifications.activateAccount(scope: a)
        await notifications.enable()
        notifications.deliver(message)
        await fulfillment(of: [started], timeout: 2)
        notifications.activateAccount(scope: b)
        notifications.deliver(message)
        await fulfillment(of: [accepted], timeout: 2)
        resume?.resume(returning: ())
        await fulfillment(of: [removed], timeout: 2)
        XCTAssertEqual(submitted.count, 2)
        XCTAssertEqual(removedIDs, [submitted[0].identifier])
        XCTAssertNotEqual(submitted[0].identifier, submitted[1].identifier)
        XCTAssertEqual(submitted[1].content.userInfo["nativeAccountScope"] as? String, b)
        XCTAssertTrue(submitted.allSatisfy { $0.content.badge == nil },
                      "Delayed deliveries must leave the authoritative unread badge unchanged")
    }

    func testResetBeforeTaskStartsDoesNotSubmit() async throws {
        let submitted = expectation(description: "No submission after reset")
        submitted.isInverted = true
        let notifications = NativeChatNotifications(submit: { _ in submitted.fulfill() }, authorize: { true })
        notifications.activateAccount(scope: a)
        await notifications.enable()
        notifications.deliver(message)
        notifications.reset()
        await fulfillment(of: [submitted], timeout: 0.05)
    }
    func testLocalizedStatusAndTypedStateRemainIndependentThroughPermissionTransitions() async throws {
        let resources = try NotificationLocalizationTestResources.bundle(for:self)
        var result = 0
        let notifications = NativeChatNotifications(submit:{ _ in },authorize:{
            if result == 2 { throw ChatSignInError.storage }
            return result == 0
        },language:.german,bundle:resources)
        XCTAssertFalse(notifications.isEnabled)
        XCTAssertEqual(notifications.status,"Benachrichtigungen aktivieren")
        XCTAssertFalse(notifications.hasStatusNotice)
        notifications.activateAccount(scope:a)
        await notifications.enable()
        XCTAssertTrue(notifications.isEnabled)
        XCTAssertEqual(notifications.status,"Benachrichtigungen aktiviert")
        result = 1
        await notifications.enable()
        XCTAssertFalse(notifications.isEnabled)
        XCTAssertEqual(notifications.status,"Benachrichtigungen in Systemeinstellungen blockiert")
        XCTAssertTrue(notifications.hasStatusNotice)
        result = 0
        await notifications.enable()
        XCTAssertTrue(notifications.isEnabled)
        result = 2
        await notifications.enable()
        XCTAssertFalse(notifications.isEnabled)
        XCTAssertEqual(notifications.status,"Benachrichtigungen konnten nicht aktiviert werden")
        XCTAssertTrue(notifications.hasStatusNotice)
        result = 0
        await notifications.enable()
        notifications.disable()
        XCTAssertFalse(notifications.isEnabled)
        XCTAssertEqual(notifications.status,"Benachrichtigungen aktivieren")
        XCTAssertFalse(notifications.hasStatusNotice)
    }

    func testSuspendAndResetRetainEnabledPreferenceButCannotDeliverWithoutActiveScope() async throws {
        let resources = try NotificationLocalizationTestResources.bundle(for:self)
        let unexpected = expectation(description:"Suspended/reset context cannot submit")
        unexpected.isInverted = true
        let delivered = expectation(description:"Reactivated account delivers with translated status")
        var reactivated = false
        let notifications = NativeChatNotifications(submit:{ request in
            if reactivated { XCTAssertEqual(request.content.userInfo["nativeAccountScope"] as? String,self.b) }
            else { unexpected.fulfill() }
        },authorize:{ true },language:.german,bundle:resources)
        notifications.activateAccount(scope:a)
        await notifications.enable()
        notifications.suspendAccount()
        XCTAssertTrue(notifications.isEnabled)
        notifications.deliver(message)
        notifications.reset()
        XCTAssertTrue(notifications.isEnabled)
        notifications.deliver(message)
        await fulfillment(of:[unexpected],timeout:0.03)
        reactivated = true
        notifications.activateAccount(scope:b)
        XCTAssertTrue(notifications.isEnabled)
        XCTAssertEqual(notifications.status,"Benachrichtigungen aktiviert")
        notifications.onDelivery = { _ in delivered.fulfill() }
        notifications.deliver(message)
        await fulfillment(of:[delivered],timeout:2)
        notifications.disable()
        XCTAssertFalse(notifications.isEnabled)
    }

    func testDeliveryCallbackCarriesTypedAcceptedOrRejectedOutcome() async throws {
        let resources = try NotificationLocalizationTestResources.bundle(for:self)
        for rejected in [false,true] {
            let delivered = expectation(description:rejected ? "Typed rejection" : "Typed acceptance")
            let notifications = NativeChatNotifications(submit:{ _ in
                if rejected { throw NSError(domain:"synthetic.notification",code:119) }
            },authorize:{ true },language:.german,bundle:resources)
            notifications.onDelivery = { outcome in
                XCTAssertEqual(outcome,rejected ? .rejected(119) : .accepted)
                delivered.fulfill()
            }
            notifications.activateAccount(scope:a)
            await notifications.enable()
            notifications.deliver(message)
            await fulfillment(of:[delivered],timeout:2)
            notifications.disable()
        }
    }

}
