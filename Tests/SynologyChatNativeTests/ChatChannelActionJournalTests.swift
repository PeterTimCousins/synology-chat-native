import XCTest
@testable import SynologyChatNative

@MainActor final class ChatChannelActionJournalTests:XCTestCase {
    private let scope = String(repeating:"a",count:64)
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("channel-journal-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at:url) };return url
    }
    private func record(_ id:Int64 = 97,latest:Int64? = 200)->ChatChannelActionRecord { .init(kind:latest == nil ? .close : .archive,channelID:id,channelType:"private",encrypted:false,latestPostID:latest,priorArchiveIDs:[6,26]) }
    func testAtomicRoundTripSurvivesNewInstanceAndOmitsPrivateContent() throws {
        let directory = try directory(),journal = ChatChannelActionJournal(directory:directory),record = record()
        XCTAssertTrue(try journal.activate(scope:scope).isEmpty);try journal.remember(record);journal.deactivate()
        let fresh = ChatChannelActionJournal(directory:directory);XCTAssertEqual(try fresh.activate(scope:scope),[record])
        let file = directory.appendingPathComponent(scope+".json"),data = try Data(contentsOf:file),text = String(decoding:data,as:UTF8.self)
        for forbidden in ["sid","SynoToken","password","message","name","key_enc","username","https:"] { XCTAssertFalse(text.contains(forbidden)) }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        try fresh.remove(record);XCTAssertTrue(try ChatChannelActionJournal(directory:directory).activate(scope:scope).isEmpty)
    }
    func testAccountIsolationAndInvalidScopeRejection() throws {
        let directory = try directory(),journal = ChatChannelActionJournal(directory:directory);_ = try journal.activate(scope:scope);try journal.remember(record())
        XCTAssertTrue(try journal.activate(scope:String(repeating:"b",count:64)).isEmpty)
        XCTAssertEqual(try journal.activate(scope:scope),[record()])
        for invalid in ["../account","https://server","",String(repeating:"A",count:64)] { XCTAssertThrowsError(try journal.activate(scope:invalid)) }
    }
    func testCorruptWrongScopeAndOversizedRecordsArePreservedAndRejected() throws {
        let directory = try directory(),file = directory.appendingPathComponent(scope+".json")
        for data in [Data("invalid JSON".utf8),Data(#"{"version":1,"accountScope":"wrong","records":[]}"#.utf8),Data(repeating:32,count:1024*1024+1)] {
            try data.write(to:file)
            XCTAssertThrowsError(try ChatChannelActionJournal(directory:directory).activate(scope:scope))
            XCTAssertEqual(try Data(contentsOf:file),data)
        }
    }
    func testInterleavedWritersPreserveOtherRequestsAndRejectDuplicateDispatchRecord() throws {
        let directory = try directory(),first = ChatChannelActionJournal(directory:directory),second = ChatChannelActionJournal(directory:directory)
        _ = try first.activate(scope:scope);_ = try second.activate(scope:scope)
        try first.remember(record());try second.remember(record(98))
        XCTAssertEqual(try ChatChannelActionJournal(directory:directory).activate(scope:scope).map(\.id),[97,98])
        XCTAssertThrowsError(try second.remember(record()))
    }
    func testOldReceiptCannotEraseNewerRequestForSameChannel() throws {
        let directory = try directory(),first = ChatChannelActionJournal(directory:directory),second = ChatChannelActionJournal(directory:directory)
        _ = try first.activate(scope:scope);try first.remember(record());_ = try second.activate(scope:scope)
        try second.remove(record());try second.remember(record(latest:300))
        XCTAssertThrowsError(try first.remove(record()))
        XCTAssertEqual(try ChatChannelActionJournal(directory:directory).activate(scope:scope),[record(latest:300)])
    }
    func testUnsupportedAndMalformedRecordsNeverPersist() throws {
        let journal = ChatChannelActionJournal()
        for record in [record(1),.init(kind:.archive,channelID:97,channelType:"public",encrypted:false,latestPostID:200,priorArchiveIDs:[]),.init(kind:.archive,channelID:97,channelType:"private",encrypted:true,latestPostID:200,priorArchiveIDs:[]),.init(kind:.close,channelID:97,channelType:"private",encrypted:false,latestPostID:200,priorArchiveIDs:[]),.init(kind:.close,channelID:97,channelType:"private",encrypted:false,latestPostID:nil,priorArchiveIDs:[6,6])] { XCTAssertThrowsError(try journal.remember(record)) }
    }
    func testFallbackSnapshotHasNoKeysAndNeverRequiresAStoredName() throws {
        let record = ChatChannelActionRecord(kind:.close,channelID:97,channelType:"anonymous",encrypted:true,latestPostID:nil,priorArchiveIDs:[])
        let channel = try record.channel(loaded:[])
        XCTAssertEqual(channel.id,97);XCTAssertEqual(channel.name,"Channel 97");XCTAssertNil(channel.channel_key_enc);XCTAssertTrue(channel.encrypted)
    }
    func testSymlinkJournalIsRejectedWithoutReadingOrReplacingTarget() throws {
        let directory = try directory(),target = directory.appendingPathComponent("untouched.txt"),data = Data("Synthetic unrelated file".utf8)
        try data.write(to:target);try FileManager.default.createSymbolicLink(at:directory.appendingPathComponent(scope+".json"),withDestinationURL:target)
        XCTAssertThrowsError(try ChatChannelActionJournal(directory:directory).activate(scope:scope));XCTAssertEqual(try Data(contentsOf:target),data)
    }
}
