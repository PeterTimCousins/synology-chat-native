import XCTest
@testable import SynologyChatNative

final class NativeUserActivityDeadlineTests: XCTestCase {
    func testNoActivityUntilInputAndExactOfficialIdleBoundary() {
        var deadline = NativeUserActivityDeadline()
        XCTAssertEqual(NativeUserActivityDeadline.idleInterval, 180)
        XCTAssertEqual(NativeUserActivityDeadline.pollingInterval, 10)
        XCTAssertFalse(deadline.isActive(at: 100))
        deadline.recordActivity(at: 100)
        XCTAssertTrue(deadline.isActive(at: 279.999))
        XCTAssertFalse(deadline.isActive(at: 280))
    }

    func testPeriodicChecksNeverRenewOrReactivateExpiredDeadline() {
        var deadline = NativeUserActivityDeadline()
        deadline.recordActivity(at: 20)
        for second in stride(from: 30, to: 200, by: 10) { XCTAssertTrue(deadline.isActive(at: Double(second))) }
        for second in stride(from: 200, through: 1000, by: 10) { XCTAssertFalse(deadline.isActive(at: Double(second))) }
        deadline.recordActivity(at: 1001)
        XCTAssertTrue(deadline.isActive(at: 1001)); XCTAssertTrue(deadline.isActive(at: 1180))
        XCTAssertFalse(deadline.isActive(at: 1181))
    }

    func testExplicitActivityRenewsDeadlineBeforeOrAfterIdle() {
        var deadline = NativeUserActivityDeadline()
        deadline.recordActivity(at: 0)
        deadline.recordActivity(at: 150)
        XCTAssertTrue(deadline.isActive(at: 329)); XCTAssertFalse(deadline.isActive(at: 330))
        deadline.recordActivity(at: 400)
        XCTAssertTrue(deadline.isActive(at: 579)); XCTAssertFalse(deadline.isActive(at: 580))
    }

    func testLargeSleepLikeElapsedJumpExpiresWithoutPeriodicTicks() {
        var deadline = NativeUserActivityDeadline()
        deadline.recordActivity(at: 42)
        XCTAssertFalse(deadline.isActive(at: 100_000))
        XCTAssertFalse(deadline.isActive(at: 100_010))
        deadline.recordActivity(at: 100_011)
        XCTAssertTrue(deadline.isActive(at: 100_011))
    }

    func testRollbackAndInvalidClockInvalidateUntilFreshInput() {
        for invalid in [-1.0, .infinity, -.infinity, .nan, 99] {
            var deadline = NativeUserActivityDeadline()
            deadline.recordActivity(at: 100)
            XCTAssertFalse(deadline.isActive(at: invalid))
            XCTAssertFalse(deadline.isActive(at: 101))
            deadline.recordActivity(at: 102)
            XCTAssertTrue(deadline.isActive(at: 102))
        }
    }

    func testInvalidInputCannotCreateActivityAndResetRetiresDeadline() {
        var deadline = NativeUserActivityDeadline()
        deadline.recordActivity(at: .nan)
        XCTAssertFalse(deadline.isActive(at: 100))
        deadline.recordActivity(at: 99)
        XCTAssertFalse(deadline.isActive(at: 101))
        deadline.recordActivity(at: 102)
        XCTAssertTrue(deadline.isActive(at: 102))
        deadline.reset()
        XCTAssertFalse(deadline.isActive(at: 103))
    }
}
