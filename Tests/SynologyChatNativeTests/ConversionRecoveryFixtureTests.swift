#if DEBUG
import XCTest
@testable import SynologyChatNative

@MainActor final class ConversionRecoveryFixtureTests:XCTestCase {
    private func folder() -> URL {
        let directory = URL(fileURLWithPath:"/private/tmp/native-conversion-recovery-ui."+UUID().uuidString,isDirectory:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:directory) };return directory
    }
    func testFixtureRetainsKnownCreatedIDAndReadOnlyResolutionNeverInvites() async throws {
        let directory = folder(),first = try await NativeConversionRecoveryFixture.makeModel(directory:directory)
        let snapshot = try await first.loadPromotionSnapshot(channelID:93)
        do { _ = try await first.promoteConversation(snapshot,draft:NativeConversionRecoveryFixture.draft);XCTFail("Rejected join confirmed") } catch { }
        XCTAssertEqual(NativeConversionRecoveryFixture.counts,[1,1,0,0]);XCTAssertEqual(first.pendingPromotions[93]?.targetID,96)
        first.signOutLocally()
        let restored = try await NativeConversionRecoveryFixture.makeModel(directory:directory);defer { restored.signOutLocally() }
        XCTAssertEqual(restored.pendingPromotions[93]?.targetID,96)
        do { _ = try await restored.checkPromotionStatus(channelID:93);XCTFail("Unjoined target confirmed") } catch { }
        XCTAssertEqual(NativeConversionRecoveryFixture.counts,[1,1,0,0])
        try NativeConversionRecoveryFixture.resolveSyntheticTarget()
        let target = try await restored.checkPromotionStatus(channelID:93)
        XCTAssertEqual(target.id,96);XCTAssertTrue(restored.pendingPromotions.isEmpty)
        XCTAssertEqual(restored.drafts[93],NativeConversionRecoveryFixture.originalDraft)
        XCTAssertEqual(NativeConversionRecoveryFixture.counts,[1,1,0,0])
    }
    func testFixtureRejectsOutsideAndSymlinkedStateDirectories() throws {
        XCTAssertThrowsError(try NativeConversionRecoveryFixture.validateDirectory(URL(fileURLWithPath:"/private/tmp/not-conversion-state")))
        let directory = folder(),link = folder();try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:directory)
        XCTAssertThrowsError(try NativeConversionRecoveryFixture.validateDirectory(link))
    }
}
#endif
