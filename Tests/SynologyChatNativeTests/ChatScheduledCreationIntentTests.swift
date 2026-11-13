import Foundation
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatScheduledCreationIntentTests:XCTestCase {
    private let text = "Private synthetic scheduled draft 😀"
    private let sendAt:Int64 = 2000000000000
    private func job(_ id:Int64,message:String? = nil,time:Double? = nil)->ChatScheduledMessage {
        .init(cronjob_id:id,message:message ?? text,send_at:time ?? Double(sendAt))
    }
    private func record(channel:Int64 = 93,before:[ChatScheduledMessage] = []) throws -> ChatScheduledCreationIntent {
        try .init(channelID:channel,message:text,sendAt:sendAt,before:before,now:Date(timeIntervalSince1970:1900000000))
    }
    func testExactContentAndTimestampMatchingExcludesOnlyMatchingBaseline() throws {
        let value = try record(before:[job(9),job(3),job(4,message:"Different"),job(5,time:Double(sendAt+1))])
        XCTAssertEqual(value.id,"create:93");XCTAssertEqual(value.beforeMatchingJobIDs,[3,9])
        XCTAssertTrue(value.matches(job(3)));XCTAssertFalse(value.matches(job(10,message:text+" ")))
        XCTAssertFalse(value.matches(job(11,time:Double(sendAt)+0.5)))
        XCTAssertFalse(value.matches(job(0)));XCTAssertFalse(value.matches(job(12,time:.nan)))
        XCTAssertEqual(value.candidates(in:[job(9),job(12),job(3),job(10),job(13,message:"Different")]).map(\.id),[10,12])
        XCTAssertEqual(try value.acknowledging(10).acknowledging(10).acknowledgedID,10)
        XCTAssertThrowsError(try value.acknowledging(3));XCTAssertThrowsError(try value.acknowledging(0))
        XCTAssertThrowsError(try value.acknowledging(10).acknowledging(11))
    }
    func testFingerprintUsesExactValidatedUTF8WithoutNormalization() throws {
        let known = try ChatScheduledCreationIntent(channelID:93,message:"abc",sendAt:sendAt,before:[])
        XCTAssertEqual(known.messageFingerprint,"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let composed = try ChatScheduledCreationIntent(channelID:93,message:"é",sendAt:sendAt,before:[])
        XCTAssertFalse(composed.matches(job(1,message:"e\u{301}")))
        XCTAssertTrue(composed.matches(job(Int64.max,message:"é")),"Current scheduled-job contract permits every positive Int64 ID")
    }
    func testRejectsInvalidInputsAndOversizedBaselineInsteadOfTruncating() throws {
        XCTAssertEqual(try record(before:(1...128).map { job(Int64($0)) }).beforeMatchingJobIDs.count,128)
        XCTAssertThrowsError(try record(before:(1...129).map { job(Int64($0)) }))
        XCTAssertThrowsError(try record(before:[job(1),job(1)]))
        XCTAssertThrowsError(try record(before:[job(0)]));XCTAssertThrowsError(try record(channel:0))
        for message in [""," \n",String(repeating:"x",count:2001)] {
            XCTAssertThrowsError(try ChatScheduledCreationIntent(channelID:93,message:message,sendAt:sendAt,before:[]))
        }
        let invalidTimes:[Int64] = [0,-1,253402300800000,Int64.max]
        for time in invalidTimes {
            XCTAssertThrowsError(try ChatScheduledCreationIntent(channelID:93,message:text,sendAt:time,before:[]))
        }
        for timestamp in [Double.nan,Double.infinity,0,-1,Date.distantFuture.timeIntervalSince1970] {
            XCTAssertThrowsError(try ChatScheduledCreationIntent(channelID:93,message:text,sendAt:sendAt,before:[],now:Date(timeIntervalSince1970:timestamp)))
        }
    }
    func testDecodedMalformedReceiptsFailValidation() throws {
        let original = try record(before:[job(3)])
        let encoded = try JSONEncoder().encode(original)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        let mutations:[(String,Any)] = [("messageFingerprint",String(repeating:"A",count:64)),("messageFingerprint",String(repeating:"a",count:63)),("beforeMatchingJobIDs",[3,2]),("beforeMatchingJobIDs",[3,3]),("beforeMatchingJobIDs",[0]),("beforeMatchingJobIDs",Array(1...129)),("acknowledgedID",3),("acknowledgedID",0),("channelID",0),("sendAt",253402300800000 as Int64),("createdAt",0)]
        for (key,value) in mutations {
            var mutated = payload;mutated[key] = value
            let decoded = try JSONDecoder().decode(ChatScheduledCreationIntent.self,from:JSONSerialization.data(withJSONObject:mutated))
            XCTAssertThrowsError(try decoded.validate(),key)
        }
        XCTAssertEqual(try JSONDecoder().decode(ChatScheduledCreationIntent.self,from:encoded),original)
    }
    func testPrivateJournalReloadScopeAndAcknowledgementCheckpoint() throws {
        let directory = URL(fileURLWithPath:"/private/tmp").appendingPathComponent("scheduled-intent-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let scope = String(repeating:"a",count:64),other = String(repeating:"b",count:64)
        let original = try record(before:[job(3)]),confirmed = try original.acknowledging(10)
        let journal = ChatScheduledCreationJournal(directory:directory)
        _ = try journal.activate(scope:scope);try journal.remember(original);try journal.replace(original,with:confirmed)
        let file = directory.appendingPathComponent(scope+".json")
        let stored = try String(contentsOf:file,encoding:.utf8)
        XCTAssertFalse(stored.contains(text));XCTAssertFalse(stored.contains("Private synthetic"));XCTAssertFalse(stored.contains("😀"))
        XCTAssertTrue(stored.contains(original.messageFingerprint))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        let reopened = ChatScheduledCreationJournal(directory:directory)
        XCTAssertEqual(try reopened.activate(scope:scope),[confirmed]);XCTAssertTrue(try reopened.activate(scope:other).isEmpty)
        XCTAssertEqual(try reopened.activate(scope:scope),[confirmed]);XCTAssertThrowsError(try reopened.remove(original))
        try reopened.remove(confirmed);XCTAssertTrue(try reopened.activate(scope:scope).isEmpty)
    }
    func testChannelConflictAndLeaseExcludeConcurrentAttemptsWithoutBlockingOtherChannels() throws {
        let directory = URL(fileURLWithPath:"/private/tmp").appendingPathComponent("scheduled-lease-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let scope = String(repeating:"c",count:64)
        let first = try record(),retry = try record(),other = try record(channel:94)
        XCTAssertNotEqual(first.operationID,retry.operationID)
        XCTAssertTrue(first.conflicts(with:retry));XCTAssertFalse(first.conflicts(with:other))
        let a = ChatScheduledCreationJournal(directory:directory),b = ChatScheduledCreationJournal(directory:directory)
        _ = try a.activate(scope:scope);_ = try b.activate(scope:scope)
        try a.remember(first);XCTAssertThrowsError(try b.remember(retry));try b.remember(other)
        let held = try a.acquireActionLease(for:first)
        XCTAssertThrowsError(try b.acquireActionLease(for:retry))
        let unrelated = try b.acquireActionLease(for:other);unrelated.release()
        let otherAccount = ChatScheduledCreationJournal(directory:directory)
        _ = try otherAccount.activate(scope:String(repeating:"d",count:64))
        let otherScopeLease = try otherAccount.acquireActionLease(for:first);otherScopeLease.release()
        held.release();let next = try b.acquireActionLease(for:retry);next.release()
        try a.remove(first);try b.remember(retry);XCTAssertThrowsError(try a.remove(first))
        XCTAssertEqual(Set(try a.activate(scope:scope).map(\.operationID)),Set([retry.operationID,other.operationID]))
    }
}
