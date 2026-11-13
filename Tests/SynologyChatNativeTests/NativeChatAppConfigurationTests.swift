import XCTest
@testable import SynologyChatNative

final class NativeChatAppConfigurationTests: XCTestCase {
    func testReleaseAPIAndPreviewOpenNativeWhileOriginalWrapperStaysIndependent() {
        for id in ["com.costwisegroup.synology-chat-native.api", "com.costwisegroup.synology-chat-native.api-preview"] {
            XCTAssertTrue(NativeChatAppConfiguration.isNativeClient(bundleID: id, arguments: []))
        }
        XCTAssertFalse(NativeChatAppConfiguration.isNativeClient(bundleID: "com.costwisegroup.synology-chat-native", arguments: []))
        XCTAssertFalse(NativeChatAppConfiguration.isNativeClient(bundleID: nil, arguments: []))
        XCTAssertTrue(NativeChatAppConfiguration.isNativeClient(bundleID: nil, arguments: ["--native-preview"]))
    }
    func testOnlyNormalAppAutomaticallyReadsSavedKeychainSession() {
        XCTAssertTrue(NativeChatAppConfiguration.automaticallyRestoresSavedSession(bundleID: "com.costwisegroup.synology-chat-native.api"))
        for id in ["com.costwisegroup.synology-chat-native.api-preview", "com.costwisegroup.synology-chat-native", "other"] {
            XCTAssertFalse(NativeChatAppConfiguration.automaticallyRestoresSavedSession(bundleID: id))
        }
        XCTAssertFalse(NativeChatAppConfiguration.automaticallyRestoresSavedSession(bundleID: nil))
    }
    func testNativeMessageViewportNeedsAnExplicitNativeClientOptIn() {
        for id:String? in [nil,"other","com.costwisegroup.synology-chat-native","com.costwisegroup.synology-chat-native.api","com.costwisegroup.synology-chat-native.api-preview"] {
            XCTAssertFalse(NativeChatAppConfiguration.enablesNativeMessageViewport(bundleID:id,arguments:[]))
            XCTAssertEqual(NativeChatAppConfiguration.enablesNativeMessageViewport(bundleID:id,arguments:["--native-message-viewport"]),["com.costwisegroup.synology-chat-native.api","com.costwisegroup.synology-chat-native.api-preview"].contains(id ?? ""))
            XCTAssertTrue(NativeChatAppConfiguration.enablesNativeMessageViewport(bundleID:id,arguments:["--native-preview","--native-message-viewport"]))
        }
        XCTAssertFalse(NativeChatAppConfiguration.enablesNativeMessageViewport(bundleID:"com.costwisegroup.synology-chat-native.api",arguments:["--native-message-viewport=false"]))
    }

    func testOfficialSessionImportIsLimitedToDebugDevelopmentApps() {
        for id: String? in [nil, "com.costwisegroup.synology-chat-native", "com.costwisegroup.synology-chat-native.api-preview", "com.costwisegroup.synology-chat-native.api"] {
            XCTAssertFalse(NativeChatAppConfiguration.allowsOfficialSessionImport(bundleID: id, debugBuild: false))
            XCTAssertEqual(NativeChatAppConfiguration.allowsOfficialSessionImport(bundleID: id, debugBuild: true), id != "com.costwisegroup.synology-chat-native.api")
        }
    }

}
