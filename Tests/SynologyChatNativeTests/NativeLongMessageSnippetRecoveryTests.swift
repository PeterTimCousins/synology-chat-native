import XCTest
@testable import SynologyChatNative

@MainActor final class NativeLongMessageSnippetRecoveryTests:XCTestCase {
    private let longText = "  " + String(repeating:"😀e\u{301}\r\n",count:500) + "\n  "
    private func created(rootID:Int64? = nil,channelID:Int64 = 23,creatorID:Int64 = 10)->ChatPost {
        try! JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:[
            "post_id":1099,"channel_id":channelID,"creator_id":creatorID,"thread_id":rootID ?? 0,
            "type":"file","message":"","create_at":1_700_000_000_000,
            "file_props":["is_snippet":true,"name":"Untitled.txt","id":44]
        ]))
    }
    private func model() async throws -> NativeChatPreviewModel {
        let model = try await NativeTimelineChecks.makeModel()
        addTeardownBlock { @MainActor in model.signOutLocally() }
        return model
    }
    func testUTF16BoundaryAndFullOriginalBytesArePreservedForReview() throws {
        XCTAssertNil(NativeLongMessageSnippetRecovery(text:String(repeating:"😀",count:1000),accountGeneration:4,channelID:23,rootID:nil))
        let recovery = try XCTUnwrap(NativeLongMessageSnippetRecovery(text:longText,accountGeneration:4,channelID:23,rootID:nil))
        XCTAssertEqual(Data(recovery.initialDraft.content.utf8),Data(longText.utf8))
        XCTAssertEqual(recovery.initialDraft.caption,"")
        XCTAssertEqual(recovery.initialDraft.filename,"Untitled.txt")
        XCTAssertTrue(recovery.matches(currentText:longText,accountGeneration:4,channelID:23,rootID:nil))
        XCTAssertFalse(recovery.matches(currentText:longText.precomposedStringWithCanonicalMapping,accountGeneration:4,channelID:23,rootID:nil))
        XCTAssertFalse(recovery.matches(currentText:longText,accountGeneration:5,channelID:23,rootID:nil))
        XCTAssertFalse(recovery.matches(currentText:longText,accountGeneration:4,channelID:24,rootID:nil))
        XCTAssertFalse(recovery.matches(currentText:longText,accountGeneration:4,channelID:23,rootID:1003))
    }
    func testPreparingDoesNotClearMessageOrOverwriteIndependentSnippetDraft() async throws {
        let model = try await model();model.draft = longText
        let key = model.snippetDraftKey(channelID:23,rootID:nil)
        let independent = NativeSnippetDraft(filename:"existing.swift",content:"let x = 1")
        model.snippetDrafts[key] = independent
        let recovery = try XCTUnwrap(model.prepareLongMessageSnippet())
        XCTAssertEqual(Data(recovery.initialDraft.content.utf8),Data(longText.utf8))
        XCTAssertEqual(Data(model.draft.utf8),Data(longText.utf8))
        XCTAssertEqual(model.snippetDrafts[key],independent)
        model.finishLongMessageSnippet(recovery,created:created())
        XCTAssertEqual(model.draft,"")
        XCTAssertEqual(model.snippetDrafts[key],independent)
    }
    func testOnlyConfirmedMatchingSourceIsClearedAndNewerEditsRemain() async throws {
        let model = try await model();model.draft = longText
        let recovery = try XCTUnwrap(model.prepareLongMessageSnippet())
        for wrong in [created(channelID:24),created(creatorID:20),created(rootID:1003)] {
            model.finishLongMessageSnippet(recovery,created:wrong)
            XCTAssertEqual(model.draft,longText)
        }
        model.draft += "New edit"
        model.finishLongMessageSnippet(recovery,created:created())
        XCTAssertEqual(model.draft,longText + "New edit")
    }
    func testThreadConversionClearsOnlyOriginalThreadAndLeavesMainDraft() async throws {
        let model = try await model()
        model.threadRoot = try XCTUnwrap(model.posts.first(where:{ $0.id == 1003 }))
        model.replyDraft = longText;model.draft = "Independent main draft"
        let recovery = try XCTUnwrap(model.prepareLongMessageSnippet(inThread:true))
        XCTAssertEqual(recovery.rootID,1003)
        model.finishLongMessageSnippet(recovery,created:created(rootID:1004))
        XCTAssertEqual(model.replyDraft,longText)
        model.finishLongMessageSnippet(recovery,created:created(rootID:1003))
        XCTAssertEqual(model.replyDraft,"")
        XCTAssertEqual(model.draft,"Independent main draft")
    }
    func testUnconfirmedAttemptSurvivesReopeningAndIsScopedWithoutStoringText() throws {
        let suite = "native-snippet-recovery-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let key = NativeSnippetRecoveryAttempts.key(scope:"account-a",channel:23,root:nil,text:longText)
        XCTAssertFalse(key.contains(longText));XCTAssertFalse(key.contains("account-a"))
        NativeSnippetRecoveryAttempts.markDispatched(key,defaults:defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName:suite))
        XCTAssertTrue(NativeSnippetRecoveryAttempts.needsReview(key,defaults:reopened))
        for other in [NativeSnippetRecoveryAttempts.key(scope:"account-b",channel:23,root:nil,text:longText),
                      NativeSnippetRecoveryAttempts.key(scope:"account-a",channel:24,root:nil,text:longText),
                      NativeSnippetRecoveryAttempts.key(scope:"account-a",channel:23,root:1003,text:longText),
                      NativeSnippetRecoveryAttempts.key(scope:"account-a",channel:23,root:nil,text:longText + "new")] {
            XCTAssertFalse(NativeSnippetRecoveryAttempts.needsReview(other,defaults:reopened))
        }
        NativeSnippetRecoveryAttempts.clearAfterReviewOrSuccess(key,defaults:reopened)
        XCTAssertFalse(NativeSnippetRecoveryAttempts.needsReview(key,defaults:defaults))
    }
    func testEditedThreadSnippetSurvivesPresentationReplacementWithoutOverwritingOtherDrafts() async throws {
        let model = try await model()
        model.threadRoot = try XCTUnwrap(model.posts.first(where:{ $0.id == 1003 }))
        model.replyDraft = longText
        let original = try XCTUnwrap(model.prepareLongMessageSnippet(inThread:true))
        let edited = NativeSnippetDraft(filename:"review.swift",caption:"Kept description",content:longText + "edited")
        model.retainLongMessageSnippet(original,draft:edited)
        model.closeThread()
        model.threadRoot = try XCTUnwrap(model.posts.first(where:{ $0.id == 1003 }))
        let reopened = try XCTUnwrap(model.prepareLongMessageSnippet(inThread:true))
        XCTAssertEqual(reopened.initialDraft,edited)
        XCTAssertEqual(model.replyDraft,longText)
        model.discardLongMessageSnippet(reopened)
        XCTAssertEqual(model.prepareLongMessageSnippet(inThread:true)?.initialDraft.content,longText)
    }
}
