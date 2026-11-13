import XCTest
@testable import SynologyChatNative

final class ChatSearchFilterTests: XCTestCase {
    private func object(_ filters: ChatSearchFilters, calendar: Calendar) throws -> [String:Any] {
        try JSONSerialization.jsonObject(with:JSONEncoder().encode(filters.parameters(calendar:calendar))) as! [String:Any]
    }
    private var london: Calendar { var value = Calendar(identifier:.gregorian);value.timeZone = TimeZone(identifier:"Europe/London")!;return value }
    func testTypedAuthorMentionContentAndBookmarkMap() throws {
        var filters = ChatSearchFilters();filters.authorID = 10;filters.mentionID = 6
        filters.content = .file;filters.attribute = .star;filters.fileType = " PNG "
        let fields = try object(filters,calendar:london)
        XCTAssertEqual(fields["from"] as? [Int],[10]);XCTAssertEqual(fields["mention"] as? [Int],[6])
        XCTAssertEqual(fields["post_type"] as? [String],["file"]);XCTAssertEqual(fields["has"] as? [String],["star"])
        XCTAssertEqual(fields["file_type"] as? [String],["png"])
        XCTAssertNil(fields["keyword"]);XCTAssertNil(fields["in"])
    }
    func testLocalDayBoundsRespectDSTAndOfficialLastSecond() throws {
        let calendar = london
        for (month,day,hours) in [(3,29,23),(10,25,25)] {
            let date = calendar.date(from:DateComponents(year:2026,month:month,day:day,hour:12))!
            var filters = ChatSearchFilters();filters.after = date;filters.before = date
            let fields = try object(filters,calendar:calendar)
            let first = (fields["after"] as! NSNumber).int64Value;let last = (fields["before"] as! NSNumber).int64Value
            XCTAssertEqual(last-first,Int64(hours*3600-1)*1000)
            XCTAssertEqual(first%1000,0);XCTAssertEqual(last%1000,0)
            XCTAssertEqual(calendar.component(.hour,from:Date(timeIntervalSince1970:Double(first)/1000)),0)
            XCTAssertEqual(calendar.component(.hour,from:Date(timeIntervalSince1970:Double(last)/1000)),23)
        }
    }
    func testInvalidFiltersFailBeforeBuildingRequest() {
        var filters = ChatSearchFilters();filters.fileType = ".pdf";XCTAssertThrowsError(try filters.parameters())
        filters.fileType = "";filters.authorID = -1;XCTAssertThrowsError(try filters.parameters())
        filters.authorID = nil;filters.after = Date(timeIntervalSince1970:172800);filters.before = Date(timeIntervalSince1970:0)
        XCTAssertThrowsError(try filters.parameters(calendar:Calendar(identifier:.gregorian)))
        filters.before = nil;filters.after = Date(timeIntervalSince1970:.infinity);XCTAssertThrowsError(try filters.parameters())
    }
    func testEmptyFiltersDoNotChangeLegacySearch() throws {
        XCTAssertTrue(ChatSearchFilters().isEmpty)
        XCTAssertTrue(try ChatSearchFilters().parameters().isEmpty)
        var filters = ChatSearchFilters();filters.fileType = "  ";XCTAssertTrue(filters.isEmpty)
        filters.attribute = .url;XCTAssertFalse(filters.isEmpty)
    }
}
