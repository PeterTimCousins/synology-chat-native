import AppKit
import XCTest
@testable import SynologyChatNative

@MainActor final class ChatChannelDiscoveryTests:XCTestCase {
    private func api() async throws -> ChatAPIClient {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [DiscoveryProtocol.self]
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://discovery-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:URLSession(configuration:config))
        try await api.discover();return api
    }
    private func channel(_ fields:[String:Any]) throws -> ChatChannel { try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:fields)) }
    private func model() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(client:try await api(),restoreNotificationPreference:false)
        model.connected = true;model.liveStatus = .live;_ = try await model.channelDiscovery();model.selection = 2
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    override func setUp() { super.setUp();DiscoveryProtocol.reset() }
    override func tearDown() { DiscoveryProtocol.observer = nil;DiscoveryProtocol.held = nil;super.tearDown() }
    func testWireSeparatesUnjoinedListingFromNamedMembershipAndPresenceLeave() async throws {
        let api = try await api();var seen:[String] = []
        DiscoveryProtocol.observer = { fields in
            guard fields["api"] != "SYNO.Chat.Post" else { return };seen.append(fields["method"]!)
            if fields["method"] == "list" { XCTAssertEqual(fields["api"],"SYNO.Chat.Channel");XCTAssertEqual(fields["is_joined"],"false");XCTAssertEqual(fields["version"],"5") }
            else {
                XCTAssertEqual(fields["api"],"SYNO.Chat.Channel.Named");XCTAssertEqual(fields["version"],"1");XCTAssertNil(fields["conn_id"])
                if fields["method"] == "join" { XCTAssertEqual(fields["channel_key_enc"],#""""#) }
            }
        }
        let available = try await api.unjoinedChannels();XCTAssertEqual(available.map(\.id),[97])
        try await api.joinPublicChannel(available[0]);var joined = DiscoveryProtocol.publicChannel;joined["is_joined"] = true
        try await api.disjoinNamedChannel(try channel(joined));XCTAssertEqual(seen,["list","join","disjoin"])
    }
    func testPolicyExcludesGeneralDMPrivateJoinAndEncryptedJoin() throws {
        let publicChannel = try channel(DiscoveryProtocol.publicChannel);XCTAssertTrue(publicChannel.canJoinUnencryptedPublic)
        for fields:[String:Any] in [["channel_id":0],["type":"private"],["encrypted":true],["is_joined":true],["is_closed":true],["hide_global_at":1000]] {
            XCTAssertFalse(try channel(DiscoveryProtocol.publicChannel.merging(fields,uniquingKeysWith:{ _,new in new })).canJoinUnencryptedPublic)
        }
        XCTAssertTrue(try channel(DiscoveryProtocol.joinedChannel).canLeaveNamed)
        for fields:[String:Any] in [["channel_id":1],["type":"anonymous"],["is_joined":false],["is_closed":true]] {
            XCTAssertFalse(try channel(DiscoveryProtocol.joinedChannel.merging(fields,uniquingKeysWith:{ _,new in new })).canLeaveNamed)
        }
    }
    func testUnjoinedListRejectsMissingMembershipFlagsDuplicatesAndNonpositiveIDs() async throws {
        let api = try await api();var missing = DiscoveryProtocol.publicChannel;missing["is_joined"] = nil
        var badID = DiscoveryProtocol.publicChannel;badID["channel_id"] = 0
        for page in [[missing],[badID],[DiscoveryProtocol.publicChannel,DiscoveryProtocol.publicChannel]] {
            DiscoveryProtocol.available = page
            do { _ = try await api.unjoinedChannels();XCTFail("Malformed list accepted") } catch { }
        }
    }
    func testDiscoveryRefreshLoadsACLAndJoinedStateWithoutMembershipWrites() async throws {
        let model = try await model();let values = try await model.channelDiscovery()
        XCTAssertEqual(values.map(\.id),[97]);XCTAssertEqual(model.channels.map(\.id),[2])
        XCTAssertTrue(model.canJoinDiscoveredChannel(values[0]));XCTAssertTrue(model.canLeaveDiscoveredChannel(model.channels[0]));XCTAssertTrue(DiscoveryProtocol.writes.isEmpty)
    }
    func testEncryptedNamedChannelCanBeLeftWithMessageKeysLocked() async throws {
        DiscoveryProtocol.joined = [["channel_id":96,"name":"Synthetic-encrypted","type":"private","encrypted":true,"channel_key_enc":"synthetic-envelope","is_joined":true,"unread":0]]
        let model = try await model()
        let target = try XCTUnwrap(model.channels.first)
        model.selection = target.id
        XCTAssertFalse(model.encryptionUnlocked)
        XCTAssertFalse(model.canRead(target.id))
        XCTAssertTrue(model.canLeaveDiscoveredChannel(target),"Leaving membership must not require decrypting messages")
        DiscoveryProtocol.observer = { fields in
            if fields["method"] == "disjoin" {
                XCTAssertEqual(Set(fields.keys),Set(["api","version","method","channel_id"]))
                XCTAssertEqual(fields["channel_id"],"96")
            }
        }
        try await model.leaveDiscoveredChannel(target)
        XCTAssertEqual(DiscoveryProtocol.writes,["disjoin"])
        XCTAssertFalse(model.channels.contains { $0.id == target.id })
        XCTAssertNil(model.selection)
        XCTAssertFalse(model.encryptionUnlocked)
        XCTAssertFalse(model.canRead(target.id))
    }
    func testEncryptedLeaveRejectsChangedEnvelopeOrEncryptionBeforeDispatch() async throws {
        let original:[String:Any] = ["channel_id":96,"name":"Synthetic-encrypted","type":"private","encrypted":true,"channel_key_enc":"synthetic-envelope","is_joined":true,"unread":0]
        DiscoveryProtocol.joined = [original]
        let model = try await model(),target = try XCTUnwrap(model.channels.first)
        for change:[String:Any] in [["channel_key_enc":"replacement-envelope"],["encrypted":false]] {
            DiscoveryProtocol.joined = [original.merging(change,uniquingKeysWith:{ _,new in new })]
            do { try await model.leaveDiscoveredChannel(target);XCTFail("Stale encrypted scope left channel") } catch { }
        }
        XCTAssertTrue(DiscoveryProtocol.writes.isEmpty)
        XCTAssertTrue(model.unresolvedMembership.isEmpty)
    }
    func testEncryptedLeaveRevocationAndUnconfirmedResultPreserveMembership() async throws {
        DiscoveryProtocol.joined = [["channel_id":96,"name":"Synthetic-encrypted","type":"private","encrypted":true,"channel_key_enc":"synthetic-envelope","is_joined":true,"unread":0]]
        let model = try await model(),target = try XCTUnwrap(model.channels.first)
        DiscoveryProtocol.allowLeave = false
        do { try await model.leaveDiscoveredChannel(target);XCTFail("Revoked encrypted leave dispatched") } catch { }
        XCTAssertTrue(DiscoveryProtocol.writes.isEmpty)
        DiscoveryProtocol.allowLeave = true;DiscoveryProtocol.ignoreWrite = true
        do { try await model.leaveDiscoveredChannel(target);XCTFail("Unconfirmed encrypted leave accepted") } catch let failure as ChatChannelMembershipFailure { XCTAssertTrue(failure.uncertain) }
        XCTAssertTrue(model.channels.contains { $0.id == target.id })
        XCTAssertTrue(model.unresolvedMembership.contains(target.id))
        XCTAssertFalse(model.canLeaveDiscoveredChannel(target))
        do { try await model.leaveDiscoveredChannel(target);XCTFail("Uncertain encrypted leave repeated") } catch { }
        XCTAssertEqual(DiscoveryProtocol.writes,["disjoin"])
    }
    func testEncryptedPublicAndPrivateLeaveWireCarriesOnlyMembershipID() async throws {
        let api = try await api()
        DiscoveryProtocol.observer = { fields in
            XCTAssertEqual(Set(fields.keys),Set(["api","version","method","channel_id"]))
            XCTAssertEqual(fields["api"],"SYNO.Chat.Channel.Named")
            XCTAssertEqual(fields["method"],"disjoin");XCTAssertEqual(fields["version"],"1")
        }
        for type in ["public","private"] {
            try await api.disjoinNamedChannel(try channel(["channel_id":96,"name":"Synthetic-encrypted","type":type,"encrypted":true,"is_joined":true,"unread":0]))
        }
        XCTAssertEqual(DiscoveryProtocol.writes,["disjoin","disjoin"])
    }
    func testPublicPreviewReadsTwentyPostsWithoutChangingActiveConversationOrMembership() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        model.draft = "Keep active draft"
        model.threadRoot = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:previewPost(50,channel:2)))
        model.replyDraft = "Keep reply draft"
        DiscoveryProtocol.previewPosts = [previewPost(102),previewPost(101)]
        var reads = 0
        DiscoveryProtocol.observer = { fields in
            if fields["api"] == "SYNO.Chat.Post" {
                reads += 1
                XCTAssertEqual(fields["method"],"list");XCTAssertEqual(fields["version"],"5")
                XCTAssertEqual(fields["channel_id"],"97");XCTAssertEqual(fields["prev_count"],"20");XCTAssertEqual(fields["next_count"],"0")
                XCTAssertNil(fields["post_id"])
            }
        }
        let value = try await model.previewDiscoveredChannel(target)
        XCTAssertEqual(value.posts.map(\.id),[101,102]);XCTAssertEqual(reads,1)
        XCTAssertEqual(model.selection,2);XCTAssertEqual(model.channels.map(\.id),[2]);XCTAssertTrue(model.posts.isEmpty)
        XCTAssertEqual(model.draft,"Keep active draft");XCTAssertEqual(model.replyDraft,"Keep reply draft")
        XCTAssertTrue(DiscoveryProtocol.writes.isEmpty);XCTAssertFalse(model.canRead(97))
    }
    private func previewPost(_ id:Int,channel:Int = 97)->[String:Any] {
        ["post_id":id,"channel_id":channel,"creator_id":10,"message":"Synthetic **preview**","type":"normal","create_at":1000]
    }
    func testPreviewRejectsMalformedPagesAndUnsupportedScopes() async throws {
        let api = try await api(),target = try channel(DiscoveryProtocol.publicChannel)
        for posts in [[previewPost(1,channel:2)],[previewPost(0)],[previewPost(1),previewPost(1)],(1...21).map { previewPost($0) }] {
            DiscoveryProtocol.previewPosts = posts
            do { _ = try await api.publicChannelPreviewPosts(target);XCTFail("Invalid preview page") } catch ChatAPIError.invalidResponse { }
        }
        var reads = 0;DiscoveryProtocol.observer = { if $0["api"] == "SYNO.Chat.Post" { reads += 1 } }
        for fields:[String:Any] in [["encrypted":true],["type":"private"],["is_joined":true],["is_closed":true]] {
            let invalid = try channel(DiscoveryProtocol.publicChannel.merging(fields,uniquingKeysWith:{ _,new in new }))
            do { _ = try await api.publicChannelPreviewPosts(invalid);XCTFail("Unsupported preview") } catch ChatAPIError.invalidResponse { }
        }
        XCTAssertEqual(reads,0)
    }
    func testPreviewRechecksVisibilityAfterPostReadAndNeverPublishesRevokedScope() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        DiscoveryProtocol.observer = { fields in
            if fields["api"] == "SYNO.Chat.Post" { DiscoveryProtocol.available[0]["encrypted"] = true }
        }
        do { _ = try await model.previewDiscoveredChannel(target);XCTFail("Changed scope published") } catch { }
        XCTAssertEqual(model.selection,2);XCTAssertTrue(model.posts.isEmpty);XCTAssertTrue(DiscoveryProtocol.writes.isEmpty)
    }
    func testSignOutDuringPreviewReadDiscardsOldAccountSnapshotWithoutFurtherReads() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        let started = expectation(description:"Preview read held");DiscoveryProtocol.holdPreview = true
        DiscoveryProtocol.observer = { if $0["api"] == "SYNO.Chat.Post" { started.fulfill() } }
        let task = Task { try await model.previewDiscoveredChannel(target) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally()
        var followups = 0;DiscoveryProtocol.observer = { _ in followups += 1 }
        DiscoveryProtocol.held?.finish(["success":true,"data":["posts":[previewPost(101)]]])
        do { _ = try await task.value;XCTFail("Old account preview published") } catch is CancellationError { }
        XCTAssertEqual(followups,0);XCTAssertTrue(model.posts.isEmpty);XCTAssertTrue(DiscoveryProtocol.writes.isEmpty)
    }
    func testPreviewMemberReaderValidatesCanonicalIDsAndRetainsActiveState() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        let snapshot = try await model.previewDiscoveredChannel(target)
        DiscoveryProtocol.memberIDs = [10,6]
        let ids = try await model.previewChannelMemberIDs(snapshot)
        XCTAssertEqual(ids,[6,10]);XCTAssertEqual(model.selection,2);XCTAssertFalse(model.canRead(97))
        for invalid:[Int64] in [[6,6],[0],[-1]] {
            DiscoveryProtocol.memberIDs = invalid
            do { _ = try await model.previewChannelMemberIDs(snapshot);XCTFail("Invalid membership accepted") } catch ChatAPIError.invalidResponse { }
        }
        DiscoveryProtocol.memberIDs = [6,10]
        DiscoveryProtocol.observer = { if $0["api"] == "SYNO.Chat.Channel.Member" { DiscoveryProtocol.available = [] } }
        do { _ = try await model.previewChannelMemberIDs(snapshot);XCTFail("Revoked scope published") } catch { }
        XCTAssertTrue(DiscoveryProtocol.writes.isEmpty)
    }
    func testPreviewImageUsesCanonicalPostAndBoundedMediumThumbnailWithoutJoining() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        var post = previewPost(101);post["file_props"] = ["is_image":true,"name":"Synthetic.gif"]
        DiscoveryProtocol.previewPosts = [post];DiscoveryProtocol.imageBytes = try NativeSyntheticAnimatedImage.gif()
        let snapshot = try await model.previewDiscoveredChannel(target)
        var imageReads = 0
        DiscoveryProtocol.observer = { fields in
            if fields["api"] == "SYNO.Chat.Post.File" {
                imageReads += 1;XCTAssertEqual(fields["method"],"thumbnail");XCTAssertEqual(fields["version"],"2")
                XCTAssertEqual(fields["post_id"],"101");XCTAssertEqual(fields["type"],#""M""#)
            }
        }
        let image = try await model.previewChannelThumbnail(snapshot,postID:101)
        XCTAssertEqual(NativeInlineImagePreview.frameCount(image),2);XCTAssertEqual(imageReads,1)
        XCTAssertEqual(model.selection,2);XCTAssertTrue(model.posts.isEmpty);XCTAssertFalse(model.canRead(97));XCTAssertTrue(DiscoveryProtocol.writes.isEmpty)
        DiscoveryProtocol.previewPosts[0]["delete_at"] = 1
        do { _ = try await model.previewChannelThumbnail(snapshot,postID:101);XCTFail("Deleted image read") } catch ChatAPIError.invalidResponse { }
        XCTAssertEqual(imageReads,1)
    }
    func testPreviewImageRevokedScopeAndOldAccountCannotPublishOrReadAgain() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        var post = previewPost(101);post["file_props"] = ["is_image":true]
        DiscoveryProtocol.previewPosts = [post];DiscoveryProtocol.imageBytes = try NativeSyntheticAnimatedImage.gif()
        let snapshot = try await model.previewDiscoveredChannel(target)
        DiscoveryProtocol.observer = { if $0["api"] == "SYNO.Chat.Post.File" { DiscoveryProtocol.available[0]["type"] = "private" } }
        do { _ = try await model.previewChannelThumbnail(snapshot,postID:101);XCTFail("Revoked image published") } catch { }
        DiscoveryProtocol.available = [DiscoveryProtocol.publicChannel];model.signOutLocally()
        var reads = 0;DiscoveryProtocol.observer = { _ in reads += 1 }
        do { _ = try await model.previewChannelThumbnail(snapshot,postID:101);XCTFail("Old snapshot reused") } catch is CancellationError { }
        do { _ = try await model.previewChannelMemberIDs(snapshot);XCTFail("Old member snapshot reused") } catch is CancellationError { }
        XCTAssertEqual(reads,0)
    }
    func testSignOutDuringHeldPreviewImageOrMembersDiscardsLateDataWithoutFollowups() async throws {
        for memberRead in [false,true] {
            DiscoveryProtocol.reset()
            let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
            var post = previewPost(101);post["file_props"] = ["is_image":true]
            DiscoveryProtocol.previewPosts = [post];DiscoveryProtocol.imageBytes = try NativeSyntheticAnimatedImage.gif()
            let snapshot = try await model.previewDiscoveredChannel(target)
            DiscoveryProtocol.holdImage = !memberRead;DiscoveryProtocol.holdMembers = memberRead
            let started = expectation(description:"Preview dependent read held")
            DiscoveryProtocol.observer = { if $0["api"] == (memberRead ? "SYNO.Chat.Channel.Member" : "SYNO.Chat.Post.File") { started.fulfill() } }
            let task = Task {
                if memberRead { _ = try await model.previewChannelMemberIDs(snapshot) }
                else { _ = try await model.previewChannelThumbnail(snapshot,postID:101) }
            }
            await fulfillment(of:[started],timeout:2);model.signOutLocally()
            var followups = 0;DiscoveryProtocol.observer = { _ in followups += 1 }
            if memberRead { DiscoveryProtocol.held?.finish(["success":true,"data":["user_ids":[6,10]]]) }
            else { DiscoveryProtocol.held?.finishImage() }
            do { try await task.value;XCTFail("Late dependent preview published") } catch is CancellationError { }
            XCTAssertEqual(followups,0);XCTAssertTrue(model.posts.isEmpty);XCTAssertTrue(DiscoveryProtocol.writes.isEmpty)
        }
    }
    func testReadOnlyPreviewPollAndStickerContentRejectsDeletedOrMalformedData() throws {
        func decode(_ fields:[String:Any]) throws -> ChatPost { try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:previewPost(101).merging(fields,uniquingKeysWith:{ _,new in new }))) }
        XCTAssertEqual(ChatChannelPreviewContent.stickerName(try decode(["type":"sticker","message":":synthetic_smile:"])),"synthetic_smile")
        XCTAssertNil(ChatChannelPreviewContent.stickerName(try decode(["type":"sticker","message":":../unsafe:"])))
        XCTAssertNil(ChatChannelPreviewContent.stickerName(try decode(["type":"sticker","message":":synthetic_smile:","delete_at":1])))
        let choices:[[String:Any]] = [["id":"a","text":"First","count":2],["id":"b","text":"Second","count":1]]
        let poll:[String:Any] = ["state":"open","choices":choices,"options":["multiple":false,"anonymous":true,"add_option":false,"expire_at":0]]
        let valid = try decode(["type":"vote","props":["vote":poll]])
        XCTAssertEqual(ChatChannelPreviewContent.poll(valid)?.choices.map(\.text),["First","Second"])
        var invalid = poll;invalid["choices"] = [choices[0],choices[0]]
        XCTAssertNil(ChatChannelPreviewContent.poll(try decode(["type":"vote","props":["vote":invalid]])))
        XCTAssertNil(ChatChannelPreviewContent.poll(try decode(["type":"vote","props":["vote":poll],"delete_at":1])))
    }
    private func setPreviewCards(_ model:NativeChatPreviewModel,hidden:Bool) {
        model.handleLiveEvent(.init(name:"client.setting.update",payload:.object(["hide_post_url_preview":.bool(hidden)])))
    }
    private func linkPreviewPost() -> [String:Any] {
        previewPost(103).merging(["url_props":[["url":"https://destination.synthetic.invalid/page","title":"Synthetic title","image":"https://images.synthetic.invalid/card.png","favicon":"https://images.synthetic.invalid/icon.png","hidden":false]]],uniquingKeysWith:{ _,new in new })
    }
    func testPublicPreviewCardsRespectLiveGlobalSettingAndSafetyMetadata() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        DiscoveryProtocol.previewPosts = [linkPreviewPost()]
        let snapshot = try await model.previewDiscoveredChannel(target)
        XCTAssertTrue(model.previewLinkCards(snapshot,postID:103).isEmpty)
        setPreviewCards(model,hidden:false)
        XCTAssertEqual(model.previewLinkCards(snapshot,postID:103).map(\.index),[0])
        for fields:[String:Any] in [["props":["safe_url":false]],["props":["encrypted":true]],["delete_at":1],["url_props":[["url":"javascript:alert(1)"]]],["url_props":[["url":"https://safe.synthetic.invalid/","hidden":true]]]] {
            let value = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:linkPreviewPost().merging(fields,uniquingKeysWith:{ _,new in new })))
            let changed = ChatChannelPreviewSnapshot(channel:snapshot.channel,posts:[value],accountGeneration:snapshot.accountGeneration)
            XCTAssertTrue(model.previewLinkCards(changed,postID:103).isEmpty)
        }
        setPreviewCards(model,hidden:true)
        XCTAssertTrue(model.previewLinkCards(snapshot,postID:103).isEmpty)
        XCTAssertEqual(model.selection,2);XCTAssertTrue(model.posts.isEmpty);XCTAssertTrue(DiscoveryProtocol.writes.isEmpty)
    }
    func testPublicPreviewCardImagesAndFaviconsUseOnlyAuthenticatedNASOGRoute() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        DiscoveryProtocol.previewPosts = [linkPreviewPost()];DiscoveryProtocol.imageBytes = try NativeSyntheticAnimatedImage.gif()
        setPreviewCards(model,hidden:false)
        let snapshot = try await model.previewDiscoveredChannel(target)
        var assets:[String] = []
        DiscoveryProtocol.observer = { fields in
            if fields["api"] == "SYNO.Chat.Post.File" {
                XCTAssertEqual(fields["method"],"og");XCTAssertEqual(fields["version"],"2");XCTAssertEqual(fields["post_id"],"103")
                assets.append((try? JSONDecoder().decode(String.self,from:Data((fields["url"] ?? "").utf8))) ?? "invalid")
            }
        }
        let image = try await model.previewChannelLinkAsset(snapshot,postID:103,index:0,asset:.image)
        let favicon = try await model.previewChannelLinkAsset(snapshot,postID:103,index:0,asset:.favicon)
        XCTAssertGreaterThan(image.size.width,0);XCTAssertLessThanOrEqual(favicon.size.width,32)
        XCTAssertEqual(assets,["https://images.synthetic.invalid/card.png","https://images.synthetic.invalid/icon.png"])
        XCTAssertEqual(Set(DiscoveryProtocol.requestedHosts),["discovery-fixture.invalid"])
        XCTAssertEqual(model.selection,2);XCTAssertTrue(model.posts.isEmpty);XCTAssertTrue(DiscoveryProtocol.writes.isEmpty)
    }
    func testChangedCanonicalCardOrDisabledPreferenceStopsImageBeforeTransfer() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        DiscoveryProtocol.previewPosts = [linkPreviewPost()];setPreviewCards(model,hidden:false)
        let snapshot = try await model.previewDiscoveredChannel(target)
        var transfers = 0,total = 0
        DiscoveryProtocol.observer = { fields in total += 1;if fields["api"] == "SYNO.Chat.Post.File" { transfers += 1 } }
        DiscoveryProtocol.previewPosts[0]["url_props"] = [["url":"https://other.synthetic.invalid/","image":"https://images.synthetic.invalid/card.png"]]
        do { _ = try await model.previewChannelLinkAsset(snapshot,postID:103,index:0,asset:.image);XCTFail("Changed destination transferred") } catch ChatAPIError.invalidResponse { }
        XCTAssertEqual(transfers,0)
        setPreviewCards(model,hidden:true);total = 0
        do { _ = try await model.previewChannelLinkAsset(snapshot,postID:103,index:0,asset:.image);XCTFail("Hidden card transferred") } catch ChatAPIError.invalidResponse { }
        XCTAssertEqual(total,0)
    }
    func testHidingLinkPreviewsDuringHeldAssetReadDiscardsImage() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        DiscoveryProtocol.previewPosts = [linkPreviewPost()];DiscoveryProtocol.imageBytes = try NativeSyntheticAnimatedImage.gif()
        setPreviewCards(model,hidden:false)
        let snapshot = try await model.previewDiscoveredChannel(target)
        DiscoveryProtocol.holdImage = true
        let started = expectation(description:"OG image held")
        DiscoveryProtocol.observer = { if $0["api"] == "SYNO.Chat.Post.File" { started.fulfill() } }
        let task = Task { try await model.previewChannelLinkAsset(snapshot,postID:103,index:0,asset:.image) }
        await fulfillment(of:[started],timeout:2);setPreviewCards(model,hidden:true)
        DiscoveryProtocol.held?.finishImage()
        do { _ = try await task.value;XCTFail("Hidden image published") } catch ChatAPIError.invalidResponse { }
        XCTAssertTrue(model.previewLinkCards(snapshot,postID:103).isEmpty);XCTAssertTrue(DiscoveryProtocol.writes.isEmpty)
    }
    func testSignOutDuringHeldPreviewLinkAssetDiscardsImageWithoutFollowupReads() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        DiscoveryProtocol.previewPosts = [linkPreviewPost()];DiscoveryProtocol.imageBytes = try NativeSyntheticAnimatedImage.gif()
        setPreviewCards(model,hidden:false)
        let snapshot = try await model.previewDiscoveredChannel(target)
        DiscoveryProtocol.holdImage = true
        let started = expectation(description:"OG reply held at signout")
        DiscoveryProtocol.observer = { if $0["api"] == "SYNO.Chat.Post.File" { started.fulfill() } }
        let task = Task { try await model.previewChannelLinkAsset(snapshot,postID:103,index:0,asset:.image) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally()
        var followups = 0;DiscoveryProtocol.observer = { _ in followups += 1 }
        DiscoveryProtocol.held?.finishImage()
        do { _ = try await task.value;XCTFail("Old account OG published") } catch is CancellationError { }
        XCTAssertEqual(followups,0);XCTAssertTrue(model.previewLinkCards(snapshot,postID:103).isEmpty)
    }
    func testPreviewWebsiteOpenRevalidatesMessageWithoutJoiningOrChangingDraft() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        let url = URL(string:"https://destination.synthetic.invalid/page")!
        var post = linkPreviewPost();post["message"] = "Read <https://destination.synthetic.invalid/page|the page>"
        DiscoveryProtocol.previewPosts = [post];model.draft = "Keep active draft"
        let snapshot = try await model.previewDiscoveredChannel(target)
        // Hidden metadata does not disable the same literal message link.
        let intent = try model.previewLinkIntent(snapshot,postID:103,destination:url,source:.message)
        var opened:[URL] = []
        let result = try await model.openPreviewLink(intent,open:{ opened.append($0);return true })
        if case .opened = result { } else { XCTFail("Safe message link did not open") }
        XCTAssertEqual(opened,[url]);XCTAssertEqual(model.selection,2);XCTAssertEqual(model.draft,"Keep active draft")
        XCTAssertTrue(model.posts.isEmpty);XCTAssertTrue(DiscoveryProtocol.writes.isEmpty);XCTAssertFalse(model.canRead(97))
    }
    func testPreviewLINERequiresApplicationReviewAndFreshUnsafeReviewWithoutJoining() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        let destination = URL(string:"line://msg/text/Synthetic")!
        var post = linkPreviewPost();post["message"] = "<line://msg/text/Synthetic|Open LINE>";post["props"] = ["safe_url":true]
        DiscoveryProtocol.previewPosts = [post];model.draft = "Keep active draft"
        let snapshot = try await model.previewDiscoveredChannel(target)
        let intent = try model.previewLinkIntent(snapshot,postID:103,destination:destination,source:.message)
        XCTAssertTrue(intent.requiresConfirmation);XCTAssertFalse(intent.flaggedByServer)
        var opened:[URL] = []
        guard case .confirmation(let review) = try await model.openPreviewLink(intent,open:{ opened.append($0);return true }) else { return XCTFail("LINE opened without explicit review") }
        XCTAssertTrue(opened.isEmpty)
        DiscoveryProtocol.previewPosts[0]["props"] = ["safe_url":false]
        guard case .confirmation(let flagged) = try await model.openPreviewLink(review,allowUnsafe:true,open:{ opened.append($0);return true }) else { return XCTFail("Application approval bypassed new unsafe flag") }
        XCTAssertTrue(flagged.flaggedByServer);XCTAssertTrue(opened.isEmpty)
        _ = try await model.openPreviewLink(flagged,allowUnsafe:true,open:{ opened.append($0);return true })
        XCTAssertEqual(opened,[destination]);XCTAssertEqual(model.selection,2);XCTAssertEqual(model.draft,"Keep active draft")
        XCTAssertTrue(DiscoveryProtocol.writes.isEmpty);XCTAssertFalse(model.canRead(97))
        DiscoveryProtocol.previewPosts[0]["message"] = "line://msg/text/Changed"
        do { _ = try await model.openPreviewLink(flagged,allowUnsafe:true,open:{ opened.append($0);return true });XCTFail("Changed application link opened") } catch { }
        XCTAssertEqual(opened,[destination])
    }
    func testPreviewFlaggedWebsiteRequiresExplicitBoundConfirmationAndFreshDestination() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        let url = URL(string:"https://destination.synthetic.invalid/page")!
        var post = linkPreviewPost();post["message"] = url.absoluteString;post["props"] = ["safe_url":false]
        DiscoveryProtocol.previewPosts = [post]
        let snapshot = try await model.previewDiscoveredChannel(target)
        let intent = try model.previewLinkIntent(snapshot,postID:103,destination:url,source:.message)
        var calls = 0
        let first = try await model.openPreviewLink(intent,open:{ _ in calls += 1;return true })
        guard case .confirmation(let review) = first else { return XCTFail("No flagged-link confirmation") }
        XCTAssertTrue(review.requiresConfirmation);XCTAssertEqual(calls,0)
        DiscoveryProtocol.previewPosts[0]["message"] = "https://changed.synthetic.invalid/"
        do { _ = try await model.openPreviewLink(review,allowUnsafe:true,open:{ _ in calls += 1;return true });XCTFail("Edited link opened after confirmation") } catch { }
        XCTAssertEqual(calls,0)
        DiscoveryProtocol.previewPosts = [post]
        let final = try await model.openPreviewLink(review,allowUnsafe:true,open:{ _ in calls += 1;return true })
        if case .opened = final { } else { XCTFail("Confirmed flagged link did not open") }
        XCTAssertEqual(calls,1);XCTAssertTrue(DiscoveryProtocol.writes.isEmpty)
    }
    func testNewSafetyFlagCannotUseAnEarlierSafeReviewAsUnsafeApproval() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        let url = URL(string:"https://destination.synthetic.invalid/page")!
        var post = linkPreviewPost();post["message"] = url.absoluteString;post["props"] = ["safe_url":true]
        DiscoveryProtocol.previewPosts = [post]
        let snapshot = try await model.previewDiscoveredChannel(target)
        let intent = try model.previewLinkIntent(snapshot,postID:103,destination:url,source:.message)
        XCTAssertFalse(intent.requiresConfirmation)
        DiscoveryProtocol.previewPosts[0]["props"] = ["safe_url":false]
        var calls = 0
        let result = try await model.openPreviewLink(intent,allowUnsafe:true,open:{ _ in calls += 1;return true })
        guard case .confirmation(let fresh) = result else { return XCTFail("New safety flag bypassed") }
        XCTAssertTrue(fresh.requiresConfirmation);XCTAssertEqual(calls,0)
    }
    func testPreviewLinkIntentRejectsUnrenderedCodeForeignTargetsAndHiddenCards() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        var post = linkPreviewPost();post["message"] = "```https://fenced.synthetic.invalid/```\n`https://inline.synthetic.invalid/`\n>>> https://quoted.synthetic.invalid/"
        DiscoveryProtocol.previewPosts = [post]
        let snapshot = try await model.previewDiscoveredChannel(target)
        for raw in ["https://fenced.synthetic.invalid/","https://inline.synthetic.invalid/","https://absent.synthetic.invalid/","file:///tmp/private","https://nas.synthetic.invalid/?_sid=synthetic"] {
            do { _ = try model.previewLinkIntent(snapshot,postID:103,destination:URL(string:raw)!,source:.message);XCTFail("Unrendered or invalid target") } catch { }
        }
        _ = try model.previewLinkIntent(snapshot,postID:103,destination:URL(string:"https://quoted.synthetic.invalid/")!,source:.message)
        let card = URL(string:"https://destination.synthetic.invalid/page")!
        do { _ = try model.previewLinkIntent(snapshot,postID:103,destination:card,source:.card(0));XCTFail("Hidden card opened") } catch { }
        setPreviewCards(model,hidden:false)
        _ = try model.previewLinkIntent(snapshot,postID:103,destination:card,source:.card(0))
        var systemPost = post;systemPost["type"] = "system";systemPost["message"] = "https://quoted.synthetic.invalid/"
        let system = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:systemPost))
        XCTAssertTrue(ChatChannelPreviewContent.messageDestinations(system).isEmpty)

        do { _ = try model.previewLinkIntent(snapshot,postID:103,destination:card,source:.message);XCTFail("Metadata-only URL treated as body link") } catch { }
    }
    func testPreviewWebsiteDoesNotOpenAfterScopeRevocationOrSignoutDuringCanonicalRead() async throws {
        for signout in [false,true] {
            DiscoveryProtocol.reset()
            let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
            let url = URL(string:"https://destination.synthetic.invalid/page")!
            var post = linkPreviewPost();post["message"] = url.absoluteString
            DiscoveryProtocol.previewPosts = [post]
            let snapshot = try await model.previewDiscoveredChannel(target)
            let intent = try model.previewLinkIntent(snapshot,postID:103,destination:url,source:.message)
            let started = expectation(description:"Website source read held");DiscoveryProtocol.holdPreview = true
            DiscoveryProtocol.observer = { if $0["api"] == "SYNO.Chat.Post" { started.fulfill() } }
            var calls = 0
            let task = Task { try await model.openPreviewLink(intent,open:{ _ in calls += 1;return true }) }
            await fulfillment(of:[started],timeout:2)
            if signout { model.signOutLocally() } else { DiscoveryProtocol.available = [] }
            DiscoveryProtocol.held?.finish(["success":true,"data":["posts":[post]]])
            do { _ = try await task.value;XCTFail("Revoked website opened") } catch { }
            XCTAssertEqual(calls,0);XCTAssertTrue(DiscoveryProtocol.writes.isEmpty)
        }
    }
    func testPreviewCardWebsiteUsesCanonicalDestinationAndReportsBrowserFailureWithoutRetry() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        DiscoveryProtocol.previewPosts = [linkPreviewPost()];setPreviewCards(model,hidden:false)
        let snapshot = try await model.previewDiscoveredChannel(target)
        let url = URL(string:"https://destination.synthetic.invalid/page")!
        let intent = try model.previewLinkIntent(snapshot,postID:103,destination:url,source:.card(0))
        var calls = 0
        do { _ = try await model.openPreviewLink(intent,open:{ destination in XCTAssertEqual(destination,url);calls += 1;return false });XCTFail("Browser failure ignored") } catch { }
        XCTAssertEqual(calls,1)
        setPreviewCards(model,hidden:true)
        do { _ = try await model.openPreviewLink(intent,open:{ _ in calls += 1;return true });XCTFail("Newly hidden card opened") } catch { }
        XCTAssertEqual(calls,1)
    }
    func testCanonicalJoinOpensChannelAndLeaveRetainsItsDraft() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        let joined = try await model.joinDiscoveredChannel(target);XCTAssertEqual(joined.id,97);XCTAssertEqual(model.selection,97)
        model.draft = "Unsent joined-channel draft"
        try await model.leaveDiscoveredChannel(joined)
        XCTAssertNil(model.selection);XCTAssertEqual(model.drafts[97],"Unsent joined-channel draft");XCTAssertFalse(model.channels.contains(where:{ $0.id == 97 }))
        XCTAssertEqual(DiscoveryProtocol.writes,["join","disjoin"]);XCTAssertFalse(model.channelManagementBusy)
    }
    func testFreshACLRevocationAndChangedChannelFailBeforeWrites() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel)
        DiscoveryProtocol.allowJoin = false
        do { _ = try await model.joinDiscoveredChannel(target);XCTFail("Revoked join dispatched") } catch { }
        DiscoveryProtocol.allowJoin = true;DiscoveryProtocol.available[0]["encrypted"] = true
        do { _ = try await model.joinDiscoveredChannel(target);XCTFail("Changed channel dispatched") } catch { }
        DiscoveryProtocol.allowLeave = false
        do { try await model.leaveDiscoveredChannel(model.channels[0]);XCTFail("Revoked leave dispatched") } catch { }
        XCTAssertTrue(DiscoveryProtocol.writes.isEmpty)
    }
    func testUnconfirmedJoinBlocksRepeatUntilBothMembershipScopesAreRefreshed() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel);DiscoveryProtocol.ignoreWrite = true
        do { _ = try await model.joinDiscoveredChannel(target);XCTFail("No-op join confirmed") } catch let failure as ChatChannelMembershipFailure { XCTAssertTrue(failure.uncertain) }
        XCTAssertTrue(model.unresolvedMembership.contains(97));XCTAssertFalse(model.canJoinDiscoveredChannel(target))
        do { _ = try await model.joinDiscoveredChannel(target);XCTFail("Uncertain join repeated") } catch { }
        XCTAssertEqual(DiscoveryProtocol.writes,["join"])
        _ = try await model.channelDiscovery();XCTAssertTrue(model.unresolvedMembership.isEmpty)
        DiscoveryProtocol.ignoreWrite = false;_ = try await model.joinDiscoveredChannel(target);XCTAssertEqual(model.selection,97)
    }
    func testIgnoredLeaveDoesNotDropLocalMembershipOrDraft() async throws {
        let model = try await model();model.draft = "Keep this draft";DiscoveryProtocol.ignoreWrite = true
        do { try await model.leaveDiscoveredChannel(model.channels[0]);XCTFail("No-op leave confirmed") } catch let failure as ChatChannelMembershipFailure { XCTAssertTrue(failure.uncertain) }
        XCTAssertEqual(model.selection,2);XCTAssertEqual(model.draft,"Keep this draft");XCTAssertEqual(model.channels.count,1);XCTAssertTrue(model.unresolvedMembership.contains(2))
    }
    func testSignOutAfterJoinDispatchDoesNotPublishOldAccountMembership() async throws {
        let model = try await model(),target = try channel(DiscoveryProtocol.publicChannel),started = expectation(description:"Join held");DiscoveryProtocol.holdJoin = true
        DiscoveryProtocol.observer = { if $0["method"] == "join" { started.fulfill() } }
        let task = Task { try await model.joinDiscoveredChannel(target) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally();DiscoveryProtocol.held?.finish(["success":true])
        do { _ = try await task.value;XCTFail("Old membership published") } catch is CancellationError { }
        XCTAssertTrue(model.channels.isEmpty);XCTAssertTrue(model.unresolvedMembership.isEmpty);XCTAssertFalse(model.channelManagementBusy)
    }
    func testOverlappingScopeSnapshotsDoNotPublishFalseMembership() async throws {
        let model = try await model();var duplicate = DiscoveryProtocol.publicChannel;duplicate["is_joined"] = true;DiscoveryProtocol.joined.append(duplicate)
        do { _ = try await model.channelDiscovery();XCTFail("Inconsistent scopes published") } catch ChatAPIError.invalidResponse { }
        XCTAssertEqual(model.channels.map(\.id),[2])
    }
    func testUnsavedEditBlocksJoinAndLeaveWithoutRequests() async throws {
        let model = try await model(),owner = UUID();model.beginMessageEditing(owner:owner)
        XCTAssertFalse(model.canJoinDiscoveredChannel(try channel(DiscoveryProtocol.publicChannel)));XCTAssertFalse(model.canLeaveDiscoveredChannel(model.channels[0]))
        XCTAssertEqual(model.activeMessageEditor,owner);XCTAssertTrue(DiscoveryProtocol.writes.isEmpty)
    }
}

private final class DiscoveryProtocol:URLProtocol {
    static let publicChannel:[String:Any] = ["channel_id":97,"name":"Synthetic-discovery","purpose":"A literal <channel> description 👋","type":"public","encrypted":false,"is_joined":false,"unread":0,"total_member_count":3]
    static let joinedChannel:[String:Any] = ["channel_id":2,"name":"Synthetic-joined","type":"public","encrypted":false,"is_joined":true,"unread":0]
    static var available = [publicChannel],joined = [joinedChannel]
    static var allowJoin = true,allowLeave = true,ignoreWrite = false,holdJoin = false
    static var previewPosts:[[String:Any]] = []
    static var holdPreview = false
    static var memberIDs:[Int64] = []
    static var holdImage = false,holdMembers = false
    static var imageBytes = Data()
    static var requestedHosts:[String] = []
    static var writes:[String] = []
    static var observer:(([String:String])->Void)?
    static var held:DiscoveryProtocol?
    static func reset() { available = [publicChannel];joined = [joinedChannel];allowJoin = true;allowLeave = true;ignoreWrite = false;holdJoin = false;writes = [];previewPosts = [];holdPreview = false;memberIDs = [];imageBytes = Data();requestedHosts = [];holdImage = false;holdMembers = false;observer = nil;held = nil }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        Self.requestedHosts.append(request.url?.host ?? "missing")
        if request.url!.path.contains("SYNO.API.Info") { finish(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.Channel","SYNO.Chat.Channel.Named","SYNO.Chat.Misc","SYNO.Chat.Post","SYNO.Chat.Post.File","SYNO.Chat.Channel.Member"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"] as [String:Any]) })]);return }
        var data = request.httpBody ?? Data()
        if data.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048);while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count);if n <= 0 { break };data.append(contentsOf:buffer.prefix(n)) } }
        var parts = URLComponents();parts.percentEncodedQuery = String(decoding:data,as:UTF8.self)
        var fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last });let api = request.url!.lastPathComponent;fields["api"] = api;let method = fields["method"] ?? ""
        if api == "SYNO.Chat.Channel.Named" {
            Self.writes.append(method)
            let id = Int(fields["channel_id"] ?? "0") ?? 0
            if !Self.ignoreWrite {
                if method == "join",var value = Self.available.first(where:{ $0["channel_id"] as? Int == id }) { Self.available.removeAll { $0["channel_id"] as? Int == id };value["is_joined"] = true;Self.joined.append(value) }
                if method == "disjoin",var value = Self.joined.first(where:{ $0["channel_id"] as? Int == id }) { Self.joined.removeAll { $0["channel_id"] as? Int == id };value["is_joined"] = false;Self.available.append(value) }
            }
            if method == "join",Self.holdJoin { Self.held = self;Self.observer?(fields);return }
            Self.observer?(fields);finish(["success":true]);return
        }
        Self.observer?(fields)
        if api == "SYNO.Chat.Misc" { finish(["success":true,"data":["acls":[["acl_name":"channel_join","allow":Self.allowJoin],["acl_name":"channel_disjoin","allow":Self.allowLeave]]]]);return }
        if api == "SYNO.Chat.Channel.Member" {
            if Self.holdMembers { Self.held = self;return }
            finish(["success":true,"data":["user_ids":Self.memberIDs]]);return }
        if api == "SYNO.Chat.Post.File" {
            if Self.holdImage { Self.held = self;return }
            finishImage();return
        }
        if api == "SYNO.Chat.Post" {
            if Self.holdPreview { Self.held = self;return }
            finish(["success":true,"data":["posts":Self.previewPosts]]);return
        }
        finish(["success":true,"data":["channels":fields["is_joined"] == "false" ? Self.available : Self.joined]])
    }
    func finishImage() {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"image/gif"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Self.imageBytes);client?.urlProtocolDidFinishLoading(self)
    }
    func finish(_ object:[String:Any]) { let data = try! JSONSerialization.data(withJSONObject:object);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
