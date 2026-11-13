import XCTest
@testable import SynologyChatNative

final class NativeYouTubePlayerPolicyTests:XCTestCase {
    @MainActor func testVideoCheckerUsesSyntheticCanonicalReadsAndNeverRestoresAuthentication() async throws {
        let model = try await NativeYouTubeChecks.makeModel();defer { model.signOutLocally() }
        XCTAssertNil(model.userID);XCTAssertEqual(model.selection,23)
        XCTAssertEqual(model.draft,"Unsent synthetic video-check draft.")
        let post = try XCTUnwrap(model.posts.first),destination = NativeYouTubeChecks.destination
        let review = try model.messageLinkIntent(post,destination:destination,source:.card(0))
        var opened:[URL] = []
        _ = try await model.openMessageLink(review,open:{ opened.append($0);return true })
        XCTAssertEqual(opened,[destination]);XCTAssertEqual(model.selection,23)
        XCTAssertFalse(NativeChatAppConfiguration.automaticallyRestoresSavedSession(bundleID:NativeYouTubeChecks.bundleID))
    }
    func testPlayerRequestContainsOnlyCanonicalVideoAndApplicationIdentity() throws {
        let video = try XCTUnwrap(ChatYouTubeVideo(url:URL(string:"https://youtu.be/M7lc1UVf-VE?t=30s&private_context=never-forward")!))
        let request = NativeYouTubePlayerPolicy.request(for:video)
        XCTAssertEqual(request.url,video.embedURL)
        XCTAssertEqual(request.value(forHTTPHeaderField:"Referer"),NativeYouTubePlayerPolicy.referrer.absoluteString)
        XCTAssertNil(request.value(forHTTPHeaderField:"Cookie"));XCTAssertNil(request.value(forHTTPHeaderField:"Authorization"))
        XCTAssertFalse(request.url!.absoluteString.contains("private_context"))
        XCTAssertEqual(request.cachePolicy,.reloadIgnoringLocalCacheData)
    }
    func testPlayerCannotNavigateToOtherVideosWebsitesFilesOrAppSchemes() throws {
        let video = try XCTUnwrap(ChatYouTubeVideo(url:URL(string:"https://youtu.be/M7lc1UVf-VE")!))
        XCTAssertTrue(NativeYouTubePlayerPolicy.allowsNavigation(video.embedURL,video:video,isMainFrame:true))
        XCTAssertTrue(NativeYouTubePlayerPolicy.allowsNavigation(URL(string:"about:blank")!,video:video,isMainFrame:false))
        for target in ["about:blank","file:///tmp/test","javascript:alert(1)","https://example.test/","https://www.youtube.com/watch?v=M7lc1UVf-VE","https://www.youtube-nocookie.com/embed/abcdefghijk","https://www.youtube-nocookie.com.evil.test/embed/M7lc1UVf-VE","https://user:pass@www.youtube-nocookie.com/embed/M7lc1UVf-VE","http://www.youtube-nocookie.com/embed/M7lc1UVf-VE"] {
            XCTAssertFalse(NativeYouTubePlayerPolicy.allowsNavigation(URL(string:target)!,video:video,isMainFrame:true),target)
        }
    }
}
