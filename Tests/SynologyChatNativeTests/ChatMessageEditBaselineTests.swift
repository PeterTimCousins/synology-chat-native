import Foundation
import XCTest
@testable import SynologyChatNative

final class ChatMessageEditBaselineTests:XCTestCase {
    private func post(_ changes:[String:Any] = [:]) throws -> ChatPost {
        var value:[String:Any] = ["post_id":120,"channel_id":23,"creator_id":10,"type":"normal","message":"Original raw wire message café 😀","create_at":1000]
        value.merge(changes,uniquingKeysWith:{ _,new in new })
        return try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:value))
    }
    func testUnchangedWireContentMatchesButEveryEditIdentityFieldIsRequired() throws {
        let baseline = ChatMessageEditBaseline(try post(["thread_id":9,"update_at":2000]))
        XCTAssertTrue(baseline.matches(try post(["thread_id":9,"update_at":2000])))
        for change:[String:Any] in [["post_id":121],["channel_id":24],["creator_id":11],["thread_id":8],["thread_id":0],["type":"file"],["create_at":1001],["update_at":2001],["message":"Changed wire content"]] {
            var updated:[String:Any] = ["thread_id":9,"update_at":2000]
            updated.merge(change,uniquingKeysWith:{ _,new in new })
            XCTAssertFalse(baseline.matches(try post(updated)),"Changed fields: \(change.keys.sorted())")
        }
    }
    func testOriginalOrFreshDeletionRejectsEvenWhenContentAndRevisionAreUnchanged() throws {
        let clean = try post(),deleted = try post(["delete_at":3000])
        XCTAssertFalse(ChatMessageEditBaseline(clean).matches(deleted))
        XCTAssertFalse(ChatMessageEditBaseline(deleted).matches(clean))
        XCTAssertFalse(ChatMessageEditBaseline(deleted).matches(deleted))
        XCTAssertTrue(ChatMessageEditBaseline(try post(["delete_at":0])).matches(clean))
        XCTAssertTrue(ChatMessageEditBaseline(try post(["delete_at":-1])).matches(try post(["delete_at":-2])))
    }
    func testWireUTF8DoesNotUseCanonicalStringEquivalenceOrWhitespaceNormalization() throws {
        let composed = "café",decomposed = "cafe\u{301}"
        XCTAssertEqual(composed,decomposed)
        XCTAssertNotEqual(Data(composed.utf8),Data(decomposed.utf8))
        let baseline = ChatMessageEditBaseline(try post(["message":composed]))
        XCTAssertTrue(baseline.matches(try post(["message":composed])))
        XCTAssertFalse(baseline.matches(try post(["message":decomposed])))
        XCTAssertFalse(baseline.matches(try post(["message":composed+" "])))
        XCTAssertFalse(baseline.matches(try post(["message":" "+composed])))
    }
    func testReactionsCommentsStarsPinsAndURLMetadataAreBenign() throws {
        let baseline = ChatMessageEditBaseline(try post(["update_at":2000]))
        let fresh = try post(["update_at":2000,"comment_count":9,"last_comment_at":7000,"is_star":true,"star_at":8000,"is_sticky":true,"last_pin_at":9000,
            "reactions":[["sticker_name":"like","user_ids":[10,20]]],
            "url_props":[["url":"https://example.invalid/","title":"Refreshed metadata","image":"https://example.invalid/preview.png"]],
            "hashtags":["new"],"props":["safe_url":true]])
        XCTAssertEqual(fresh.comment_count,9);XCTAssertEqual(fresh.is_star,true);XCTAssertEqual(fresh.last_pin_at,9000)
        XCTAssertFalse(fresh.reactions?.isEmpty ?? true);XCTAssertFalse(fresh.url_props?.isEmpty ?? true)
        XCTAssertTrue(baseline.matches(fresh))
    }
    func testRootSelfThreadZeroAndNilShareNormalContextButRealReplyDoesNot() throws {
        let root = ChatMessageEditBaseline(try post(["thread_id":120]))
        XCTAssertTrue(root.matches(try post(["thread_id":0])))
        XCTAssertTrue(root.matches(try post()))
        XCTAssertFalse(root.matches(try post(["thread_id":9])))
        let reply = ChatMessageEditBaseline(try post(["thread_id":9]))
        XCTAssertFalse(reply.matches(try post(["thread_id":120])))
        XCTAssertFalse(reply.matches(try post()))
    }
    func testIdentitySeparatesContentConflictsAndTombstonesWithoutAcceptingNonfiniteCreation() throws {
        let baseline = ChatMessageEditBaseline(try post())
        for fresh in [try post(["message":"Changed content"]),try post(["update_at":2000]),try post(["delete_at":3000])] {
            XCTAssertTrue(baseline.matchesIdentity(fresh));XCTAssertFalse(baseline.matches(fresh))
        }
        XCTAssertFalse(baseline.matchesIdentity(try post(["thread_id":9])))
        for value in ["Infinity","-Infinity","NaN"] {
            let raw:[String:Any] = ["post_id":120,"channel_id":23,"creator_id":10,"type":"normal","message":"Original raw wire message café 😀","create_at":value]
            let decoder = JSONDecoder();decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity:"Infinity",negativeInfinity:"-Infinity",nan:"NaN")
            let invalid = try decoder.decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:raw))
            XCTAssertFalse(baseline.matchesIdentity(invalid))
            XCTAssertFalse(ChatMessageEditBaseline(invalid).matchesIdentity(invalid))
            XCTAssertFalse(ChatMessageEditBaseline(invalid).matches(invalid))
        }
    }
    func testNilAndZeroUpdateRevisionAreEquivalentButNonzeroCannotDisappear() throws {
        XCTAssertTrue(ChatMessageEditBaseline(try post()).matches(try post(["update_at":0])))
        XCTAssertTrue(ChatMessageEditBaseline(try post(["update_at":0])).matches(try post()))
        XCTAssertFalse(ChatMessageEditBaseline(try post(["update_at":1])).matches(try post()))
        XCTAssertFalse(ChatMessageEditBaseline(try post()).matches(try post(["update_at":1])))
    }
}
