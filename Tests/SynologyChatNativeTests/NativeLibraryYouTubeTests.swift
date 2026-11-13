import XCTest
@testable import SynologyChatNative

@MainActor final class NativeLibraryYouTubeTests:XCTestCase {
    private func post(url:String = "https://www.youtube.com/watch?v=M7lc1UVf-VE",hidden:Bool = false,safe:Bool = true) throws -> ChatPost {
        try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:[
            "post_id":5001,"channel_id":23,"creator_id":10,"type":"normal","message":url,"create_at":1794481200000,
            "props":["safe_url":safe],"url_props":[["url":url,"title":"Synthetic library video","hidden":hidden]]
        ]))
    }
    private func model() async throws -> NativeChatPreviewModel {
        let model = try await NativeYouTubeChecks.makeModel()
        addTeardownBlock { @MainActor in model.signOutLocally() }
        return model
    }
    func testExplicitLibraryVideoWorksWithHiddenInlineMetadataOnlyAfterCanonicalReview() async throws {
        let model = try await model(),source = try post(hidden:true),draft = model.draft
        model.posts = [source]
        model.handleLiveEvent(.init(name:"client.broadcast",payload:.object(["type":.string("setting.update"),"data":.object(["hide_post_url_preview":.bool(true)])])))
        let entry = try XCTUnwrap(ChatLinkLibrary.entries([source]).first)
        XCTAssertTrue(model.hidesLinkPreviews);XCTAssertTrue(model.canBrowseLibraryLink(entry))
        XCTAssertThrowsError(try model.messageLinkIntent(source,destination:entry.destination,source:.card(0)))
        let review = try model.messageLinkIntent(source,destination:entry.destination,source:.library(entry.rawURL))
        var presented:[ChatYouTubeVideo] = []
        XCTAssertTrue(presented.isEmpty)
        _ = try await model.openMessageLink(review,open:{ destination in
            guard let parsed = ChatYouTubeVideo(url:destination) else { return false }
            presented.append(parsed);return true
        })
        XCTAssertEqual(presented.map(\.id),["M7lc1UVf-VE"])
        XCTAssertEqual(model.selection,23);XCTAssertEqual(model.draft,draft)
    }
    func testFlaggedLibraryPlayRequiresConfirmationBeforeCreatingAPlayer() async throws {
        let model = try await model(),source = try post(safe:false)
        model.posts = [source]
        let destination = NativeYouTubeChecks.destination
        let review = try model.messageLinkIntent(source,destination:destination,source:.library(destination.absoluteString))
        var opens = 0
        let first = try await model.openMessageLink(review,open:{ _ in opens += 1;return true })
        XCTAssertEqual(opens,0)
        guard case .confirmation(let confirmation) = first else { return XCTFail("Unsafe library playback must be reviewed") }
        _ = try await model.openMessageLink(confirmation,allowUnsafe:true,open:{ _ in opens += 1;return true })
        XCTAssertEqual(opens,1)
    }
    func testCanonicalSourceRetractionPreventsPlaybackDespiteValidCapturedYouTubeURL() async throws {
        let model = try await model()
        let destination = URL(string:"https://www.youtube.com/watch?v=abcdefghijk")!
        let source = try post(url:destination.absoluteString)
        model.posts = [source]
        let review = try model.messageLinkIntent(source,destination:destination,source:.library(destination.absoluteString))
        var opens = 0
        do {
            _ = try await model.openMessageLink(review,open:{ _ in opens += 1;return true })
            XCTFail("The canonical fixture post no longer contains the captured video")
        } catch { }
        XCTAssertEqual(opens,0)
    }
    func testDisconnectedOrMismatchedLibrarySourceCannotCreateAPlayer() async throws {
        let model = try await model(),source = try XCTUnwrap(model.posts.first),destination = NativeYouTubeChecks.destination
        XCTAssertThrowsError(try model.messageLinkIntent(source,destination:destination,source:.library("https://example.test/other")))
        let review = try model.messageLinkIntent(source,destination:destination,source:.library(destination.absoluteString))
        model.connected = false
        var opens = 0
        do { _ = try await model.openMessageLink(review,open:{ _ in opens += 1;return true });XCTFail("Disconnected playback must be refused") }
        catch { }
        XCTAssertEqual(opens,0)
    }
}
