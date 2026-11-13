#if DEBUG
import AppKit
import XCTest
@testable import SynologyChatNative

@MainActor final class ChannelSettingsUIFixtureTests:XCTestCase {
    func testBrowserListsLockedEncryptedLeaveButFixtureRejectsMembershipWrite() async throws {
        let model = try await NativeChannelSettingsUIFixture.makeModel()
        defer { model.signOutLocally() }
        let available = try await model.channelDiscovery()
        XCTAssertEqual(available.map(\.id),[97])
        let channel = try XCTUnwrap(model.channels.first { $0.id == 96 })
        XCTAssertFalse(model.encryptionUnlocked)
        XCTAssertTrue(model.canLeaveDiscoveredChannel(channel))
        do { try await model.leaveDiscoveredChannel(channel);XCTFail("Fixture allowed membership mutation") } catch { }
        XCTAssertEqual(NativeChannelSettingsUIFixture.disjoinAttemptCount,1)
        XCTAssertTrue(model.channels.contains { $0.id == 96 })
        XCTAssertEqual(NativeChannelSettingsUIFixture.metadataWriteCount,0)
    }
    func testPublicPreviewFixtureUsesRealReaderWithoutChangingLockedSelectionOrDraft() async throws {
        let model = try await NativeChannelSettingsUIFixture.makeModel()
        defer { model.signOutLocally() }
        let available = try await model.channelDiscovery(),target = try XCTUnwrap(available.first)
        let snapshot = try await model.previewDiscoveredChannel(target)
        XCTAssertEqual(snapshot.posts.map(\.id),[101,102,103,104,105,106])
        XCTAssertEqual(snapshot.posts[1].file_props?.name,"Synthetic-preview.gif")
        XCTAssertEqual(snapshot.posts[2].url_props?.first?.title,"Synthetic link preview")
        let members = try await model.previewChannelMemberIDs(snapshot)
        XCTAssertEqual(members,[10,20])
        let image = try await model.previewChannelThumbnail(snapshot,postID:102)
        XCTAssertEqual(NativeInlineImagePreview.frameCount(image),2)
        XCTAssertEqual(ChatChannelPreviewContent.stickerName(snapshot.posts[3]),"synthetic_smile")
        let sticker = await model.stickers.image("synthetic_smile")
        XCTAssertNotNil(sticker)
        XCTAssertEqual(ChatChannelPreviewContent.poll(snapshot.posts[4])?.choices.count,2)
        XCTAssertEqual(model.previewLinkCards(snapshot,postID:103).count,1)
        let cardImage = try await model.previewChannelLinkAsset(snapshot,postID:103,index:0,asset:.image)
        XCTAssertEqual(cardImage.size.width,32)
        let safeURL = URL(string:"https://example.invalid/synthetic")!
        let safeIntent = try model.previewLinkIntent(snapshot,postID:103,destination:safeURL,source:.message)
        var websiteOpens = 0
        let safeResult = try await model.openPreviewLink(safeIntent,open:{ _ in websiteOpens += 1;return true })
        if case .opened = safeResult { } else { XCTFail("Synthetic safe link did not open") }
        let unsafeURL = URL(string:"https://unsafe.example.invalid/synthetic")!
        let unsafeIntent = try model.previewLinkIntent(snapshot,postID:106,destination:unsafeURL,source:.message)
        let unsafeResult = try await model.openPreviewLink(unsafeIntent,open:{ _ in websiteOpens += 1;return true })
        if case .confirmation = unsafeResult { } else { XCTFail("Synthetic unsafe link lacked confirmation") }
        XCTAssertEqual(websiteOpens,1)

        model.handleLiveEvent(.init(name:"client.setting.update",payload:.object(["hide_post_url_preview":.bool(true)])))
        XCTAssertTrue(model.previewLinkCards(snapshot,postID:103).isEmpty)
        XCTAssertEqual(model.selection,96);XCTAssertEqual(model.draft,"Synthetic settings draft — keep unchanged.")
        XCTAssertFalse(model.encryptionUnlocked);XCTAssertFalse(model.canRead(97))
        XCTAssertEqual(NativeChannelSettingsUIFixture.metadataWriteCount,0)
        XCTAssertEqual(NativeChannelSettingsUIFixture.disjoinAttemptCount,0)
    }
    func testSyntheticPreviewJoinSelectsCanonicalChannelWithoutChangingEncryptedDraft() async throws {
        let model = try await NativeChannelSettingsUIFixture.makeModel()
        defer { model.signOutLocally() }
        let available = try await model.channelDiscovery(),target = try XCTUnwrap(available.first)
        let snapshot = try await model.previewDiscoveredChannel(target)
        let joined = try await model.joinDiscoveredChannel(snapshot.channel)
        XCTAssertEqual(joined.id,97);XCTAssertEqual(model.selection,97)
        XCTAssertEqual(model.drafts[96],"Synthetic settings draft — keep unchanged.")
        XCTAssertEqual(NativeChannelSettingsUIFixture.joinAttemptCount,1)
        XCTAssertEqual(NativeChannelSettingsUIFixture.disjoinAttemptCount,0)
        XCTAssertEqual(NativeChannelSettingsUIFixture.metadataWriteCount,0)
        let refreshed = try await model.channelDiscovery();XCTAssertTrue(refreshed.isEmpty)
        XCTAssertTrue(model.channels.contains { $0.id == 96 })
        XCTAssertFalse(model.encryptionUnlocked)
    }
    func testSyntheticBootstrapLockedPrivateMetadataAndRevokedSystemAuthority() async throws {
        let model = try await NativeChannelSettingsUIFixture.makeModel()
        defer { model.signOutLocally() }
        XCTAssertTrue(model.connected);XCTAssertTrue(model.isVerifiedAdministrator)
        XCTAssertFalse(model.encryptionUnlocked)
        let encrypted = try XCTUnwrap(model.channels.first { $0.id == 96 })
        XCTAssertTrue(model.canEditChannelDetails(encrypted))
        let original = try await model.loadChannelDetails(channelID:96)
        var draft = ChatChannelDetailsDraft(channel:original);draft.purpose = "Updated synthetic plaintext purpose"
        let updated = try await model.saveChannelDetails(original:original,draft:draft)
        XCTAssertEqual(updated.purpose,draft.purpose)
        XCTAssertEqual(updated.channel_key_enc,original.channel_key_enc)
        XCTAssertFalse(model.encryptionUnlocked)
        XCTAssertEqual(model.selection,96)
        XCTAssertEqual(model.draft,"Synthetic settings draft — keep unchanged.")
        XCTAssertEqual(NativeChannelSettingsUIFixture.metadataWriteCount,1)
        let general = try await model.loadChannelDetails(channelID:1)
        XCTAssertTrue(model.canEditChannelDetails(general))
        try await NativeChannelSettingsUIFixture.setSyntheticAdministrator(false,model:model)
        XCTAssertFalse(model.canEditChannelDetails(general))
        XCTAssertTrue(model.canEditChannelDetails(updated))
        draft = ChatChannelDetailsDraft(channel:general);draft.purpose = "Must not be written"
        do { _ = try await model.saveChannelDetails(original:general,draft:draft);XCTFail("Revoked synthetic administrator wrote system details") } catch { }
        XCTAssertEqual(NativeChannelSettingsUIFixture.metadataWriteCount,1)
    }
    func testSyntheticPublicArchiveDeletionAlwaysRejectsAndLeavesPeriodPresent() async throws {
        let model = try await NativeChannelSettingsUIFixture.makeModel()
        defer { model.signOutLocally() }
        let names = try await model.loadArchiveNames(kind:.public)
        XCTAssertEqual(names,["Synthetic public archive"])
        let periods = try await model.loadArchives(kind:.public,name:names[0])
        let archive = try XCTUnwrap(periods.first)
        XCTAssertEqual(archive.id,600)
        let preparation = try await model.prepareArchiveDeletion(archive,kind:.public,name:names[0])
        do { try await model.deleteArchive(preparation);XCTFail("Fixture deletion was accepted") } catch { }
        XCTAssertEqual(NativeChannelSettingsUIFixture.deleteAttemptCount,1)
        let after = try await model.loadArchives(kind:.public,name:names[0])
        XCTAssertEqual(after.map(\.id),[600])
    }
}
#endif
