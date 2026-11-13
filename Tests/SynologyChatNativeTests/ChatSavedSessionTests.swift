import XCTest
@testable import SynologyChatNative

@MainActor
final class ChatSavedSessionTests: XCTestCase {
    func testDevelopmentAppsCannotRestoreOrRemoveNormalAppKeychainSession() {
        let normal = ChatAccountKeychain.serviceName(for: "com.costwisegroup.synology-chat-native.api")
        XCTAssertEqual(normal, "com.costwisegroup.synology-chat-native.session", "Keep existing normal app sessions discoverable")
        let preview = ChatAccountKeychain.serviceName(for: "com.costwisegroup.synology-chat-native.api-preview")
        let wrapper = ChatAccountKeychain.serviceName(for: "com.costwisegroup.synology-chat-native")
        XCTAssertEqual(Set([normal, preview, wrapper, ChatAccountKeychain.serviceName(for: nil)]).count, 4)
    }

    private var syntheticAccount: ChatAccount {
        .init(session: .init(baseURL: URL(string: "https://synthetic.test")!, sid: "synthetic", synoToken: "synthetic"),
              username: "Synthetic", importedFromOfficialApp: false)
    }

    func testUncheckedRememberRemovesPreviousSavedAccountWithoutSavingNewSession() async {
        var savedAccount: ChatAccount? = syntheticAccount
        let warning = await ChatSavedSignInPreference.apply(account: syntheticAccount, remember: false,
            save: { _ in XCTFail("Unchecked preference must not save the new session") },
            remove: { savedAccount = nil })
        XCTAssertNil(warning)
        XCTAssertNil(savedAccount, "Next launch must not restore a previously saved account")
    }

    func testCheckedRememberReplacesSavedAccountAndDoesNotRemoveIt() async {
        var saved: ChatAccount?
        let warning = await ChatSavedSignInPreference.apply(account: syntheticAccount, remember: true,
            save: { saved = $0 }, remove: { XCTFail("Remembered sign-in must not be removed") })
        XCTAssertNil(warning)
        XCTAssertEqual(saved?.session.sid, syntheticAccount.session.sid)
        XCTAssertEqual(saved?.username, syntheticAccount.username)
    }

    func testFailedRemovalWarnsThatOldAccountCanRestore() async {
        let warning = await ChatSavedSignInPreference.apply(account: syntheticAccount, remember: false,
            save: { _ in XCTFail("Must not save") }, remove: { throw ChatSignInError.storage })
        XCTAssertTrue(warning?.contains("previous saved sign-in could not be removed") == true)
        XCTAssertTrue(warning?.contains("restoring next time") == true)
    }

    func testFailedSaveOffersSignInRecoveryWithoutDeletingStoredAccount() async {
        let warning = await ChatSavedSignInPreference.apply(account: syntheticAccount, remember: true,
            save: { _ in throw ChatSignInError.storage }, remove: { XCTFail("Save failure must not trigger unrelated removal") })
        XCTAssertTrue(warning?.contains("could not be saved") == true)
    }

    func testPendingKeychainRestoreIsVisibleAndCannotQueueDuplicateRestore() async {
        let model = NativeChatPreviewModel()
        let started = expectation(description: "Saved account lookup started")
        var resume: CheckedContinuation<ChatAccount?, Never>?
        let first = Task {
            await model.restoreSavedSession(loadAccount: {
                await withCheckedContinuation { continuation in resume = continuation; started.fulfill() }
            })
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(model.restoringSavedSession)
        await model.restoreSavedSession(loadAccount: { XCTFail("Duplicate Keychain lookup must not queue"); return nil })
        resume?.resume(returning: nil)
        await first.value
        XCTAssertFalse(model.restoringSavedSession)
    }

    func testStaleRestoreFailureCannotOverwriteNewerConnectedState() async {
        let model = NativeChatPreviewModel()
        let started = expectation(description: "Keychain lookup pending")
        var resume: CheckedContinuation<ChatAccount?, Error>?
        let lookup = Task {
            await model.restoreSavedSession(loadAccount: {
                try await withCheckedThrowingContinuation { continuation in resume = continuation; started.fulfill() }
            })
        }
        await fulfillment(of: [started], timeout: 1)
        model.connected = true
        model.error = "Newer connection status"
        resume?.resume(throwing: ChatSignInError.storage)
        await lookup.value
        XCTAssertEqual(model.error, "Newer connection status")
        XCTAssertFalse(model.restoringSavedSession)
    }

    func testCancelledRestoreDoesNotPresentStorageFailure() async {
        let model = NativeChatPreviewModel()
        let started = expectation(description: "Keychain lookup pending")
        var resume: CheckedContinuation<ChatAccount?, Error>?
        let lookup = Task {
            await model.restoreSavedSession(loadAccount: {
                try await withCheckedThrowingContinuation { continuation in resume = continuation; started.fulfill() }
            })
        }
        await fulfillment(of: [started], timeout: 1)
        lookup.cancel()
        resume?.resume(throwing: ChatSignInError.storage)
        await lookup.value
        XCTAssertNil(model.error)
        XCTAssertFalse(model.restoringSavedSession)
    }

    func testRestoreFailureClearsProgressAndOffersRecovery() async {
        let model = NativeChatPreviewModel()
        await model.restoreSavedSession(loadAccount: { throw ChatSignInError.storage })
        XCTAssertFalse(model.restoringSavedSession)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.connected)
    }
}
