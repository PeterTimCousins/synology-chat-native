import XCTest
@testable import SynologyChatNative

@MainActor final class ChatEncryptedConversationIntentTests:XCTestCase {
    private let password = "Synthetic intent password"
    private func setup() throws -> (ChatEncryptionKeyPair,ChatEncryptionSession,[ChatUser],ChatEncryptedConversationIntent) {
        let pair = try ChatEncryptionManagement.generateKeyPair(password:password,confirmation:password),keys = ChatEncryptionSession();try keys.unlock(pair,password:password)
        let users = try [10,30].map { id in
            try JSONDecoder().decode(ChatUser.self,from:JSONSerialization.data(withJSONObject:["user_id":id,"username":"synthetic-private-name-\(id)","nickname":"Private nickname","type":"human","human_type":"dsm","user_props":["key_pair":["public_key":pair.public_key]]]))
        }
        let plan = try ChatEncryptedConversationStart(ownerID:10,owner:pair,users:users,encryption:keys)
        return (pair,keys,users,try .init(plan:plan,owner:pair))
    }
    private func channel(_ intent:ChatEncryptedConversationIntent,changes:[String:Any] = [:]) throws -> ChatChannel {
        var value:[String:Any] = ["channel_id":123,"name":"","type":"anonymous","encrypted":true,"is_joined":true,"unread":0,"channel_key_enc":intent.creatorEnvelope]
        value.merge(changes,uniquingKeysWith:{ _,new in new });return try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:value))
    }
    func testJournalColdRestoreDuplicateGuardAndLateCandidateRemainInOriginalAccount() throws {
        let (_,_,_,intent) = try setup(),folder = FileManager.default.temporaryDirectory.appendingPathComponent("encrypted-start-journal-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let first = String(repeating:"a",count:64),second = String(repeating:"b",count:64),journal = ChatEncryptedConversationJournal(directory:folder)
        XCTAssertTrue(try journal.activate(scope:first).isEmpty);try journal.rememberAsOnlyPending(intent)
        XCTAssertThrowsError(try journal.rememberAsOnlyPending(intent))
        let restored = ChatEncryptedConversationJournal(directory:folder);XCTAssertEqual(try restored.activate(scope:first),[intent])
        XCTAssertTrue(try journal.activate(scope:second).isEmpty)
        let known = try intent.recordingCandidate(123);try journal.replaceInScope(intent,with:known,originalScope:first)
        XCTAssertTrue(try journal.activate(scope:second).isEmpty)
        XCTAssertEqual(try restored.activate(scope:first),[known]);XCTAssertThrowsError(try known.recordingCandidate(124))
        try restored.remove(known);XCTAssertTrue(try restored.activate(scope:first).isEmpty)
        let data = try Data(contentsOf:folder.appendingPathComponent(first+".json"));XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("private-name"))
    }
    func testStoredReceiptContainsNoNamesPasswordsOrPlaintextKeysAndRejectsCorruption() throws {
        let (pair,_,_,intent) = try setup(),data = try JSONEncoder().encode(intent),text = String(decoding:data,as:UTF8.self)
        XCTAssertFalse(text.contains("private-name"));XCTAssertFalse(text.contains("Private nickname"));XCTAssertFalse(text.contains(password));XCTAssertFalse(text.contains(pair.private_key_enc))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        object["candidateChannelID"] = -1
        let corrupt = try JSONDecoder().decode(ChatEncryptedConversationIntent.self,from:JSONSerialization.data(withJSONObject:object));XCTAssertThrowsError(try corrupt.validate())
        object["candidateChannelID"] = 123
        object["creatorEnvelope"] = "invalid"
        let invalidKey = try JSONDecoder().decode(ChatEncryptedConversationIntent.self,from:JSONSerialization.data(withJSONObject:object));XCTAssertThrowsError(try invalidKey.validate())
    }
    func testReadOnlyRecoveryRequiresUniqueEnvelopeExactMembersScopeAndUnlockedOwner() throws {
        let (owner,keys,users,intent) = try setup(),canonical = try channel(intent)
        func status(_ snapshots:[ChatEncryptedConversationRecovery.Snapshot])->ChatEncryptedConversationRecovery.Status { ChatEncryptedConversationRecovery.evaluate(intent,owner:owner,users:users,snapshots:snapshots,encryption:keys).status }
        XCTAssertEqual(status([]),.pending)
        XCTAssertEqual(status([.init(channel:canonical,memberIDs:[30,10])]),.verified)
        XCTAssertEqual(status([.init(channel:canonical,memberIDs:[10,30]),.init(channel:canonical,memberIDs:[10,30])]),.ambiguous)
        for members:[Int64]? in [nil,[10],[10,30,40],[10,10]] { XCTAssertEqual(status([.init(channel:canonical,memberIDs:members)]),.unverified) }
        for changes:[String:Any] in [["type":"private"],["is_joined":false],["encrypted":false],["is_closed":true],["hide_global_at":1]] {
            XCTAssertEqual(status([.init(channel:try channel(intent,changes:changes),memberIDs:[10,30])]),.unverified)
        }
        keys.lock();XCTAssertEqual(status([.init(channel:canonical,memberIDs:[10,30])]),.needsUnlock)
        let different = try ChatEncryptionManagement.generateKeyPair(password:password,confirmation:password)
        XCTAssertEqual(ChatEncryptedConversationRecovery.evaluate(intent,owner:different,users:users,snapshots:[],encryption:keys).status,.changedKeys)
        XCTAssertEqual(ChatEncryptedConversationRecovery.evaluate(intent,owner:owner,users:[],snapshots:[],encryption:keys).status,.changedKeys)
    }
    func testKnownConcurrentExistingKeyRequiresReviewAndUnknownReplyCannotInferByParticipants() throws {
        let (owner,keys,users,intent) = try setup()
        let otherPlan = try ChatEncryptedConversationStart(ownerID:10,owner:owner,users:users,encryption:keys)
        let existing = try channel(intent,changes:["channel_key_enc":otherPlan.ownerEnvelope])
        let snapshots = [ChatEncryptedConversationRecovery.Snapshot(channel:existing,memberIDs:[10,30])]
        XCTAssertEqual(ChatEncryptedConversationRecovery.evaluate(intent,owner:owner,users:users,snapshots:snapshots,encryption:keys).status,.pending)
        let known = try intent.recordingCandidate(123)
        XCTAssertEqual(ChatEncryptedConversationRecovery.evaluate(known,owner:owner,users:users,snapshots:snapshots,encryption:keys).status,.existingNeedsReview)
        let bad = try channel(intent,changes:["channel_key_enc":Data(repeating:0,count:92).base64EncodedString()])
        XCTAssertEqual(ChatEncryptedConversationRecovery.evaluate(known,owner:owner,users:users,snapshots:[.init(channel:bad,memberIDs:[10,30])],encryption:keys).status,.unverified)
        let privateKey = try ChatContentCrypto.unlockPrivateKey(owner.private_key_enc,password:password)
        let rewrapped = ChatEncryptionKeyPair(public_key:owner.public_key,private_key_enc:try ChatContentCrypto.wrapPrivateKey(privateKey,password:"New password"))
        XCTAssertTrue(intent.matchesOwner(rewrapped))
    }
}
