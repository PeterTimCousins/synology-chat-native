import XCTest
@testable import SynologyChatNative

@MainActor final class NativeDesktopPreferencesTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "native-desktop-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }; return defaults
    }
    func testInitializationReadsSystemRatherThanSavedLoginFlagAndDoesNotRegister() throws {
        let defaults = try defaults(); defaults.set(true,forKey:"openAtLogin")
        let service = FakeLoginItem(); let preferences = NativeDesktopPreferences(defaults:defaults,loginItem:service)
        XCTAssertEqual(preferences.loginState,.disabled); XCTAssertTrue(service.requests.isEmpty)
        service.state = .enabled; preferences.refreshLoginItem(); XCTAssertEqual(preferences.loginState,.enabled)
        service.state = .disabled; preferences.refreshLoginItem(); XCTAssertEqual(preferences.loginState,.disabled)
    }
    func testSuccessfulEnableAndDisableReadBackActualStateWithoutPersistingLoginFlag() async throws {
        let defaults = try defaults(), service = FakeLoginItem(), preferences = NativeDesktopPreferences(defaults:defaults,loginItem:service)
        await preferences.setOpenAtLogin(true); XCTAssertEqual(preferences.loginState,.enabled)
        await preferences.setOpenAtLogin(false); XCTAssertEqual(preferences.loginState,.disabled)
        XCTAssertEqual(service.requests,[true,false]); XCTAssertNil(preferences.loginError)
        XCTAssertFalse(preferences.changingLoginItem); XCTAssertNil(defaults.object(forKey:"openAtLogin"))
    }
    func testRequiresApprovalRemainsPendingAndCanBeCancelledWithoutRegisteringAgain() async {
        let service = FakeLoginItem(); service.result = .requiresApproval
        let preferences = NativeDesktopPreferences(loginItem:service)
        await preferences.setOpenAtLogin(true); XCTAssertEqual(preferences.loginState,.requiresApproval)
        XCTAssertTrue(preferences.loginState.requested); XCTAssertNotEqual(preferences.loginState,.enabled)
        await preferences.setOpenAtLogin(true); XCTAssertEqual(service.requests,[true])
        service.result = nil; await preferences.setOpenAtLogin(false)
        XCTAssertEqual(service.requests,[true,false]); XCTAssertEqual(preferences.loginState,.disabled)
    }
    func testRegistrationErrorKeepsSystemStateAndSanitizesError() async {
        let service = FakeLoginItem(); service.failure = NSError(domain:"private-path-and-credential",code:1)
        let preferences = NativeDesktopPreferences(loginItem:service)
        await preferences.setOpenAtLogin(true)
        XCTAssertEqual(preferences.loginState,.disabled); XCTAssertFalse(preferences.changingLoginItem)
        XCTAssertNotNil(preferences.loginError); XCTAssertFalse(preferences.loginError!.contains("credential"))
        service.failure = nil; await preferences.setOpenAtLogin(true)
        XCTAssertEqual(preferences.loginState,.enabled); XCTAssertNil(preferences.loginError)
    }
    func testUnregisterErrorCannotPretendItemWasDisabled() async {
        let service = FakeLoginItem(); service.state = .enabled; service.failure = NSError(domain:"test",code:2)
        let preferences = NativeDesktopPreferences(loginItem:service)
        await preferences.setOpenAtLogin(false)
        XCTAssertEqual(preferences.loginState,.enabled); XCTAssertNotNil(preferences.loginError)
    }
    func testSuccessWithoutEnabledReadbackDoesNotClaimEnabled() async {
        let service = FakeLoginItem(); service.result = .unavailable
        let preferences = NativeDesktopPreferences(loginItem:service)
        await preferences.setOpenAtLogin(true)
        XCTAssertEqual(preferences.loginState,.unavailable); XCTAssertFalse(preferences.loginState.requested)
    }
    func testExternalChangeBeforeActionAvoidsRedundantRegistration() async {
        let service = FakeLoginItem(), preferences = NativeDesktopPreferences(loginItem:service)
        service.state = .enabled; await preferences.setOpenAtLogin(true)
        XCTAssertEqual(preferences.loginState,.enabled); XCTAssertTrue(service.requests.isEmpty)
    }
    func testConcurrentToggleCannotRaceUnregisterWithOutstandingRegistration() async {
        let service = FakeLoginItem(); service.hold = true
        let preferences = NativeDesktopPreferences(loginItem:service)
        let started = expectation(description:"Service request started"); service.started = { started.fulfill() }
        let first = Task { await preferences.setOpenAtLogin(true) }
        await fulfillment(of:[started],timeout:2)
        XCTAssertTrue(preferences.changingLoginItem)
        await preferences.setOpenAtLogin(false); preferences.refreshLoginItem()
        XCTAssertEqual(service.requests,[true]); XCTAssertEqual(preferences.loginState,.disabled)
        service.release(); await first.value
        XCTAssertEqual(preferences.loginState,.enabled); XCTAssertFalse(preferences.changingLoginItem)
    }
    func testMenuBarPreferencePersistsOnlyWithinOwnDefaultsAndDoesNotTouchLogin() throws {
        let defaults = try defaults(), other = try self.defaults(), service = FakeLoginItem()
        let preferences = NativeDesktopPreferences(defaults:defaults,loginItem:service)
        XCTAssertFalse(preferences.showMenuBarIcon)
        preferences.setMenuBarIcon(true)
        XCTAssertTrue(NativeDesktopPreferences(defaults:defaults,loginItem:service).showMenuBarIcon)
        XCTAssertFalse(NativeDesktopPreferences(defaults:other,loginItem:service).showMenuBarIcon)
        preferences.setMenuBarIcon(false)
        XCTAssertFalse(NativeDesktopPreferences(defaults:defaults,loginItem:service).showMenuBarIcon)
        XCTAssertTrue(service.requests.isEmpty)
    }
}
@MainActor private final class FakeLoginItem: NativeLoginItemService {
    var state: NativeLoginItemState = .disabled
    var requests: [Bool] = []
    var failure: Error?
    var result: NativeLoginItemState?
    var hold = false
    var started: (() -> Void)?
    var continuation: CheckedContinuation<Void,Never>?
    func setEnabled(_ enabled: Bool) async throws {
        requests.append(enabled); started?()
        if hold { await withCheckedContinuation { continuation = $0 } }
        if let failure { throw failure }
        state = result ?? (enabled ? .enabled : .disabled)
    }
    func release() { continuation?.resume(); continuation = nil }
}
