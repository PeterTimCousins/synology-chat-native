import Foundation
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatThreadWindowAPITests:XCTestCase {
    private func row(_ id:Int64,channel:Int64 = 93,thread:Int64? = 9,type:String = "normal")->[String:Any] {
        var value:[String:Any] = ["post_id":id,"channel_id":channel,"creator_id":10,"type":type,"message":"Synthetic thread window","create_at":1000]
        if let thread { value["thread_id"] = thread }
        if type == "file" { value["file_props"] = ["name":"Synthetic.txt","size":1,"is_image":false] }
        return value
    }
    private func page(_ rows:[[String:Any]]) throws -> Data { try JSONSerialization.data(withJSONObject:["success":true,"data":["posts":rows]]) }
    private func api() async throws -> ChatAPIClient {
        ThreadWindowProtocol.reset()
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ThreadWindowProtocol.self]
        config.httpShouldSetCookies = false;config.urlCache = nil
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://thread-window.synthetic.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        try await api.discover()
        return api
    }
    func testDirectionalRequestsMatchFiniteLiveContractAndDoNotFilterFileReplies() async throws {
        let api = try await api()
        let cases:[(Int,Int,[Int64])] = [(2,2,[99,100,101,102]),(2,0,[99,100]),(0,2,[100,101,102]),(0,0,[100])]
        for (previous,next,ids) in cases {
            ThreadWindowProtocol.response = try page(ids.reversed().map { row($0,type:$0 == 100 ? "file" : "normal") })
            let values = try await api.threadWindow(channelID:93,rootID:9,postID:100,previous:previous,next:next)
            XCTAssertEqual(values.map(\.id),ids);XCTAssertEqual(values.first(where:{ $0.id == 100 })?.type,"file")
            let request = try XCTUnwrap(ThreadWindowProtocol.requests.last)
            XCTAssertEqual(request["api"],"SYNO.Chat.Post");XCTAssertEqual(request["method"],"list");XCTAssertEqual(request["version"],"5")
            XCTAssertEqual(request["channel_id"],"93");XCTAssertEqual(request["thread_id"],"9");XCTAssertEqual(request["post_id"],"100")
            XCTAssertEqual(request["prev_count"],String(previous));XCTAssertEqual(request["next_count"],String(next));XCTAssertNil(request["file_type"])
        }
        XCTAssertEqual(ThreadWindowProtocol.requests.count,4);XCTAssertEqual(ThreadWindowProtocol.unexpected,0)
    }
    func testValidatedOptionalRootIsFilteredAndAbsentDeletedAnchorDoesNotTriggerFallbackRead() async throws {
        let api = try await api()
        let rootThreadIDs:[Int64?] = [nil,0,9]
        for thread in rootThreadIDs {
            ThreadWindowProtocol.response = try page([row(101),row(9,thread:thread),row(99)])
            let values = try await api.threadWindow(channelID:93,rootID:9,postID:100,previous:1,next:1)
            XCTAssertEqual(values.map(\.id),[99,101])
        }
        ThreadWindowProtocol.response = try page([])
        let empty = try await api.threadWindow(channelID:93,rootID:9,postID:100,previous:0,next:0)
        XCTAssertTrue(empty.isEmpty)
        ThreadWindowProtocol.response = try page([row(9,thread:nil),row(100)])
        let exact = try await api.threadWindow(channelID:93,rootID:9,postID:100,previous:0,next:0)
        XCTAssertEqual(exact.map(\.id),[100])
        XCTAssertEqual(ThreadWindowProtocol.requests.count,5,"A missing anchor must not trigger Post/get or an unbounded second read")
        XCTAssertEqual(ThreadWindowProtocol.unexpected,0)
    }
    func testInvalidInputIsRejectedBeforeAnyThreadRequest() async throws {
        let api = try await api()
        let invalid:[(Int64,Int64,Int64,Int,Int)] = [(0,9,100,1,1),(93,0,100,1,1),(93,9,0,1,1),(-1,9,100,1,1),(93,-1,100,1,1),(93,9,-1,1,1),(93,9,100,-1,1),(93,9,100,1,-1),(93,9,100,31,0),(93,9,100,0,31),(93,9,100,Int.max,Int.max)]
        for (channel,root,post,previous,next) in invalid {
            do { _ = try await api.threadWindow(channelID:channel,rootID:root,postID:post,previous:previous,next:next);XCTFail("Accepted invalid thread window") }
            catch let error as ChatAPIError { if case .invalidResponse = error {} else { XCTFail("Wrong error: \(error)") } }
        }
        XCTAssertTrue(ThreadWindowProtocol.requests.isEmpty);XCTAssertEqual(ThreadWindowProtocol.unexpected,0)
    }
    func testWrongMembershipDuplicateAndNonpositiveRowsFailClosed() async throws {
        let api = try await api()
        let invalid:[[[String:Any]]] = [[row(100),row(100)],[row(0)],[row(-1)],[row(100,channel:94)],[row(100,thread:10)],[row(100,thread:nil)],[row(100,thread:0)],[row(9,thread:10),row(100)],[row(9,channel:94,thread:nil),row(100)],[row(9,thread:nil),row(9,thread:nil),row(100)]]
        for rows in invalid {
            ThreadWindowProtocol.response = try page(rows)
            do { _ = try await api.threadWindow(channelID:93,rootID:9,postID:100,previous:2,next:2);XCTFail("Accepted invalid membership") }
            catch let error as ChatAPIError { if case .invalidResponse = error {} else { XCTFail("Wrong error: \(error)") } }
        }
        XCTAssertEqual(ThreadWindowProtocol.requests.count,invalid.count);XCTAssertEqual(ThreadWindowProtocol.unexpected,0)
    }
    func testPerSideBoundsAreEnforcedEvenWhenTotalWindowFits() async throws {
        let api = try await api()
        let invalid:[(Int,Int,[Int64])] = [(0,2,[99,100]),(2,0,[100,101]),(2,2,[97,98,99,100]),(0,0,[100,101]),(2,2,[97,98,99,100,101,102,103])]
        for (previous,next,ids) in invalid {
            ThreadWindowProtocol.response = try page(ids.map { row($0) })
            do { _ = try await api.threadWindow(channelID:93,rootID:9,postID:100,previous:previous,next:next);XCTFail("Accepted oversized/directionally invalid window") }
            catch let error as ChatAPIError { if case .invalidResponse = error {} else { XCTFail("Wrong error: \(error)") } }
        }
    }
    func testDefaultMaximumWindowAllowsOneRootEchoAndRejectsOneExtraReply() async throws {
        let api = try await api()
        let ids = Array(Int64(70)...130)
        ThreadWindowProtocol.response = try page([row(9,thread:9)]+ids.map { row($0) })
        let values = try await api.threadWindow(channelID:93,rootID:9,postID:100)
        XCTAssertEqual(values.map(\.id),ids)
        XCTAssertEqual(ThreadWindowProtocol.requests.last?["prev_count"],"30");XCTAssertEqual(ThreadWindowProtocol.requests.last?["next_count"],"30")
        ThreadWindowProtocol.response = try page([row(9,thread:0)]+(ids+[131]).map { row($0) })
        do { _ = try await api.threadWindow(channelID:93,rootID:9,postID:100);XCTFail("Accepted more than the finite window") }
        catch let error as ChatAPIError { if case .invalidResponse = error {} else { XCTFail("Wrong error: \(error)") } }
    }
    func testServerFailureAndMalformedListRemainErrors() async throws {
        let api = try await api()
        for bytes in [Data(#"{"success":false,"error":{"code":105}}"#.utf8),Data(#"{"success":true,"data":{"posts":"invalid"}}"#.utf8)] {
            ThreadWindowProtocol.response = bytes
            do { _ = try await api.threadWindow(channelID:93,rootID:9,postID:100);XCTFail("Accepted invalid server response") } catch {}
        }
        XCTAssertEqual(ThreadWindowProtocol.requests.count,2);XCTAssertEqual(ThreadWindowProtocol.unexpected,0)
    }
}

private final class ThreadWindowProtocol:URLProtocol {
    @MainActor static var response = Data(#"{"success":true,"data":{"posts":[]}}"#.utf8)
    @MainActor static var requests:[[String:String]] = []
    @MainActor static var unexpected = 0
    @MainActor static func reset() { response = Data(#"{"success":true,"data":{"posts":[]}}"#.utf8);requests = [];unexpected = 0 }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty,let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048)
            while stream.hasBytesAvailable,body.count < 16384 {
                let count = stream.read(&buffer,maxLength:min(buffer.count,16384-body.count));if count <= 0 { break };body.append(contentsOf:buffer.prefix(count))
            }
        }
        var components = URLComponents();components.percentEncodedQuery = String(decoding:body,as:UTF8.self)
        let fields = Dictionary((components.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last }),bounded = body.count < 16384
        Task { @MainActor in self.route(fields:fields,bounded:bounded) }
    }
    @MainActor private func route(fields:[String:String],bounded:Bool) {
        guard bounded,request.url?.scheme == "https",request.url?.host == "thread-window.synthetic.invalid" else { reject();return }
        let bytes:Data
        if request.url?.path == "/webapi/query.cgi/SYNO.API.Info",fields["api"] == "SYNO.API.Info",fields["method"] == "query" {
            bytes = Data(#"{"success":true,"data":{"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"}}}"#.utf8)
        } else if request.url?.path == "/webapi/entry.cgi/SYNO.Chat.Post",fields["api"] == "SYNO.Chat.Post",fields["method"] == "list",fields["version"] == "5" {
            Self.requests.append(fields);bytes = Self.response
        } else { reject();return }
        guard let url = request.url,let response = HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"]) else { reject();return }
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:bytes);client?.urlProtocolDidFinishLoading(self)
    }
    @MainActor private func reject() { Self.unexpected += 1;client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL)) }
    override func stopLoading() {}
}
