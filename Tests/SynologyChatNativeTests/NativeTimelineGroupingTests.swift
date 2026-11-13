import XCTest
@testable import SynologyChatNative

final class NativeTimelineGroupingTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier:.gregorian);value.timeZone = TimeZone(secondsFromGMT:0)!;return value
    }
    private let base = 1_792_843_200_000.0
    private func post(_ id:Int64, offset:Double = 0, _ extra:[String:Any] = [:]) throws -> ChatPost {
        var value:[String:Any] = ["post_id":id,"channel_id":93,"creator_id":10,"type":"normal","message":"Hello","create_at":base+offset]
        value.merge(extra) { _,new in new }
        return try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:value))
    }
    func testAdjacentOrdinaryPostsGroupOnlyWithinFiveMinuteWindow() throws {
        let first = try post(1)
        XCTAssertFalse(NativeTimelineGrouping.isContinuation(first,after:nil,calendar:calendar))
        XCTAssertFalse(NativeTimelineGrouping.isContinuation(first,after:first,calendar:calendar))
        XCTAssertTrue(NativeTimelineGrouping.isContinuation(try post(2),after:first,calendar:calendar))
        XCTAssertTrue(NativeTimelineGrouping.isContinuation(try post(2,offset:300_000),after:first,calendar:calendar))
        XCTAssertFalse(NativeTimelineGrouping.isContinuation(try post(2,offset:300_001),after:first,calendar:calendar))
        XCTAssertFalse(NativeTimelineGrouping.isContinuation(try post(2,offset:-1),after:first,calendar:calendar))
    }
    func testIdentityChannelAndThreadBoundariesRemainSeparate() throws {
        let first = try post(1)
        for extra:[String:Any] in [["creator_id":6],["channel_id":94],["thread_id":75]] {
            XCTAssertFalse(NativeTimelineGrouping.isContinuation(try post(2,extra),after:first,calendar:calendar))
        }
        XCTAssertTrue(NativeTimelineGrouping.isContinuation(try post(3,["thread_id":75]),after:try post(2,["thread_id":75]),calendar:calendar))
        XCTAssertFalse(NativeTimelineGrouping.isContinuation(try post(3,["thread_id":76]),after:try post(2,["thread_id":75]),calendar:calendar))
        // A root may use its own ID or no thread_id on the wire.
        XCTAssertTrue(NativeTimelineGrouping.isContinuation(try post(2,["thread_id":2]),after:first,calendar:calendar))
    }
    func testCalendarDayBoundaryUsesSuppliedDisplayTimezone() throws {
        let day = calendar.startOfDay(for:Date(timeIntervalSince1970:base/1_000))
        let nearMidnight = day.addingTimeInterval(24*60*60-60).timeIntervalSince1970*1_000-base
        let first = try post(1,offset:nearMidnight),next = try post(2,offset:nearMidnight+120_000)
        XCTAssertFalse(NativeTimelineGrouping.isContinuation(next,after:first,calendar:calendar))
        var shifted = calendar;shifted.timeZone = TimeZone(secondsFromGMT:2*60*60)!
        XCTAssertTrue(NativeTimelineGrouping.isContinuation(next,after:first,calendar:shifted))
    }
    func testRichDeletedAndNonMessageRowsBreakBothSidesOfAGroup() throws {
        let ordinary = try post(1)
        let exclusions:[[String:Any]] = [
            ["delete_at":base+10], ["type":"system"], ["type":"vote"], ["type":"sticker"],
            ["message":""], ["message":"> quoted"], ["message":"```\nlet value = 1\n```"], ["message":"* list"],
            ["props":["encrypted":true]], ["props":["attachments":[["text":"bot card"]]]],
            ["props":["forward":["origin_channel_id":93,"origin_post_id":22,"origin_user_id":10,"origin_thread_id":0]]],
            ["props":["vote":["state":"open","options":["multiple":false,"anonymous":false,"add_option":false,"expire_at":0],"choices":[]]]],
            ["url_props":[["url":"https://example.test","title":"Preview"]]],
            ["type":"file","file_props":["name":"code.txt","is_snippet":true]], ["type":"file"]
        ]
        for extra in exclusions {
            let special = try post(2,extra)
            XCTAssertFalse(NativeTimelineGrouping.isContinuation(special,after:ordinary,calendar:calendar),"\(extra)")
            XCTAssertFalse(NativeTimelineGrouping.isContinuation(try post(3),after:special,calendar:calendar),"\(extra)")
        }
    }
    func testSimpleFilesAndInlineFormattingKeepIndividualContinuationIdentity() throws {
        let first = try post(1)
        let file = try post(2,["type":"file","message":"caption","file_props":["name":"photo.png","is_image":true]])
        XCTAssertTrue(NativeTimelineGrouping.isContinuation(file,after:first,calendar:calendar))
        XCTAssertTrue(NativeTimelineGrouping.isContinuation(try post(3,["message":"*bold* and `inline code`"]),after:file,calendar:calendar))
        XCTAssertEqual(file.id,2)
        XCTAssertEqual(file.file_props?.name,"photo.png")
    }
}
