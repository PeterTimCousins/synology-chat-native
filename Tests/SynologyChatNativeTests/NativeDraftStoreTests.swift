import XCTest
import AppKit
@testable import SynologyChatNative

@MainActor final class NativeDraftStoreTests: XCTestCase {
    private let scope = String(repeating: "a", count: 64)
    private let other = String(repeating: "b", count: 64)
    private func folder() throws -> URL {
        let folder = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("native-drafts-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    func testAtomicDiskRoundtripAccountSeparationAndPermissions() throws {
        let folder = try folder(), store = NativeDraftStore(directory: folder)
        XCTAssertEqual(try store.activate(scope: scope), [])
        let values: [NativeDraftStore.Entry] = [.init(channelID: 23, rootID: nil, text: "Unsent 🌍"), .init(channelID: 23, rootID: 100, text: "Thread draft")]
        try store.replace(values)
        let restarted = NativeDraftStore(directory: folder)
        XCTAssertEqual(try restarted.activate(scope: other), [])
        XCTAssertEqual(try restarted.activate(scope: scope), values)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(scope + ".json").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".draft-") })
    }
    func testClearOnlyActiveAccountAndDeactivationCannotWrite() throws {
        let store = NativeDraftStore()
        _ = try store.activate(scope: scope); try store.replace([.init(channelID: 1, rootID: nil, text: "Account A")])
        _ = try store.activate(scope: other); try store.replace([.init(channelID: 1, rootID: nil, text: "Account B")]); try store.clear(); store.deactivate()
        try store.replace([.init(channelID: 2, rootID: nil, text: "Detached")])
        XCTAssertEqual(try store.activate(scope: other), [])
        XCTAssertEqual(try store.activate(scope: scope).first?.text, "Account A")
        XCTAssertThrowsError(try store.activate(scope: "invalid")); XCTAssertNil(store.scope)
    }
    func testRejectSymlinkFileAndDirectoryWithoutReadingTarget() throws {
        let folder = try folder(), target = folder.appendingPathComponent("target")
        try Data("private target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(scope + ".json"), withDestinationURL: target)
        XCTAssertThrowsError(try NativeDraftStore(directory: folder).activate(scope: scope))
        let alias = folder.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        XCTAssertThrowsError(try NativeDraftStore(directory: alias).activate(scope: scope))
        XCTAssertEqual(try String(contentsOf: target), "private target")
    }
    func testRejectDuplicateMalformedOversizedAndMismatchedScopeRecords() throws {
        let store = NativeDraftStore(); _ = try store.activate(scope: scope)
        let item = NativeDraftStore.Entry(channelID: 1, rootID: nil, text: "valid")
        XCTAssertThrowsError(try store.replace([item,item]))
        XCTAssertThrowsError(try store.replace([.init(channelID: 0, rootID: nil, text: "invalid")]))
        XCTAssertThrowsError(try store.replace([.init(channelID: 1, rootID: 0, text: "invalid")]))
        XCTAssertThrowsError(try store.replace([.init(channelID: 1, rootID: nil, text: "")]))
        XCTAssertThrowsError(try store.replace([.init(channelID: 1, rootID: nil, text: String(repeating: "x", count: NativeDraftStore.maximumTextBytes + 1))]))
        XCTAssertThrowsError(try store.replace((1...201).map { .init(channelID: Int64($0), rootID: nil, text: "draft") }))
        let folder = try folder()
        try Data("{\"version\":1,\"scope\":\"\(other)\",\"entries\":[]}".utf8).write(to: folder.appendingPathComponent(scope + ".json"))
        XCTAssertThrowsError(try NativeDraftStore(directory: folder).activate(scope: scope))
    }
    private func account(_ username: String = "peter") -> ChatAccount {
        .init(session: .init(baseURL: URL(string: "https://drafts.synthetic.test")!, sid: username, synoToken: "synthetic"), username: username, importedFromOfficialApp: false)
    }
    private func model(_ store: NativeDraftStore) -> NativeChatPreviewModel {
        NativeChatPreviewModel(restoreNotificationPreference: false, makeClient: { session in
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DraftRecoveryProtocol.self]
            return try ChatAPIClient(session: session, network: URLSession(configuration: configuration))
        }, draftStore: store)
    }
    func testModelQuitRestoresMainAndThreadWithoutPersistingEncryptedOrUnknownDrafts() async throws {
        let folder = try folder(), first = model(.init(directory: folder))
        await first.connect(using: account()); XCTAssertTrue(first.connected)
        first.selection = 23; first.draft = "Main unsent"
        first.threadRoot = try JSONDecoder().decode(ChatPost.self, from: Data(#"{"post_id":100,"channel_id":23,"creator_id":10,"message":"root","type":"normal","create_at":1}"#.utf8))
        first.replyDraft = "Reply unsent"
        first.drafts[24] = "Secret draft"; first.drafts[999] = "Unknown channel"
        first.prepareForTermination()
        let second = model(.init(directory: folder)); await second.connect(using: account())
        XCTAssertEqual(second.drafts, [23: "Main unsent"]); XCTAssertEqual(second.threadDrafts, [100: "Reply unsent"])
        second.drafts[23] = ""; second.threadDrafts[100] = ""; second.flushRecoverableDrafts(); second.prepareForTermination()
        let third = model(.init(directory: folder)); await third.connect(using: account())
        XCTAssertTrue(third.drafts.isEmpty); XCTAssertTrue(third.threadDrafts.isEmpty)
        third.signOutLocally()
    }
    func testModelAccountSwitchAndExplicitSignOutCannotRestoreOldDrafts() async throws {
        let folder = try folder(), first = model(.init(directory: folder))
        await first.connect(using: account()); first.selection = 23; first.draft = "Account A"
        await first.connect(using: account("other")); first.selection = 23; XCTAssertEqual(first.draft, "")
        first.draft = "Account B"; first.signOutLocally()
        await first.connect(using: account("other")); first.selection = 23; XCTAssertEqual(first.draft, "")
        await first.connect(using: account()); first.selection = 23; XCTAssertEqual(first.draft, "Account A")
        first.signOutLocally()
    }
    func testClearedMainAndReplyDraftsAreRemovedWithoutWaitingForDebounce() async throws {
        let folder = try folder(), account = account(), first = model(.init(directory: folder))
        await first.connect(using: account); first.selection = 23; first.draft = "Sent caption"
        first.threadRoot = try JSONDecoder().decode(ChatPost.self, from: Data(#"{"post_id":100,"channel_id":23,"creator_id":10,"message":"root","type":"normal","create_at":1}"#.utf8))
        first.replyDraft = "Sent reply"; first.flushRecoverableDrafts()
        first.drafts[23] = ""; first.threadDrafts[100] = nil
        let stored = try NativeDraftStore(directory: folder).activate(scope: ChatNotificationAccountScope.make(account: account, userID: 10)!)
        XCTAssertTrue(stored.isEmpty, "Acknowledged caption removal must reach disk before the typing debounce")
        first.signOutLocally()
    }
    func testRestoreImmediatelyPurgesPreviouslyOrdinaryNowEncryptedSavedText() async throws {
        let folder = try folder(), account = account()
        let scope = ChatNotificationAccountScope.make(account: account, userID: 10)!
        let seed = NativeDraftStore(directory: folder); _ = try seed.activate(scope: scope)
        try seed.replace([.init(channelID: 24, rootID: nil, text: "Previously ordinary"), .init(channelID: 999, rootID: 101, text: "Removed channel")])
        let first = model(.init(directory: folder)); await first.connect(using: account)
        XCTAssertTrue(first.drafts.isEmpty); XCTAssertTrue(first.threadDrafts.isEmpty)
        XCTAssertTrue(try NativeDraftStore(directory: folder).activate(scope: scope).isEmpty)
        first.signOutLocally()
    }
    func testSignOutReportsSavedDraftRemovalFailure() async throws {
        let folder = try folder(), first = model(.init(directory: folder))
        await first.connect(using: account()); first.selection = 23; first.draft = "Saved"; first.flushRecoverableDrafts()
        try FileManager.default.removeItem(at: folder); try Data("blocked directory".utf8).write(to: folder)
        first.signOutLocally()
        XCTAssertFalse(first.connected); XCTAssertTrue(first.drafts.isEmpty)
        XCTAssertTrue(first.draftRecoveryNotice?.contains("could not be removed") == true)
    }
    func testModelChannelEncryptionOrRemovalPurgesPersistedText() async throws {
        let folder = try folder(), first = model(.init(directory: folder))
        await first.connect(using: account()); first.selection = 23; first.draft = "Previously ordinary"; first.flushRecoverableDrafts()
        first.channels = [try JSONDecoder().decode(ChatChannel.self, from: Data(#"{"channel_id":23,"name":"Now encrypted","type":"private","encrypted":true,"unread":0}"#.utf8))]
        first.flushRecoverableDrafts(); first.prepareForTermination()
        let second = model(.init(directory: folder)); await second.connect(using: account()); XCTAssertTrue(second.drafts.isEmpty)
        second.selection = 23; second.draft = "Removed channel"; second.flushRecoverableDrafts(); second.channels = []; second.flushRecoverableDrafts(); second.prepareForTermination()
        let third = model(.init(directory: folder)); await third.connect(using: account()); XCTAssertTrue(third.drafts.isEmpty); third.signOutLocally()
    }
}

private final class DraftRecoveryProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let api = request.url!.lastPathComponent
        let name = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "_sid" }?.value ?? "peter"
        let body: String
        switch api {
        case "SYNO.API.Info": body = #"{"success":true,"data":{"SYNO.Chat.User":{"path":"entry.cgi","minVersion":1,"maxVersion":2},"SYNO.Chat.Channel":{"path":"entry.cgi","minVersion":1,"maxVersion":5},"SYNO.Chat.Misc":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}"#
        case "SYNO.Chat.User": body = "{\"success\":true,\"data\":{\"users\":[{\"user_id\":\(name == "other" ? 20 : 10),\"username\":\"\(name)\",\"nickname\":\"Synthetic\"}]}}"
        case "SYNO.Chat.Channel": body = #"{"success":true,"data":{"channels":[{"channel_id":23,"name":"Ordinary","type":"private","encrypted":false,"unread":0},{"channel_id":24,"name":"Encrypted","type":"private","encrypted":true,"unread":0}]}}"#
        case "SYNO.Chat.Misc": body = #"{"success":true,"data":{"acls":[]}}"#
        default: body = "{}"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
