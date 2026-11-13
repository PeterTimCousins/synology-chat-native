import XCTest
@testable import SynologyChatNative

final class ChatReminderDeliveryTests:XCTestCase {
    private func event(creator:Int = 10,channel:Int = 10,kind:String = "reminder",origin:Int = 766,deleted:Bool = false,id:Int = 900) throws -> ChatLiveEvent {
        let object:[String:Any] = ["post":["post_id":id,"channel_id":channel,"creator_id":creator,"type":"normal","message":"Synthetic personal reminder","create_at":2000,"delete_at":deleted ? 3000 : 0,"props":["forward":["type":kind,"origin_channel_id":93,"origin_post_id":origin,"origin_user_id":10,"origin_thread_id":0,"origin_create_at":1000]]]]
        return .init(name:"client.notification.create",payload:try JSONDecoder().decode(ChatJSON.self,from:JSONSerialization.data(withJSONObject:object)))
    }
    private func prefs(preview:Bool = true,active:Bool = false,mute:Bool = false,snooze:Int = 0) throws -> ChatNotificationPreferences {
        try JSONDecoder().decode(ChatNotificationPreferences.self,from:JSONSerialization.data(withJSONObject:["notification_showmessage":preview,"notification_browser_active":active,"notification_mute":mute,"snooze":snooze]))
    }
    private func render(_ event:ChatLiveEvent,privateID:Int64? = 10,preview:Bool = true,visible:Int64? = nil,encrypted:Bool = false,muted:Bool = false) throws -> ChatNotificationMessage? {
        .make(event:event,preferences:try prefs(preview:preview,mute:muted),currentUserID:10,visibleChannelID:visible,channelTitle:"My Space",contentIsEncrypted:encrypted,personalReminderChannelID:privateID)
    }
    func testOwnReminderIsAllowedOnlyForVerifiedPersonalChannelAndKeepsCopyDestination() throws {
        let event = try event(),message = try XCTUnwrap(render(event))
        XCTAssertEqual(message.title,"Reminder · My Space");XCTAssertEqual(message.body,"Synthetic personal reminder");XCTAssertEqual(message.channelID,10);XCTAssertEqual(message.postID,900);XCTAssertNil(message.threadID)
        XCTAssertNil(try render(event,privateID:nil));XCTAssertNil(try render(event,privateID:11));XCTAssertNil(try render(self.event(channel:93)))
    }
    func testOrdinaryOwnPostsNormalForwardsAndMalformedRemindersRemainSuppressed() throws {
        for e in [try event(kind:"normal"),try event(kind:"unknown"),try event(origin:0),try event(deleted:true),try event(id:0),try event(id:-1)] { XCTAssertNil(try render(e)) }
    }
    func testReminderPrivacyEncryptionSoundAndVisibilityArePreserved() throws {
        let e = try event()
        let hidden = try XCTUnwrap(render(e,preview:false,muted:true));XCTAssertEqual(hidden.title,"Synology Chat");XCTAssertEqual(hidden.body,"Message reminder");XCTAssertFalse(hidden.sound)
        XCTAssertEqual(try render(e,encrypted:true)?.body,"Encrypted message")
        XCTAssertNil(try render(e,visible:10));XCTAssertNotNil(try render(e,visible:93))
        XCTAssertNotNil(ChatNotificationMessage.make(event:e,preferences:try prefs(active:true),currentUserID:10,visibleChannelID:10,channelTitle:"My Space",personalReminderChannelID:10))
    }
    func testObservedSystemBotReminderUsesReminderPresentation() throws {
        let message = try XCTUnwrap(render(event(creator:1)))
        XCTAssertEqual(message.title,"Reminder · My Space")
        XCTAssertEqual(message.postID,900)
        XCTAssertEqual(message.channelID,10)
        XCTAssertTrue(message.sound)
    }
    func testReminderSnoozeRemainsAuthoritative() throws {
        XCTAssertNil(ChatNotificationMessage.make(event:try event(),preferences:try prefs(snooze:2000000),currentUserID:10,visibleChannelID:nil,channelTitle:"My Space",now:Date(timeIntervalSince1970:1000),personalReminderChannelID:10))
    }
    func testOriginNavigationNormalizesRootAndRejectsInvalidMetadataAndDates() throws {
        func origin(post:Int = 766,thread:Int = 0,type:String = "reminder",date:Double = 1000) throws -> ChatForwardOrigin {
            try JSONDecoder().decode(ChatForwardOrigin.self,from:JSONSerialization.data(withJSONObject:["origin_channel_id":93,"origin_post_id":post,"origin_user_id":10,"origin_thread_id":thread,"type":type,"origin_create_at":date]))
        }
        XCTAssertTrue(try origin().isReminder);XCTAssertNil(try origin().navigationThreadID);XCTAssertNil(try origin(thread:766).navigationThreadID)
        XCTAssertEqual(try origin(thread:700).navigationThreadID,700);XCTAssertEqual(try origin().originDate,Date(timeIntervalSince1970:1))
        XCTAssertFalse(try origin(post:0).isReminder);XCTAssertFalse(try origin(type:"normal").isReminder);XCTAssertNil(try origin(date:-1).originDate)
    }
}
