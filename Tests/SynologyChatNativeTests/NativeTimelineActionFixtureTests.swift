#if DEBUG
import AppKit
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeTimelineActionFixtureTests:XCTestCase {
    private func model(actions:Bool = false) async throws -> NativeChatPreviewModel {
        let model = try await NativeTimelineChecks.makeModel(actions:actions)
        addTeardownBlock { @MainActor in NativeTimelineChecks.releaseHeldActionSet();model.signOutLocally() }
        return model
    }
    private func post(_ id:Int64,in model:NativeChatPreviewModel) throws -> ChatPost {
        try XCTUnwrap((model.posts+model.replies).first { $0.id == id })
    }
    private func count(_ key:String)->Int { NativeTimelineChecks.safeActionSnapshot()[key] as? Int ?? -1 }
    private func reactionOwned(_ post:ChatPost,name:String)->Bool {
        (post.reactions ?? []).contains { $0.sticker_name == name && $0.user_ids.contains(10) }
    }
    func testDefaultFixtureRemainsReadOnlyAndRejectsActualModelReaction() async throws {
        let model = try await model(),value = try post(1003,in:model)
        XCTAssertEqual(model.posts.count,7);XCTAssertEqual(NativeTimelineChecks.safeActionSnapshot()["actions_enabled"] as? Bool,false)
        await model.toggleReaction(value,kind:try XCTUnwrap(ChatReactionKind(rawValue:"heart")))
        XCTAssertEqual(count("set_count"),0);XCTAssertEqual(count("reaction_count"),0)
        XCTAssertGreaterThanOrEqual(count("mutation_attempts"),1);XCTAssertGreaterThanOrEqual(count("unknown_mutation_attempts"),1)
        XCTAssertFalse(reactionOwned(try post(1003,in:model),name:"heart"));XCTAssertNotNil(model.error)
    }
    func testEnabledFixtureAddsAndRemovesNonThumbReactionThroughCanonicalReadback() async throws {
        let model = try await model(actions:true),kind = try XCTUnwrap(ChatReactionKind(rawValue:"heart"))
        let draft = model.draft,threadDraft = model.threadDrafts[1003]
        XCTAssertFalse(reactionOwned(try post(1003,in:model),name:"heart"))
        await model.toggleReaction(try post(1003,in:model),kind:kind)
        XCTAssertTrue(reactionOwned(try post(1003,in:model),name:"heart"));XCTAssertNil(model.error)
        await model.toggleReaction(try post(1003,in:model),kind:kind)
        XCTAssertFalse(reactionOwned(try post(1003,in:model),name:"heart"));XCTAssertNil(model.error)
        XCTAssertEqual(count("reaction_count"),2);XCTAssertEqual(count("set_count"),0)
        XCTAssertEqual(NativeTimelineChecks.safeActionSnapshot()["reaction_post_ids"] as? [Int],[1003,1003])
        XCTAssertEqual(model.draft,draft);XCTAssertEqual(model.threadDrafts[1003],threadDraft)
    }
    func testEnabledFixtureOwnedEditPublishesExactBodyWithoutChangingComposerDraft() async throws {
        for id:Int64 in [1003,1102] {
            let model = try await model(actions:true)
            if id == 1102 { await model.openThread(try post(1003,in:model)) }
            let original = try post(id,in:model),owner = UUID()
            let draft = model.draft,threadDraft = model.threadDrafts[1003],text = "Synthetic exact fixture edit e\u{301} 😀\nSecond line."
            model.beginMessageEditing(owner:owner,post:original)
            let session = try XCTUnwrap(model.messageEditorSession(owner:owner))
            let result = await model.edit(original,text:text,owner:owner,session:session)
            XCTAssertTrue(result);XCTAssertNil(model.error);XCTAssertEqual(count("set_count"),1)
            XCTAssertTrue(try post(id,in:model).message.utf8.elementsEqual(text.utf8))
            XCTAssertEqual(model.draft,draft);XCTAssertEqual(model.threadDrafts[1003],threadDraft);XCTAssertEqual(model.activeMessageEditor,owner)
            XCTAssertTrue(model.pendingMessageActions.isEmpty)
        }
    }
    func testHeldSaveIsPendingThenCommitsOnceWithoutPretendingToVerifyUIWorkingState() async throws {
        let model = try await model(actions:true),original = try post(1004,in:model),owner = UUID()
        model.beginMessageEditing(owner:owner,post:original)
        let session = try XCTUnwrap(model.messageEditorSession(owner:owner))
        NativeTimelineChecks.holdNextActionSet()
        let pending = Task { await model.edit(original,text:"Held synthetic edit",owner:owner,session:session) }
        for _ in 0..<100 {
            if NativeTimelineChecks.safeActionSnapshot()["holding_set"] as? Bool == true { break }
            try await Task.sleep(nanoseconds:5_000_000)
        }
        XCTAssertEqual(NativeTimelineChecks.safeActionSnapshot()["holding_set"] as? Bool,true)
        XCTAssertTrue(model.pendingMessageActions.contains(1004));XCTAssertEqual(count("set_count"),0)
        XCTAssertEqual(try post(1004,in:model).message,original.message)
        let duplicate = await model.edit(original,text:"Forbidden duplicate",owner:owner,session:session)
        XCTAssertFalse(duplicate)
        NativeTimelineChecks.releaseHeldActionSet();let result = await pending.value
        XCTAssertTrue(result);XCTAssertEqual(count("set_count"),1);XCTAssertTrue(model.pendingMessageActions.isEmpty)
        XCTAssertEqual(try post(1004,in:model).message,"Held synthetic edit")
    }
    func testSyntheticPNGDecodesAndOriginalViewerUsesStrictFakeFileResponse() async throws {
        let model = try await model(actions:true),imagePost = try post(1008,in:model)
        let thumbnail = await model.thumbnail(for:imagePost)
        XCTAssertEqual(thumbnail?.size,NSSize(width:96,height:64))
        // Avoid an unrelated gallery-history request; the image loader itself
        // still traverses the real model's authenticated fake file endpoints.
        model.threadRoot = imagePost;model.openImage(imagePost)
        for _ in 0..<100 where model.imageViewerLoading { try await Task.sleep(nanoseconds:5_000_000) }
        XCTAssertNil(model.imageViewerError);XCTAssertEqual(model.imageViewerImage?.size,NSSize(width:96,height:64))
        model.viewOriginalImage()
        for _ in 0..<100 where model.imageViewerLoading { try await Task.sleep(nanoseconds:5_000_000) }
        XCTAssertTrue(model.imageViewerOriginal);XCTAssertNil(model.imageViewerError)
        XCTAssertEqual(model.imageViewerImage?.size,NSSize(width:96,height:64));XCTAssertFalse(model.imageViewerLoading)
        XCTAssertEqual(count("set_count"),0);XCTAssertEqual(count("reaction_count"),0)
        model.closeImageViewer()
    }
    func testDisablingActionsRestoresSevenCanonicalPostsAndExactDrafts() async throws {
        let model = try await model(actions:true),draft = model.draft,threadDrafts = model.threadDrafts
        XCTAssertEqual(model.posts.count,8)
        await NativeTimelineChecks.configureActions(model:model,enabled:false)
        XCTAssertEqual(model.posts.map(\.id),Array(Int64(1001)...1007))
        XCTAssertEqual(model.draft,draft);XCTAssertEqual(model.threadDrafts,threadDrafts)
        XCTAssertEqual(NativeTimelineChecks.safeActionSnapshot()["actions_enabled"] as? Bool,false)
        XCTAssertEqual(count("set_count"),0);XCTAssertEqual(count("reaction_count"),0)
    }
}
#endif
