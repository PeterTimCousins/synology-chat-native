import XCTest
@testable import SynologyChatNative

@MainActor final class ChatSlashCommandTests: XCTestCase {
    override func setUp() { super.setUp(); SlashProtocol.reset() }
    private func api() async throws -> ChatAPIClient {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [SlashProtocol.self]
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://slash.invalid")!, sid: "synthetic", synoToken: "synthetic"), network: URLSession(configuration: c))
        try await api.discover(); return api
    }
    private func users() throws -> [ChatUser] { try JSONDecoder().decode(UserList.self, from: JSONSerialization.data(withJSONObject: ["users": SlashProtocol.users])).users }
    private func model(journal:ChatSlashActionJournal? = nil,scope:String? = nil) async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(client: try await api(), restoreNotificationPreference: false,slashActionJournal:journal)
        model.directory = try users(); model.channels = [try JSONDecoder().decode(ChatChannel.self, from: JSONSerialization.data(withJSONObject: SlashProtocol.channel))]
        model.connected = true; model.liveStatus = .live; model.selection = 93
        if let scope { model.restoreSlashRecovery(scope:scope) }
        addTeardownBlock { @MainActor in model.signOutLocally() }; return model
    }
    private func invocation(_ model: NativeChatPreviewModel, message: String = "/jitsi") async throws -> (NativeSlashCommandRequest, ChatSlashCommand) {
        model.draft = message; try await model.prepareSlashCommands(fromComposer: true)
        let request = try XCTUnwrap(model.slashCommandRequest)
        return (request, try XCTUnwrap(request.commands.first { $0.name == "jitsi" }))
    }
    func testSyntaxMatchesOfficialPrefixAndCompletionPreservesArguments() {
        XCTAssertEqual(ChatSlashSyntax.name("/jitsi extra 👋"), "jitsi"); XCTAssertEqual(ChatSlashSyntax.name("/jitsi.extra"), "jitsi")
        XCTAssertNil(ChatSlashSyntax.name(" /jitsi")); XCTAssertNil(ChatSlashSyntax.name("/"))
        XCTAssertFalse(ChatSlashSyntax.validName("bad name")); XCTAssertFalse(ChatSlashSyntax.validName("é"))
        XCTAssertEqual(ChatSlashSyntax.completing("/ji room", with: "jitsi"), "/jitsi room")
        XCTAssertEqual(ChatSlashSyntax.completing("/", with: "help"), "/help ")
        XCTAssertEqual(ChatSlashSyntax.arguments("/nickname Peter Cousins"), "Peter Cousins")
    }
    func testUserCatalogueFiltersDisabledAndEncryptedJitsiAndNeverRetainsEndpointSecret() throws {
        let users = try users(), commands = try ChatSlashCommand.catalogue(users: users, encrypted: false)
        XCTAssertEqual(commands.map(\.name), ["help", "jitsi", "nickname"])
        XCTAssertEqual(commands.first { $0.name == "jitsi" }?.kind, .server(3))
        XCTAssertEqual(try ChatSlashCommand.catalogue(users: users, encrypted: true).map(\.name), ["help", "nickname"])
        XCTAssertNotNil(users.last?.slash_props?.endpointFingerprint); XCTAssertFalse(String(describing: users.last).contains("secret-token"))
        SlashProtocol.disabled = true
        XCTAssertEqual(try ChatSlashCommand.catalogue(users: self.users(), encrypted: false).map(\.name), ["help", "nickname"])
        let malformed = try JSONDecoder().decode(ChatUser.self, from: Data(#"{"user_id":3,"nickname":"Malformed","type":"bot","bot_type":"slash","slash_props":42}"#.utf8))
        XCTAssertNil(malformed.slash_props?.cmd)
        XCTAssertThrowsError(try ChatSlashCommand.catalogue(users: users + [users[0]], encrypted: false))
    }
    func testExecuteV2WireForwardsFullTextAndOmitsThreadAndConnectionIDs() async throws {
        let api = try await api(), response = try await api.executeSlashCommand(channelID: 93, userID: 3, message: "/jitsi room 👋")
        XCTAssertEqual(response.message, "Synthetic local response")
        let fields = try XCTUnwrap(SlashProtocol.lastExecute)
        XCTAssertEqual(fields["version"], "2"); XCTAssertEqual(fields["channel_id"], "93"); XCTAssertEqual(fields["user_id"], "3")
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(try XCTUnwrap(fields["message"]).utf8)), "/jitsi room 👋"); XCTAssertNil(fields["thread_id"]); XCTAssertNil(fields["conn_id"])
        do { _ = try await api.executeSlashCommand(channelID: 93, userID: 3, message: "ordinary text"); XCTFail("Literal text executed") } catch { }
        XCTAssertEqual(SlashProtocol.executes, 1)
    }
    func testSendInterceptsHelpAndUnavailableCommandsWithoutPostingAndPreservesDraft() async throws {
        let model = try await model(); model.draft = "/help"
        await model.send(); let request = try XCTUnwrap(model.slashCommandRequest), help = try XCTUnwrap(request.commands.first { $0.name == "help" })
        XCTAssertEqual(model.draft, "/help"); _ = try await model.executeSlashCommand(request, command: help, message: "/help")
        XCTAssertEqual(model.draft, ""); XCTAssertEqual(SlashProtocol.executes, 0); XCTAssertEqual(SlashProtocol.postCreates, 0)
        model.dismissSlashCommands(); model.draft = "/unknown kept"
        await model.send(); XCTAssertNil(model.slashCommandRequest); XCTAssertEqual(model.draft, "/unknown kept"); XCTAssertTrue(model.error?.contains("Unknown") == true)
        XCTAssertEqual(SlashProtocol.postCreates, 0)
    }
    func testSuccessfulRunClearsOnlyUnchangedOriginAndToolbarKeepsUnsentMessage() async throws {
        let model = try await model(), (request, command) = try await invocation(model)
        _ = try await model.executeSlashCommand(request, command: command, message: "/jitsi")
        XCTAssertEqual(model.draft, ""); XCTAssertTrue(model.uncertainSlashInvocations.isEmpty)
        model.dismissSlashCommands(); model.draft = "Keep normal unsent message"
        try await model.prepareSlashCommands(); let palette = try XCTUnwrap(model.slashCommandRequest)
        _ = try await model.executeSlashCommand(palette, command: command, message: "/jitsi")
        XCTAssertEqual(model.draft, "Keep normal unsent message"); XCTAssertEqual(SlashProtocol.executes, 2)
    }
    func testEmptyAcknowledgedResponseHasVisibleFeedbackAndStillConsumesTheCommand() async throws {
        let model = try await model(), (request, command) = try await invocation(model)
        SlashProtocol.responseMessage = ""
        let result = try await model.executeSlashCommand(request, command: command, message: "/jitsi")
        XCTAssertEqual(result.message, ""); XCTAssertTrue(result.displayMessage.hasPrefix("Command sent."))
        XCTAssertEqual(model.draft, ""); XCTAssertTrue(model.uncertainSlashInvocations.isEmpty); XCTAssertEqual(SlashProtocol.executes, 1)
    }
    func testChangedEndpointMembersOrSourceTypePreventDispatch() async throws {
        let model = try await model(), (request, command) = try await invocation(model)
        SlashProtocol.endpoint += "-changed"
        do { _ = try await model.executeSlashCommand(request, command: command, message: "/jitsi"); XCTFail("Changed endpoint accepted") } catch let e as ChatSlashFailure { XCTAssertFalse(e.uncertain) }
        SlashProtocol.endpoint = "https://configured.invalid/secret-token"; SlashProtocol.members = [10]
        do { _ = try await model.executeSlashCommand(request, command: command, message: "/jitsi"); XCTFail("Changed members accepted") } catch { }
        SlashProtocol.members = [10, 6]; SlashProtocol.channel["type"] = "private"
        do { _ = try await model.executeSlashCommand(request, command: command, message: "/jitsi"); XCTFail("Changed type accepted") } catch { }
        XCTAssertEqual(SlashProtocol.executes, 0); XCTAssertTrue(model.uncertainSlashInvocations.isEmpty)
    }
    func testLostReplyBlocksSameInvocationAcrossReopenedSheetsWithoutAutoRetry() async throws {
        let model = try await model(), (request, command) = try await invocation(model); SlashProtocol.loseReply = true
        do { _ = try await model.executeSlashCommand(request, command: command, message: "/jitsi"); XCTFail("Lost response confirmed") } catch let e as ChatSlashFailure { XCTAssertTrue(e.uncertain) }
        XCTAssertEqual(model.draft, "/jitsi"); XCTAssertEqual(model.uncertainSlashInvocations.count, 1)
        model.dismissSlashCommands(); let (newRequest, newCommand) = try await invocation(model)
        do { _ = try await model.executeSlashCommand(newRequest, command: newCommand, message: "/jitsi"); XCTFail("Repeated command") } catch { }
        XCTAssertEqual(SlashProtocol.executes, 1)
    }
    func testThreadCommandUsesConversationDestinationAndClearsOnlyReplyDraft() async throws {
        let model = try await model()
        let root = try JSONDecoder().decode(ChatPost.self, from: Data(#"{"post_id":500,"channel_id":93,"creator_id":6,"type":"normal","message":"Synthetic root","create_at":1000}"#.utf8))
        model.threadRoot = root; model.draft = "Keep main draft"; model.replyDraft = "/jitsi"
        try await model.prepareSlashCommands(inThread: true, fromComposer: true)
        let request = try XCTUnwrap(model.slashCommandRequest), command = try XCTUnwrap(request.commands.first { $0.name == "jitsi" })
        XCTAssertEqual(request.rootID, 500); _ = try await model.executeSlashCommand(request, command: command, message: "/jitsi")
        XCTAssertEqual(model.replyDraft, ""); XCTAssertEqual(model.draft, "Keep main draft"); XCTAssertNil(SlashProtocol.lastExecute?["thread_id"])
    }
    func testLatePreparationAfterSelectionChangeCannotOpenStaleSheet() async throws {
        let model = try await model(), read = expectation(description: "Catalogue held"); SlashProtocol.holdUsers = true; SlashProtocol.onUsers = { read.fulfill() }
        let task = Task { try await model.prepareSlashCommands() }
        await fulfillment(of: [read], timeout: 2); model.selection = nil; SlashProtocol.heldUsers?.finish(["success": true, "data": ["users": SlashProtocol.users]]); SlashProtocol.heldUsers = nil
        do { try await task.value; XCTFail("Stale sheet opened") } catch is CancellationError { }
        XCTAssertNil(model.slashCommandRequest); XCTAssertFalse(model.slashBusy); XCTAssertEqual(SlashProtocol.executes, 0)
    }
    func testCancellationAfterDispatchRetainsUnknownAndDoesNotClearDraft() async throws {
        let model = try await model(), (request, command) = try await invocation(model), sent = expectation(description: "Command held")
        SlashProtocol.holdExecute = true; SlashProtocol.onExecute = { sent.fulfill() }
        let task = Task { try await model.executeSlashCommand(request, command: command, message: "/jitsi") }
        await fulfillment(of: [sent], timeout: 2); task.cancel(); SlashProtocol.heldExecute?.finish(["success": true, "data": [:]]); SlashProtocol.heldExecute = nil
        do { _ = try await task.value; XCTFail("Cancelled result published") } catch { }
        XCTAssertEqual(model.draft, "/jitsi"); XCTAssertEqual(model.uncertainSlashInvocations.count, 1); XCTAssertFalse(model.slashBusy)
    }
    func testLateAcknowledgementClearsOnlyTheOriginThreadDraft() async throws {
        let model = try await model()
        func root(_ id: Int64) throws -> ChatPost { try JSONDecoder().decode(ChatPost.self, from: JSONSerialization.data(withJSONObject: ["post_id": id, "channel_id": 93, "creator_id": 6, "type": "normal", "message": "Synthetic root", "create_at": 1000])) }
        model.threadRoot = try root(500); model.replyDraft = "/jitsi"
        try await model.prepareSlashCommands(inThread: true, fromComposer: true)
        let request = try XCTUnwrap(model.slashCommandRequest), command = try XCTUnwrap(request.commands.first { $0.name == "jitsi" }), sent = expectation(description: "Command held")
        SlashProtocol.holdExecute = true; SlashProtocol.onExecute = { sent.fulfill() }
        let task = Task { try await model.executeSlashCommand(request, command: command, message: "/jitsi") }
        await fulfillment(of: [sent], timeout: 2)
        model.threadRoot = try root(501); model.replyDraft = "/jitsi"
        SlashProtocol.heldExecute?.finish(["success": true, "data": [:]]); SlashProtocol.heldExecute = nil
        _ = try await task.value
        XCTAssertEqual(model.threadDrafts[500], ""); XCTAssertEqual(model.replyDraft, "/jitsi"); XCTAssertEqual(model.threadRoot?.id, 501); XCTAssertEqual(SlashProtocol.executes, 1)
    }
    func testSignOutAfterDispatchCannotPublishOldResponseOrClearNewState() async throws {
        let model = try await model(), (request, command) = try await invocation(model), sent = expectation(description: "Command held")
        SlashProtocol.holdExecute = true; SlashProtocol.onExecute = { sent.fulfill() }
        let task = Task { try await model.executeSlashCommand(request, command: command, message: "/jitsi") }
        await fulfillment(of: [sent], timeout: 2); model.signOutLocally(); SlashProtocol.heldExecute?.finish(["success": true, "data": [:]]); SlashProtocol.heldExecute = nil
        do { _ = try await task.value; XCTFail("Old response published") } catch is CancellationError { }
        XCTAssertNil(model.slashCommandRequest); XCTAssertTrue(model.uncertainSlashInvocations.isEmpty); XCTAssertFalse(model.slashBusy)
    }
    private func recoveryFolder() throws -> URL {
        let folder = URL(fileURLWithPath:"/private/tmp").appendingPathComponent("native-slash-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:folder) }
        return folder
    }
    func testUnknownSlashResultSurvivesNewModelAndExplicitAcknowledgementNeverResends() async throws {
        let directory = try recoveryFolder(),scope = String(repeating:"a",count:64)
        let first = try await model(journal:.init(directory:directory),scope:scope)
        let (request,command) = try await invocation(first,message:"/jitsi private synthetic argument")
        SlashProtocol.loseReply = true
        do { _ = try await first.executeSlashCommand(request,command:command,message:request.initialText);XCTFail("Lost reply confirmed") } catch { }
        XCTAssertEqual(SlashProtocol.executes,1);first.signOutLocally()
        let second = try await model(journal:.init(directory:directory),scope:scope)
        XCTAssertEqual(second.pendingSlashInvocations.count,1)
        let (restored,restoredCommand) = try await invocation(second,message:request.initialText)
        do { _ = try await second.executeSlashCommand(restored,command:restoredCommand,message:restored.initialText);XCTFail("Restored command replayed") } catch { }
        XCTAssertEqual(SlashProtocol.executes,1)
        let receipt = try XCTUnwrap(second.pendingSlashInvocations.values.first)
        try second.acknowledgeSlashOutcome(receipt,request:restored)
        XCTAssertEqual(SlashProtocol.executes,1);XCTAssertTrue(second.pendingSlashInvocations.isEmpty)
        XCTAssertTrue(try ChatSlashActionJournal(directory:directory).activate(scope:scope).isEmpty)
        SlashProtocol.loseReply = false
        _ = try await second.executeSlashCommand(restored,command:restoredCommand,message:restored.initialText)
        XCTAssertEqual(SlashProtocol.executes,2)
        XCTAssertTrue(try ChatSlashActionJournal(directory:directory).activate(scope:scope).isEmpty)
    }
    func testRecoveryStorageReadAndWriteFailuresBlockDispatchButLeaveLocalHelpAvailable() async throws {
        let directory = try recoveryFolder(),scope = String(repeating:"b",count:64)
        let model = try await model(journal:.init(directory:directory),scope:scope)
        let (request,command) = try await invocation(model)
        let file = directory.appendingPathComponent(scope + ".json")
        try Data("invalid synthetic record".utf8).write(to:file)
        do { _ = try await model.executeSlashCommand(request,command:command,message:"/jitsi");XCTFail("Unsaved operation sent") } catch { }
        XCTAssertNotNil(model.slashRecoveryError);XCTAssertEqual(SlashProtocol.executes,0)
        do { try model.refreshSlashRecovery(request);XCTFail("Invalid record loaded") } catch { }
        XCTAssertNotNil(model.slashRecoveryError)
        let help = try XCTUnwrap(request.commands.first { $0.kind == .help })
        _ = try await model.executeSlashCommand(request,command:help,message:"/help")
        XCTAssertEqual(SlashProtocol.executes,0)
        try FileManager.default.removeItem(at:file)
        try model.refreshSlashRecovery(request);XCTAssertNil(model.slashRecoveryError)
        _ = try await model.executeSlashCommand(request,command:command,message:"/jitsi")
        XCTAssertEqual(SlashProtocol.executes,1)
    }
    func testAcknowledgedCommandWithFailedReceiptRetirementRemainsBlockedUntilExplicitResolution() async throws {
        let directory = try recoveryFolder(),scope = String(repeating:"c",count:64)
        let model = try await model(journal:.init(directory:directory),scope:scope)
        let (request,command) = try await invocation(model),started = expectation(description:"Persisted command dispatched")
        SlashProtocol.holdExecute = true;SlashProtocol.onExecute = { started.fulfill() }
        let task = Task { try await model.executeSlashCommand(request,command:command,message:"/jitsi") }
        await fulfillment(of:[started],timeout:2)
        let file = directory.appendingPathComponent(scope + ".json"),saved = try Data(contentsOf:file)
        XCTAssertEqual(try ChatSlashActionJournal(directory:directory).activate(scope:scope).count,1)
        try Data("invalid synthetic retirement".utf8).write(to:file)
        SlashProtocol.heldExecute?.finish(["success":true,"data":["message":"Synthetic acknowledgement"]])
        let acknowledgement = try await task.value
        XCTAssertEqual(acknowledgement.message,"Synthetic acknowledgement")
        XCTAssertTrue(model.slashRecoveryError?.contains("acknowledged") == true)
        XCTAssertEqual(model.draft,"");XCTAssertEqual(model.pendingSlashInvocations.count,1)
        do { _ = try await model.executeSlashCommand(request,command:command,message:"/jitsi");XCTFail("Uncertain record replayed") } catch { }
        XCTAssertEqual(SlashProtocol.executes,1)
        try saved.write(to:file);try model.refreshSlashRecovery(request)
        try model.acknowledgeSlashOutcome(XCTUnwrap(model.pendingSlashInvocations.values.first),request:request)
        XCTAssertEqual(SlashProtocol.executes,1);XCTAssertTrue(model.uncertainSlashInvocations.isEmpty)
    }
    func testActualConnectRestoresOwnAccountCommandReceiptAndSignOutKeepsItOnDisk() async throws {
        let directory = try recoveryFolder()
        func connected() async throws -> NativeChatPreviewModel {
            let api = try await api()
            let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ _ in api },slashActionJournal:.init(directory:directory))
            await model.connect(using:.init(session:.init(baseURL:URL(string:"https://slash.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
            XCTAssertTrue(model.connected);model.liveStatus = .live;model.selection = 93
            addTeardownBlock { @MainActor in model.signOutLocally() }
            return model
        }
        let first = try await connected(),(request,command) = try await invocation(first)
        SlashProtocol.loseReply = true
        do { _ = try await first.executeSlashCommand(request,command:command,message:"/jitsi");XCTFail("Lost reply") } catch { }
        XCTAssertEqual(first.pendingSlashInvocations.count,1);first.signOutLocally()
        let second = try await connected()
        XCTAssertEqual(second.pendingSlashInvocations.count,1);XCTAssertNil(second.slashRecoveryError)
        XCTAssertEqual(SlashProtocol.executes,1)
    }
    func testNicknameIsDiscoveredButCannotBypassTheProfileEditor() async throws {
        let model = try await model(); model.draft = "/nickname Synthetic"
        await model.send(); let request = try XCTUnwrap(model.slashCommandRequest), command = try XCTUnwrap(request.commands.first { $0.name == "nickname" })
        do { _ = try await model.executeSlashCommand(request, command: command, message: model.draft); XCTFail("Profile editor bypassed") } catch { }
        XCTAssertEqual(SlashProtocol.executes, 0); XCTAssertEqual(SlashProtocol.profileWrites, 0)
        model.finishSlashNickname(request); XCTAssertEqual(model.draft, ""); XCTAssertNil(model.slashCommandRequest)
    }
}

private final class SlashProtocol: URLProtocol {
    static var endpoint = "https://configured.invalid/secret-token", disabled = false
    static var responseMessage = "Synthetic local response"
    static var members: [Int64] = [10, 6], channel: [String: Any] = [:]
    static var executes = 0, postCreates = 0, profileWrites = 0
    static var loseReply = false, holdUsers = false, holdExecute = false
    static var lastExecute: [String: String]?, heldUsers: SlashProtocol?, heldExecute: SlashProtocol?
    static var onUsers: (() -> Void)?, onExecute: (() -> Void)?
    static var users: [[String: Any]] { [["user_id": 10, "username": "synthetic", "nickname": "Synthetic Peter", "type": "human", "human_type": "dsm"], ["user_id": 6, "username": "other", "nickname": "Other Peter", "type": "human", "human_type": "dsm"], ["user_id": 3, "nickname": "Jitsi", "type": "bot", "bot_type": "slash", "is_disabled": disabled, "slash_props": ["cmd": "jitsi", "description": "webhook_builtin:desc_conference_jitsi", "usage": "", "url": endpoint]]] }
    static func reset() { responseMessage = "Synthetic local response"; endpoint = "https://configured.invalid/secret-token"; disabled = false; members = [10, 6]; channel = ["channel_id": 93, "name": "Peter", "type": "anonymous", "encrypted": false, "unread": 0, "is_joined": true]; executes = 0; postCreates = 0; profileWrites = 0; loseReply = false; holdUsers = false; holdExecute = false; lastExecute = nil; heldUsers = nil; heldExecute = nil; onUsers = nil; onExecute = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let api = request.url!.lastPathComponent
        if api == "SYNO.API.Info" { let names = ["SYNO.Chat.User", "SYNO.Chat.Channel", "SYNO.Chat.Channel.Member", "SYNO.Chat.Webhook.Slash", "SYNO.Chat.Post"]; finish(["success": true, "data": Dictionary(uniqueKeysWithValues: names.map { ($0, ["path": "entry.cgi", "minVersion": 1, "maxVersion": 5, "requestFormat": "JSON"] as [String: Any]) })]); return }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 2048); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) } }
        var q = URLComponents(); q.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        let fields = Dictionary((q.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        if api == "SYNO.Chat.User" {
            if fields["method"] == "set" { Self.profileWrites += 1; finish(["success": true]); return }
            if Self.holdUsers { Self.heldUsers = self; Self.onUsers?(); return }
            finish(["success": true, "data": ["users": Self.users]]); return
        }
        if api == "SYNO.Chat.Channel" { if fields["method"] == "list" { finish(["success": true, "data": ["channels": [Self.channel]]]) } else { finish(["success": true]) }; return }
        if api == "SYNO.Chat.Channel.Member" { finish(["success": true, "data": ["user_ids": Self.members]]); return }
        if api == "SYNO.Chat.Post" { if fields["method"] == "create" { Self.postCreates += 1 }; finish(["success": true, "data": ["posts": []]]); return }
        if api == "SYNO.Chat.Webhook.Slash" {
            Self.executes += 1; Self.lastExecute = fields
            if Self.holdExecute { Self.heldExecute = self; Self.onExecute?(); return }
            if Self.loseReply { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
            finish(["success": true, "data": ["message": Self.responseMessage]]); return
        }
        finish(["success": false, "error": ["code": 102]])
    }
    func finish(_ value: [String: Any]) { let data = try! JSONSerialization.data(withJSONObject: value); client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
