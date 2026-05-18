import XCTest
@testable import SynologyChatNative

final class ServerAddressTests: XCTestCase {
    func testNormalizesHostAndPortToChatLaunchURL() throws {
        let url = try ServerAddress.normalizedChatURL(from: "example.synology.me:5001")
        XCTAssertEqual(url, "https://example.synology.me:5001/?launchApp=SYNO.SDS.Chat.Application")
    }

    func testPreservesExistingChatURL() throws {
        let url = try ServerAddress.normalizedChatURL(from: "https://example.synology.me:5001/?launchApp=SYNO.SDS.Chat.Application#channels/11")
        XCTAssertEqual(url, "https://example.synology.me:5001/?launchApp=SYNO.SDS.Chat.Application#channels/11")
    }

    func testAddsLaunchAppToBaseURL() throws {
        let url = try ServerAddress.normalizedChatURL(from: "https://example.synology.me:5001/")
        XCTAssertEqual(url, "https://example.synology.me:5001/?launchApp=SYNO.SDS.Chat.Application")
    }

    func testNormalizesBareQuickConnectID() throws {
        let url = try ServerAddress.normalizedChatURL(from: "MyQuickConnect")
        XCTAssertEqual(url, "https://quickconnect.to/MyQuickConnect?launchApp=SYNO.SDS.Chat.Application")
    }
}
