import Foundation
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatMainHistoryRefreshTests:XCTestCase {
    private func row(_ id:Int64,channel:Int64 = 93,thread:Int64? = nil)->[String:Any] {
        var value:[String:Any] = ["post_id":id,"channel_id":channel,"creator_id":10,"type":"normal","message":"Synthetic refresh history","create_at":1000]
        if let thread { value["thread_id"] = thread };return value
    }
    private func page(_ rows:[[String:Any]]) throws -> Data { try JSONSerialization.data(withJSONObject:["success":true,"data":["posts":rows]]) }
    private func api(pages:[[[String:Any]]]) async throws -> ChatAPIClient {
        MainRefreshProtocol.reset(pages:try pages.map(page))
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [MainRefreshProtocol.self]
        config.httpShouldSetCookies = false;config.urlCache = nil
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://main-refresh.synthetic.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        try await api.discover();return api
    }
    private func assertFields(_ fields:[String:String],anchor:Int64?,previous:Int,next:Int,file:StaticString = #filePath,line:UInt = #line) {
        XCTAssertEqual(fields["api"],"SYNO.Chat.Post",file:file,line:line);XCTAssertEqual(fields["method"],"list",file:file,line:line)
        XCTAssertEqual(fields["version"],"5",file:file,line:line);XCTAssertEqual(fields["channel_id"],"93",file:file,line:line)
        XCTAssertEqual(fields["prev_count"],String(previous),file:file,line:line);XCTAssertEqual(fields["next_count"],String(next),file:file,line:line)
        XCTAssertEqual(fields["post_id"],anchor.map(String.init),file:file,line:line)
        XCTAssertNil(fields["thread_id"],file:file,line:line);XCTAssertNil(fields["file_type"],file:file,line:line)
        XCTAssertEqual(Set(fields.keys),Set(["api","method","version","channel_id","prev_count","next_count"]+(anchor == nil ? [] : ["post_id"])),file:file,line:line)
    }
    func testRawDeletedAnchorContextNeverSynthesizesAnchorAndPreservesMainReplyRecords() async throws {
        let api = try await api(pages:[[row(101),row(99,thread:9)]])
        let windows = try await api.mainHistoryRefresh(channelID:93,anchorID:100,context:true,cachedLatest:90)
        XCTAssertEqual(windows.count,1);let window = try XCTUnwrap(windows.first)
        XCTAssertEqual(window.posts.map(\.id),[99,101]);XCTAssertEqual(window.posts.first?.thread_id,9)
        XCTAssertFalse(window.latest);XCTAssertFalse(window.complete)
        XCTAssertEqual(MainRefreshProtocol.requests.count,1,"Deleted anchor must not trigger synthesized Post/get or exact read")
        assertFields(try XCTUnwrap(MainRefreshProtocol.requests.first),anchor:100,previous:15,next:15)
        XCTAssertEqual(MainRefreshProtocol.unexpected,0)
    }
    func testAwayReadReturnsAnchorThenOneShortCompleteLatestWindow() async throws {
        let api = try await api(pages:[[row(101),row(99),row(100)],[row(152),row(150),row(151)]])
        let windows = try await api.mainHistoryRefresh(channelID:93,anchorID:100,context:false,cachedLatest:80)
        XCTAssertEqual(windows.count,2);XCTAssertEqual(windows[0].posts.map(\.id),[99,100,101])
        XCTAssertFalse(windows[0].latest);XCTAssertFalse(windows[0].complete)
        XCTAssertEqual(windows[1].posts.map(\.id),[150,151,152]);XCTAssertTrue(windows[1].latest);XCTAssertTrue(windows[1].complete)
        assertFields(MainRefreshProtocol.requests[0],anchor:100,previous:15,next:15)
        assertFields(MainRefreshProtocol.requests[1],anchor:nil,previous:30,next:0)
        XCTAssertEqual(MainRefreshProtocol.requests.count,2)
    }
    func testContextWithoutAnchorReadsOnlyRawLatestAndEmptyIsComplete() async throws {
        let api = try await api(pages:[[]])
        let windows = try await api.mainHistoryRefresh(channelID:93,anchorID:nil,context:true,cachedLatest:nil)
        XCTAssertEqual(windows.count,1);XCTAssertTrue(windows[0].posts.isEmpty);XCTAssertTrue(windows[0].latest);XCTAssertTrue(windows[0].complete)
        assertFields(try XCTUnwrap(MainRefreshProtocol.requests.first),anchor:nil,previous:30,next:0)
    }
    func testGapOverThirtyIsBridgedAndReturnedAsOneAtomicRecentWindow() async throws {
        var pages = [(201...230).map { row(Int64($0)) }]
        for cursor in [201,172,143,114] { pages.append(((cursor-29)...cursor).reversed().map { row(Int64($0)) }) }
        let api = try await api(pages:pages)
        let windows = try await api.mainHistoryRefresh(channelID:93,anchorID:nil,context:false,cachedLatest:100)
        XCTAssertEqual(windows.count,1);XCTAssertEqual(windows[0].posts.map(\.id),Array(Int64(85)...230))
        XCTAssertTrue(windows[0].latest);XCTAssertFalse(windows[0].complete)
        XCTAssertEqual(MainRefreshProtocol.requests.count,5)
        assertFields(MainRefreshProtocol.requests[0],anchor:nil,previous:30,next:0)
        for (index,cursor) in [Int64(201),172,143,114].enumerated() { assertFields(MainRefreshProtocol.requests[index+1],anchor:cursor,previous:30,next:0) }
        XCTAssertEqual(MainRefreshProtocol.unexpected,0)
    }
    func testShortBridgeCompletesAggregatedHistoryWithoutDroppingNewTail() async throws {
        let api = try await api(pages:[(201...230).map { row(Int64($0)) },(172...201).map { row(Int64($0)) },(150...171).map { row(Int64($0)) }])
        let windows = try await api.mainHistoryRefresh(channelID:93,anchorID:nil,context:false,cachedLatest:1)
        XCTAssertEqual(windows.count,1);XCTAssertTrue(windows[0].complete);XCTAssertTrue(windows[0].latest)
        XCTAssertEqual(windows[0].posts.map(\.id),Array(Int64(150)...230))
        XCTAssertEqual(MainRefreshProtocol.requests.count,3)
    }
    func testInclusiveThirtyOneBridgeAndFullLatestWithoutCacheRemainBounded() async throws {
        let api = try await api(pages:[(131...160).map { row(Int64($0)) },(101...131).map { row(Int64($0)) }])
        let bridged = try await api.mainHistoryRefresh(channelID:93,anchorID:nil,context:false,cachedLatest:101)
        XCTAssertEqual(bridged[0].posts.map(\.id),Array(Int64(101)...160));XCTAssertFalse(bridged[0].complete)
        XCTAssertEqual(MainRefreshProtocol.requests.count,2)
        let second = try await self.api(pages:[(131...160).map { row(Int64($0)) }])
        let latest = try await second.mainHistoryRefresh(channelID:93,anchorID:nil,context:false,cachedLatest:nil)
        XCTAssertEqual(latest.count,1);XCTAssertFalse(latest[0].complete);XCTAssertEqual(MainRefreshProtocol.requests.count,1)
    }
    func testInvalidInputsRejectBeforeReadAndMalformedContextFailsClosed() async throws {
        let api = try await api(pages:[])
        let invalidInputs:[(Int64,Int64?,Int64?)] = [(0,nil,nil),(93,0,nil),(93,-1,nil),(93,nil,0),(93,nil,-1)]
        for (channel,anchor,cached) in invalidInputs {
            do { _ = try await api.mainHistoryRefresh(channelID:channel,anchorID:anchor,context:true,cachedLatest:cached);XCTFail("Invalid input accepted") } catch {}
        }
        XCTAssertTrue(MainRefreshProtocol.requests.isEmpty);XCTAssertEqual(MainRefreshProtocol.unexpected,0)
        let invalid:[[[String:Any]]] = [[row(100),row(100)],[row(0)],[row(-1)],[row(100,channel:94)],(80...96).map { row(Int64($0)) },(101...116).map { row(Int64($0)) },(84...115).map { row(Int64($0)) }]
        for rows in invalid {
            let client = try await self.api(pages:[rows])
            do { _ = try await client.mainHistoryRefresh(channelID:93,anchorID:100,context:true,cachedLatest:nil);XCTFail("Malformed context accepted") } catch {}
            XCTAssertEqual(MainRefreshProtocol.requests.count,1);XCTAssertEqual(MainRefreshProtocol.unexpected,0)
        }
    }
    func testInvalidLatestAndBridgeNeverExposePartialAnchoredOrRecentResults() async throws {
        let invalidLatest:[[[String:Any]]] = [[row(1),row(1)],[row(1,channel:94)],[row(0)],(1...31).map { row(Int64($0)) }]
        for rows in invalidLatest {
            let api = try await api(pages:[rows])
            do { _ = try await api.mainHistoryRefresh(channelID:93,anchorID:nil,context:false,cachedLatest:1);XCTFail("Malformed latest accepted") } catch {}
        }
        let invalidBridge:[[[String:Any]]] = [[row(200),row(200)],[row(200,channel:94)],[row(0)],[row(202)],(201...230).map { row(Int64($0)) },(170...200).map { row(Int64($0)) }]
        for rows in invalidBridge {
            let api = try await api(pages:[[row(50)],(201...230).map { row(Int64($0)) },rows])
            var returned:[ChatMainHistoryRefreshWindow]?
            do { returned = try await api.mainHistoryRefresh(channelID:93,anchorID:50,context:false,cachedLatest:1);XCTFail("Malformed bridge accepted") } catch {}
            XCTAssertNil(returned,"An earlier valid anchor/latest window must not escape when bridge validation fails")
            XCTAssertEqual(MainRefreshProtocol.requests.count,3);XCTAssertEqual(MainRefreshProtocol.unexpected,0)
        }
    }
    func testCancellationAfterResponseDeliveryCannotPublishOrStartBridge() async throws {
        let api = try await api(pages:[(201...230).map { row(Int64($0)) }])
        var operation:Task<[ChatMainHistoryRefreshWindow],Error>?
        MainRefreshProtocol.afterResponse = { operation?.cancel() }
        let task = Task { try await api.mainHistoryRefresh(channelID:93,anchorID:nil,context:false,cachedLatest:1) }
        operation = task
        do { _ = try await task.value;XCTFail("Cancelled response must not publish or continue") } catch {}
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(MainRefreshProtocol.requests.count,1)
        XCTAssertEqual(MainRefreshProtocol.unexpected,0,"A cancelled successful transport must not initiate the next page")
        MainRefreshProtocol.afterResponse = nil
    }
    func testTenBridgeReadCapThrowsBeforeAdditionalRequestOrPartialReturn() async throws {
        var pages = [(1001...1030).map { row(Int64($0)) }]
        for index in 0..<10 { let cursor = 1001-index*29;pages.append(((cursor-29)...cursor).map { row(Int64($0)) }) }
        let api = try await api(pages:pages)
        do { _ = try await api.mainHistoryRefresh(channelID:93,anchorID:nil,context:false,cachedLatest:1);XCTFail("Gap beyond cap accepted") }
        catch let error as ChatAPIError { if case .invalidResponse = error {} else { XCTFail("Wrong cap error: \(error)") } }
        XCTAssertEqual(MainRefreshProtocol.requests.count,11,"Initial latest plus exactly ten bridge reads")
        XCTAssertEqual(MainRefreshProtocol.unexpected,0,"Cap must fail before an eleventh bridge request")
    }
}

private final class MainRefreshProtocol:URLProtocol {
    @MainActor private static var pages:[Data] = []
    @MainActor static var requests:[[String:String]] = []
    @MainActor static var unexpected = 0
    @MainActor static var afterResponse:(()->Void)?
    @MainActor static func reset(pages:[Data]) { self.pages = pages;requests = [];unexpected = 0;afterResponse = nil }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty,let stream = request.httpBodyStream {
            stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048)
            while stream.hasBytesAvailable,body.count < 16384 { let count = stream.read(&buffer,maxLength:min(buffer.count,16384-body.count));if count <= 0 { break };body.append(contentsOf:buffer.prefix(count)) }
        }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:body,as:UTF8.self)
        let fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last }),bounded = body.count < 16384
        Task { @MainActor in self.route(fields:fields,bounded:bounded) }
    }
    @MainActor private func route(fields:[String:String],bounded:Bool) {
        guard bounded,request.url?.scheme == "https",request.url?.host == "main-refresh.synthetic.invalid" else { reject();return }
        let bytes:Data
        if request.url?.path == "/webapi/query.cgi/SYNO.API.Info",fields["api"] == "SYNO.API.Info",fields["method"] == "query" {
            bytes = Data(#"{"success":true,"data":{"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"}}}"#.utf8)
        } else if request.url?.path == "/webapi/entry.cgi/SYNO.Chat.Post",fields["api"] == "SYNO.Chat.Post",fields["method"] == "list",fields["version"] == "5",!Self.pages.isEmpty {
            Self.requests.append(fields);bytes = Self.pages.removeFirst()
        } else { reject();return }
        guard let url = request.url,let response = HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"]) else { reject();return }
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:bytes);client?.urlProtocolDidFinishLoading(self)
        if fields["api"] == "SYNO.Chat.Post" { Self.afterResponse?() }
    }
    @MainActor private func reject() { Self.unexpected += 1;client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL)) }
    override func stopLoading() {}
}
