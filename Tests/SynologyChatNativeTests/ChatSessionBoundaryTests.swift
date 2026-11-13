import XCTest
import Combine
@testable import SynologyChatNative

@MainActor
final class ChatSessionBoundaryTests: XCTestCase {
    func testMessageLimitMatchesJavaScriptUTF16BoundaryWithoutTruncation() {
        XCTAssertTrue(ChatMessageText.isAllowed(String(repeating: "a", count: 2_000)))
        XCTAssertFalse(ChatMessageText.isAllowed(String(repeating: "a", count: 2_001)))
        XCTAssertTrue(ChatMessageText.isAllowed(String(repeating: "😀", count: 1_000)))
        XCTAssertFalse(ChatMessageText.isAllowed(String(repeating: "😀", count: 1_001)))
        XCTAssertTrue(ChatMessageText.isAllowed(String(repeating: "e\u{301}", count: 1_000)))
        XCTAssertFalse(ChatMessageText.isAllowed(String(repeating: "e\u{301}", count: 1_001)))
        XCTAssertNil(ChatMessageText.warning(for: "Short message"))
        XCTAssertNotNil(ChatMessageText.warning(for: String(repeating: "x", count: 2_001)))
    }

    func testOversizedDraftsEditsAndAttachmentCaptionsStayLocalAndRecover() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model(); await model.connect(using: account("old")); model.liveStatus = .live
        model.selection = 23
        let original = try ownPost(); model.posts = [original]; model.threadRoot = original
        let oversized = String(repeating: "x", count: 2_001)
        model.draft = oversized; model.replyDraft = oversized
        var requests = 0
        SessionBoundaryStub.route = { request in requests += 1; request.standardResponse() }
        XCTAssertFalse(model.canSend); XCTAssertFalse(model.canReply)
        await model.send(); await model.sendReply()
        let edited = await model.edit(original, text: oversized)
        XCTAssertFalse(edited)
        await model.chooseAttachment(); await model.chooseAttachment(inThread: true)
        XCTAssertEqual(requests, 0, "Invalid text must not open a picker or send an API request")
        XCTAssertEqual(model.draft, oversized); XCTAssertEqual(model.replyDraft, oversized)
        XCTAssertEqual(model.posts.first?.message, original.message)
        XCTAssertTrue(model.pendingMessageActions.isEmpty); XCTAssertFalse(model.sending)
        model.draft = "Shortened"; model.replyDraft = "Shortened reply"
        XCTAssertTrue(model.canSend); XCTAssertTrue(model.canReply)
        model.signOutLocally()
    }

    private func account(_ id: String) -> ChatAccount {
        .init(session: .init(baseURL: URL(string: "https://synthetic.test")!, sid: id, synoToken: "synthetic"),
              username: id, importedFromOfficialApp: false)
    }
    private func model() -> NativeChatPreviewModel {
        NativeChatPreviewModel(restoreNotificationPreference: false, makeClient: { session in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SessionBoundaryStub.self]
            return try ChatAPIClient(session: session, network: URLSession(configuration: configuration))
        })
    }
    override func tearDown() { SessionBoundaryStub.route = nil; super.tearDown() }

    func testUnavailableDeletedSystemAndLockedMessagesCannotIssueMutations() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model(); await model.connect(using: account("old")); model.liveStatus = .live
        var requests = 0
        SessionBoundaryStub.route = { request in requests += 1; request.standardResponse() }
        func post(channel: Int = 23, type: String = "normal", deleted: Int = 0) throws -> ChatPost {
            try JSONDecoder().decode(ChatPost.self, from: Data("{\"post_id\":100,\"channel_id\":\(channel),\"creator_id\":10,\"message\":\"Synthetic\",\"type\":\"\(type)\",\"create_at\":1000,\"delete_at\":\(deleted)}".utf8))
        }
        for target in [try post(channel: 999), try post(type: "system"), try post(deleted: 2000)] {
            XCTAssertFalse(model.canAct(on: target))
            let edited = await model.edit(target, text: "Should not send")
            XCTAssertFalse(edited)
            await model.delete(target); await model.toggleThumbsUp(target)
        }
        model.channels = [try JSONDecoder().decode(ChatChannel.self, from: Data(#"{"channel_id":23,"name":"Locked","type":"private","encrypted":true,"unread":0}"#.utf8))]
        let locked = try post()
        XCTAssertFalse(model.canAct(on: locked))
        let edited = await model.edit(locked, text: "Should not send")
        XCTAssertFalse(edited)
        await model.delete(locked); await model.toggleThumbsUp(locked)
        XCTAssertEqual(requests, 0, "Rejected actions must not make even a preflight/read request")
        XCTAssertTrue(model.pendingMessageActions.isEmpty)
        model.signOutLocally()
    }

    func testOtherAuthorsCannotBeEditedOrDeletedButCanReceiveReactions() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model(); await model.connect(using: account("old")); model.liveStatus = .live
        let other = try JSONDecoder().decode(ChatPost.self, from: Data(#"{"post_id":101,"channel_id":23,"creator_id":20,"message":"Synthetic peer","type":"normal","create_at":1000}"#.utf8))
        XCTAssertTrue(model.canAct(on: other))
        XCTAssertFalse(model.canChangeOwnMessage(other))
        var reactions = 0, otherRequests = 0
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.Post.Reaction" { reactions += 1; request.respond(#"{"success":true}"#) }
            else { otherRequests += 1; request.respond(#"{"success":true,"data":{"posts":[{"post_id":101,"channel_id":23,"creator_id":20,"message":"Synthetic peer","type":"normal","create_at":1000}]}}"#) }
        }
        let edited = await model.edit(other, text: "Should not send")
        XCTAssertFalse(edited)
        await model.delete(other)
        XCTAssertEqual(reactions + otherRequests, 0)
        await model.toggleThumbsUp(other)
        XCTAssertEqual(reactions, 1)
        XCTAssertEqual(otherRequests, 1, "Only the reaction's canonical readback")
        XCTAssertTrue(model.pendingMessageActions.isEmpty)
        model.signOutLocally()
    }

    func testImportedOfficialSessionCannotBeRevokedByNativeSignOut() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model()
        let source = account("borrowed")
        let imported = ChatAccount(session: source.session, username: source.username, importedFromOfficialApp: true)
        await model.connect(using: imported)
        XCTAssertTrue(model.connected)
        XCTAssertFalse(model.canRevokeSession)
        var requests = 0
        SessionBoundaryStub.route = { request in requests += 1; request.standardResponse() }
        await model.signOutNativeSession()
        XCTAssertTrue(model.connected, "Imported sessions expose local disconnect only")
        XCTAssertEqual(requests, 0, "Native sign-out must neither revoke nor read the imported session")
        model.signOutLocally()
        XCTAssertFalse(model.connected)
        XCTAssertEqual(requests, 0, "Local disconnect must leave the vendor session intact")
    }

    func testSignOutInvalidatesPendingBootstrapAndPreventsFurtherReads() async throws {
        let started = expectation(description: "User request held")
        var held: SessionBoundaryStub?
        var channelReads = 0
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.User" { held = request; started.fulfill() }
            else { if request.api == "SYNO.Chat.Channel" { channelReads += 1 }; request.standardResponse() }
        }
        let model = model()
        let attempt = Task { await model.connect(using: account("old")) }
        await fulfillment(of: [started], timeout: 2)
        model.signOutLocally()
        XCTAssertFalse(model.connecting)
        held?.standardResponse()
        await attempt.value
        XCTAssertFalse(model.connected)
        XCTAssertTrue(model.directory.isEmpty)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertEqual(model.accountDisplay, "")
        XCTAssertNil(model.error)
        XCTAssertEqual(channelReads, 0)
    }

    func testOldFailureCannotClearNewConnectionProgressOrPublishOldAccount() async throws {
        let oldStarted = expectation(description: "Old bootstrap held")
        let newStarted = expectation(description: "New bootstrap held")
        var old: SessionBoundaryStub?
        var new: SessionBoundaryStub?
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.User" {
                if request.identity == "old" { old = request; oldStarted.fulfill() }
                else { new = request; newStarted.fulfill() }
            } else { request.standardResponse() }
        }
        let model = model()
        let first = Task { await model.connect(using: account("old")) }
        await fulfillment(of: [oldStarted], timeout: 2)
        model.signOutLocally()
        let second = Task { await model.connect(using: account("new")) }
        await fulfillment(of: [newStarted], timeout: 2)
        old?.fail()
        await first.value
        XCTAssertTrue(model.connecting, "Old task cleanup must not finish the newer attempt")
        XCTAssertNil(model.error)
        new?.standardResponse()
        await second.value
        XCTAssertTrue(model.connected)
        XCTAssertFalse(model.connecting)
        XCTAssertTrue(model.accountDisplay.hasPrefix("new ·"))
        XCTAssertEqual(model.directory.map(\.username), ["new"])
        XCTAssertEqual(model.channels.map(\.name), ["new channel"])
        model.signOutLocally()
    }

    func testBootstrapDoesNotPublishPartialDirectoryWhenLaterReadFails() async throws {
        let started = expectation(description: "Channel request held after user response")
        var held: SessionBoundaryStub?
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.Channel" { held = request; started.fulfill() }
            else { request.standardResponse() }
        }
        let model = model()
        let attempt = Task { await model.connect(using: account("old")) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.directory.isEmpty)
        XCTAssertEqual(model.accountDisplay, "")
        XCTAssertNil(model.userID)
        held?.fail()
        await attempt.value
        XCTAssertFalse(model.connected)
        XCTAssertFalse(model.connecting)
        XCTAssertTrue(model.directory.isEmpty)
        XCTAssertNotNil(model.error)
    }

    func testCancelledBootstrapReturnsToCleanSignedOutState() async throws {
        let started = expectation(description: "Pending request")
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.User" { started.fulfill() }
            else { request.standardResponse() }
        }
        let model = model()
        let attempt = Task { await model.connect(using: account("old")) }
        await fulfillment(of: [started], timeout: 2)
        attempt.cancel()
        await attempt.value
        XCTAssertFalse(model.connected)
        XCTAssertFalse(model.connecting)
        XCTAssertTrue(model.directory.isEmpty)
        XCTAssertEqual(model.accountDisplay, "")
        XCTAssertNil(model.error)
    }

    func testEmojiRecentsRecordOnlyValidReactionAddsAndClearOnSignOut() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model(); await model.connect(using: account("old")); model.liveStatus = .live
        XCTAssertTrue(model.connected)
        // The official queue records selection intent before the RPC. A failed
        // dispatch must not be retried merely to keep a local recent emoji.
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.Post.Reaction" { request.fail() }
            else { request.standardResponse() }
        }
        await model.toggleReaction(try ownPost(), kind: .heart)
        XCTAssertEqual(model.emojiPreferences.recent, [.heart])
        model.emojiPreferences.record(.eyes)
        let existing = try JSONDecoder().decode(ChatPost.self, from: Data(#"{"post_id":100,"channel_id":23,"creator_id":10,"message":"Synthetic","type":"normal","create_at":1000,"reactions":[{"sticker_name":"heart","user_ids":[10]}]}"#.utf8))
        await model.toggleReaction(existing, kind: .heart)
        XCTAssertEqual(model.emojiPreferences.recent, [.eyes, .heart], "Removing a reaction must not promote it in recents")
        model.signOutLocally()
        XCTAssertTrue(model.emojiPreferences.recent.isEmpty)
        await model.toggleReaction(existing, kind: .thumbsUp)
        XCTAssertTrue(model.emojiPreferences.recent.isEmpty)
    }

    func testReactionDetailsReadIsScopedAndRejectsMismatchedPost() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model(); await model.connect(using: account("old"))
        let post = try ownPost()
        XCTAssertTrue(model.canViewReactionDetails(post))
        var mutations = 0
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.Post", request.method == "list" {
                request.respond(#"{"success":true,"data":{"posts":[{"post_id":100,"channel_id":23,"creator_id":10,"type":"normal","create_at":1000,"message":"Synthetic","thread_id":0,"reactions":[{"sticker_name":"heart","user_ids":[10,20]}]}]}}"#)
            } else { mutations += 1; request.standardResponse() }
        }
        let details = try await model.reactionDetails(post)
        XCTAssertEqual(details.people().map(\.id), [10,20]); XCTAssertEqual(mutations, 0)
        SessionBoundaryStub.route = { request in
            request.respond(#"{"success":true,"data":{"posts":[{"post_id":101,"channel_id":23,"creator_id":10,"type":"normal","create_at":1000,"message":"Wrong post"}]}}"#)
        }
        do { _ = try await model.reactionDetails(post); XCTFail("Wrong post must be rejected") } catch { }
        model.signOutLocally(); XCTAssertFalse(model.canViewReactionDetails(post))
    }

    func testReactionDetailsCannotReturnAfterSignOut() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model(); await model.connect(using: account("old"))
        let post = try ownPost(); let started = expectation(description: "Reaction details held")
        var held: SessionBoundaryStub?
        SessionBoundaryStub.route = { request in held = request; started.fulfill() }
        let operation = Task { try await model.reactionDetails(post) }
        await fulfillment(of: [started], timeout: 2)
        model.signOutLocally()
        held?.respond(#"{"success":true,"data":{"posts":[{"post_id":100,"channel_id":23,"creator_id":10,"type":"normal","create_at":1000,"message":"Synthetic"}]}}"#)
        do { _ = try await operation.value; XCTFail("Old account details must be discarded") } catch { }
    }

    private func hashtagPost(_ tags: [[String:Any]], message: String = "Synthetic") -> String {
        let data:[String:Any] = ["success":true,"data":["posts":[["post_id":100,"channel_id":23,"creator_id":10,"type":"normal","create_at":1000,"message":message,"hashtags":["inline"] + tags.compactMap { $0["hashtag"] as? String },"hashtags_additional":tags]]]]
        return String(decoding:try! JSONSerialization.data(withJSONObject:data),as:UTF8.self)
    }
    func testAdditionalTagRoundTripUsesCanonicalStateWithoutEditingBody() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model(); await model.connect(using:account("old"));model.liveStatus = .live;model.selection = 23
        var tags:[[String:Any]] = [];var writes = 0
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.Post",request.method == "list" { request.respond(self.hashtagPost(tags)) }
            else if request.api == "SYNO.Chat.Post.Hashtag" { writes += 1; tags = request.method == "set" ? [["hashtag":"topic","user_id":10]] : [];request.respond(#"{"success":true}"#) }
            else { XCTFail("Unexpected request");request.fail() }
        }
        let source = try await model.postHashtags(try ownPost())
        let added = try await model.changeAdditionalHashtag(source,hashtag:"topic",enabled:true)
        XCTAssertEqual(added.additional.map(\.hashtag),["topic"]);XCTAssertEqual(added.post.message,"Synthetic")
        let removed = try await model.changeAdditionalHashtag(added,hashtag:"topic",enabled:false)
        XCTAssertTrue(removed.additional.isEmpty);XCTAssertEqual(removed.otherIndexed,["inline"])
        XCTAssertEqual(writes,2);XCTAssertTrue(model.pendingMessageActions.isEmpty)
        XCTAssertTrue(model.postHashtagsNeedRefresh.isEmpty);model.signOutLocally()
    }
    func testAdditionalTagExistingAndMissingOutcomesDoNotReplayWrites() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() };let model = model();await model.connect(using:account("old"));model.liveStatus = .live
        var tags:[[String:Any]] = [["hashtag":"topic","user_id":10]];var writes = 0
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.Post" { request.respond(self.hashtagPost(tags)) }
            else { writes += 1;request.fail() }
        }
        let source = try await model.postHashtags(try ownPost())
        _ = try await model.changeAdditionalHashtag(source,hashtag:"topic",enabled:true)
        tags = [];_ = try await model.changeAdditionalHashtag(source,hashtag:"topic",enabled:false)
        XCTAssertEqual(writes,0);model.signOutLocally()
    }
    func testAdditionalTagCannotRemoveChangedAttributionOrAlterInlineTag() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() };let model = model();await model.connect(using:account("old"));model.liveStatus = .live
        var tags:[[String:Any]] = [["hashtag":"topic","user_id":10]];var writes = 0
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.Post" { request.respond(self.hashtagPost(tags)) }
            else { writes += 1;request.fail() }
        }
        let source = try await model.postHashtags(try ownPost());tags = [["hashtag":"topic","user_id":20]]
        do { _ = try await model.changeAdditionalHashtag(source,hashtag:"topic",enabled:false);XCTFail() } catch { }
        do { _ = try await model.changeAdditionalHashtag(source,hashtag:"inline",enabled:true);XCTFail() } catch { }
        XCTAssertEqual(writes,0);XCTAssertTrue(model.postHashtagsNeedRefresh.isEmpty);model.signOutLocally()
    }
    func testUncertainAdditionalTagWriteBlocksUntilExplicitFreshRead() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() };let model = model();await model.connect(using:account("old"));model.liveStatus = .live
        var tags:[[String:Any]] = [];var writes = 0
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.Post" { request.respond(self.hashtagPost(tags)) }
            else if request.api == "SYNO.Chat.Post.Hashtag" { writes += 1;tags = [["hashtag":"topic","user_id":10]];request.fail() }
            else { request.fail() }
        }
        let source = try await model.postHashtags(try ownPost())
        do { _ = try await model.changeAdditionalHashtag(source,hashtag:"topic",enabled:true);XCTFail() } catch { }
        XCTAssertTrue(model.postHashtagsNeedRefresh.contains(100))
        do { _ = try await model.changeAdditionalHashtag(source,hashtag:"topic",enabled:true);XCTFail() } catch { }
        XCTAssertEqual(writes,1)
        let refreshed = try await model.postHashtags(try ownPost());XCTAssertEqual(refreshed.additional.count,1)
        XCTAssertTrue(model.postHashtagsNeedRefresh.isEmpty);model.signOutLocally()
    }
    func testAdditionalTagLateWriteCannotPublishAfterSignOut() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() };let model = model();await model.connect(using:account("old"));model.liveStatus = .live
        let started = expectation(description:"Tag write held");var held:SessionBoundaryStub?
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.Post" { request.respond(self.hashtagPost([])) }
            else { held = request;started.fulfill() }
        }
        let source = try await model.postHashtags(try ownPost())
        let operation = Task { try await model.changeAdditionalHashtag(source,hashtag:"topic",enabled:true) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally();held?.respond(#"{"success":true}"#)
        do { _ = try await operation.value;XCTFail() } catch { }
        XCTAssertTrue(model.postHashtagsNeedRefresh.isEmpty);XCTAssertTrue(model.posts.isEmpty)
    }
    func testAdditionalTagReadOnlyStatesCannotWrite() async throws {
        let model = model();let post = try ownPost();XCTAssertFalse(model.canViewPostHashtags(post))
        SessionBoundaryStub.route = { $0.standardResponse() };await model.connect(using:account("old"));model.liveStatus = .rejected
        XCTAssertTrue(model.canViewPostHashtags(post));XCTAssertFalse(model.canChangePostHashtags(post))
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":23,"type":"private","encrypted":true,"name":"locked","unread":0}"#.utf8))]
        XCTAssertFalse(model.canViewPostHashtags(post));model.signOutLocally()
    }

    func testConnectionResyncPublishesOnlyCurrentAccountAndRejectsLatePreRecoveryRead() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() };let model = model();await model.connect(using:account("old"));model.selection = 23
        let watch = UUID();model.watchCollection(watch,channelID:nil)
        var recovered:[Int] = [];var published = 0;var held:SessionBoundaryStub?
        let recovery = model.collectionResyncs.sink { recovered.append($0) }
        let changes = model.collectionChanges.sink { if case .updated = $0.state { published += 1 } }
        defer { recovery.cancel();changes.cancel();model.signOutLocally() }
        model.channels.append(try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":24,"name":"Other synthetic","type":"private","encrypted":false,"unread":0}"#.utf8)))
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.Post",request.postID == 200 { held = request }
            else { request.standardResponse() }
        }
        model.handleLiveEvent(.init(name:"client.post.set",payload:.object(["channel_id":.integer(24),"post_id":.integer(200)])))
        for _ in 0..<100 where held == nil { await Task.yield() }
        XCTAssertNotNil(held)
        let epoch = model.accountGeneration;model.resyncAfterConnection();XCTAssertEqual(recovered,[epoch])
        held?.respond(#"{"success":true,"data":{"posts":[{"post_id":200,"channel_id":24,"creator_id":10,"message":"Old transport result","type":"normal","create_at":1000}]}}"#)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(published,0)
        model.signOutLocally();model.resyncAfterConnection();XCTAssertEqual(recovered,[epoch])
    }
    func testReminderSourceNavigationRequiresBothReadableContextsAndRejectsDeletedOrigin() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() };let model = model();await model.connect(using:account("old"));model.selection = 23
        let copy = try JSONDecoder().decode(ChatPost.self,from:Data(#"{"post_id":500,"channel_id":23,"creator_id":10,"message":"Personal reminder copy","type":"normal","create_at":2000,"props":{"forward":{"type":"reminder","origin_channel_id":24,"origin_post_id":200,"origin_user_id":10,"origin_thread_id":0}}}"#.utf8))
        XCTAssertFalse(model.canOpenReminderSource(copy))
        model.channels.append(try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":24,"name":"Synthetic origin","type":"private","encrypted":false,"unread":0}"#.utf8)))
        XCTAssertTrue(model.canOpenReminderSource(copy));model.openReminderSource(copy);XCTAssertEqual(model.selection,24)
        model.selection = 23
        model.handleLiveEvent(.init(name:"client.post.delete",payload:.object(["channel_id":.integer(24),"post_id":.integer(200)])))
        XCTAssertFalse(model.canOpenReminderSource(copy));model.openReminderSource(copy);XCTAssertEqual(model.selection,23);model.signOutLocally()
    }
    private func otherCollectionPost(starred: Bool = true) throws -> ChatPost {
        try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:["post_id":200,"channel_id":24,"creator_id":10,"message":"Other synthetic source","type":"normal","create_at":1000,"is_star":starred,"url_props":[["url":"https://example.test/synthetic"]]]))
    }
    private func collectionChannels() -> String { #"{"success":true,"data":{"channels":[{"channel_id":23,"name":"Selected","type":"private","encrypted":false,"unread":0},{"channel_id":24,"name":"Other synthetic","type":"private","encrypted":false,"unread":0}]}}"# }
    func testGlobalCollectionReceivesOtherChannelUpdatesWithoutChangingTimeline() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() };let model = model();await model.connect(using:account("old"));model.selection = 23;model.posts = [try ownPost()]
        model.channels.append(try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":24,"name":"Other synthetic","type":"private","encrypted":false,"unread":0}"#.utf8)))
        var reads = 0;var updates:[Int64] = []
        let subscription = model.collectionChanges.sink { if case .updated(let post) = $0.state { updates.append(post.id) } }
        defer { subscription.cancel();model.signOutLocally() }
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.Channel" { request.respond(self.collectionChannels()) }
            else if request.api == "SYNO.Chat.Post" { reads += 1;request.respond(#"{"success":true,"data":{"posts":[{"post_id":200,"channel_id":24,"creator_id":10,"message":"Other synthetic source","type":"normal","create_at":1000,"is_star":true}]}}"#) }
            else { request.standardResponse() }
        }
        let scoped = UUID();model.watchCollection(scoped,channelID:23)
        let event = ChatLiveEvent(name:"client.post.update",payload:.object(["channel_id":.integer(24),"post_id":.integer(200)]))
        model.handleLiveEvent(event);for task in Array(model.eventTasks.values) { await task.value };XCTAssertEqual(reads,0)
        model.stopWatchingCollection(scoped);let global = UUID();model.watchCollection(global,channelID:nil)
        model.handleLiveEvent(event);for task in Array(model.eventTasks.values) { await task.value }
        XCTAssertEqual(reads,1);XCTAssertTrue(updates.contains(200));XCTAssertEqual(model.posts.map(\.id),[100]);XCTAssertEqual(model.selection,23)
        model.stopWatchingCollection(global)
        model.handleLiveEvent(event);for task in Array(model.eventTasks.values) { await task.value };XCTAssertEqual(reads,1)
    }
    func testOtherChannelLocalBookmarkReadbackPublishesCollectionChange() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() };let model = model();await model.connect(using:account("old"));model.selection = 23;model.liveStatus = .live;model.posts = [try ownPost()]
        model.channels.append(try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":24,"name":"Other synthetic","type":"private","encrypted":false,"unread":0}"#.utf8)))
        var updated = false
        let subscription = model.collectionChanges.sink { if case .updated(let post) = $0.state, post.id == 200 { updated = post.is_star == false } }
        defer { subscription.cancel();model.signOutLocally() }
        SessionBoundaryStub.route = { request in
            if request.method == "unstar" { request.respond(#"{"success":true}"#) }
            else if request.api == "SYNO.Chat.Post" { request.respond(#"{"success":true,"data":{"posts":[{"post_id":200,"channel_id":24,"creator_id":10,"message":"Other synthetic source","type":"normal","create_at":1000,"is_star":false}]}}"#) }
            else { request.standardResponse() }
        }
        let changed = await model.setBookmark(try otherCollectionPost(),enabled:false)
        XCTAssertTrue(changed);XCTAssertTrue(updated);XCTAssertEqual(model.posts.map(\.id),[100])
    }
    func testOtherChannelDeletionIsPublishedAndCannotRemainReadableFromCachedSource() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() };let model = model();await model.connect(using:account("old"));model.selection = 23
        model.channels.append(try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":24,"name":"Other synthetic","type":"private","encrypted":false,"unread":0}"#.utf8)))
        let post = try otherCollectionPost();XCTAssertTrue(model.canViewReactionDetails(post));var deleted = false
        let subscription = model.collectionChanges.sink { if case .deleted = $0.state, $0.postID == 200, $0.channelID == 24 { deleted = true } }
        defer { subscription.cancel();model.signOutLocally() }
        model.handleLiveEvent(.init(name:"client.post.delete",payload:.object(["channel_id":.integer(24),"post_id":.integer(200)])))
        XCTAssertTrue(deleted);XCTAssertFalse(model.canViewReactionDetails(post));XCTAssertEqual(model.selection,23)
    }

    func testLateReactionFailureCannotOverwriteSignedOutStatus() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model()
        await model.connect(using: account("old"))
        XCTAssertTrue(model.connected)
        model.liveStatus = .live
        let started = expectation(description: "Reaction request held")
        var held: SessionBoundaryStub?
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.Post.Reaction" { held = request; started.fulfill() }
            else { request.standardResponse() }
        }
        let post = try JSONDecoder().decode(ChatPost.self, from: Data(#"{"post_id":100,"channel_id":23,"creator_id":10,"message":"Synthetic","type":"normal","create_at":1000}"#.utf8))
        let operation = Task { await model.toggleThumbsUp(post) }
        await fulfillment(of: [started], timeout: 2)
        model.signOutLocally()
        model.error = "Newer account status"
        held?.fail()
        await operation.value
        XCTAssertEqual(model.error, "Newer account status")
        XCTAssertFalse(model.connected)
    }

    func testLateSuccessfulReactionDoesNotFetchPostFromInvalidatedSession() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model()
        await model.connect(using: account("old"))
        model.liveStatus = .live
        let started = expectation(description: "Reaction request held")
        var held: SessionBoundaryStub?
        var postReads = 0
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.Post.Reaction" { held = request; started.fulfill() }
            else { if request.api == "SYNO.Chat.Post" { postReads += 1 }; request.standardResponse() }
        }
        let post = try ownPost()
        let operation = Task { await model.toggleThumbsUp(post) }
        await fulfillment(of: [started], timeout: 2)
        model.signOutLocally()
        held?.respond(#"{"success":true}"#)
        await operation.value
        XCTAssertEqual(postReads, 0)
        XCTAssertNil(model.error)
    }

    func testLateEditAndDeletionFailuresCannotReplaceNewerStatus() async throws {
        for deleting in [false, true] {
            SessionBoundaryStub.route = { $0.standardResponse() }
            let model = model()
            await model.connect(using: account("old"))
            model.liveStatus = .live;model.selection = 23
            let started = expectation(description: "Author action held")
            var held: SessionBoundaryStub?
            SessionBoundaryStub.route = { request in
                if request.api == "SYNO.Chat.Post" { held = request; started.fulfill() }
                else { request.standardResponse() }
            }
            let post = try ownPost()
            let operation = Task {
                if deleting { await model.delete(post) }
                else { _ = await model.edit(post, text: "Synthetic edit") }
            }
            await fulfillment(of: [started], timeout: 2)
            model.signOutLocally()
            model.error = "Newer account status"
            held?.fail()
            await operation.value
            XCTAssertEqual(model.error, "Newer account status")
        }
    }

    func testManualReconnectClearsOldThreadSurfaceButKeepsSameAccountDrafts() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model()
        await model.connect(using: account("old"))
        model.selection = 23
        model.draft = "Synthetic main draft"
        model.threadRoot = try ownPost()
        model.replyDraft = "Synthetic reply draft"
        model.beginMessageEditing(owner: UUID())
        await model.connect(using: account("old"))
        XCTAssertFalse(model.isEditingMessage)
        XCTAssertNil(model.threadRoot)
        XCTAssertTrue(model.replies.isEmpty)
        XCTAssertEqual(model.drafts[23], "Synthetic main draft")
        XCTAssertEqual(model.threadDrafts[100], "Synthetic reply draft")
        XCTAssertTrue(model.connected)
        model.signOutLocally()
    }

    func testPendingReactionBlocksConflictingWritesAndFailureAllowsRetry() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model()
        await model.connect(using: account("old"))
        model.liveStatus = .live
        let started = expectation(description: "Reaction held")
        var held: SessionBoundaryStub?
        var writes = 0
        SessionBoundaryStub.route = { request in
            writes += 1; held = request; started.fulfill()
        }
        let post = try ownPost()
        let first = Task { await model.toggleThumbsUp(post) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.pendingMessageActions, [post.id])
        await model.toggleThumbsUp(post)
        await model.delete(post)
        let edited = await model.edit(post, text: "Conflicting edit")
        XCTAssertFalse(edited)
        XCTAssertEqual(writes, 1, "Only one mutation of this message may be in flight")
        held?.fail()
        await first.value
        XCTAssertTrue(model.pendingMessageActions.isEmpty)
        XCTAssertNotNil(model.error)
        let retried = expectation(description: "Retry sent")
        SessionBoundaryStub.route = { request in held = request; retried.fulfill() }
        let retry = Task { await model.delete(post) }
        await fulfillment(of: [retried], timeout: 2)
        XCTAssertEqual(model.pendingMessageActions, [post.id])
        held?.respond(#"{"success":true}"#)
        await retry.value
        XCTAssertNil(model.error, "A successful retry must not retain the previous failure warning")
        XCTAssertTrue(model.pendingMessageActions.isEmpty)
        model.signOutLocally()
    }

    func testDifferentMessagesCanMutateWhileAnotherMessageIsPending() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model()
        await model.connect(using: account("old"))
        model.liveStatus = .live
        let started = expectation(description: "Both independent requests held")
        started.expectedFulfillmentCount = 2
        var held: [SessionBoundaryStub] = []
        SessionBoundaryStub.route = { request in held.append(request); started.fulfill() }
        let firstPost = try ownPost()
        let secondPost = try JSONDecoder().decode(ChatPost.self, from: Data(#"{"post_id":101,"channel_id":23,"creator_id":10,"message":"Other","type":"normal","create_at":1000}"#.utf8))
        let first = Task { await model.delete(firstPost) }
        let second = Task { await model.delete(secondPost) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.pendingMessageActions, [100, 101])
        for request in held { request.respond(#"{"success":true}"#) }
        await first.value; await second.value
        XCTAssertTrue(model.pendingMessageActions.isEmpty)
        model.signOutLocally()
    }

    func testOldActionCleanupCannotReleaseNewAccountMessageLock() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model()
        await model.connect(using: account("old"))
        model.liveStatus = .live
        let oldStarted = expectation(description: "Old action held")
        var oldRequest: SessionBoundaryStub?
        SessionBoundaryStub.route = { request in oldRequest = request; oldStarted.fulfill() }
        let post = try ownPost()
        let old = Task { await model.delete(post) }
        await fulfillment(of: [oldStarted], timeout: 2)
        model.signOutLocally()
        XCTAssertTrue(model.pendingMessageActions.isEmpty)
        SessionBoundaryStub.route = { $0.standardResponse() }
        await model.connect(using: account("new"))
        model.liveStatus = .live
        let newStarted = expectation(description: "New action held")
        var newRequest: SessionBoundaryStub?
        SessionBoundaryStub.route = { request in newRequest = request; newStarted.fulfill() }
        let newer = Task { await model.delete(post) }
        await fulfillment(of: [newStarted], timeout: 2)
        model.error = "New account status"
        oldRequest?.fail()
        await old.value
        XCTAssertEqual(model.pendingMessageActions, [post.id])
        XCTAssertEqual(model.error, "New account status")
        newRequest?.respond(#"{"success":true}"#)
        await newer.value
        XCTAssertTrue(model.pendingMessageActions.isEmpty)
        model.signOutLocally()
    }

    func testEditFailurePreservesMessageAndRetryPublishesCanonicalContent() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model()
        await model.connect(using: account("old"))
        model.liveStatus = .live
        model.selection = 23
        let original = try ownPost()
        model.posts = [original]
        model.threadRoot = original
        SessionBoundaryStub.route = { $0.fail() }
        let failed = await model.edit(original, text: "Changed")
        XCTAssertFalse(failed)
        XCTAssertEqual(model.posts.first?.message, "Synthetic")
        XCTAssertEqual(model.threadRoot?.message, "Synthetic")
        XCTAssertNotNil(model.error)
        var reads = 0
        SessionBoundaryStub.route = { request in
            if request.method == "list" {
                reads += 1
                if reads == 1 { request.respond(self.postResponse("Synthetic")) }
                else { request.respond(#"{"success":true,"data":{"posts":[{"post_id":100,"channel_id":23,"creator_id":10,"message":"Changed","type":"normal","create_at":1000,"update_at":2000}]}}"#) }
            } else { request.respond(#"{"success":true}"#) }
        }
        let succeeded = await model.edit(original, text: "Changed")
        XCTAssertTrue(succeeded)
        XCTAssertEqual(reads, 2,"Original preflight followed by confirmed submitted content")
        XCTAssertEqual(model.posts.first?.message, "Changed")
        XCTAssertEqual(model.threadRoot?.message, "Changed")
        XCTAssertNil(model.error)
        XCTAssertTrue(model.pendingMessageActions.isEmpty)
        model.signOutLocally()
    }

    func testDeletingReplyRefreshesCanonicalRootWithoutLosingOtherReplies() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model()
        await model.connect(using: account("old"))
        model.liveStatus = .live
        model.selection = 23
        let root = try ownPost()
        let reply = try JSONDecoder().decode(ChatPost.self, from: Data(#"{"post_id":101,"channel_id":23,"creator_id":10,"message":"Reply","type":"normal","create_at":1001,"thread_id":100}"#.utf8))
        let other = try JSONDecoder().decode(ChatPost.self, from: Data(#"{"post_id":102,"channel_id":23,"creator_id":20,"message":"Other reply","type":"normal","create_at":1002,"thread_id":100}"#.utf8))
        model.posts = [root]; model.threadRoot = root; model.replies = [reply, other]
        let refreshed = expectation(description: "Canonical thread header requested")
        SessionBoundaryStub.route = { request in
            if request.method == "list" {
                request.respond(#"{"success":true,"data":{"posts":[{"post_id":100,"channel_id":23,"creator_id":10,"message":"Synthetic","type":"normal","create_at":1000,"comment_count":1}]}}"#)
                refreshed.fulfill()
            } else { request.respond(#"{"success":true}"#) }
        }
        await model.delete(reply)
        await fulfillment(of: [refreshed], timeout: 2)
        for _ in 0..<100 where model.threadRoot?.comment_count != 1 { await Task.yield() }
        XCTAssertEqual(model.replies.map(\.id), [102])
        XCTAssertEqual(model.threadRoot?.comment_count, 1)
        XCTAssertEqual(model.posts.first?.comment_count, 1)
        model.signOutLocally()
    }

    func testMessageEditorOwnsSendShortcutWithoutLosingComposerDrafts() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model()
        await model.connect(using: account("old"))
        model.liveStatus = .live; model.selection = 23
        model.threadRoot = try ownPost()
        model.draft = "Unsent main draft"; model.replyDraft = "Unsent reply draft"
        XCTAssertTrue(model.canSend); XCTAssertTrue(model.canReply)
        let first = UUID(), second = UUID()
        model.beginMessageEditing(owner: first)
        XCTAssertFalse(model.canSend); XCTAssertFalse(model.canReply)
        model.beginMessageEditing(owner: second)
        model.endMessageEditing(owner: first)
        XCTAssertEqual(model.activeMessageEditor, second, "Old row cleanup cannot release a newer editor's shortcut")
        model.endMessageEditing(owner: second)
        XCTAssertTrue(model.canSend); XCTAssertTrue(model.canReply)
        XCTAssertEqual(model.draft, "Unsent main draft")
        XCTAssertEqual(model.replyDraft, "Unsent reply draft")
        model.beginMessageEditing(owner: first)
        model.signOutLocally()
        XCTAssertFalse(model.isEditingMessage)
    }

    private var postUpdate: ChatLiveEvent {
        .init(name: "client.post.update", payload: .object(["channel_id": .integer(23), "post_id": .integer(100)]))
    }
    private func postResponse(_ message: String) -> String {
        "{\"success\":true,\"data\":{\"posts\":[{\"post_id\":100,\"channel_id\":23,\"creator_id\":10,\"message\":\"\(message)\",\"type\":\"normal\",\"create_at\":1000}]}}"
    }

    func testOlderLiveRefreshCannotOverwriteNewerMessageOrPublishLateFailure() async throws {
        for failOlder in [false, true] {
            SessionBoundaryStub.route = { $0.standardResponse() }
            let model = model()
            await model.connect(using: account("old"))
            model.selection = 23; model.posts = [try ownPost()]; model.error = nil
            let firstStarted = expectation(description: "First live refresh held")
            let secondStarted = expectation(description: "Second live refresh held")
            var first: SessionBoundaryStub?, second: SessionBoundaryStub?
            var reads = 0
            SessionBoundaryStub.route = { request in
                if request.api == "SYNO.Chat.Post" {
                    reads += 1
                    if reads == 1 { first = request; firstStarted.fulfill() }
                    else { second = request; secondStarted.fulfill() }
                } else { request.standardResponse() }
            }
            model.handleLiveEvent(postUpdate)
            await fulfillment(of: [firstStarted], timeout: 2)
            let older = model.eventTasks
            model.handleLiveEvent(postUpdate)
            await fulfillment(of: [secondStarted], timeout: 2)
            let newer = model.eventTasks.filter { older[$0.key] == nil }
            second?.respond(postResponse("Newest canonical content"))
            for task in newer.values { await task.value }
            XCTAssertEqual(model.posts.first?.message, "Newest canonical content")
            if failOlder { first?.fail() } else { first?.respond(postResponse("Obsolete content")) }
            for task in older.values { await task.value }
            XCTAssertEqual(model.posts.first?.message, "Newest canonical content")
            XCTAssertNil(model.error)
            model.signOutLocally()
        }
    }

    func testConfirmedEditInvalidatesOlderLiveRead() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model()
        await model.connect(using: account("old"))
        model.liveStatus = .live; model.selection = 23; model.posts = [try ownPost()]
        let started = expectation(description: "Old live post read held")
        var held: SessionBoundaryStub?
        var reads = 0,writes = 0
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.Post" {
                if request.method == "list" {
                    reads += 1
                    if reads == 1 { held = request; started.fulfill() }
                    else if reads == 2 { request.respond(self.postResponse("Synthetic")) }
                    else { request.respond(self.postResponse("Confirmed edited content")) }
                } else { if request.method == "set" { writes += 1 };request.respond(#"{"success":true}"#) }
            } else { request.standardResponse() }
        }
        model.handleLiveEvent(postUpdate)
        await fulfillment(of: [started], timeout: 2)
        let tasks = Array(model.eventTasks.values)
        let edited = await model.edit(try ownPost(), text: "Confirmed edited content")
        XCTAssertTrue(edited)
        held?.respond(postResponse("Obsolete pre-edit content"))
        for task in tasks { await task.value }
        XCTAssertEqual(model.posts.first?.message, "Confirmed edited content")
        XCTAssertEqual(reads,3);XCTAssertEqual(writes,1)
        XCTAssertTrue(model.pendingMessageActions.isEmpty)
        model.signOutLocally()
    }

    func testNewerLiveReadSupersedesPendingEditReadback() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model()
        await model.connect(using: account("old"))
        model.liveStatus = .live; model.selection = 23; model.posts = [try ownPost()]
        let editReadStarted = expectation(description: "Confirmed edit readback held")
        let liveReadStarted = expectation(description: "Newer event readback")
        var held: SessionBoundaryStub?
        var reads = 0,writes = 0
        SessionBoundaryStub.route = { request in
            guard request.api == "SYNO.Chat.Post" else { request.standardResponse(); return }
            if request.method == "list" {
                reads += 1
                if reads == 1 { request.respond(self.postResponse("Synthetic")) }
                else if reads == 2 { held = request; editReadStarted.fulfill() }
                else { request.respond(self.postResponse("Newer live canonical content")); liveReadStarted.fulfill() }
            } else { if request.method == "set" { writes += 1 };request.respond(#"{"success":true}"#) }
        }
        let post = try ownPost()
        let editing = Task { await model.edit(post, text: "Older confirmed edit snapshot") }
        await fulfillment(of: [editReadStarted], timeout: 2)
        model.handleLiveEvent(postUpdate)
        await fulfillment(of: [liveReadStarted], timeout: 2)
        let liveReads = Array(model.eventTasks.values)
        for task in liveReads { await task.value }
        held?.respond(postResponse("Older confirmed edit snapshot"))
        let edited = await editing.value
        XCTAssertTrue(edited)
        XCTAssertEqual(model.posts.first?.message, "Newer live canonical content")
        XCTAssertEqual(reads,3);XCTAssertEqual(writes,1)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.pendingMessageActions.isEmpty)
        model.signOutLocally()
    }

    func testOlderThreadHeaderReadCannotRollBackNewReplyCount() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model()
        await model.connect(using: account("old"))
        model.selection = 23
        func response(id: Int64, thread: Int64, count: Int) -> String {
            "{\"success\":true,\"data\":{\"posts\":[{\"post_id\":\(id),\"channel_id\":23,\"creator_id\":10,\"message\":\"Synthetic\",\"type\":\"normal\",\"create_at\":1000,\"thread_id\":\(thread),\"comment_count\":\(count)}]}}"
        }
        let root = try JSONDecoder().decode(ChatPost.self, from: Data(#"{"post_id":50,"channel_id":23,"creator_id":10,"message":"Synthetic","type":"normal","create_at":1000,"comment_count":0}"#.utf8))
        model.posts = [root]; model.threadRoot = root
        let firstStarted = expectation(description: "First header held")
        let secondStarted = expectation(description: "Second header held")
        var first: SessionBoundaryStub?, second: SessionBoundaryStub?
        var headerReads = 0
        SessionBoundaryStub.route = { request in
            guard request.api == "SYNO.Chat.Post" else { request.standardResponse(); return }
            if request.postID == 50 {
                headerReads += 1
                if headerReads == 1 { first = request; firstStarted.fulfill() }
                else { second = request; secondStarted.fulfill() }
            } else { request.respond(response(id: request.postID ?? 0, thread: 50, count: 0)) }
        }
        model.handleLiveEvent(.init(name: "client.post.create", payload: .object(["channel_id": .integer(23), "post_id": .integer(101), "thread_id": .integer(50)])))
        await fulfillment(of: [firstStarted], timeout: 2)
        let older = model.eventTasks
        model.handleLiveEvent(.init(name: "client.post.create", payload: .object(["channel_id": .integer(23), "post_id": .integer(102), "thread_id": .integer(50)])))
        await fulfillment(of: [secondStarted], timeout: 2)
        let newer = model.eventTasks.filter { older[$0.key] == nil }
        second?.respond(response(id: 50, thread: 0, count: 2))
        for task in newer.values { await task.value }
        first?.respond(response(id: 50, thread: 0, count: 1))
        for task in older.values { await task.value }
        XCTAssertEqual(model.threadRoot?.comment_count, 2)
        XCTAssertEqual(model.posts.first?.comment_count, 2)
        XCTAssertEqual(model.replies.map(\.id), [101, 102])
        model.signOutLocally()
    }

    func testLiveDeletionInvalidatesPendingRefreshAndItsLateError() async throws {
        for failRead in [false, true] {
            SessionBoundaryStub.route = { $0.standardResponse() }
            let model = model()
            await model.connect(using: account("old"))
            model.selection = 23; model.posts = [try ownPost()]; model.error = nil
            let started = expectation(description: "Read held before delete event")
            var held: SessionBoundaryStub?
            SessionBoundaryStub.route = { request in
                if request.api == "SYNO.Chat.Post" { held = request; started.fulfill() }
                else { request.standardResponse() }
            }
            model.handleLiveEvent(postUpdate)
            await fulfillment(of: [started], timeout: 2)
            let tasks = Array(model.eventTasks.values)
            model.handleLiveEvent(.init(name: "client.post.delete", payload: postUpdate.payload))
            if failRead { held?.fail() } else { held?.respond(postResponse("Deleted obsolete content")) }
            for task in tasks { await task.value }
            XCTAssertTrue(model.posts.isEmpty)
            XCTAssertNil(model.error)
            model.signOutLocally()
        }
    }

    private func snapshotPost(_ id: Int64, message: String = "Snapshot", thread: Int64 = 0) -> [String: Any] {
        ["post_id": id, "channel_id": 23, "creator_id": 10, "message": message, "type": "normal", "create_at": 1000, "thread_id": thread]
    }
    private func snapshotResponse(_ posts: [[String: Any]]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["success":true,"data":["posts":posts]]), as: UTF8.self)
    }
    private func updateEvent(_ id: Int64, thread: Int64 = 0) -> ChatLiveEvent {
        .init(name: "client.post.update", payload: .object(["channel_id":.integer(23), "post_id":.integer(id), "thread_id":.integer(thread)]))
    }

    func testMainSnapshotPreservesLiveUpdatesAndContextDoesNotAppendUnrelatedPosts() async throws {
        for context in [false, true] {
            SessionBoundaryStub.route = { $0.standardResponse() }
            let model = model(); await model.connect(using: account("old")); model.selection = 23
            let started = expectation(description: "Main snapshot held")
            var held: SessionBoundaryStub?
            SessionBoundaryStub.route = { request in
                guard request.api == "SYNO.Chat.Post" else { request.standardResponse(); return }
                if (request.previousCount ?? 0) > 0 { held = request; started.fulfill() }
                else { request.respond(self.snapshotResponse([self.snapshotPost(request.postID ?? 0, message: "Live canonical")])) }
            }
            if context { model.navigateToMessage(channelID: 23, postID: 100) } else { model.loadSelection() }
            await fulfillment(of: [started], timeout: 2)
            model.handleLiveEvent(updateEvent(100)); model.handleLiveEvent(updateEvent(101))
            for task in Array(model.eventTasks.values) { await task.value }
            model.handleLiveEvent(.init(name: "client.post.delete", payload: updateEvent(102).payload))
            held?.respond(snapshotResponse([snapshotPost(99),snapshotPost(100),snapshotPost(102)]))
            await model.historyTask?.value
            XCTAssertEqual(model.posts.map(\.id), context ? [99,100] : [99,100,101])
            XCTAssertEqual(model.posts.first { $0.id == 100 }?.message, "Live canonical")
            model.signOutLocally()
        }
    }

    func testThreadSnapshotPreservesConcurrentLiveRepliesAndContextRange() async throws {
        for context in [false, true] {
            SessionBoundaryStub.route = { $0.standardResponse() }
            let model = model(); await model.connect(using: account("old")); model.selection = 23
            let root = try ownPost()
            let started = expectation(description: "Thread snapshot held")
            var held: SessionBoundaryStub?
            SessionBoundaryStub.route = { request in
                guard request.api == "SYNO.Chat.Post" else { request.standardResponse(); return }
                if (request.previousCount ?? 0) > 0 { held = request; started.fulfill() }
                else {
                    let id = request.postID ?? 0
                    request.respond(self.snapshotResponse([self.snapshotPost(id, message: "Live canonical", thread: id == 100 ? 0 : 100)]))
                }
            }
            let opening = Task { await model.openThread(root, around: context ? 101 : nil) }
            await fulfillment(of: [started], timeout: 2)
            model.handleLiveEvent(updateEvent(101, thread: 100)); model.handleLiveEvent(updateEvent(103, thread: 100))
            while !model.eventTasks.isEmpty { for task in Array(model.eventTasks.values) { await task.value } }
            model.handleLiveEvent(.init(name: "client.post.delete", payload: updateEvent(102, thread: 100).payload))
            while !model.eventTasks.isEmpty { for task in Array(model.eventTasks.values) { await task.value } }
            held?.respond(snapshotResponse([snapshotPost(101,thread:100),snapshotPost(102,thread:100)]))
            await opening.value
            XCTAssertEqual(model.replies.map(\.id), context ? [101] : [101,103])
            XCTAssertEqual(model.replies.first?.message, "Live canonical")
            model.signOutLocally()
        }
    }

    func testEarlierReplySnapshotCannotOverwriteConcurrentSameTimestampUpdate() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model(); await model.connect(using: account("old")); model.selection = 23
        model.threadRoot = try ownPost()
        model.replies = [try JSONDecoder().decode(ChatPost.self, from: JSONSerialization.data(withJSONObject: snapshotPost(130,thread:100)))]
        model.canLoadOlderReplies = true
        let started = expectation(description: "Older reply snapshot held")
        var held: SessionBoundaryStub?
        SessionBoundaryStub.route = { request in
            guard request.api == "SYNO.Chat.Post" else { request.standardResponse(); return }
            if (request.previousCount ?? 0) > 0 { held = request; started.fulfill() }
            else {
                let id = request.postID ?? 0
                request.respond(self.snapshotResponse([self.snapshotPost(id,message:"Live canonical",thread:id == 100 ? 0 : 100)]))
            }
        }
        let loading = Task { await model.loadOlderReplies() }
        await fulfillment(of: [started], timeout: 2)
        model.handleLiveEvent(updateEvent(120,thread:100))
        while !model.eventTasks.isEmpty { for task in Array(model.eventTasks.values) { await task.value } }
        held?.respond(snapshotResponse([snapshotPost(110,thread:100),snapshotPost(120,thread:100),snapshotPost(130,thread:100)]))
        await loading.value
        XCTAssertEqual(model.replies.map(\.id), [110,120,130])
        XCTAssertEqual(model.replies.first { $0.id == 120 }?.message, "Live canonical")
        model.signOutLocally()
    }

    func testEarlierMainContextPageUsesUpdatesForPreviouslyUnloadedPost() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model(); await model.connect(using: account("old")); model.selection = 23
        model.posts = [try ownPost()]; model.viewingMessageContext = true
        let started = expectation(description: "Older context page held")
        var held: SessionBoundaryStub?
        SessionBoundaryStub.route = { request in
            guard request.api == "SYNO.Chat.Post" else { request.standardResponse(); return }
            if (request.previousCount ?? 0) > 0 { held = request; started.fulfill() }
            else { request.respond(self.snapshotResponse([self.snapshotPost(request.postID ?? 0,message:"Live canonical")])) }
        }
        let loading = Task { await model.loadOlder() }
        await fulfillment(of: [started], timeout: 2)
        model.handleLiveEvent(updateEvent(90))
        for task in Array(model.eventTasks.values) { await task.value }
        XCTAssertEqual(model.posts.map(\.id), [100])
        held?.respond(snapshotResponse([snapshotPost(80),snapshotPost(90),snapshotPost(100)]))
        await loading.value
        XCTAssertEqual(model.posts.map(\.id), [80,90,100])
        XCTAssertEqual(model.posts.first { $0.id == 90 }?.message, "Live canonical")
        model.signOutLocally()
    }

    func testRetainedThreadRootReadCannotRollBackNewerLiveHeaderDuringResync() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model(); await model.connect(using: account("old")); model.selection = 23
        model.threadRoot = try ownPost()
        let started = expectation(description: "Retained root read held")
        var held: SessionBoundaryStub?
        var rootReads = 0
        SessionBoundaryStub.route = { request in
            guard request.api == "SYNO.Chat.Post" else { request.standardResponse(); return }
            if request.threadID != nil { request.respond(self.snapshotResponse([])) }
            else if (request.previousCount ?? 0) > 0 { request.respond(self.snapshotResponse([self.snapshotPost(100)])) }
            else {
                rootReads += 1
                if rootReads == 1 { held = request; started.fulfill() }
                else { request.respond(self.snapshotResponse([self.snapshotPost(100,message:"New live root")])) }
            }
        }
        model.loadSelection(preservingThread: true)
        await fulfillment(of: [started], timeout: 2)
        model.handleLiveEvent(postUpdate)
        for task in Array(model.eventTasks.values) { await task.value }
        held?.respond(snapshotResponse([snapshotPost(100,message:"Obsolete retained root")]))
        await model.historyTask?.value
        XCTAssertEqual(model.threadRoot?.message, "New live root")
        XCTAssertEqual(model.posts.first?.message, "New live root")
        model.signOutLocally()
    }

    private func peopleResponse(_ username: String) -> String {
        "{\"success\":true,\"data\":{\"users\":[{\"user_id\":10,\"username\":\"\(username)\",\"nickname\":\"Self\",\"type\":\"human\",\"human_type\":\"dsm\"},{\"user_id\":20,\"username\":\"peer\",\"nickname\":\"Peer\",\"type\":\"human\",\"human_type\":\"dsm\"}]}}"
    }

    func testMemberReadStopsBeforeDirectoryRequestAfterSignOut() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model(); await model.connect(using: account("old"))
        let started = expectation(description: "Member read held")
        var held: SessionBoundaryStub?
        var directoryReads = 0
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.Channel.Member" { held = request; started.fulfill() }
            else { directoryReads += 1; request.standardResponse() }
        }
        let reading = Task { try await model.conversationMembers(channelID: 23) }
        await fulfillment(of: [started], timeout: 2)
        model.signOutLocally()
        held?.respond(#"{"success":true,"data":{"user_ids":[10,20]}}"#)
        do { _ = try await reading.value; XCTFail("Invalidated member result") } catch is CancellationError { }
        XCTAssertEqual(directoryReads, 0)
    }

    func testConversationOpeningSerializesAndCancellationReleasesBusyState() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model(); await model.connect(using: account("old")); model.liveStatus = .live
        let started = expectation(description: "People read held")
        var requests = 0
        SessionBoundaryStub.route = { _ in requests += 1; started.fulfill() }
        let opening = Task { try await model.startConversation(with: [20]) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.channelManagementBusy)
        do { try await model.startConversation(with: [20]); XCTFail("Duplicate operation must not proceed") } catch { }
        XCTAssertEqual(requests, 1)
        opening.cancel()
        do { try await opening.value; XCTFail("Cancelled picker operation") } catch is CancellationError { }
        XCTAssertFalse(model.channelManagementBusy)
        model.signOutLocally()
    }

    func testOldConversationReadCannotContinueOrClearNewAccountBusyState() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model(); await model.connect(using: account("old")); model.liveStatus = .live
        let oldStarted = expectation(description: "Old people read held")
        var old: SessionBoundaryStub?
        SessionBoundaryStub.route = { request in old = request; oldStarted.fulfill() }
        let first = Task { try await model.startConversation(with: [20]) }
        await fulfillment(of: [oldStarted], timeout: 2)
        model.signOutLocally()
        SessionBoundaryStub.route = { $0.standardResponse() }
        await model.connect(using: account("new")); model.liveStatus = .live
        let newStarted = expectation(description: "New people read held")
        var furtherReads = 0
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.User" { newStarted.fulfill() }
            else { furtherReads += 1; request.standardResponse() }
        }
        let second = Task { try await model.startConversation(with: [20]) }
        await fulfillment(of: [newStarted], timeout: 2)
        old?.respond(peopleResponse("old"))
        do { try await first.value; XCTFail("Old operation must stop") } catch is CancellationError { }
        XCTAssertEqual(furtherReads, 0)
        XCTAssertTrue(model.channelManagementBusy)
        second.cancel()
        do { try await second.value; XCTFail("Cancelled new operation") } catch is CancellationError { }
        XCTAssertFalse(model.channelManagementBusy)
        model.signOutLocally()
    }

    func testEncryptedMemberRemovalWorksWithLockedKeysAndRetainsFreshAuthorityChecks() async throws {
        for scenario in ["confirmed", "revoked", "creator", "absent", "unconfirmed"] {
            SessionBoundaryStub.route = { $0.standardResponse() }
            let model = model(); await model.connect(using: account("old")); model.liveStatus = .live
            var writes = 0, memberReads = 0
            SessionBoundaryStub.route = { request in
                switch request.api {
                case "SYNO.Chat.Misc":
                    request.respond("{\"success\":true,\"data\":{\"acls\":[{\"acl_name\":\"channel_kick\",\"allow\":\(scenario != "revoked")}]}}")
                case "SYNO.Chat.Channel":
                    request.respond("{\"success\":true,\"data\":{\"channels\":[{\"channel_id\":23,\"name\":\"Locked\",\"type\":\"private\",\"encrypted\":true,\"creator_id\":\(scenario == "creator" ? 20 : 10),\"is_joined\":true,\"unread\":0}]}}")
                case "SYNO.Chat.Channel.Member":
                    memberReads += 1
                    let includesPeer = scenario != "absent" && (writes == 0 || scenario == "unconfirmed")
                    request.respond(includesPeer ? #"{"success":true,"data":{"user_ids":[10,20]}}"# : #"{"success":true,"data":{"user_ids":[10]}}"#)
                case "SYNO.Chat.User": request.respond(self.peopleResponse("old"))
                case "SYNO.Chat.Channel.Named":
                    writes += 1
                    XCTAssertEqual(request.method, "kick")
                    request.respond(#"{"success":true}"#)
                default: request.standardResponse()
                }
            }
            do {
                try await model.removeMember(20, channelID:23)
                XCTAssertEqual(scenario, "confirmed")
            } catch {
                XCTAssertNotEqual(scenario, "confirmed", "\(error)")
            }
            XCTAssertEqual(writes, ["confirmed", "unconfirmed"].contains(scenario) ? 1 : 0)
            XCTAssertFalse(model.channelManagementBusy)
            model.signOutLocally()
        }
    }

    func testMembershipPreflightsStopBetweenReadsAfterSessionInvalidation() async throws {
        for holdMembers in [false, true] {
            for removing in [false, true] {
                SessionBoundaryStub.route = { $0.standardResponse() }
                let model = model(); await model.connect(using: account("old")); model.liveStatus = .live
                let started = expectation(description: "Membership preflight held")
                var held: SessionBoundaryStub?
                var followups = 0
                var invalidated = false
                SessionBoundaryStub.route = { request in
                    if invalidated { followups += 1; request.standardResponse(); return }
                    if request.api == (holdMembers ? "SYNO.Chat.Channel.Member" : "SYNO.Chat.Misc") {
                        held = request; started.fulfill()
                    } else if request.api == "SYNO.Chat.Misc" {
                        request.respond(#"{"success":true,"data":{"acls":[{"acl_name":"channel_invite","allow":true},{"acl_name":"channel_kick","allow":true}]}}"#)
                    } else { request.standardResponse() }
                }
                let operation = Task {
                    if removing { try await model.removeMember(20,channelID:23) }
                    else { try await model.inviteMembers([20],channelID:23) }
                }
                await fulfillment(of: [started], timeout: 2)
                invalidated = true; model.signOutLocally()
                held?.respond(holdMembers ? #"{"success":true,"data":{"user_ids":[10,20]}}"# : #"{"success":true,"data":{"acls":[]}}"#)
                do { try await operation.value; XCTFail("Invalidated preflight") } catch is CancellationError { }
                XCTAssertEqual(followups, 0)
                XCTAssertFalse(model.channelManagementBusy)
            }
        }
    }

    func testConfirmedMembershipWriteCannotReadBackThroughOldSession() async throws {
        for removing in [false, true] {
            SessionBoundaryStub.route = { $0.standardResponse() }
            let model = model(); await model.connect(using: account("old")); model.liveStatus = .live
            let started = expectation(description: "Membership write response held")
            var held: SessionBoundaryStub?
            var memberReads = 0
            SessionBoundaryStub.route = { request in
                switch request.api {
                case "SYNO.Chat.Misc": request.respond(#"{"success":true,"data":{"acls":[{"acl_name":"channel_invite","allow":true},{"acl_name":"channel_kick","allow":true}]}}"#)
                case "SYNO.Chat.Channel.Member":
                    memberReads += 1
                    request.respond(removing ? #"{"success":true,"data":{"user_ids":[10,20]}}"# : #"{"success":true,"data":{"user_ids":[10]}}"#)
                case "SYNO.Chat.User": request.respond(self.peopleResponse("old"))
                case "SYNO.Chat.Channel.Named": held = request; started.fulfill()
                default: request.standardResponse()
                }
            }
            let operation = Task {
                if removing { try await model.removeMember(20,channelID:23) }
                else { try await model.inviteMembers([20],channelID:23) }
            }
            await fulfillment(of: [started], timeout: 2)
            XCTAssertEqual(memberReads, 1)
            model.signOutLocally()
            held?.respond(#"{"success":true}"#)
            do { try await operation.value; XCTFail("Old session write completion") } catch is CancellationError { }
            XCTAssertEqual(memberReads, 1, "No follow-up old-session read after confirmed write")
            XCTAssertFalse(model.channelManagementBusy)
            XCTAssertTrue(model.directory.isEmpty)
        }
    }

    func testCreatedChannelCannotJoinAfterSessionChanges() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model(); await model.connect(using: account("old")); model.liveStatus = .live
        let started = expectation(description: "Create response held")
        var held: SessionBoundaryStub?
        var joins = 0
        SessionBoundaryStub.route = { request in
            if request.api == "SYNO.Chat.Misc" { request.respond(#"{"success":true,"data":{"acls":[{"acl_name":"channel_create","allow":true}]}}"#) }
            else if request.api == "SYNO.Chat.Channel.Named" && request.method == "create" { held = request; started.fulfill() }
            else { joins += 1; request.standardResponse() }
        }
        let creating = Task { try await model.createChannel(name:"synthetic-channel",purpose:"",kind:.private) }
        await fulfillment(of: [started], timeout: 2)
        model.signOutLocally()
        held?.respond(#"{"success":true,"data":{"channel_id":123}}"#)
        do { try await creating.value; XCTFail("Must not publish unjoined channel") }
        catch let error as ChatChannelCreatedError { XCTAssertEqual(error.channelID, 123) }
        XCTAssertEqual(joins, 0)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertFalse(model.channelManagementBusy)
    }

    func testSearchCannotReturnPreviousAccountResultsAfterSignOut() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model(); await model.connect(using: account("old"))
        let started = expectation(description: "Search response held")
        var held: SessionBoundaryStub?
        SessionBoundaryStub.route = { request in held = request; started.fulfill() }
        let searching = Task { try await model.searchMessages(query:"synthetic",channelID:23,offset:0) }
        await fulfillment(of: [started], timeout: 2)
        model.signOutLocally()
        held?.respond(#"{"success":true,"data":{"search_results":[],"total":0}}"#)
        do { _ = try await searching.value; XCTFail("Previous session search result") } catch is CancellationError { }
    }

    func testNotificationVisibilityTracksLatestRangeAndExactVisibleThread() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model(); await model.connect(using: account("old")); model.liveStatus = .live; model.selection = 23
        model.updateReadingVisibility(active:true, atBottom:true)
        XCTAssertEqual(model.notificationVisibleLocation?.channelID, 23)
        XCTAssertNil(model.notificationVisibleLocation?.threadID)
        model.viewingMessageContext = true
        XCTAssertNil(model.notificationVisibleLocation, "Old context is not the latest visible timeline")
        model.viewingMessageContext = false
        model.threadRoot = try ownPost()
        XCTAssertNil(model.notificationVisibleLocation)
        model.updateThreadReadingVisibility(active:true, atBottom:true)
        XCTAssertEqual(model.notificationVisibleLocation?.threadID, 100)
        model.threadViewingContext = true
        XCTAssertNil(model.notificationVisibleLocation)
        model.threadViewingContext = false; model.loadingThread = true
        XCTAssertNil(model.notificationVisibleLocation)
        model.loadingThread = false
        model.updateThreadReadingVisibility(active:true,atBottom:false)
        XCTAssertNil(model.notificationVisibleLocation)
        model.updateThreadReadingVisibility(active:true,atBottom:true)
        model.previewDidDisappear()
        XCTAssertNil(model.notificationVisibleLocation)
        model.signOutLocally()
    }

    private func ownPost() throws -> ChatPost {
        try JSONDecoder().decode(ChatPost.self, from: Data(#"{"post_id":100,"channel_id":23,"creator_id":10,"message":"Synthetic","type":"normal","create_at":1000}"#.utf8))
    }

    private func notification(for name: String) throws -> ChatNotificationDestination {
        let scope = try XCTUnwrap(ChatNotificationAccountScope.make(account: account(name), userID: 10))
        return try XCTUnwrap(ChatNotificationDestination(userInfo: ["nativeAccountScope": scope, "nativeChannelID": "23", "nativePostID": "100"]))
    }

    func testColdNotificationOpensOnlyAfterMatchingAccountRestores() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model()
        model.receiveNotification(try notification(for: "old"))
        XCTAssertFalse(model.openPendingNotification())
        await model.connect(using: account("old"))
        model.liveStatus = .live
        XCTAssertTrue(model.openPendingNotification())
        XCTAssertEqual(model.selection, 23)
        XCTAssertFalse(model.openPendingNotification())
        model.signOutLocally()
    }

    func testColdNotificationForOtherAccountCannotOpenSameChannelID() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model()
        // Same NAS/user ID but distinct username represents the same account; use a distinct NAS scope here.
        let foreign = try XCTUnwrap(ChatNotificationDestination(userInfo: ["nativeAccountScope": String(repeating: "f", count: 64), "nativeChannelID": "23", "nativePostID": "100"]))
        model.receiveNotification(foreign)
        await model.connect(using: account("new"))
        model.liveStatus = .live
        XCTAssertFalse(model.openPendingNotification())
        XCTAssertNil(model.selection)
        model.receiveNotification(foreign)
        XCTAssertNil(model.selection)
        model.signOutLocally()
    }

    func testExplicitSignOutDoesNotQueueOldNotificationForNextSignIn() async throws {
        SessionBoundaryStub.route = { $0.standardResponse() }
        let model = model()
        await model.connect(using: account("old"))
        model.signOutLocally()
        model.receiveNotification(try notification(for: "old"))
        await model.connect(using: account("old"))
        model.liveStatus = .live
        XCTAssertFalse(model.openPendingNotification())
        XCTAssertNil(model.selection)
        model.signOutLocally()
    }
}

private final class SessionBoundaryStub: URLProtocol {
    static var route: ((SessionBoundaryStub) -> Void)?
    var api: String { request.url!.lastPathComponent }
    var identity: String { URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "_sid" }?.value ?? "" }
    var method: String? { formFields["method"] }
    var postID: Int64? { formFields["post_id"].flatMap(Int64.init) }
    var threadID: Int64? { formFields["thread_id"].flatMap(Int64.init) }
    var previousCount: Int? { formFields["prev_count"].flatMap(Int.init) }
    private var decodedFields: [String: String]?
    private var formFields: [String: String] {
        if let decodedFields { return decodedFields }
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        let pairs = URLComponents(string: "https://synthetic.test/?" + String(decoding: bytes, as: UTF8.self))?.queryItems ?? []
        let fields = Dictionary(pairs.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        decodedFields = fields
        return fields
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if api == "SYNO.API.Info" { standardResponse() } else { Self.route?(self) }
    }
    func fail() { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
    func standardResponse() {
        let body: String
        switch api {
        case "SYNO.API.Info": body = #"{"success":true,"data":{"SYNO.Chat.User":{"path":"entry.cgi","minVersion":1,"maxVersion":2,"requestFormat":"JSON"},"SYNO.Chat.Channel":{"path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"JSON"},"SYNO.Chat.Misc":{"path":"entry.cgi","minVersion":1,"maxVersion":1,"requestFormat":"JSON"},"SYNO.Chat.Channel.Member":{"path":"entry.cgi","minVersion":1,"maxVersion":1,"requestFormat":"JSON"},"SYNO.Chat.Channel.Named":{"path":"entry.cgi","minVersion":1,"maxVersion":1,"requestFormat":"JSON"},"SYNO.Chat.Channel.Anonymous":{"path":"entry.cgi","minVersion":1,"maxVersion":2,"requestFormat":"JSON"},"SYNO.Chat.Post.Reaction":{"path":"entry.cgi","minVersion":1,"maxVersion":1,"requestFormat":"JSON"},"SYNO.Chat.Post.Hashtag":{"path":"entry.cgi","minVersion":1,"maxVersion":1,"requestFormat":"JSON"},"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"}}}"#
        case "SYNO.Chat.User": body = "{\"success\":true,\"data\":{\"users\":[{\"user_id\":10,\"username\":\"\(identity)\",\"nickname\":\"Synthetic\"}]}}"
        case "SYNO.Chat.Channel": body = "{\"success\":true,\"data\":{\"channels\":[{\"channel_id\":23,\"name\":\"\(identity) channel\",\"type\":\"private\",\"encrypted\":false,\"unread\":0}]}}"
        case "SYNO.Chat.Misc": body = #"{"success":true,"data":{"acls":[]}}"#
        default: body = "{}" // Runtime configuration fails, so these tests never open a real socket.
        }
        respond(body)
    }
    func respond(_ body: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: api == "config" ? 404 : 200,
            httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
