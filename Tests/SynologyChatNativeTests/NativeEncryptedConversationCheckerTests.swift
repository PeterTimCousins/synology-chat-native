#if DEBUG
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeEncryptedConversationCheckerTests:XCTestCase {
    func testWindowFactoryKeepsSyntheticPendingStartOnDiskWithoutReplayingItOnFreshFactoryRestore() async throws {
        let directory = URL(fileURLWithPath:"/private/tmp/native-channel-invitation-fixture.checker-test-"+UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let (model,state) = try await NativeChannelInvitationUIFixture.makeModel(directory:directory,configure:{ $0.allowAnonymous = true })
        let snapshot = try await model.loadQuickSwitcher();state.loseAnonymousReply = true
        do { try await model.startEncryptedConversation(with:[20],reviewed:snapshot);XCTFail() } catch { }
        let intent = try XCTUnwrap(model.pendingEncryptedConversationStarts.values.first)
        XCTAssertEqual(state.anonymousStarts.count,1)
        let journal = directory.appendingPathComponent("conversation-receipts")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at:journal,includingPropertiesForKeys:nil).contains { $0.pathExtension == "json" })
        model.signOutLocally()
        let (restored,newBackend) = try await NativeChannelInvitationUIFixture.makeModel(directory:directory,unlock:false,configure:{ $0.allowAnonymous = true })
        defer { restored.signOutLocally() }
        XCTAssertEqual(restored.pendingEncryptedConversationStarts.values.first,intent)
        XCTAssertTrue(newBackend.anonymousStarts.isEmpty)
        XCTAssertFalse(NativeChatAppConfiguration.automaticallyRestoresSavedSession(bundleID:NativeEncryptedConversationChecks.bundleID))
    }
}
#endif
