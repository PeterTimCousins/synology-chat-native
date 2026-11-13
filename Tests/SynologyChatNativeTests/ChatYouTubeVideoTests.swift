import Foundation
import XCTest
@testable import SynologyChatNative

final class ChatYouTubeVideoTests: XCTestCase {
    private let id = "AbC_12-xYz9"
    private func video(_ text: String) -> ChatYouTubeVideo? { URL(string: text).flatMap(ChatYouTubeVideo.init(url:)) }

    func testAcceptedExactHostsAndPathsNormalizeToOneIdentity() throws {
        let expected = try XCTUnwrap(video("https://www.youtube.com/watch?v=\(id)"))
        for host in ["youtube.com", "www.youtube.com", "m.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com"] {
            for path in ["watch?v=\(id)", "embed/\(id)", "v/\(id)", "shorts/\(id)"] {
                for scheme in ["http", "https"] { XCTAssertEqual(video("\(scheme)://\(host)/\(path)"), expected) }
            }
        }
        XCTAssertEqual(video("https://youtu.be/\(id)"), expected)
        XCTAssertEqual(video("https://WWW.YouTube.COM:443/watch?v=\(id)"), expected)
        XCTAssertEqual(video("http://youtube.com:80/embed/\(id)"), expected)
        XCTAssertEqual(expected.id, id); XCTAssertNil(expected.startSeconds)
        XCTAssertEqual(expected.embedURL.absoluteString, "https://www.youtube-nocookie.com/embed/\(id)?autoplay=0&playsinline=1")
        XCTAssertEqual(expected.watchURL.absoluteString, "https://www.youtube.com/watch?v=\(id)")
    }

    func testForeignHostsCredentialsPortsAndPathAmbiguityAreRejected() {
        let rejected = [
            "https://youtube.com.evil.invalid/watch?v=\(id)", "https://evil.invalid/youtube.com/watch?v=\(id)",
            "https://www.youtu.be/\(id)", "https://youtube.com./watch?v=\(id)",
            "https://%79outube.com/watch?v=\(id)", "ftp://youtube.com/watch?v=\(id)",
            "https://user:secret@youtube.com/watch?v=\(id)", "https://user@youtube.com/watch?v=\(id)",
            "https://youtube.com:80/watch?v=\(id)", "http://youtube.com:443/watch?v=\(id)",
            "https://youtube.com:8443/watch?v=\(id)", "https://youtu.be/\(id)/extra", "https://youtu.be/\(id)/",
            "https://youtube.com/watch/?v=\(id)", "https://youtube.com//embed/\(id)",
            "https://youtube.com/Embed/\(id)", "https://youtube.com/embed/\(id)/extra",
            "https://youtube.com/%65mbed/\(id)", "https://youtube.com/watch", "https://youtube.com/watch?v",
            "https://youtube.com/embed/\(id)?v=Different_1", "https://youtube.com/playlist?v=\(id)"
        ]
        for text in rejected { XCTAssertNil(video(text), text) }
    }

    func testVideoIDAndDuplicateQueryInjectionAreRejected() {
        for invalid in ["", "short", id + "x", "AbC_12-xYz!", "AbC_12-xYzé", "AbC_12-xYz%", "AbC_12-xYz9/", "AbC_12-xYz9%00"] {
            XCTAssertNil(video("https://youtu.be/" + invalid), invalid)
            XCTAssertNil(video("https://youtube.com/watch?v=" + invalid), invalid)
        }
        for suffix in ["&v=\(id)", "&v=Different_1", "&%76=\(id)", "&t=1&t=1", "&start=1&start=1"] {
            XCTAssertNil(video("https://youtube.com/watch?v=\(id)" + suffix), suffix)
        }
        XCTAssertNil(video("https://youtube.com/watch?v=\(id)%26autoplay%3D1"))
        XCTAssertNil(video("https://youtube.com/embed/%41bC_12-xYz9"))
    }

    func testBoundedStartTimeAndCanonicalDestinations() throws {
        for (query, seconds) in [("t=123", 123), ("t=123s", 123), ("t=1h2m3s", 3723),
                                  ("t=2m3s", 123), ("t=24h", 86400), ("start=86400", 86400),
                                  ("t=0", 0), ("start=000123", 123), ("start=123&t=2m3s", 123)] {
            let parsed = try XCTUnwrap(video("https://youtu.be/\(id)?\(query)"), query)
            XCTAssertEqual(parsed.startSeconds, seconds, query)
            XCTAssertEqual(parsed.embedURL.absoluteString, "https://www.youtube-nocookie.com/embed/\(id)?autoplay=0&playsinline=1&start=\(seconds)")
            XCTAssertEqual(parsed.watchURL.absoluteString, "https://www.youtube.com/watch?v=\(id)&t=\(seconds)s")
            XCTAssertEqual(video(parsed.watchURL.absoluteString), parsed)
            XCTAssertEqual(video(parsed.embedURL.absoluteString), parsed)
        }
        for query in ["t=", "start=", "t", "start", "t=-1", "start=+1", "t=1.5", "t=1H", "t=1m2h",
                      "t=1s2s", "t=1h2", "t=86401", "t=24h1s", "start=86401", "start=1m", "t=999999999999999999999999999999",
                      "t=1&start=2", "t=1%0A", "t=1%26autoplay=1"] {
            XCTAssertNil(video("https://youtu.be/\(id)?\(query)"), query)
        }
    }

    func testUnrelatedParametersAndFragmentNeverReachCanonicalURLs() throws {
        let parsed = try XCTUnwrap(video("https://youtube.com/watch?v=\(id)&list=private&autoplay=1&origin=https%3A%2F%2Fevil.invalid&_sid=secret&synotoken=secret#t=40&secret=hidden"))
        XCTAssertNil(parsed.startSeconds)
        XCTAssertEqual(parsed.embedURL.absoluteString, "https://www.youtube-nocookie.com/embed/\(id)?autoplay=0&playsinline=1")
        XCTAssertEqual(parsed.watchURL.absoluteString, "https://www.youtube.com/watch?v=\(id)")
    }
}
