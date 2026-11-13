#if DEBUG
import XCTest
@testable import SynologyChatNative

@MainActor final class SlashRecoveryFixtureTests:XCTestCase {
    private func folder() throws -> URL {
        let directory = URL(fileURLWithPath:"/private/tmp/native-slash-recovery-ui."+UUID().uuidString,isDirectory:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:directory) }
        return directory
    }
    private func request(_ model:NativeChatPreviewModel) async throws -> (NativeSlashCommandRequest,ChatSlashCommand) {
        try await model.prepareSlashCommands(fromComposer:true)
        let request = try XCTUnwrap(model.slashCommandRequest),command = try XCTUnwrap(request.commands.first { $0.name == "synthetic" })
        return (request,command)
    }
    func testSyntheticFixturePersistsUnknownAndLocalAcknowledgementNeverDispatches() async throws {
        let directory = try folder(),first = try await NativeSlashRecoveryFixture.makeModel(directory:directory)
        let (initial,command) = try await request(first)
        XCTAssertEqual(NativeSlashRecoveryFixture.totalDispatches,0)
        do { _ = try await first.executeSlashCommand(initial,command:command,message:NativeSlashRecoveryFixture.input);XCTFail("Synthetic lost reply acknowledged") } catch { }
        XCTAssertEqual(NativeSlashRecoveryFixture.totalDispatches,1);XCTAssertEqual(first.pendingSlashInvocations.count,1)
        first.signOutLocally()
        let restored = try await NativeSlashRecoveryFixture.makeModel(directory:directory)
        defer { restored.signOutLocally() }
        XCTAssertEqual(NativeSlashRecoveryFixture.totalDispatches,1);XCTAssertEqual(restored.pendingSlashInvocations.count,1)
        let (reviewed,current) = try await request(restored)
        do { _ = try await restored.executeSlashCommand(reviewed,command:current,message:NativeSlashRecoveryFixture.input);XCTFail("Fixture replayed stored command") } catch { }
        XCTAssertEqual(NativeSlashRecoveryFixture.totalDispatches,1)
        try restored.acknowledgeSlashOutcome(XCTUnwrap(restored.pendingSlashInvocations.values.first),request:reviewed)
        XCTAssertEqual(NativeSlashRecoveryFixture.totalDispatches,1)
        NativeSlashRecoveryFixture.setAcknowledgedResponse(true)
        _ = try await restored.executeSlashCommand(reviewed,command:current,message:NativeSlashRecoveryFixture.input)
        XCTAssertEqual(NativeSlashRecoveryFixture.totalDispatches,2);XCTAssertTrue(restored.draft.isEmpty);XCTAssertTrue(restored.pendingSlashInvocations.isEmpty)
    }
    func testFixtureRejectsOutsideOrSymlinkedStateDirectoriesBeforeCreatingModel() async throws {
        XCTAssertThrowsError(try NativeSlashRecoveryFixture.validateDirectory(URL(fileURLWithPath:"/private/tmp/not-a-slash-recovery-fixture")))
        let directory = try folder(),link = try folder()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:directory)
        XCTAssertThrowsError(try NativeSlashRecoveryFixture.validateDirectory(link))
    }
}
#endif
