import XCTest
@testable import SynologyChatNative

@MainActor final class ChatGuestAuthenticationTests: XCTestCase {
    private let address = "https://guest-auth.synthetic.invalid"
    private let discovery = #"{"success":true,"data":{"SYNO.API.Auth":{"path":"auth.cgi","minVersion":1,"maxVersion":7},"SYNO.Chat.User":{"path":"entry.cgi","minVersion":1,"maxVersion":2},"SYNO.Chat.Channel":{"path":"entry.cgi","minVersion":1,"maxVersion":5},"SYNO.Chat.Misc":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}"#
    private let success = #"{"success":true,"data":{"sid":"guest-synthetic-sid","synotoken":"guest-synthetic-token"}}"#
    private func network() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GuestAuthenticationURLProtocol.self]
        config.urlCache = nil
        return URLSession(configuration:config)
    }
    override func tearDown() { GuestAuthenticationURLProtocol.handler = nil;super.tearDown() }

    func testGuestLoginUsesSameAuthRouteWithCanonicalAccountAndNoGuestCreation() async throws {
        var requests:[(URLRequest,[String:String])] = []
        GuestAuthenticationURLProtocol.handler = { request,fields in
            requests.append((request,fields))
            return fields["api"] == "SYNO.API.Info" ? self.discovery : self.success
        }
        let account = try await ChatAuthentication(network:network()).signIn(address:address,username:"guest@example.test",password:"synthetic-password",otp:"",asGuest:true)
        XCTAssertEqual(account.username,"guest_guest@example.test")
        XCTAssertEqual(requests.count,2)
        let login = try XCTUnwrap(requests.last)
        XCTAssertEqual(login.0.url?.path,"/webapi/auth.cgi/SYNO.API.Auth")
        XCTAssertEqual(login.1["api"],"SYNO.API.Auth");XCTAssertEqual(login.1["method"],"login")
        XCTAssertEqual(login.1["version"],"6");XCTAssertEqual(login.1["session"],"chat")
        XCTAssertEqual(login.1["account"],"guest_guest@example.test");XCTAssertEqual(login.1["passwd"],"synthetic-password")
        XCTAssertNil(login.1["otp_code"]);XCTAssertEqual(login.1["enable_syno_token"],"yes")
        XCTAssertFalse(login.0.url!.absoluteString.contains("synthetic-password"))
        XCTAssertFalse(requests.contains { $0.1["method"] == "register" || $0.1["method"] == "resend_email" })
    }
    func testPrefixIsIdempotentForGuestButOrdinaryUsernamesStayExact() async throws {
        for (username,guest,expected) in [("person@example.test",true,"guest_person@example.test"),("guest_person@example.test",true,"guest_person@example.test"),("GUEST_person@example.test",true,"guest_person@example.test"),("Guest Person",false,"Guest Person"),("guest_person",false,"guest_person")] {
            var sent:String?
            GuestAuthenticationURLProtocol.handler = { _,fields in
                if fields["api"] == "SYNO.API.Info" { return self.discovery }
                sent = fields["account"];return self.success
            }
            let account = try await ChatAuthentication(network:network()).signIn(address:address,username:username,password:"synthetic",otp:"",asGuest:guest)
            XCTAssertEqual(sent,expected);XCTAssertEqual(account.username,expected)
        }
    }
    func testGuestOTPChallengeRequiresExplicitRetryAndRetainsCanonicalIdentity() async throws {
        var logins:[[String:String]] = []
        GuestAuthenticationURLProtocol.handler = { _,fields in
            if fields["api"] == "SYNO.API.Info" { return self.discovery }
            logins.append(fields)
            return logins.count == 1 ? #"{"success":false,"error":{"code":403}}"# : self.success
        }
        let auth = ChatAuthentication(network:network())
        do {
            _ = try await auth.signIn(address:address,username:"person@example.test",password:"synthetic",otp:"",asGuest:true)
            XCTFail("Expected verification challenge")
        } catch ChatSignInError.otpRequired { }
        XCTAssertEqual(logins.count,1);XCTAssertNil(logins.first?["otp_code"])
        let identity = ChatSignInIdentity(address:address,username:"person@example.test",asGuest:true)
        let code = ChatSignInChallenge(identity:identity).verificationCode("123456",for:identity)
        let account = try await auth.signIn(address:address,username:identity.username,password:"synthetic",otp:code,asGuest:true)
        XCTAssertEqual(logins.count,2);XCTAssertEqual(logins.last?["otp_code"],"123456")
        XCTAssertEqual(logins.last?["account"],"guest_person@example.test");XCTAssertEqual(account.username,"guest_person@example.test")
    }
    func testPendingCodeCannotCrossServerUsernameOrLoginMode() {
        let original = ChatSignInIdentity(address:address,username:"person@example.test",asGuest:true)
        let challenge = ChatSignInChallenge(identity:original)
        XCTAssertEqual(challenge.verificationCode("123456",for:original),"123456")
        for changed in [ChatSignInIdentity(address:"https://another.synthetic.invalid",username:original.username,asGuest:true),ChatSignInIdentity(address:address,username:"other@example.test",asGuest:true),ChatSignInIdentity(address:address,username:original.username,asGuest:false)] {
            XCTAssertEqual(challenge.verificationCode("123456",for:changed),"")
        }
    }
    func testSavedGuestIdentityRoundtripMatchesDirectoryAndAccountScope() async throws {
        GuestAuthenticationURLProtocol.handler = { _,fields in
            switch fields["api"] {
            case "SYNO.API.Info":return self.discovery
            case "SYNO.API.Auth":return self.success
            case "SYNO.Chat.User":return #"{"success":true,"data":{"users":[{"user_id":42,"username":"guest_person@example.test","nickname":"Guest Example","type":"human","human_type":"guest"}]}}"#
            case "SYNO.Chat.Channel":return #"{"success":true,"data":{"channels":[{"channel_id":23,"name":"Guest channel","type":"private","encrypted":false,"unread":0}]}}"#
            case "SYNO.Chat.Misc":return #"{"success":true,"data":{"acls":[]}}"#
            default:return #"{"success":false,"error":{"code":404}}"#
            }
        }
        let account = try await ChatAuthentication(network:network()).signIn(address:address,username:"person@example.test",password:"synthetic-password",otp:"123456",asGuest:true)
        let bytes = try JSONEncoder().encode(account),restored = try JSONDecoder().decode(ChatAccount.self,from:bytes)
        XCTAssertEqual(restored.username,"guest_person@example.test")
        XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("synthetic-password"))
        XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("123456"))
        XCTAssertEqual(ChatNotificationAccountScope.make(account:account,userID:42),ChatNotificationAccountScope.make(account:restored,userID:42))
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in try ChatAPIClient(session:session,network:self.network()) })
        defer { model.signOutLocally() }
        await model.connect(using:restored)
        XCTAssertTrue(model.connected);XCTAssertEqual(model.userID,42)
        XCTAssertEqual(model.directory.first?.human_type,"guest")
        XCTAssertEqual(model.directory.first?.username,restored.username)
        XCTAssertFalse(model.canChooseNASFiles());XCTAssertFalse(model.canChooseDriveFiles())
    }
    func testGuestInvalidOTPDoesNotFallBackToOrdinaryLogin() async throws {
        var accounts:[String] = []
        GuestAuthenticationURLProtocol.handler = { _,fields in
            if fields["api"] == "SYNO.API.Info" { return self.discovery }
            accounts.append(fields["account"] ?? "");return #"{"success":false,"error":{"code":404}}"#
        }
        do {
            _ = try await ChatAuthentication(network:network()).signIn(address:address,username:"person@example.test",password:"synthetic",otp:"123456",asGuest:true)
            XCTFail("Expected rejected verification code")
        } catch ChatSignInError.otpInvalid { }
        XCTAssertEqual(accounts,["guest_person@example.test"])
    }
}

private final class GuestAuthenticationURLProtocol:URLProtocol {
    static var handler:((URLRequest,[String:String])->String)?
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "guest-auth.synthetic.invalid",let handler = Self.handler else {
            client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return
        }
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty,let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count);if count <= 0 { break };bytes.append(contentsOf:buffer.prefix(count)) }
        }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
        let fields = Dictionary((parts.queryItems ?? []).map{($0.name,$0.value ?? "")},uniquingKeysWith:{ first,_ in first })
        let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(handler(request,fields).utf8));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
