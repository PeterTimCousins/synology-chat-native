import XCTest
@testable import SynologyChatNative

@MainActor final class ChatEncryptedChannelCreationTests:XCTestCase {
    private func setup() async throws -> (ChatAPIClient,ChatEncryptionKeyPair,ChatEncryptionSession,ChatEncryptedChannelCreation) {
        let pair = try ChatEncryptionManagement.generateKeyPair(password:"Synthetic password",confirmation:"Synthetic password")
        let keys = ChatEncryptionSession();try keys.unlock(pair,password:"Synthetic password")
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [EncryptedCreationProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://encrypted-creation.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        try await api.discover()
        return (api,pair,keys,try ChatEncryptedChannelCreation(owner:pair,encryption:keys))
    }
    private func canonical(_ envelope:String,changes:[String:Any] = [:]) throws -> [String:Any] {
        var value:[String:Any] = ["channel_id":123,"name":"Synthetic-private","purpose":"Synthetic purpose","type":"private","encrypted":true,"is_joined":true,"unread":0,"channel_key_enc":envelope]
        value.merge(changes,uniquingKeysWith:{ _,new in new });return value
    }
    override func tearDown() { EncryptedCreationProtocol.handler = nil;super.tearDown() }
    func testCreatorEnvelopeFreshnessOwnershipAndLockedSession() async throws {
        let (_,pair,keys,plan) = try await setup()
        let another = try ChatEncryptedChannelCreation(owner:pair,encryption:keys)
        XCTAssertNotEqual(plan.creatorEnvelope,another.creatorEnvelope)
        let publicKey = try ChatContentCrypto.decodeBase64(pair.public_key),privateKey = try ChatContentCrypto.unlockPrivateKey(pair.private_key_enc,password:"Synthetic password")
        let key = try ChatContentCrypto.unwrapChannelKey(plan.creatorEnvelope,publicKey:publicKey,privateKey:privateKey)
        XCTAssertEqual(key.count,32)
        XCTAssertNotEqual(key,try ChatContentCrypto.unwrapChannelKey(another.creatorEnvelope,publicKey:publicKey,privateKey:privateKey))
        let other = try ChatEncryptionManagement.generateKeyPair(password:"Another password",confirmation:"Another password")
        XCTAssertThrowsError(try plan.validate(owner:other,encryption:keys))
        XCTAssertThrowsError(try ChatContentCrypto.unwrapChannelKey(plan.creatorEnvelope,publicKey:ChatContentCrypto.decodeBase64(other.public_key),privateKey:ChatContentCrypto.unlockPrivateKey(other.private_key_enc,password:"Another password")))
        let rewrapped = ChatEncryptionKeyPair(public_key:pair.public_key,private_key_enc:try ChatContentCrypto.wrapPrivateKey(privateKey,password:"Rewrapped password"))
        XCTAssertThrowsError(try plan.validate(owner:rewrapped,encryption:keys))
        keys.lock();XCTAssertThrowsError(try plan.validate(owner:pair,encryption:keys))
        XCTAssertThrowsError(try ChatEncryptedChannelCreation(owner:pair,encryption:keys))
    }
    func testCreateCheckpointBeforeJoinAndExactCanonicalReadback() async throws {
        let (api,pair,keys,plan) = try await setup()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("encrypted-creation-checkpoint-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:folder) }
        let file = folder.appendingPathComponent("checkpoint.json")
        var operations:[String] = []
        EncryptedCreationProtocol.handler = { fields in
            let method = fields["method"]!;operations.append(method)
            switch method {
            case "create":
                XCTAssertEqual(fields["type"],"\"private\"");XCTAssertEqual(fields["encrypted"],"true");XCTAssertNil(fields["channel_key_enc"])
                return ["channel_id":123]
            case "join":
                let saved = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
                XCTAssertEqual(saved["channel_id"] as? Int,123);XCTAssertEqual(saved["creator_envelope"] as? String,plan.creatorEnvelope)
                XCTAssertEqual(fields["channel_key_enc"],String(data:try JSONEncoder().encode(plan.creatorEnvelope),encoding:.utf8))
                XCTAssertNil(fields["channel_key"]);XCTAssertNil(fields["private_key"])
                return [:]
            case "list": return ["channels":[try self.canonical("\r\n"+plan.creatorEnvelope)]]
            default: XCTFail("Unexpected operation");return [:]
            }
        }
        let result = try await api.createEncryptedNamedChannel(name:"  Synthetic-private  ",purpose:"Synthetic purpose",plan:plan,owner:pair,encryption:keys,onCreated:{ id,envelope in
            try JSONSerialization.data(withJSONObject:["channel_id":id,"creator_envelope":envelope]).write(to:file,options:.atomic)
        },checkContinuation:{ try Task.checkCancellation() })
        XCTAssertEqual(result.id,123);XCTAssertEqual(operations,["create","join","list"])
        XCTAssertEqual(try keys.key(for:result).count,32)
    }
    func testCheckpointFailureOrLockStopsBeforeJoinWhilePreservingKnownID() async throws {
        for lock in [false,true] {
            let (api,pair,keys,plan) = try await setup();var operations:[String] = [];var checkpoint:Int64?
            EncryptedCreationProtocol.handler = { fields in operations.append(fields["method"]!);return ["channel_id":123] }
            do {
                _ = try await api.createEncryptedNamedChannel(name:"Synthetic-private",purpose:"",plan:plan,owner:pair,encryption:keys,onCreated:{ id,_ in
                    checkpoint = id
                    if lock { keys.lock() } else { throw CocoaError(.fileWriteNoPermission) }
                },checkContinuation:{ try Task.checkCancellation() })
                XCTFail("Must stop before join")
            } catch let error as ChatChannelCreatedError { XCTAssertEqual(error.channelID,123) }
            XCTAssertEqual(checkpoint,123);XCTAssertEqual(operations,["create"])
        }
    }
    func testCancelledOrLockedPreflightCannotDispatchCreation() async throws {
        for lock in [false,true] {
            let (api,pair,keys,plan) = try await setup();var sends = 0;var checkpoint = false
            EncryptedCreationProtocol.handler = { _ in sends += 1;return ["channel_id":123] }
            do {
                _ = try await api.createEncryptedNamedChannel(name:"Synthetic-private",purpose:"",plan:plan,owner:pair,encryption:keys,onCreated:{ _,_ in checkpoint = true },checkContinuation:{
                    if lock { keys.lock() } else { throw CancellationError() }
                })
                XCTFail("Preflight retirement must prevent mutation")
            } catch { }
            XCTAssertEqual(sends,0);XCTAssertFalse(checkpoint)
        }
    }
    func testUnknownCreationNeverJoinsRetriesOrInfersByName() async throws {
        let (api,pair,keys,plan) = try await setup();var operations:[String] = [];var checkpoint = false
        EncryptedCreationProtocol.handler = { fields in operations.append(fields["method"]!);throw URLError(.networkConnectionLost) }
        do {
            _ = try await api.createEncryptedNamedChannel(name:"Synthetic-private",purpose:"",plan:plan,owner:pair,encryption:keys,onCreated:{ _,_ in checkpoint = true },checkContinuation:{})
            XCTFail()
        } catch is ChatChannelCreationUnconfirmedError { }
        XCTAssertEqual(operations,["create"]);XCTAssertFalse(checkpoint)
    }
    func testCanonicalScopeEnvelopeAndDuplicateChecksRetainCreatedID() async throws {
        for change:[String:Any] in [["type":"public"],["encrypted":false],["is_joined":false],["name":"Changed"],["purpose":"Changed"],["is_closed":true],["channel_key_enc":"invalid"],["duplicate":true]] {
            let (api,pair,keys,plan) = try await setup();var operations:[String] = []
            EncryptedCreationProtocol.handler = { fields in
                let method = fields["method"]!;operations.append(method)
                if method == "create" { return ["channel_id":123] }
                if method == "join" { return [:] }
                let channel = try self.canonical(plan.creatorEnvelope,changes:change)
                return ["channels":change["duplicate"] == nil ? [channel] : [channel,channel]]
            }
            do {
                _ = try await api.createEncryptedNamedChannel(name:"Synthetic-private",purpose:"Synthetic purpose",plan:plan,owner:pair,encryption:keys,onCreated:{ _,_ in },checkContinuation:{})
                XCTFail("Changed scope must not publish")
            } catch let error as ChatChannelCreatedError { XCTAssertEqual(error.channelID,123) }
            XCTAssertEqual(operations,["create","join","list"])
        }
    }
}
private final class EncryptedCreationProtocol:URLProtocol {
    static var handler:(([String:String]) throws -> [String:Any])?
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "encrypted-creation.invalid" else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        do {
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };bytes.append(contentsOf:buffer.prefix(n)) } }
            var parts = URLComponents();parts.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
            let fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
            let payload:[String:Any]
            if request.url!.lastPathComponent == "SYNO.API.Info" { payload = ["SYNO.Chat.Channel.Named":["path":"entry.cgi","minVersion":1,"maxVersion":1,"requestFormat":"JSON"],"SYNO.Chat.Channel":["path":"entry.cgi","minVersion":1,"maxVersion":6,"requestFormat":"JSON"]] }
            else { guard let handler = Self.handler else { throw URLError(.unsupportedURL) };payload = try handler(fields) }
            let data = try JSONSerialization.data(withJSONObject:["success":true,"data":payload])
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() { }
}
