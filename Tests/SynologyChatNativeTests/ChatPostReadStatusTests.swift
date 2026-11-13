#if DEBUG
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatPostReadStatusTests:XCTestCase {
    override func tearDown() {
        ReadStatusFixtureProtocol.requestObserver = nil;ReadStatusFixtureProtocol.readStatusProvider = nil
        ReadStatusFixtureProtocol.holdReadResponse = false;ReadStatusFixtureProtocol.held = nil
        super.tearDown()
    }
    private func model() async throws -> NativeChatPreviewModel {
        let value = try await NativeReadStatusFixture.makeModel()
        addTeardownBlock { @MainActor in value.signOutLocally() };return value
    }
    func testReadStatusHonorsNASPolicyAndAuthorBeforeSendingRequest() async throws {
        let model = try await model();let own = try XCTUnwrap(model.posts.first { $0.creator_id == 10 })
        let other = try XCTUnwrap(model.posts.first { $0.creator_id == 11 })
        XCTAssertTrue(model.canViewReadStatus(own));XCTAssertFalse(model.canViewReadStatus(other))
        var readRequests = 0
        ReadStatusFixtureProtocol.requestObserver = { _,method in if method == "get_read_status" { readRequests += 1 } }
        do { _ = try await model.readStatus(other);XCTFail("Other author read details exposed") } catch ChatAPIError.unsupportedAPI { }
        let status = try await model.readStatus(own)
        XCTAssertEqual(status.readIDs,[10,11]);XCTAssertEqual(status.unreadIDs,[12]);XCTAssertEqual(readRequests,1)
        model.handleLiveEvent(.init(name:"client.setting.update",payload:.object(["allow_read_status":.bool(false)])))
        XCTAssertFalse(model.canViewReadStatus(own))
        do { _ = try await model.readStatus(own);XCTFail("Disabled policy queried") } catch ChatAPIError.unsupportedAPI { }
        XCTAssertEqual(readRequests,1)
    }
    func testMissingUnknownAndMalformedPolicyFailClosedAndSignOutClearsIt() async throws {
        let settings = try JSONDecoder().decode(ChatDisplaySettings.self,from:Data("{}".utf8));XCTAssertNil(settings.allow_read_status)
        XCTAssertThrowsError(try JSONDecoder().decode(ChatDisplaySettings.self,from:Data(#"{"allow_read_status":"true"}"#.utf8)))
        let model = try await model();XCTAssertTrue(model.allowsReadStatus)
        model.handleLiveEvent(.init(name:"client.broadcast",payload:.object(["type":.string("setting.update"),"data":.object([:])])))
        XCTAssertFalse(model.allowsReadStatus)
        model.handleLiveEvent(.init(name:"client.setting.update",payload:.object(["allow_read_status":.bool(true)])))
        XCTAssertTrue(model.allowsReadStatus);model.signOutLocally();XCTAssertFalse(model.allowsReadStatus)
    }
    func testPolicyRevocationDuringHeldRequestCannotPublishParticipants() async throws {
        let model = try await model();let own = try XCTUnwrap(model.posts.first { $0.creator_id == 10 })
        let started = expectation(description:"Read held")
        ReadStatusFixtureProtocol.holdReadResponse = true
        ReadStatusFixtureProtocol.requestObserver = { _,method in if method == "get_read_status" { started.fulfill() } }
        let task = Task { try await model.readStatus(own) }
        await fulfillment(of:[started],timeout:2)
        model.handleLiveEvent(.init(name:"client.setting.update",payload:.object(["allow_read_status":.bool(false)])))
        ReadStatusFixtureProtocol.held?.deliverReadStatus(["read_users":[10,11],"unread_users":[12]])
        do { _ = try await task.value;XCTFail("Revoked read status published") } catch is CancellationError { }
    }
    func testInvalidResponseCannotMislabelParticipantsAndRefreshRecovers() async throws {
        let model = try await model();let own = try XCTUnwrap(model.posts.first { $0.creator_id == 10 });let store = NativeReadStatusStore()
        ReadStatusFixtureProtocol.readStatusProvider = { ["read_users":[10,11],"unread_users":[11]] }
        store.load { try await model.readStatus(own) };await store.task?.value
        XCTAssertNil(store.status);XCTAssertNotNil(store.failure);XCTAssertNil(store.updatedAt)
        ReadStatusFixtureProtocol.readStatusProvider = { ["read_users":[11,10,11],"unread_users":[12]] }
        store.load { try await model.readStatus(own) };await store.task?.value
        XCTAssertEqual(store.status?.readIDs,[10,11]);XCTAssertNil(store.failure);XCTAssertNotNil(store.updatedAt)
        XCTAssertThrowsError(try ChatPostReadStatus(read_users:[0],unread_users:[]).validate())
        XCTAssertThrowsError(try ChatPostReadStatus(read_users:Array(repeating:10,count:10001),unread_users:[]).validate())
    }
    func testClearedViewRejectsLateResponseEvenIfLoaderDoesNotCancel() async throws {
        let store = NativeReadStatusStore();var pending:CheckedContinuation<ChatPostReadStatus,Error>?
        store.load { try await withCheckedThrowingContinuation { pending = $0 } }
        let old = store.task;while pending == nil { await Task.yield() }
        store.clear();pending?.resume(returning:.init(read_users:[10],unread_users:[11]));await old?.value
        XCTAssertNil(store.status);XCTAssertNil(store.failure);XCTAssertFalse(store.loading)
    }
    func testSignOutDuringHeldReadCannotPublishOldAccountDetails() async throws {
        let model = try await model();let own = try XCTUnwrap(model.posts.first { $0.creator_id == 10 })
        let started = expectation(description:"Old account read held");ReadStatusFixtureProtocol.holdReadResponse = true
        ReadStatusFixtureProtocol.requestObserver = { _,method in if method == "get_read_status" { started.fulfill() } }
        let task = Task { try await model.readStatus(own) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally()
        ReadStatusFixtureProtocol.held?.deliverReadStatus(["read_users":[10,11],"unread_users":[12]])
        do { _ = try await task.value;XCTFail("Old account data published") } catch is CancellationError { }
    }
}

#endif
