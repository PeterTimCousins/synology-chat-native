import XCTest
@testable import SynologyChatNative

@MainActor final class CollectionReconciliationTests: XCTestCase {
    private func post(_ id:Int, name:String = "Synthetic", type:String = "file", starred:Bool = true, pinned:Bool = true, url:String = "https://example.test/shared") throws -> ChatPost {
        try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:["post_id":id,"channel_id":93,"creator_id":10,"message":name,"type":type,"create_at":id,"is_star":starred,"last_pin_at":pinned ? 1000 : 0,"last_comment_at":0,"file_props":["name":name,"is_image":true],"url_props":[["url":url]]]))
    }
    private func change(_ post:ChatPost,account:Int = 7) -> ChatCollectionChange { .init(accountGeneration:account,channelID:post.channel_id,postID:post.id,state:.updated(post)) }
    func testDeletionRebasesTwoLoadedPagesWithoutSkippingAndRejectsOldPage() async throws {
        let store = NativeConversationLibraryStore();var server = try (1...31).map { try post($0) }
        var holdMore = true;var resume:CheckedContinuation<ChatSearchPage,Never>?
        let loader:NativeConversationLibraryStore.Loader = { _,offset,_ in
            if offset == 25 && holdMore { holdMore = false;return await withCheckedContinuation { resume = $0 } }
            return .init(search_results:Array(server.dropFirst(offset).prefix(25)),total:server.count)
        }
        store.load(kind:.files,query:"",channelID:93,accountGeneration:7,using:loader);await store.task?.value
        store.load(kind:.files,query:"",channelID:93,more:true,accountGeneration:7,using:loader)
        while resume == nil { await Task.yield() };let old = store.task
        server.removeAll { $0.id == 5 };store.receive(.init(accountGeneration:7,channelID:93,postID:5,state:.deleted))
        XCTAssertFalse(store.posts.contains { $0.id == 5 })
        await store.task?.value
        resume?.resume(returning:.init(search_results:try (26...31).map { try post($0) },total:31));await old?.value
        XCTAssertEqual(store.posts.map(\.id),server.map(\.id));XCTAssertEqual(store.posts.count,30);XCTAssertFalse(store.hasMore)
    }
    func testCanonicalUpdateWinsOverUncooperativeEarlierSnapshot() async throws {
        let store = NativeConversationLibraryStore();let fresh = try post(1,name:"Updated")
        var first = true;var resume:CheckedContinuation<ChatSearchPage,Never>?
        store.load(kind:.files,query:"",channelID:93,accountGeneration:7) { _,_,_ in
            if first { first = false;return await withCheckedContinuation { resume = $0 } }
            return .init(search_results:[fresh],total:1)
        }
        while resume == nil { await Task.yield() };let old = store.task
        store.receive(change(fresh));XCTAssertEqual(store.posts.first?.message,"Updated")
        await store.task?.value;resume?.resume(returning:.init(search_results:[try post(1,name:"Obsolete")],total:1));await old?.value
        XCTAssertEqual(store.posts.first?.message,"Updated")
    }
    func testKeywordMembershipIsRequeriedRatherThanGuessedLocally() async throws {
        let store = NativeConversationLibraryStore();var after = false
        let initial = try post(1,name:"invoice")
        store.load(kind:.files,query:" invoice ",channelID:93,accountGeneration:7) { query,_,_ in
            XCTAssertEqual(query,"invoice");return .init(search_results:after ? [] : [initial],total:after ? 0 : 1)
        }
        await store.task?.value;after = true
        store.receive(change(try post(2,name:"invoice-like-but-not-in-server-result")))
        XCTAssertEqual(store.posts.map(\.id),[1]);await store.task?.value;XCTAssertTrue(store.posts.isEmpty)
    }
    func testReplyPinOrderUsesRebasedBackendPositionForUpdatedRow() async throws {
        let store = NativeConversationLibraryStore();let values = try [1,3,2].map { try post($0) };var after = false
        store.load(kind:.pins,query:"",channelID:93,pinSort:.activity,accountGeneration:7) { _,_,_ in
            .init(search_results:after ? [values[2],values[0],values[1]] : values,total:3)
        }
        await store.task?.value;after = true;store.receive(change(values[2]));await store.task?.value
        XCTAssertEqual(store.posts.map(\.id),[2,1,3])
    }
    func testCanonicalMembershipWinsForAnIDReturnedByBackendKeywordSearch() async throws {
        let store = NativeConversationLibraryStore();let stale = try post(1,name:"invoice",starred:false)
        store.load(kind:.bookmarks,query:"invoice",channelID:93,accountGeneration:7) { _,_,_ in .init(search_results:[stale],total:1) }
        await store.task?.value;XCTAssertTrue(store.posts.isEmpty)
        store.receive(change(try post(1,name:"invoice",starred:true)));await store.task?.value
        XCTAssertEqual(store.posts.map(\.id),[1])
    }
    func testOtherAccountAndChannelChangesCannotAffectResults() async throws {
        let store = NativeConversationLibraryStore();let value = try post(1)
        store.load(kind:.files,query:"",channelID:93,accountGeneration:7) { _,_,_ in .init(search_results:[value],total:1) };await store.task?.value
        store.receive(.init(accountGeneration:8,channelID:93,postID:1,state:.deleted))
        store.receive(.init(accountGeneration:7,channelID:94,postID:1,state:.deleted))
        XCTAssertEqual(store.posts.map(\.id),[1]);XCTAssertNil(store.task)
    }
    func testDeletedDuplicateSourcePromotesNextAndStaleRebaseCannotResurrectIt() async throws {
        let store = NativeConversationLibraryStore();let values = try [1,2].map { try post($0,type:"normal") }
        store.load(kind:.links,query:"",channelID:93,accountGeneration:7) { _,_,_ in .init(search_results:values,total:2) };await store.task?.value
        XCTAssertEqual(ChatLinkLibrary.entries(store.posts).first?.post.id,1)
        store.receive(.init(accountGeneration:7,channelID:93,postID:1,state:.deleted))
        XCTAssertEqual(ChatLinkLibrary.entries(store.posts).first?.post.id,2);await store.task?.value
        XCTAssertEqual(store.posts.map(\.id),[2])
    }
    func testUnbookmarkAndUnpinDoNotReturnFromStaleSearchPage() async throws {
        for kind in [NativeConversationLibraryStore.Kind.bookmarks,.pins] {
            let store = NativeConversationLibraryStore();let original = try post(1)
            store.load(kind:kind,query:"",channelID:93,accountGeneration:7) { _,_,_ in .init(search_results:[original],total:1) };await store.task?.value
            store.receive(change(try post(1,starred:false,pinned:false)));XCTAssertTrue(store.posts.isEmpty)
            await store.task?.value;XCTAssertTrue(store.posts.isEmpty)
        }
    }
    func testFailedAutomaticRebaseCanRetryWhenNoMorePagesExist() async throws {
        let store = NativeConversationLibraryStore();let value = try post(1);var fail = false
        store.load(kind:.files,query:"",channelID:93,accountGeneration:7) { _,_,_ in
            if fail { throw URLError(.networkConnectionLost) };return .init(search_results:[value],total:1)
        }
        await store.task?.value;fail = true;store.receive(change(try post(1,name:"Canonical")));await store.task?.value
        XCTAssertNotNil(store.failure);XCTAssertFalse(store.hasMore);XCTAssertEqual(store.posts.first?.message,"Canonical")
        fail = false;store.retry();await store.task?.value;XCTAssertNil(store.failure)
        XCTAssertEqual(store.posts.first?.message,"Canonical")
    }
    func testRecoveryReplacesMissedMembershipAndMetadataAcrossLoadedPages() async throws {
        let store = NativeConversationLibraryStore();var server = try (1...31).map { try post($0) };var offsets:[Int] = []
        let loader:NativeConversationLibraryStore.Loader = { _,offset,_ in offsets.append(offset);return .init(search_results:Array(server.dropFirst(offset).prefix(25)),total:server.count) }
        store.load(kind:.bookmarks,query:"",channelID:nil,accountGeneration:7,using:loader);await store.task?.value
        store.load(kind:.bookmarks,query:"",channelID:nil,more:true,accountGeneration:7,using:loader);await store.task?.value
        store.receive(change(try post(1,name:"Last seen online")));await store.task?.value
        // No events: remove an old bookmark, edit another and add a saved post.
        server.removeAll { $0.id == 1 };server[0] = try post(2,name:"Edited while offline");server.append(try post(32))
        offsets = [];store.recover(accountGeneration:7);await store.task?.value
        XCTAssertEqual(offsets,[0,25]);XCTAssertEqual(Set(store.posts.map(\.id)),Set(server.map(\.id)))
        XCTAssertEqual(store.posts.first(where:{$0.id == 2})?.message,"Edited while offline");XCTAssertFalse(store.hasMore)
    }
    func testRecoveryRetiresOldOverlayButKeepsEventsArrivingDuringHeldSnapshot() async throws {
        let store = NativeConversationLibraryStore();let initial = try post(1,name:"Before disconnect"),fresh = try post(1,name:"After reconnect event")
        var hold = false;var resume:CheckedContinuation<ChatSearchPage,Never>?
        store.load(kind:.files,query:"",channelID:93,accountGeneration:7) { _,_,_ in
            if hold { hold = false;return await withCheckedContinuation { resume = $0 } }
            return .init(search_results:[initial],total:1)
        };await store.task?.value
        store.receive(change(initial));await store.task?.value
        hold = true;store.recover(accountGeneration:7);while resume == nil { await Task.yield() };let old = store.task
        store.receive(change(fresh));await store.task?.value
        resume?.resume(returning:.init(search_results:[initial],total:1));await old?.value
        XCTAssertEqual(store.posts.first?.message,fresh.message)
    }
    func testRecoveryRetainsConfirmedTombstonesEvenIfSearchIndexIsStale() async throws {
        let store = NativeConversationLibraryStore();let values = try [1,2].map { try post($0) }
        store.load(kind:.pins,query:"",channelID:93,accountGeneration:7) { _,_,_ in .init(search_results:values,total:2) };await store.task?.value
        store.receive(.init(accountGeneration:7,channelID:93,postID:1,state:.deleted));await store.task?.value
        store.recover(accountGeneration:7);await store.task?.value
        XCTAssertEqual(store.posts.map(\.id),[2])
    }
    func testWrongAccountAndDismissedCollectionCannotTriggerRecoveryReads() async throws {
        let store = NativeConversationLibraryStore();var reads = 0
        store.load(kind:.links,query:"invoice",channelID:93,accountGeneration:7) { _,_,_ in reads += 1;return .init(search_results:[],total:0) };await store.task?.value
        store.recover(accountGeneration:8);XCTAssertNil(store.task)
        store.clear();store.recover(accountGeneration:7);XCTAssertNil(store.task);XCTAssertEqual(reads,1)
    }
    func testFailedRecoveryPreservesVisibleRowsAndRetryUsesNewServerState() async throws {
        let store = NativeConversationLibraryStore();let value = try post(1);var fail = false;var missedRemoval = false
        store.load(kind:.bookmarks,query:"",channelID:nil,accountGeneration:7) { _,_,_ in
            if fail { throw URLError(.notConnectedToInternet) }
            return .init(search_results:missedRemoval ? [] : [value],total:missedRemoval ? 0 : 1)
        };await store.task?.value;store.receive(change(value));await store.task?.value
        fail = true;missedRemoval = true;store.recover(accountGeneration:7);await store.task?.value
        XCTAssertNotNil(store.failure);XCTAssertEqual(store.posts.map(\.id),[1])
        fail = false;store.retry();await store.task?.value
        XCTAssertNil(store.failure);XCTAssertTrue(store.posts.isEmpty,"Old overlay must not resurrect the bookmark removed while offline")
    }
    func testImageGalleryCallbackCannotReadAReplacementSearchEvenWithSameScopeFields() async throws {
        let store = NativeConversationLibraryStore();var reads = 0
        let loader:NativeConversationLibraryStore.Loader = { _,_,_ in reads += 1;return .init(search_results:try (1...25).map{try self.post($0)},total:31) }
        store.load(kind:.files,query:"",channelID:93,accountGeneration:7,using:loader);await store.task?.value
        let old = try XCTUnwrap(store.imageGalleryLoader())
        store.load(kind:.files,query:"",channelID:93,accountGeneration:7,using:loader);await store.task?.value
        do { _ = try await old();XCTFail("Old gallery scope continued into a replacement search") } catch is CancellationError {} catch { XCTFail("Wrong failure: \(error)") }
        XCTAssertEqual(reads,2)
    }
    func testImageGalleryWaitsForInvalidatedPageRebaseBeforeReturningResults() async throws {
        let store = NativeConversationLibraryStore();var server = try (1...31).map{try post($0)};var resume:CheckedContinuation<ChatSearchPage,Never>?
        var hold = true
        store.load(kind:.files,query:"",channelID:93,accountGeneration:7) { _,offset,_ in
            if offset == 25 && hold { hold = false;return await withCheckedContinuation { resume = $0 } }
            return .init(search_results:Array(server.dropFirst(offset).prefix(25)),total:server.count)
        };await store.task?.value
        let next = try XCTUnwrap(store.imageGalleryLoader());let page = Task { try await next() }
        while resume == nil { await Task.yield() }
        server.removeAll{$0.id == 1};store.receive(.init(accountGeneration:7,channelID:93,postID:1,state:.deleted))
        await store.task?.value;resume?.resume(returning:.init(search_results:try (26...31).map{try post($0)},total:31))
        let result = try await page.value
        XCTAssertEqual(result.posts.map(\.id),server.map(\.id));XCTAssertEqual(result.cursor,30);XCTAssertFalse(result.hasMore)
    }
    func testClearCancelsDebounceAndForgetsOldAccountJournal() async throws {
        let store = NativeConversationLibraryStore();let value = try post(1);var requests = 0
        store.load(kind:.files,query:"",channelID:93,accountGeneration:7) { _,_,_ in requests += 1;return .init(search_results:[value],total:1) };await store.task?.value
        store.receive(change(try post(2)));store.receive(change(try post(3)));let pending = store.task
        store.clear();await pending?.value
        XCTAssertEqual(requests,1);XCTAssertTrue(store.posts.isEmpty);XCTAssertFalse(store.loading)
        store.receive(change(value));XCTAssertTrue(store.posts.isEmpty)
    }
}
