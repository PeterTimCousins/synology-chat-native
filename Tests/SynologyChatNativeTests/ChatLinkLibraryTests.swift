import XCTest
@testable import SynologyChatNative

final class ChatLinkLibraryTests: XCTestCase {
    func post(_ id: Int, links: [[String:Any]], created: Int = 1000, updated: Int? = nil, deleted: Bool = false, encrypted: Bool = false, safe: Bool = true) throws -> ChatPost {
        var value:[String:Any] = ["post_id":id,"channel_id":93,"creator_id":10,"type":"normal","message":"Synthetic links","create_at":created,"url_props":links,"delete_at":deleted ? 100 : 0,"props":["encrypted":encrypted,"safe_url":safe]]
        if let updated { value["update_at"] = updated }
        return try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:value))
    }
    func testMultipleServerURLsExpandWithoutParsingMessageBody() throws {
        let source = try post(1,links:[["url":"https://example.test/a","title":"A"],["url":"https://example.test/b","description":"B"]])
        let entries = ChatLinkLibrary.entries([source])
        XCTAssertEqual(entries.map(\.rawURL),["https://example.test/a","https://example.test/b"])
        XCTAssertEqual(entries.map { $0.post.id },[1,1]);XCTAssertEqual(entries[1].preview.description,"B")
    }
    func testExactDuplicateKeepsFirstSourceAndNextSourceIsPromotedAfterRemoval() throws {
        let first = try post(1,links:[["url":"https://example.test/a","title":"First"]])
        let second = try post(2,links:[["url":"https://example.test/a","title":"Second"]],created:2000)
        let entries = ChatLinkLibrary.entries([first,second])
        XCTAssertEqual(entries.count,1);XCTAssertEqual(entries[0].post.id,1);XCTAssertEqual(entries[0].preview.title,"First")
        XCTAssertEqual(ChatLinkLibrary.entries([second])[0].post.id,2)
    }
    func testURLVariantsRetainDistinctExactIdentityAndOpaqueStableIDs() throws {
        let values = ["https://example.test/a","https://example.test/a#one","http://example.test/a"]
        let source = try post(1,links:values.map { ["url":$0] })
        let entries = ChatLinkLibrary.entries([source]);XCTAssertEqual(entries.count,3)
        XCTAssertEqual(Set(entries.map(\.id)).count,3);XCTAssertTrue(entries.allSatisfy { $0.id.count == 64 && !$0.id.contains("https") })
        XCTAssertEqual(entries.map(\.id),ChatLinkLibrary.entries([source]).map(\.id))
    }
    func testRepresentativeUpdateTimeSortsDescendingWithStableEqualTimes() throws {
        let old = try post(1,links:[["url":"https://example.test/a"]],created:100,updated:400)
        let new = try post(2,links:[["url":"https://example.test/b"]],created:300)
        let tied = try post(3,links:[["url":"https://example.test/c"]],created:400)
        XCTAssertEqual(ChatLinkLibrary.entries([old,new,tied]).map { $0.post.id },[1,3,2])
    }
    func testIndexedHiddenMetadataRemainsBrowsableAndUnsafeFlagIsRetained() throws {
        let source = try post(1,links:[["url":"https://example.test/a","hidden":true]],safe:false)
        let entry = try XCTUnwrap(ChatLinkLibrary.entries([source]).first)
        XCTAssertTrue(entry.preview.hidden);XCTAssertEqual(entry.post.props?.safe_url,false)
    }
    func testMalformedUnsafeSchemesAndSessionBearingDestinationsAreExcluded() throws {
        let values = ["javascript:alert(1)","file:///tmp/test","https://user:password@example.test/a","https://example.test/?_sid=synthetic","https://example.test/%0Atest"]
        let source = try post(1,links:values.map { ["url":$0] } + [["title":"Missing URL"],["url":123]])
        XCTAssertTrue(ChatLinkLibrary.entries([source]).isEmpty)
    }
    func testDeletedAndEncryptedSourcesCannotSupplyCards() throws {
        let deleted = try post(1,links:[["url":"https://example.test/a"]],deleted:true)
        let encrypted = try post(2,links:[["url":"https://example.test/b"]],encrypted:true)
        XCTAssertTrue(ChatLinkLibrary.entries([deleted,encrypted]).isEmpty)
    }
}

@MainActor final class ChatLinkLibraryPagingTests: XCTestCase {
    func testPagingAdvancesBySourcePostsInsteadOfUniqueURLs() async throws {
        let fixture = ChatLinkLibraryTests();let store = NativeConversationLibraryStore()
        let first = try (1...25).map { try fixture.post($0,links:[["url":"https://example.test/shared"]]) }
        store.load(kind:.links,query:"",channelID:93) { _,offset,_ in XCTAssertEqual(offset,0);return .init(search_results:first,total:27) }
        await store.task?.value;XCTAssertEqual(ChatLinkLibrary.entries(store.posts).count,1);XCTAssertTrue(store.hasMore)
        store.load(kind:.links,query:"",channelID:93,more:true) { _,offset,_ in
            XCTAssertEqual(offset,25)
            return .init(search_results:[try fixture.post(26,links:[["url":"https://example.test/shared"]]),try fixture.post(27,links:[["url":"https://example.test/new"]])],total:27)
        }
        await store.task?.value
        XCTAssertEqual(ChatLinkLibrary.entries(store.posts).count,2);XCTAssertEqual(store.posts.count,27);XCTAssertFalse(store.hasMore)
        XCTAssertEqual(ChatLinkLibrary.entries(store.posts)[0].post.id,1)
    }
}
