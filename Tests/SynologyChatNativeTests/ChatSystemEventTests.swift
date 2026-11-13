import XCTest
@testable import SynologyChatNative

final class ChatSystemEventTests:XCTestCase {
    private func post(_ system:Any?,type:String = "system",message:String = "") throws -> ChatPost {
        var data:[String:Any] = ["post_id":10,"channel_id":4,"creator_id":1,"message":message,"type":type,"create_at":1500]
        if let system { data["system_props"] = system }
        return try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:data))
    }
    func testSystemAuthorUsesEffectiveUserAndNeverChangesOrdinaryAuthor() throws {
        let value:[String:Any] = ["event":"channel.update","effective_user_id":10]
        XCTAssertEqual(try post(value).displayAuthorID,10)
        XCTAssertEqual(try post(value,type:"text").displayAuthorID,1)
        XCTAssertEqual(try post(["effective_user_id":0]).displayAuthorID,1)
    }
    func testMetadataUpdatesRenderLiteralNameAndEmptyPurpose() throws {
        let event:[String:Any] = ["event":"channel.update","extra":["update_info":[["attr":"channel_name","new":"<literal> **name**"],["attr":"purpose","new":""],["attr":"type","new":"private"]]]]
        XCTAssertEqual(try post(event).systemEventText(names:[:]),"Channel name changed to <literal> **name**. Channel purpose cleared. Conversation converted to a private channel.")
    }
    func testPurposeAndUnknownUpdateFields() throws {
        let event:[String:Any] = ["event":"channel.update","extra":["update_info":[["attr":"future","new":true],["attr":"purpose","new":"Literal purpose"]]]]
        XCTAssertEqual(try post(event).systemEventText(names:[:]),"Channel purpose changed to Literal purpose.")
        XCTAssertEqual(try post(["event":"channel.update","extra":["update_info":true]]).systemEventText(names:[:]),"Channel details changed.")
    }
    func testMembershipInviterKickerAndSelfJoinLeave() throws {
        let names:[Int64:String] = [10:"Peter",6:"Peer"]
        XCTAssertEqual(try post(["event":"channel.join","target_user_ids":[6],"trigger_user_id":10]).systemEventText(names:names),"Peer joined the channel, invited by Peter.")
        XCTAssertEqual(try post(["event":"channel.disjoin","target_user_ids":[6],"trigger_user_id":10]).systemEventText(names:names),"Peer removed from the channel by Peter.")
        XCTAssertEqual(try post(["event":"channel.join","target_user_ids":[6]]).systemEventText(names:names),"Peer joined the channel.")
        XCTAssertEqual(try post(["event":"channel.disjoin","target_user_ids":[6]]).systemEventText(names:names),"Peer left the channel.")
    }
    func testMalformedAndFutureEventsHaveReadableFallbackWithoutRawMarkup() throws {
        for value:Any? in [nil,NSNull(),["event":45],["event":"future.unknown"],"unexpected"] {
            XCTAssertEqual(try post(value,message:"<script>raw</script>").systemEventText(names:[:]),"Conversation event.")
        }
    }
    func testEncryptionRepairIsNotPresentedAsArchiveRestore() throws {
        XCTAssertEqual(try post(["event":"channel.rescue","trigger_user_id":10,"target_user_ids":[6]]).systemEventText(names:[10:"Peter",6:"Peer"]),"Peter repaired encrypted channel access for Peer.")
        XCTAssertEqual(try post(["event":"encrypt.enabled"]).systemEventText(names:[:]),"Conversation encryption enabled.")
    }
    func testMembershipDisplayBoundsLargeTargetListAndUsesUnknownUserFallback() throws {
        let result = try post(["event":"channel.join","target_user_ids":Array(1...25)]).systemEventText(names:[:])
        XCTAssertTrue(result.contains("User 20 and 5 others"));XCTAssertFalse(result.contains("User 21"))
    }
    private func localizedBundle() throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-system-event-"+UUID().uuidString+".bundle")
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        let info:[String:Any] = ["CFBundleIdentifier":"synthetic.system-event."+UUID().uuidString,"CFBundlePackageType":"BNDL","CFBundleDevelopmentRegion":"en"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:root.appendingPathComponent("Contents/Info.plist"))
        let german:[String:String] = [
            "A member":"Ein Mitglied","a member":"ein Mitglied","User %lld":"Nutzer %lld",
            "an integration":"eine Integration","Conversation event.":"Unterhaltungsereignis.",
            "Channel details changed.":"Kanaldetails geändert.","Channel membership changed.":"Kanalmitgliedschaft geändert.",
            "Channel name changed to %@.":"Kanalname jetzt: %@.","Channel purpose changed to %@.":"Zweck jetzt: %@.",
            "Channel purpose cleared.":"Kanalzweck gelöscht.",
            "%@ joined the channel, invited by %@.":"%2$@ hat %1$@ in den Kanal eingeladen.",
            "%@ joined the channel.":"%@ ist beigetreten.",
            "%@ removed from the channel by %@.":"%2$@ hat %1$@ aus dem Kanal entfernt.",
            "%@ repaired encrypted channel access for %@.":"%1$@ reparierte Zugriff für %2$@.",
            "%@ added %@.":"%1$@ fügte %2$@ hinzu."]
        for (id,values) in [("en",["Conversation event.":"Conversation event.","Channel closed.":"English channel closed."]),("de",german)] {
            let folder = resources.appendingPathComponent(id+".lproj")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
            try PropertyListSerialization.data(fromPropertyList:values,format:.xml,options:0).write(to:folder.appendingPathComponent("Localizable.strings"))
        }
        let plural:[String:Any] = [" and %lld others":["NSStringLocalizedFormatKey":"%#@count@","count":[
            "NSStringFormatSpecTypeKey":"NSStringPluralRuleType","NSStringFormatValueTypeKey":"lld",
            "one":" und %lld weitere Person","other":" und %lld weitere Personen"]]]
        try PropertyListSerialization.data(fromPropertyList:plural,format:.xml,options:0).write(to:resources.appendingPathComponent("de.lproj/Localizable.stringsdict"))
        return try XCTUnwrap(Bundle(url:root))
    }
    func testLocalizedMembershipCanReorderActorAndTargetsWithoutInterpretingNames() throws {
        let resources = try localizedBundle()
        let actor = "Peter 100% %@ 日本語",target = "Peer %n **literal**"
        let names:[Int64:String] = [10:actor,6:target]
        let joined = try post(["event":"channel.join","target_user_ids":[6],"trigger_user_id":10])
        XCTAssertEqual(joined.systemEventText(names:names,language:.german,bundle:resources),actor+" hat "+target+" in den Kanal eingeladen.")
        let removed = try post(["event":"channel.disjoin","target_user_ids":[6],"trigger_user_id":10])
        XCTAssertEqual(removed.systemEventText(names:names,language:.german,bundle:resources),actor+" hat "+target+" aus dem Kanal entfernt.")
        XCTAssertEqual(try post(["event":"channel.join","target_user_ids":[6]]).systemEventText(names:[:],language:.german,bundle:resources),"Nutzer 6 ist beigetreten.")
    }
    func testLocalizedMetadataPreservesLiteralDataAndReadableMissingOrUnknownFallbacks() throws {
        let resources = try localizedBundle(),name = "100% %@ 日本語",purpose = "<literal> %n **purpose**"
        let update:[String:Any] = ["event":"channel.update","extra":["update_info":[["attr":"channel_name","new":name],["attr":"purpose","new":purpose],["attr":"purpose","new":""]]]]
        XCTAssertEqual(try post(update).systemEventText(names:[:],language:.german,bundle:resources),"Kanalname jetzt: "+name+". Zweck jetzt: "+purpose+". Kanalzweck gelöscht.")
        XCTAssertEqual(try post(["event":"channel.update","extra":["update_info":true]]).systemEventText(names:[:],language:.german,bundle:resources),"Kanaldetails geändert.")
        for value:Any? in [nil,NSNull(),["event":45],["event":"future.unknown"],"unexpected"] {
            XCTAssertEqual(try post(value,message:"Never expose raw event text").systemEventText(names:[:],language:.german,bundle:resources),"Unterhaltungsereignis.")
        }
        XCTAssertEqual(try post(["event":"channel.close"]).systemEventText(names:[:],language:.french,bundle:resources),"English channel closed.")
    }
    func testLocalizedOverflowKeepsFirstTwentyInOrderAndSelectsSingularOrPlural() throws {
        let resources = try localizedBundle()
        let names = Dictionary(uniqueKeysWithValues:(1...22).map { (Int64($0),"Mitglied-\($0)") })
        for count in [21,22] {
            let event = try post(["event":"channel.join","target_user_ids":Array(1...count)])
            let result = event.systemEventText(names:names,language:.german,bundle:resources)
            XCTAssertTrue(result.hasPrefix("Mitglied-1, Mitglied-2, "))
            XCTAssertTrue(result.contains(count == 21 ? "Mitglied-20 und 1 weitere Person" : "Mitglied-20 und 2 weitere Personen"))
            XCTAssertFalse(result.contains("Mitglied-21"))
            XCTAssertTrue(result.hasSuffix(" ist beigetreten."))
        }
        XCTAssertEqual(try post(["event":"channel.rescue"]).systemEventText(names:[:],language:.german,bundle:resources),"Ein Mitglied reparierte Zugriff für ein Mitglied.")
        XCTAssertEqual(try post(["event":"bot.add"]).systemEventText(names:[:],language:.german,bundle:resources),"Ein Mitglied fügte eine Integration hinzu.")
    }
    func testRemainingEnglishEventBranchesRetainExistingMeanings() throws {
        for (event,expected) in [
            ("channel.kick","You were removed from the channel."),("encrypt.disabled","Conversation encryption disabled."),
            ("encrypt.notify","Peter updated conversation encryption."),("channel.revive","Peter reopened a conversation."),
            ("channel.close","Channel closed."),("post.pin","Peter pinned a message."),("post.unpin","Peter unpinned a message."),
            ("post.vote.close","Peter closed a poll."),("post.vote.update","Peter updated a poll."),
            ("bot.add","Peter added an integration."),("bot.delete","Peter removed an integration.")
        ] {
            XCTAssertEqual(try post(["event":event,"trigger_user_id":10]).systemEventText(names:[10:"Peter"],language:.english),expected)
        }
    }
}
