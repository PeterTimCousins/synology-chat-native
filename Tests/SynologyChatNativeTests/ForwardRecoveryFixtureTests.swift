#if DEBUG
import XCTest
@testable import SynologyChatNative

@MainActor final class ForwardRecoveryFixtureTests:XCTestCase {
    func testSyntheticFactoryRestoresPendingForwardAndStatusNeverDispatches() async throws {
        let directory = URL(fileURLWithPath:"/private/tmp/native-forward-recovery-fixture.test-"+UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let model = try await NativeForwardRecoveryFixture.makeModel(directory:directory)
        let snapshot = try await model.loadQuickSwitcher()
        XCTAssertTrue(snapshot.entries.contains { $0.person?.user_id == 30 && $0.channel == nil })
        XCTAssertEqual(NativeForwardRecoveryFixture.state?.attempts,0);model.signOutLocally()
        for phase in ["create-stop","restore-check","resolve-check","verify-finished"] {
            let passed = await NativeForwardRecoveryFixture.runContract(directory:directory,phase:phase)
            XCTAssertTrue(passed,phase)
        }
        XCTAssertEqual(NativeForwardRecoveryFixture.state?.attempts,1)
        XCTAssertThrowsError(try NativeForwardRecoveryFixture.validateDirectory(URL(fileURLWithPath:"/private/tmp/unrelated-forward-state")))
    }
}
#endif
