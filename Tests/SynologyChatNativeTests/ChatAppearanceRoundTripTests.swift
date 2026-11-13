import XCTest
@testable import SynologyChatNative

@MainActor final class ChatAppearanceRoundTripTests: XCTestCase {
    private let original = ChatAppearanceSettings(style: .dark, background: .preset3)
    func testChangeAndRestorePreserveConcurrentUntouchedStyle() async {
        var current = original, writes: [ChatAppearanceSettingsPatch] = []
        let result = await ChatAppearanceRoundTrip.perform(original: original, read: { current }, write: { patch in
            writes.append(patch)
            current = .init(style: .light, background: patch.background ?? current.background)
        }, recordBeforeChange: { alternate in XCTAssertEqual(alternate.background, .preset0) })
        XCTAssertTrue(result.changedConfirmed); XCTAssertTrue(result.restored)
        XCTAssertEqual(current.style, .light); XCTAssertEqual(current.background, .preset3)
        XCTAssertEqual(writes.count, 2); XCTAssertTrue(writes.allSatisfy { $0.style == nil })
    }
    func testLostAcknowledgementsDoNotCauseRepeatsWhenCanonicalStateConfirms() async {
        var current = original, count = 0
        let result = await ChatAppearanceRoundTrip.perform(original: original, read: { current }, write: { patch in
            count += 1; current = .init(style: current.style, background: patch.background!)
            throw ChatAPIError.connection
        }, recordBeforeChange: { _ in })
        XCTAssertTrue(result.changedConfirmed); XCTAssertTrue(result.restored)
        XCTAssertEqual(current, original); XCTAssertEqual(count, 2)
    }
    func testFreshConflictAndReceiptFailureCannotDispatch() async {
        var writes = 0
        let conflict = await ChatAppearanceRoundTrip.perform(original: original, read: { .init(style: .dark, background: .preset2) }, write: { _ in writes += 1 }, recordBeforeChange: { _ in XCTFail("Stale state journaled for dispatch") })
        XCTAssertEqual(conflict.state, "changed_elsewhere_no_dispatch")
        let failedReceipt = await ChatAppearanceRoundTrip.perform(original: original, read: { self.original }, write: { _ in writes += 1 }, recordBeforeChange: { _ in throw ChatAPIError.connection })
        XCTAssertEqual(failedReceipt.state, "not_dispatched"); XCTAssertEqual(writes, 0)
    }
    func testAnotherClientsNewBackgroundCannotBeOverwrittenByRestore() async {
        var current = original, writes = 0
        let result = await ChatAppearanceRoundTrip.perform(original: original, read: { current }, write: { _ in
            writes += 1; current = .init(style: .light, background: .preset2)
        }, recordBeforeChange: { _ in })
        XCTAssertFalse(result.restored); XCTAssertEqual(result.state, "changed_elsewhere_no_restore")
        XCTAssertEqual(writes, 1); XCTAssertEqual(current.background, .preset2)
    }
    func testNewBackgroundBetweenConfirmationAndRestoreCannotDispatchRestore() async {
        var reads = 0, writes = 0
        let result = await ChatAppearanceRoundTrip.perform(original: original, read: {
            reads += 1
            return .init(style: .dark, background: reads == 1 ? .preset3 : reads == 2 ? .preset0 : .preset1)
        }, write: { _ in writes += 1 }, recordBeforeChange: { _ in })
        XCTAssertEqual(result.state, "changed_before_restore_no_dispatch")
        XCTAssertTrue(result.changedConfirmed); XCTAssertFalse(result.restored); XCTAssertEqual(writes, 1)
    }
    func testIgnoredRestoreDoesNotAutomaticallyRetry() async {
        var current = original, writes = 0
        let result = await ChatAppearanceRoundTrip.perform(original: original, read: { current }, write: { patch in
            writes += 1
            if writes == 1 { current = .init(style: current.style, background: patch.background!) }
        }, recordBeforeChange: { _ in })
        XCTAssertTrue(result.changedConfirmed); XCTAssertFalse(result.restored)
        XCTAssertEqual(result.state, "restore_unconfirmed_no_repeat"); XCTAssertEqual(writes, 2)
    }
    func testLostChangeAcknowledgementWithOriginalReadRemainsUnresolved() async {
        var writes = 0
        let result = await ChatAppearanceRoundTrip.perform(original: original, read: { self.original }, write: { _ in
            writes += 1; throw ChatAPIError.connection
        }, recordBeforeChange: { _ in })
        XCTAssertFalse(result.changedConfirmed); XCTAssertFalse(result.restored)
        XCTAssertEqual(result.ending, original); XCTAssertEqual(writes, 1)
        XCTAssertEqual(result.state, "change_outcome_unknown_original_observed")
    }
    func testLaterReadFailurePreservesPreviouslyConfirmedChange() async {
        var reads = 0, writes = 0
        let result = await ChatAppearanceRoundTrip.perform(original: original, read: {
            reads += 1
            if reads == 3 { throw ChatAPIError.connection }
            return .init(style: .dark, background: reads == 1 ? .preset3 : .preset0)
        }, write: { _ in writes += 1 }, recordBeforeChange: { _ in })
        XCTAssertTrue(result.changedConfirmed); XCTAssertFalse(result.restored)
        XCTAssertEqual(result.state, "read_unavailable_no_repeat"); XCTAssertEqual(writes, 1)
    }
}
