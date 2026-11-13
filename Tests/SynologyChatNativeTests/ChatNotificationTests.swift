import XCTest
@testable import SynologyChatNative

final class ChatNotificationTests: XCTestCase {
    private let scope = String(repeating: "a", count: 64)
    func testClickDestinationPreservesFullWidthIDsAndRejectsInvalidMetadata() {
        let destination = ChatNotificationDestination(userInfo: ["nativeAccountScope": scope, "nativeChannelID": "23", "nativePostID": "9007199254740993", "nativeThreadID": "456"])
        XCTAssertEqual(destination?.postID, 9_007_199_254_740_993)
        XCTAssertEqual(destination?.threadID, 456)
        for values in [ ["nativeChannelID": "0", "nativePostID": "1"],
                        ["nativeChannelID": "23", "nativePostID": "-1"],
                        ["nativeChannelID": "23", "nativePostID": "1", "nativeThreadID": "invalid"],
                        ["nativeChannelID": "23", "nativePostID": "1.5"] ] {
            XCTAssertNil(ChatNotificationDestination(userInfo: values.merging(["nativeAccountScope": scope], uniquingKeysWith: { first, _ in first })))
        }
        XCTAssertNil(ChatNotificationDestination(userInfo: ["nativeAccountScope": scope, "nativeChannelID": "23", "nativePostID": "456", "nativeThreadID": "456"])?.threadID)
    }

    private func event(name: String = "client.broadcast", creator: Int64 = 20, thread: Int64 = 0,
                       message:String = "Private synthetic message",type:String = "normal",filename:String? = nil,reminder:Bool = false) throws -> ChatLiveEvent {
        var post:[String:Any] = ["post_id":9_007_199_254_740_993,"channel_id":23,"creator_id":creator,
            "message":message,"type":type,"create_at":1000,"thread_id":thread]
        if let filename { post["file_props"] = ["name":filename] }
        if reminder { post["props"] = ["forward":["type":"reminder","origin_channel_id":93,"origin_post_id":766,"origin_user_id":10,"origin_thread_id":0,"origin_create_at":1000]] }
        let value = try JSONDecoder().decode(ChatJSON.self,from:JSONSerialization.data(withJSONObject:["type":"notification.create","data":["post":post]]))
        return .init(name:name,payload:value)
    }
    private func preferences(show: Bool = true, active: Bool = false, mute: Bool = false) -> ChatNotificationPreferences {
        .init(notification_showmessage: show, notification_browser_active: active, notification_mute: mute)
    }
    private func render(_ event: ChatLiveEvent, prefs: ChatNotificationPreferences?, visible: Int64? = nil, user: Int64? = 10) -> ChatNotificationMessage? {
        ChatNotificationMessage.make(event: event, preferences: prefs, currentUserID: user,
                                     visibleChannelID: visible, channelTitle: "Synthetic conversation")
    }

    func testEncryptedNotificationNeverUsesRawCiphertextAsPreview() throws {
        let message = ChatNotificationMessage.make(event: try event(), preferences: preferences(), currentUserID: 10,
            visibleChannelID: nil, channelTitle: "Synthetic", contentIsEncrypted: true)
        XCTAssertEqual(message?.body, "Encrypted message")
        XCTAssertFalse(message?.body.contains("Private synthetic") ?? true)
    }

    func testOnlyServerNotificationEventCanDeliver() throws {
        XCTAssertNotNil(render(try event(), prefs: preferences()))
        XCTAssertNil(render(try event(name: "client.post.create"), prefs: preferences()))
        XCTAssertNil(render(try event(creator: 10), prefs: preferences()))
        XCTAssertNil(render(try event(), prefs: preferences(), user: nil))
    }
    func testMissingOrDisabledPreviewSettingsHideMessageAndConversationTitle() throws {
        for prefs in [nil, preferences(show: false)] {
            let message = try XCTUnwrap(render(try event(), prefs: prefs))
            XCTAssertEqual(message.title, "Synology Chat")
            XCTAssertEqual(message.body, "New message")
        }
        let privateReply = try XCTUnwrap(render(try event(thread: 456), prefs: preferences(show: false)))
        XCTAssertEqual(privateReply.body, "New reply")
        XCTAssertEqual(privateReply.threadID, 456)
    }
    func testForegroundAndSoundFollowServerPreferences() throws {
        XCTAssertNil(render(try event(), prefs: preferences(), visible: 23))
        let active = try XCTUnwrap(render(try event(), prefs: preferences(active: true), visible: 23))
        XCTAssertEqual(active.body, "Private synthetic message")
        XCTAssertEqual(active.postID, 9_007_199_254_740_993)
        XCTAssertTrue(active.sound)
        XCTAssertFalse(try XCTUnwrap(render(try event(), prefs: preferences(mute: true))).sound)
        XCTAssertFalse(try XCTUnwrap(render(try event(), prefs: nil)).sound)
    }
    func testVisibleThreadSuppressionOnlyAppliesToThatThreadsReplies() throws {
        func renderVisible(_ event: ChatLiveEvent, thread: Int64?, active: Bool = false) -> ChatNotificationMessage? {
            ChatNotificationMessage.make(event: event, preferences: preferences(active: active), currentUserID: 10,
                visibleChannelID: 23, visibleThreadID: thread, channelTitle: "Synthetic")
        }
        XCTAssertNotNil(renderVisible(try event(thread:456), thread:nil), "Latest main messages do not display a thread reply")
        XCTAssertNil(renderVisible(try event(thread:456), thread:456))
        XCTAssertNotNil(renderVisible(try event(thread:789), thread:456))
        XCTAssertNotNil(renderVisible(try event(), thread:456), "An open thread does not display new main messages")
        XCTAssertNotNil(renderVisible(try event(thread:456), thread:456, active:true))
    }

    func testLocalizedSummariesKeepNormalMessageAndChannelDataVerbatim() throws {
        let resources = try NotificationLocalizationTestResources.bundle(for:self)
        let raw = "New message %@ %n 100% 日本語"
        let channel = "Channel %@ %n 100% 日本語"
        func render(_ event:ChatLiveEvent,show:Bool = true,encrypted:Bool = false,mute:Bool = false) -> ChatNotificationMessage? {
            .make(event:event,preferences:preferences(show:show,mute:mute),currentUserID:10,visibleChannelID:nil,
                channelTitle:channel,contentIsEncrypted:encrypted,personalReminderChannelID:23,language:.german,bundle:resources)
        }
        let normal = try XCTUnwrap(render(event(message:raw)))
        XCTAssertEqual(normal.body,raw);XCTAssertEqual(normal.title,channel)
        XCTAssertEqual(try render(event(type:"file",filename:raw+".txt"))?.body,"Datei geteilt: "+raw+".txt")
        XCTAssertEqual(try render(event(type:"file"))?.body,"Datei geteilt")
        XCTAssertEqual(try render(event(type:"sticker"))?.body,"Sticker gesendet")
        XCTAssertEqual(try render(event(type:"vote"))?.body,"Umfrage erstellt")
        XCTAssertEqual(try render(event(type:"unknown"))?.body,"Neue Aktivität")
        XCTAssertEqual(try render(event(message:raw),encrypted:true)?.body,"Verschlüsselte Nachricht")
        XCTAssertEqual(try render(event(thread:456,message:raw),encrypted:true)?.body,"Verschlüsselte Antwort")
        let hidden = try XCTUnwrap(render(event(message:raw),show:false,mute:true))
        XCTAssertEqual(hidden.body,"Neue Nachricht");XCTAssertEqual(hidden.title,"Synology Chat");XCTAssertFalse(hidden.sound)
        XCTAssertEqual(try render(event(thread:456),show:false)?.body,"Neue Antwort")
        XCTAssertNil(ChatNotificationMessage.make(event:try event(),preferences:preferences(),currentUserID:10,
            visibleChannelID:23,channelTitle:channel,language:.german,bundle:resources))
    }
    func testLocalizedReminderTitleSubstitutesRawChannelNameWithoutLeakingHiddenPreview() throws {
        let resources = try NotificationLocalizationTestResources.bundle(for:self)
        let channel = "Channel %@ %n 100% 日本語"
        let own = try event(creator:10,message:"Reminder payload %@ 日本語",reminder:true)
        let shown = try XCTUnwrap(ChatNotificationMessage.make(event:own,preferences:preferences(),currentUserID:10,
            visibleChannelID:nil,channelTitle:channel,personalReminderChannelID:23,language:.german,bundle:resources))
        XCTAssertEqual(shown.title,"Erinnerung · "+channel);XCTAssertEqual(shown.body,"Reminder payload %@ 日本語")
        let hidden = try XCTUnwrap(ChatNotificationMessage.make(event:own,preferences:preferences(show:false),currentUserID:10,
            visibleChannelID:nil,channelTitle:channel,personalReminderChannelID:23,language:.german,bundle:resources))
        XCTAssertEqual(hidden.title,"Synology Chat");XCTAssertEqual(hidden.body,"Nachrichtenerinnerung")
        XCTAssertNil(ChatNotificationMessage.make(event:own,preferences:preferences(),currentUserID:10,
            visibleChannelID:nil,channelTitle:channel,language:.german,bundle:resources))
    }

}

/// Synthetic catalogs only; shared with typed service-state tests.
enum NotificationLocalizationTestResources {
    static func bundle(for test:XCTestCase) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notification-localization-"+UUID().uuidString+".bundle")
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        let info:[String:Any] = ["CFBundleIdentifier":"synthetic.notification."+UUID().uuidString,"CFBundlePackageType":"BNDL","CFBundleDevelopmentRegion":"en"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:root.appendingPathComponent("Contents/Info.plist"))
        let german = ["Enable notifications":"Benachrichtigungen aktivieren","Notifications enabled":"Benachrichtigungen aktiviert",
            "Notifications blocked in System Settings":"Benachrichtigungen in Systemeinstellungen blockiert","Could not enable notifications":"Benachrichtigungen konnten nicht aktiviert werden",
            "Encrypted reply":"Verschlüsselte Antwort","Encrypted message":"Verschlüsselte Nachricht","Shared a file":"Datei geteilt",
            "Shared a file: %@":"Datei geteilt: %1$@","Sent a sticker":"Sticker gesendet","Created a poll":"Umfrage erstellt","New activity":"Neue Aktivität",
            "Message reminder":"Nachrichtenerinnerung","New reply":"Neue Antwort","New message":"Neue Nachricht","Reminder · %@":"Erinnerung · %1$@",
            "New message %@ %n 100% 日本語":"DO NOT TRANSLATE MESSAGE DATA","Channel %@ %n 100% 日本語":"DO NOT TRANSLATE CHANNEL DATA"]
        for (id,values) in [("en",Dictionary(uniqueKeysWithValues:german.keys.map { ($0,$0) })),("de",german)] {
            let folder = resources.appendingPathComponent(id+".lproj")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
            try PropertyListSerialization.data(fromPropertyList:values,format:.xml,options:0).write(to:folder.appendingPathComponent("Localizable.strings"))
        }
        return try XCTUnwrap(Bundle(url:root))
    }
}
