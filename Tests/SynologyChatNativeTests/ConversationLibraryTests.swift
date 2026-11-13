import XCTest
@testable import SynologyChatNative

@MainActor final class ConversationLibraryTests: XCTestCase {
    private func page(_ ids: [Int], total: Int? = nil, channel: Int = 93, type: String = "file", deleted: Bool = false) throws -> ChatSearchPage {
        var object: [String:Any] = ["search_results":ids.map { ["post_id":$0,"channel_id":channel,"creator_id":10,"message":"Synthetic library entry","type":type,"create_at":1000,"delete_at":deleted ? 1001 : 0,"url_props":[["url":"https://fixture.invalid/\($0)"]]] }]
        if let total { object["total"] = total }
        return try JSONDecoder().decode(ChatSearchPage.self,from:JSONSerialization.data(withJSONObject:object))
    }
    func testPaginationUsesServerOffsetAndKeepsOrderWithoutDuplicates() async throws {
        let store = NativeConversationLibraryStore()
        store.load(kind:.files,query:"  synthetic  ",channelID:93) { text,offset,filters in
            XCTAssertEqual(text,"synthetic"); XCTAssertEqual(offset,0);XCTAssertEqual(filters.content,.file)
            return try self.page(Array(1...25),total:27)
        }
        await store.task?.value
        XCTAssertEqual(store.posts.count,25);XCTAssertTrue(store.hasMore)
        store.load(kind:.files,query:"synthetic",channelID:93,more:true) { _,offset,_ in
            XCTAssertEqual(offset,25)
            return try self.page([25,26],total:27)
        }
        await store.task?.value
        XCTAssertEqual(store.posts.map(\.id),Array(1...26).map(Int64.init));XCTAssertFalse(store.hasMore)
    }
    func testReplacingQueryCannotPublishLateResponseEvenIfLoaderIgnoresCancellation() async throws {
        let store = NativeConversationLibraryStore()
        var pending: CheckedContinuation<ChatSearchPage,Error>?
        store.load(kind:.files,query:"old",channelID:93) { _,_,_ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        let old = store.task
        while pending == nil { await Task.yield() }
        store.load(kind:.links,query:"new",channelID:93) { _,offset,filters in
            XCTAssertEqual(offset,0);XCTAssertEqual(filters.attribute,.url);XCTAssertEqual(filters.content,.any)
            return try self.page([77],type:"normal")
        }
        await store.task?.value
        pending?.resume(returning:try page([1])); await old?.value
        XCTAssertEqual(store.posts.map(\.id),[77]);XCTAssertNil(store.failure)
        store.clear();XCTAssertTrue(store.posts.isEmpty);XCTAssertFalse(store.searched)
    }
    func testForeignDeletedAndWrongTypeResultsAreExcludedAndFailureCanRetry() async throws {
        let store = NativeConversationLibraryStore()
        for page in [try page([1],channel:94),try page([2],type:"normal"),try page([3],deleted:true)] {
            store.load(kind:.files,query:"",channelID:93) { _,_,_ in page }; await store.task?.value
            XCTAssertTrue(store.posts.isEmpty)
        }
        store.load(kind:.files,query:"",channelID:93) { _,_,_ in throw ChatAPIError.connection }
        await store.task?.value;XCTAssertNotNil(store.failure);XCTAssertFalse(store.loading)
        store.load(kind:.files,query:"",channelID:93) { _,_,_ in try self.page([4]) }
        await store.task?.value;XCTAssertNil(store.failure);XCTAssertEqual(store.posts.map(\.id),[4])
    }
    func testSavedAndPinnedGalleryPagesKeepExactCollectionFiltersAndInvalidateOnReplacement() async throws {
        for kind in [NativeConversationLibraryStore.Kind.bookmarks,.pins] {
            let store = NativeConversationLibraryStore()
            var offsets:[Int] = []
            store.load(kind:kind,query:"fixture",channelID:kind == .pins ? 93 : nil,accountGeneration:7) { text,offset,filters in
                XCTAssertEqual(text,"fixture");XCTAssertEqual(filters.attribute,kind == .pins ? .pin : .star)
                offsets.append(offset)
                let ids = offset == 0 ? Array(1...25) : [26,27]
                let rows = ids.map { id -> [String:Any] in
                    ["post_id":id,"channel_id":93,"creator_id":10,"message":"Synthetic collection entry","type":id == 27 ? "file" : "normal","create_at":1000,"is_star":true,"star_at":id,"last_pin_at":id,"file_props":["name":"Synthetic.png","is_image":id == 27,"size":100]]
                }
                return try JSONDecoder().decode(ChatSearchPage.self,from:JSONSerialization.data(withJSONObject:["search_results":rows,"total":27]))
            }
            await store.task?.value
            let load = try XCTUnwrap(store.imageGalleryLoader())
            let page = try await load()
            XCTAssertEqual(offsets,[0,25]);XCTAssertEqual(page.cursor,27);XCTAssertFalse(page.hasMore)
            XCTAssertEqual(page.posts.count,27)
            XCTAssertEqual(page.posts.filter { $0.file_props?.is_image == true }.map(\.id),[27])
            store.clear()
            do { _ = try await load();XCTFail("An old gallery must not page a replacement collection") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }
}
