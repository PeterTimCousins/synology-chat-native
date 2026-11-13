import XCTest
@testable import SynologyChatNative

@MainActor final class NativeCollectionPreviewOwnershipTests:XCTestCase {
    private func image(_ id:Int,channel:Int = 24) throws -> ChatPost {
        try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:[
            "post_id":id,"channel_id":channel,"creator_id":10,"type":"file","message":"Synthetic saved image",
            "create_at":1_700_000_000_000,"file_props":["name":"Synthetic.png","is_image":true,"size":100]
        ]))
    }
    func testCrossConversationPreviewRetainsSelectedDraftAndOtherOwnerCannotCloseIt() async throws {
        let session = try await NativeSearchResultsUIFixture.makeInteractiveSession();defer { session.cleanup() }
        let model = session.model,owner = UUID(),other = UUID(),post = session.documents[0],draft = model.draft
        model.openSearchDocument(post,owner:owner);await model.documentPreviewTask?.value
        XCTAssertEqual(model.searchDocumentOwner,owner);XCTAssertNotNil(model.documentPreviewContent)
        XCTAssertEqual(model.selection,23);XCTAssertEqual(model.draft,draft)
        model.closeCollectionPreviews(owner:other)
        XCTAssertEqual(model.searchDocumentOwner,owner)
        model.closeCollectionPreviews(owner:owner)
        XCTAssertNil(model.searchDocumentOwner);XCTAssertNil(model.documentPreviewPost)
        XCTAssertEqual(model.selection,23);XCTAssertEqual(model.draft,draft)
    }
    func testEverySourceChangeClosesOwnedDocumentButUnrelatedScopesDoNot() async throws {
        let session = try await NativeSearchResultsUIFixture.makeInteractiveSession();defer { session.cleanup() }
        let model = session.model,owner = UUID(),post = session.documents[0]
        for state in [ChatCollectionChange.State.invalidated,.updated(post),.deleted] {
            model.openSearchDocument(post,owner:owner)
            model.closeCollectionPreviews(owner:owner,changed:.init(accountGeneration:model.accountGeneration+1,channelID:post.channel_id,postID:post.id,state:state))
            model.closeCollectionPreviews(owner:owner,changed:.init(accountGeneration:model.accountGeneration,channelID:23,postID:post.id,state:state))
            model.closeCollectionPreviews(owner:owner,changed:.init(accountGeneration:model.accountGeneration,channelID:post.channel_id,postID:post.id+1,state:state))
            XCTAssertEqual(model.searchDocumentOwner,owner)
            model.closeCollectionPreviews(owner:owner,changed:.init(accountGeneration:model.accountGeneration,channelID:post.channel_id,postID:post.id,state:state))
            XCTAssertNil(model.searchDocumentOwner);XCTAssertNil(model.documentPreviewTask)
        }
    }
    func testChangesToAnyLoadedGallerySourceInvalidateCapturedGalleryOnlyForItsOwner() async throws {
        let session = try await NativeSearchResultsUIFixture.makeInteractiveSession();defer { session.cleanup() }
        let model = session.model,owner = UUID(),first = try image(3001),second = try image(3002)
        model.openSearchImage(first,context:[first,second],owner:owner)
        XCTAssertEqual(model.imageViewerCount,2);XCTAssertEqual(model.imageViewerPost?.id,first.id)
        let change = ChatCollectionChange(accountGeneration:model.accountGeneration,channelID:second.channel_id,postID:second.id,state:.invalidated)
        model.closeCollectionPreviews(owner:UUID(),changed:change)
        XCTAssertEqual(model.searchImageOwner,owner)
        model.closeCollectionPreviews(owner:owner,changed:change)
        XCTAssertNil(model.searchImageOwner);XCTAssertEqual(model.imageViewerCount,0);XCTAssertNil(model.imageViewerTask)
        XCTAssertEqual(model.selection,23)
    }
    func testCollectionImageOriginalUsesAttachmentResponseAndRetainsSourceDraft() async throws {
        let session = try await NativeSearchResultsUIFixture.makeInteractiveSession();defer { session.cleanup() }
        let model = session.model,post = try image(3001),draft = model.draft
        model.openSearchImage(post,context:[post],owner:UUID())
        await model.imageViewerTask?.value
        XCTAssertNotNil(model.imageViewerImage);XCTAssertNil(model.imageViewerError)
        model.viewOriginalImage();await model.imageViewerTask?.value
        XCTAssertTrue(model.imageViewerOriginal);XCTAssertNotNil(model.imageViewerImage);XCTAssertNil(model.imageViewerError)
        XCTAssertEqual(model.selection,23);XCTAssertEqual(model.draft,draft)
    }
}
