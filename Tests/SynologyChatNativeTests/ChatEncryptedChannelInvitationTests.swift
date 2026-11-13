import XCTest
@testable import SynologyChatNative

@MainActor final class ChatEncryptedChannelInvitationTests:XCTestCase {
    private struct Fixture:Decodable { let password,publicKey,privateKey,wrappedPrivateKey,wrappedChannelKey,channelKey:String }
    private func fixture() throws -> Fixture { try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:XCTUnwrap(Bundle.module.url(forResource:"ChatCrypto",withExtension:"json",subdirectory:"Fixtures")))) }
    private func channel(_ fixture:Fixture,changes:[String:Any] = [:]) throws -> ChatChannel {
        var object:[String:Any] = ["channel_id":23,"name":"Synthetic encrypted private","type":"private","encrypted":true,"is_joined":true,"unread":0,"channel_key_enc":fixture.wrappedChannelKey]
        object.merge(changes,uniquingKeysWith:{ _,new in new });return try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:object))
    }
    private func user(_ id:Int64,key:String?,name:String = "Synthetic peer",changes:[String:Any] = [:]) throws -> ChatUser {
        var object:[String:Any] = ["user_id":id,"username":"synthetic-\(id)","nickname":name,"type":"human","human_type":"dsm"]
        if let key { object["user_props"] = ["key_pair":["public_key":key]] }
        object.merge(changes,uniquingKeysWith:{ _,new in new });return try JSONDecoder().decode(ChatUser.self,from:JSONSerialization.data(withJSONObject:object))
    }
    private func unlocked(_ f:Fixture) throws -> ChatEncryptionSession {
        let keys = ChatEncryptionSession();try keys.unlock(.init(public_key:f.publicKey,private_key_enc:f.wrappedPrivateKey),password:f.password);return keys
    }
    private let password = "Synthetic invitation password"
    override func tearDown() { EncryptedInviteProtocol.requests = [];super.tearDown() }
    func testRecipientPublicOnlyKeysProduceAlignedIndependentEnvelopesWithoutPrivateRecipientMaterial() throws {
        let f = try fixture(),keys = try unlocked(f)
        let first = try ChatEncryptionManagement.generateKeyPair(password:password,confirmation:password),second = try ChatEncryptionManagement.generateKeyPair(password:password,confirmation:password)
        let users = [try user(30,key:second.public_key),try user(20,key:first.public_key)]
        XCTAssertFalse(users[0].user_props?.key_pair?.isInitialized ?? true)
        let plan = try ChatEncryptedChannelInvitation(channel:channel(f),recipients:users,encryption:keys)
        XCTAssertEqual(plan.userIDs,[20,30]);XCTAssertEqual(plan.envelopes.count,2)
        let expected = try ChatContentCrypto.decodeBase64(f.channelKey)
        for (index,pair) in [first,second].enumerated() {
            let privateKey = try ChatContentCrypto.unlockPrivateKey(pair.private_key_enc,password:password)
            XCTAssertEqual(try ChatContentCrypto.unwrapChannelKey(plan.envelopes[index],publicKey:ChatContentCrypto.decodeBase64(pair.public_key),privateKey:privateKey),expected)
        }
        XCTAssertThrowsError(try ChatContentCrypto.unwrapChannelKey(plan.envelopes[0],publicKey:ChatContentCrypto.decodeBase64(second.public_key),privateKey:ChatContentCrypto.unlockPrivateKey(second.private_key_enc,password:password)))
        let again = try ChatEncryptedChannelInvitation(channel:channel(f),recipients:users,encryption:keys)
        XCTAssertNotEqual(plan.envelopes,again.envelopes)
        let exported:[String:Any] = ["synthetic_only":true,"channel_key":f.channelKey,"user_ids":plan.userIDs,"envelopes":plan.envelopes,"public_keys":[first.public_key,second.public_key],"private_keys":try [first,second].map { try ChatContentCrypto.unlockPrivateKey($0.private_key_enc,password:password).base64EncodedString() }]
        let file = URL(fileURLWithPath:"/private/tmp/native-encrypted-invitation-interop.json")
        try JSONSerialization.data(withJSONObject:exported,options:[.prettyPrinted,.sortedKeys]).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func testLockedInvalidRecipientOrUnsupportedScopeNeverBuildsPlan() throws {
        let f = try fixture(),keys = try unlocked(f),peer = try user(20,key:f.publicKey),valid = try channel(f)
        XCTAssertThrowsError(try ChatEncryptedChannelInvitation(channel:valid,recipients:[peer],encryption:ChatEncryptionSession()))
        for recipients in [[],[peer,peer],[try user(0,key:f.publicKey)],[try user(20,key:nil)],[try user(20,key:"not-base64")],[try user(20,key:Data(repeating:1,count:31).base64EncodedString())],[try user(20,key:f.publicKey,changes:["is_disabled":true])],[try user(20,key:f.publicKey,changes:["human_type":"guest"])]] {
            XCTAssertThrowsError(try ChatEncryptedChannelInvitation(channel:valid,recipients:recipients,encryption:keys))
        }
        for change:[String:Any] in [["type":"public"],["encrypted":false],["channel_id":1],["is_joined":false],["is_closed":true],["hide_global_at":1000]] {
            XCTAssertThrowsError(try ChatEncryptedChannelInvitation(channel:channel(f,changes:change),recipients:[peer],encryption:keys))
        }
        // General is the known reserved ID; do not invent a restriction on a
        // server-verified private channel merely because its ID is two.
        XCTAssertNoThrow(try ChatEncryptedChannelInvitation(channel:channel(f,changes:["channel_id":2]),recipients:[peer],encryption:keys))
    }
    func testFreshRecipientIdentityPublicKeyAndOwnerEnvelopeMustMatchReviewedPlan() throws {
        let f = try fixture(),peer = try user(20,key:f.publicKey),valid = try channel(f)
        let plan = try ChatEncryptedChannelInvitation(channel:valid,recipients:[peer],encryption:unlocked(f))
        try plan.validate(channel:valid,users:[try user(20,key:"\r\n"+f.publicKey)])
        let replacement = try ChatEncryptionManagement.generateKeyPair(password:password,confirmation:password)
        for users in [[try user(20,key:replacement.public_key)],[try user(20,key:f.publicKey,name:"Changed peer")],[],[peer,peer]] {
            XCTAssertThrowsError(try plan.validate(channel:valid,users:users))
        }
        XCTAssertThrowsError(try plan.validate(channel:channel(f,changes:["channel_key_enc":replacement.public_key]),users:[peer]))
    }
    func testEncryptedInviteWireSendsOnlySortedIDsAndCorrespondingSealedKeysAndRejectsChangedPlanBeforeRequest() async throws {
        let f = try fixture(),peers = [try user(30,key:f.publicKey),try user(20,key:f.publicKey)],valid = try channel(f)
        let plan = try ChatEncryptedChannelInvitation(channel:valid,recipients:peers,encryption:unlocked(f))
        let configuration = URLSessionConfiguration.ephemeral;configuration.protocolClasses = [EncryptedInviteProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://encrypted-invite-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:configuration))
        try await api.discover();try await api.inviteEncryptedChannelMembers(plan,channel:valid,users:peers)
        let fields = try XCTUnwrap(EncryptedInviteProtocol.requests.first)
        XCTAssertEqual(EncryptedInviteProtocol.requests.count,1);XCTAssertEqual(fields["method"],"invite");XCTAssertEqual(fields["version"],"1");XCTAssertEqual(fields["channel_id"],"23")
        XCTAssertEqual(fields["user_ids"],"[20,30]")
        let envelopes = try JSONDecoder().decode([String].self,from:Data(try XCTUnwrap(fields["channel_key_encs"]).utf8))
        XCTAssertEqual(envelopes,plan.envelopes);XCTAssertFalse(envelopes.contains(f.channelKey));XCTAssertNil(fields["channel_key"]);XCTAssertNil(fields["private_key"])
        do { try await api.inviteEncryptedChannelMembers(plan,channel:valid,users:[try user(20,key:f.publicKey,name:"Renamed"),peers[0]]);XCTFail() } catch { }
        do { try await api.inviteChannelMembers([20],channel:valid);XCTFail("Encrypted invitation fell back to empty envelopes") } catch { }
        XCTAssertEqual(EncryptedInviteProtocol.requests.count,1)
    }
}
private final class EncryptedInviteProtocol:URLProtocol {
    static var requests:[[String:String]] = []
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "encrypted-invite-fixture.invalid" else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };bytes.append(contentsOf:buffer.prefix(n)) } }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
        let fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        let object:[String:Any]
        if request.url!.lastPathComponent == "SYNO.API.Info" { object = ["success":true,"data":["SYNO.Chat.Channel.Named":["path":"entry.cgi","minVersion":1,"maxVersion":1,"requestFormat":"JSON"]]] }
        else { Self.requests.append(fields);object = ["success":true] }
        let data = try! JSONSerialization.data(withJSONObject:object)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
