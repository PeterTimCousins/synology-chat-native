import Foundation
import XCTest
@testable import SynologyChatNative

final class ChatArchivePeriodPresentationTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let locale = Locale(identifier: "en_GB")
    private func archive(_ start: Double, _ end: Double) throws -> ChatArchive {
        let channel = try JSONDecoder().decode(ChatChannel.self, from: Data(#"{"channel_id":400,"name":"Synthetic","type":"private","encrypted":false,"unread":0}"#.utf8))
        return .init(archive_id:600,post_start:start,post_end:end,post_id_start:1,post_id_end:100,
                     props:.init(channel:channel,reason:"channel_closed",trigger_user_id:10))
    }
    private func regional(date: String = "Y-m-d", time: String = "H:i") throws -> ChatRegionalDisplay {
        let personal = try JSONDecoder().decode(ChatDesktopPersonalSettings.self,from:JSONSerialization.data(withJSONObject:["Personal":["dateFormat":date,"timeFormat":time]]))
        let defaults = try JSONDecoder().decode(ChatRegionalDefaults.self,from:Data(#"{"Session":{"date_format":"d/m/Y","time_format":"H:i"}}"#.utf8))
        return .init(personal:personal,defaults:defaults)
    }
    func testShortSyntheticPeriodIncludesSecondsAndIdentityWithoutChangingWireValues() throws {
        let source = try archive(1000,3000)
        let value = ChatArchivePeriodPresentation(archive:source,regional:try regional(),locale:locale,timeZone:utc)
        XCTAssertTrue(value.isAvailable)
        XCTAssertEqual(value.identifier,"Archive 600")
        XCTAssertEqual(value.summary,"1970-01-01 00:00:01 – 1970-01-01 00:00:03")
        XCTAssertEqual(value.exactRange,"1970-01-01 00:00:01.000 UTC+00:00 – 1970-01-01 00:00:03.000 UTC+00:00")
        XCTAssertEqual(value.label,"Archive 600 · " + value.summary)
        XCTAssertEqual(source.post_start.bitPattern,Double(1000).bitPattern)
        XCTAssertEqual(source.post_end.bitPattern,Double(3000).bitPattern)
    }
    func testSubsecondEndpointsAndSubmillisecondRangeAreNotCollapsed() throws {
        let value = ChatArchivePeriodPresentation(archive:try archive(1001,1002),regional:try regional(),timeZone:utc)
        XCTAssertTrue(value.summary.contains("00:00:01.001"));XCTAssertTrue(value.summary.contains("00:00:01.002"))
        let finer = ChatArchivePeriodPresentation(archive:try archive(1001.1,1001.2),regional:try regional(),timeZone:utc)
        XCTAssertTrue(finer.summary.contains("less than 1 millisecond"))
        XCTAssertFalse(finer.summary.contains("since epoch"))
        XCTAssertTrue(finer.exactRange.contains("1001.1–1001.2 ms since epoch"))
    }
    func testRepeatedDSTClockTimeIncludesDifferentUTCOffsets() throws {
        let zone = try XCTUnwrap(TimeZone(identifier:"Europe/London"))
        let parser = ISO8601DateFormatter()
        let first = try XCTUnwrap(parser.date(from:"2026-10-25T00:30:00Z")).timeIntervalSince1970 * 1000
        let last = try XCTUnwrap(parser.date(from:"2026-10-25T01:30:00Z")).timeIntervalSince1970 * 1000
        let value = ChatArchivePeriodPresentation(archive:try archive(first,last),regional:try regional(),timeZone:zone)
        XCTAssertEqual(value.summary,"2026-10-25 01:30:00 UTC+01:00 – 2026-10-25 01:30:00 UTC+00:00")
        XCTAssertTrue(value.exactRange.contains("01:30:00.000 UTC+01:00"))
        XCTAssertTrue(value.exactRange.contains("01:30:00.000 UTC+00:00"))
    }
    func testRegionalDateAndClockPreferencesWithUnchangedDefaultFormatter() throws {
        let settings = try regional(date:"m/d/Y",time:"h:i a")
        let instant = try archive(47_107_000,47_107_000)
        let value = ChatArchivePeriodPresentation(archive:instant,regional:settings,timeZone:utc)
        XCTAssertEqual(value.summary,"01/01/1970 01:05:07 pm")
        XCTAssertEqual(settings.format(Date(timeIntervalSince1970:47_107),zone:utc),"01/01/1970 01:05 pm")
        XCTAssertEqual(settings.format(Date(timeIntervalSince1970:47_107),dateOnly:true,zone:utc,precision:.milliseconds),"01/01/1970")
        let inherited = ChatArchivePeriodPresentation(archive:instant,regional:try regional(date:"system",time:"system"),timeZone:utc)
        XCTAssertEqual(inherited.summary,"01/01/1970 13:05:07")
    }
    func testIdenticalInstantHasSingleTimestampAndExactRangeIsLocaleIndependent() throws {
        let source = try archive(1234,1234)
        let one = ChatArchivePeriodPresentation(archive:source,locale:Locale(identifier:"ja_JP"),timeZone:utc)
        let two = ChatArchivePeriodPresentation(archive:source,locale:Locale(identifier:"en_US"),timeZone:utc)
        XCTAssertFalse(one.summary.contains(" – "))
        XCTAssertEqual(one.exactRange,"1970-01-01 00:00:01.234 UTC+00:00")
        XCTAssertEqual(one.exactRange,two.exactRange)
    }
    func testInvalidExtremeAndReversedBoundsFailWithoutFormatting() throws {
        for (start,end) in [(Double.nan,1),(0,Double.infinity),(-Double.infinity,0),(3000,1000),
                            (-Double.greatestFiniteMagnitude,0),(0,Double.greatestFiniteMagnitude),
                            (-62_135_596_800_001,0),(0,253_402_300_800_000)] {
            let value = ChatArchivePeriodPresentation(archive:try archive(start,end),regional:try regional(),timeZone:utc)
            XCTAssertFalse(value.isAvailable)
            XCTAssertEqual(value.summary,"Unavailable archive period")
            XCTAssertEqual(value.exactRange,value.summary)
            XCTAssertEqual(value.label,"Archive 600 · Unavailable archive period")
        }
    }
}
