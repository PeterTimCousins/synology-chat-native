import XCTest
@testable import SynologyChatNative

@MainActor final class ChatEncryptedConversationStartTests:XCTestCase {
    private let password = "Synthetic conversation password"
    private func pair() throws -> ChatEncryptionKeyPair { try ChatEncryptionManagement.generateKeyPair(password:password,confirmation:password) }
    private func user(_ id:Int64,pair:ChatEncryptionKeyPair?,name:String = "Synthetic",disabled:Bool = false) throws -> ChatUser {
        var value:[String:Any] = ["user_id":id,"username":"synthetic-\(id)","nickname":name,"type":"human","human_type":"dsm","is_disabled":disabled]
        if let pair { value["user_props"] = ["key_pair":["public_key":pair.public_key]] }
        return try JSONDecoder().decode(ChatUser.self,from:JSONSerialization.data(withJSONObject:value))
    }
    private func setup() throws -> (ChatEncryptionKeyPair,ChatEncryptionSession,[ChatUser],ChatEncryptedConversationStart) {
        let owner = try pair(),peer = try pair(),keys = ChatEncryptionSession();try keys.unlock(owner,password:password)
        let users = try [user(30,pair:peer),user(10,pair:owner)]
        return (owner,keys,users,try ChatEncryptedConversationStart(ownerID:10,owner:owner,users:users,encryption:keys))
    }
    private func response(_ envelope:String,changes:[String:Any] = [:]) -> [String:Any] {
        var value:[String:Any] = ["channel_id":123,"name":"","type":"anonymous","encrypted":true,"unread":0,"channel_key_enc":envelope]
        value.merge(changes,uniquingKeysWith:{ _,new in new });return value
    }
    private func api() async throws -> ChatAPIClient {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [EncryptedStartProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://encrypted-start.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config));try await api.discover();return api
    }
    override func tearDown() { EncryptedStartProtocol.handler = nil;super.tearDown() }

    func testOneFreshKeyIsSealedForEveryParticipantIncludingOwnerInCanonicalOrder() throws {
        let owner = try pair(),first = try pair(),second = try pair(),keys = ChatEncryptionSession();try keys.unlock(owner,password:password)
        let users = try [user(30,pair:second),user(10,pair:owner),user(20,pair:first)]
        let plan = try ChatEncryptedConversationStart(ownerID:10,owner:owner,users:users,encryption:keys)
        XCTAssertEqual(plan.userIDs,[10,20,30]);XCTAssertEqual(Set(plan.envelopes).count,3)
        var decrypted:[Data] = []
        for (index,pair) in [owner,first,second].enumerated() {
            decrypted.append(try ChatContentCrypto.unwrapChannelKey(plan.envelopes[index],publicKey:ChatContentCrypto.decodeBase64(pair.public_key),privateKey:ChatContentCrypto.unlockPrivateKey(pair.private_key_enc,password:password)))
        }
        XCTAssertEqual(Set(decrypted).count,1);XCTAssertEqual(decrypted[0].count,32)
        let another = try ChatEncryptedConversationStart(ownerID:10,owner:owner,users:users,encryption:keys)
        let anotherKey = try ChatContentCrypto.unwrapChannelKey(another.ownerEnvelope,publicKey:ChatContentCrypto.decodeBase64(owner.public_key),privateKey:ChatContentCrypto.unlockPrivateKey(owner.private_key_enc,password:password))
        XCTAssertNotEqual(decrypted[0],anotherKey)
        XCTAssertThrowsError(try ChatContentCrypto.unwrapChannelKey(plan.envelopes[1],publicKey:ChatContentCrypto.decodeBase64(second.public_key),privateKey:ChatContentCrypto.unlockPrivateKey(second.private_key_enc,password:password)))
    }
    func testMissingDuplicateDisabledOwnerAndRecipientChangesRejectBeforeDispatch() throws {
        let (owner,keys,users,plan) = try setup(),replacement = try pair()
        for changed in [[],[users[0]],[users[0],users[0]],try [user(10,pair:owner),user(30,pair:nil)],try [user(10,pair:owner),user(30,pair:replacement,disabled:true)]] {
            XCTAssertThrowsError(try ChatEncryptedConversationStart(ownerID:10,owner:owner,users:changed,encryption:keys))
        }
        for changed in [try [user(10,pair:owner),user(30,pair:replacement)],try [user(10,pair:owner),user(30,pair:owner,name:"Changed")],users+[try user(40,pair:owner)]] {
            XCTAssertThrowsError(try plan.validate(owner:owner,users:changed,encryption:keys))
        }
        let privateKey = try ChatContentCrypto.unlockPrivateKey(owner.private_key_enc,password:password)
        let rewrapped = ChatEncryptionKeyPair(public_key:owner.public_key,private_key_enc:try ChatContentCrypto.wrapPrivateKey(privateKey,password:"Changed password"))
        XCTAssertThrowsError(try plan.validate(owner:rewrapped,users:users,encryption:keys))
        keys.lock();XCTAssertThrowsError(try plan.validate(owner:owner,users:users,encryption:keys))
    }
    func testCreatedResponseRequiresAnonymousEncryptedOpenScopeAndExactOwnerEnvelope() throws {
        let (_,_,_,plan) = try setup()
        let valid = try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:response("\r\n"+plan.ownerEnvelope)))
        XCTAssertTrue(plan.matchesCreatedResponse(valid))
        for change:[String:Any] in [["channel_id":1],["type":"private"],["encrypted":false],["is_joined":false],["is_closed":true],["hide_global_at":1],["channel_key_enc":"invalid"]] {
            let value = try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:response(plan.ownerEnvelope,changes:change)))
            XCTAssertFalse(plan.matchesCreatedResponse(value))
        }
    }
    func testActualWireUsesEncryptedFlagAlignedEnvelopeArrayAndNoSeparateJoin() async throws {
        let (owner,keys,users,plan) = try setup(),api = try await api();var requests = 0
        EncryptedStartProtocol.handler = { fields in
            requests += 1
            XCTAssertEqual(fields["api"],"SYNO.Chat.Channel.Anonymous");XCTAssertEqual(fields["method"],"initiate");XCTAssertEqual(fields["version"],"2")
            XCTAssertEqual(Set(fields.keys),Set(["api","method","version","user_ids","encrypted","channel_key_encs"]))
            XCTAssertEqual(fields["encrypted"],"true")
            XCTAssertEqual(try JSONDecoder().decode([Int64].self,from:Data(fields["user_ids"]!.utf8)),plan.userIDs)
            XCTAssertEqual(try JSONDecoder().decode([String].self,from:Data(fields["channel_key_encs"]!.utf8)),plan.envelopes)
            return self.response(plan.ownerEnvelope)
        }
        let channel = try await api.initiateEncryptedConversation(plan,owner:owner,users:users,encryption:keys)
        XCTAssertEqual(channel.id,123);XCTAssertEqual(requests,1)
        try keys.validateChannelEnvelope(channel.channel_key_enc!)
    }
    func testLockedAndCancelledPlansSendNothingAndLostResponseIsNeverRetried() async throws {
        let (owner,keys,users,plan) = try setup(),api = try await api();var requests = 0
        EncryptedStartProtocol.handler = { _ in requests += 1;throw URLError(.badServerResponse) }
        keys.lock()
        do { _ = try await api.initiateEncryptedConversation(plan,owner:owner,users:users,encryption:keys);XCTFail() } catch { }
        XCTAssertEqual(requests,0);try keys.unlock(owner,password:password)
        let cancelled = Task { try Task.checkCancellation();return try await api.initiateEncryptedConversation(plan,owner:owner,users:users,encryption:keys) };cancelled.cancel()
        do { _ = try await cancelled.value;XCTFail() } catch { }
        XCTAssertEqual(requests,0)
        do { _ = try await api.initiateEncryptedConversation(plan,owner:owner,users:users,encryption:keys);XCTFail() } catch { }
        XCTAssertEqual(requests,1)
    }
    func testMismatchedResponseRetainsCandidateIDWithoutPublishingJoiningOrRetrying() async throws {
        for change:[String:Any] in [["encrypted":false],["type":"private"],["is_joined":false],["channel_key_enc":"different"],["channel_id":0]] {
            let (owner,keys,users,plan) = try setup(),api = try await api();var requests = 0
            EncryptedStartProtocol.handler = { fields in requests += 1;XCTAssertEqual(fields["method"],"initiate");return self.response(plan.ownerEnvelope,changes:change) }
            do { _ = try await api.initiateEncryptedConversation(plan,owner:owner,users:users,encryption:keys);XCTFail("Mismatched response must not publish") }
            catch let error as ChatEncryptedConversationResponseUnconfirmed { XCTAssertEqual(error.candidateChannelID,change["channel_id"] as? Int == 0 ? nil : 123) }
            XCTAssertEqual(requests,1)
        }
    }
}

private final class EncryptedStartProtocol:URLProtocol {
    static var handler:(([String:String]) throws -> [String:Any])?
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "encrypted-start.invalid",request.url?.scheme == "https" else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        do {
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:4096);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };bytes.append(contentsOf:buffer.prefix(n)) } }
            var parts = URLComponents();parts.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
            let fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
            let payload:[String:Any]
            if request.url?.lastPathComponent == "SYNO.API.Info" { payload = ["SYNO.Chat.Channel.Anonymous":["path":"entry.cgi","minVersion":1,"maxVersion":2,"requestFormat":"JSON"]] }
            else { guard let handler = Self.handler else { throw URLError(.unsupportedURL) };payload = try handler(fields) }
            let data = try JSONSerialization.data(withJSONObject:["success":true,"data":payload])
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() { }
}
