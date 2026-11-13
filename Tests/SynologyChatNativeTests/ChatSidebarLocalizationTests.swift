import Foundation
import XCTest
@testable import SynologyChatNative

final class ChatSidebarLocalizationTests:XCTestCase {
    private let liveLabels:[(ChatLiveStatus,String,String)] = [
        (.connecting,"Connecting live updates…","Live-Verbindung wird hergestellt…"),
        (.live,"Live","Verbunden"),
        (.reconnecting,"Reconnecting · messages may be out of date","Erneute Verbindung · Nachrichten möglicherweise veraltet"),
        (.offline,"Offline · refresh to check for new messages","Offline · Für neue Nachrichten aktualisieren"),
        (.rejected,"Live updates were rejected · reconnect or sign in again","Live-Verbindung abgelehnt · Erneut verbinden oder anmelden")]

    private func resources() throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-sidebar-localization-"+UUID().uuidString+".bundle")
        let folder = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"synthetic.sidebar."+UUID().uuidString,"CFBundlePackageType":"BNDL","CFBundleDevelopmentRegion":"en"],format:.xml,options:0).write(to:root.appendingPathComponent("Contents/Info.plist"))
        for language in ["en","de"] {
            let local = folder.appendingPathComponent(language+".lproj")
            try FileManager.default.createDirectory(at:local,withIntermediateDirectories:false)
            var strings = Dictionary(uniqueKeysWithValues:liveLabels.map { ($0.1,language == "de" ? $0.2 : $0.1) })
            strings["No unread messages"] = language == "de" ? "Keine ungelesenen Nachrichten" : "No unread messages"
            strings["%@, %@"] = language == "de" ? "[%2$@] %1$@" : "%@, %@"
            try PropertyListSerialization.data(fromPropertyList:strings,format:.xml,options:0).write(to:local.appendingPathComponent("Localizable.strings"))
            func plural(_ one:String,_ other:String)->[String:Any] {
                ["NSStringLocalizedFormatKey":"%#@count@","count":["NSStringFormatSpecTypeKey":"NSStringPluralRuleType","NSStringFormatValueTypeKey":"lld","one":one,"other":other]]
            }
            let plurals:[String:Any] = [
                "%lld unread messages":language == "de" ? plural("%lld ungelesene Nachricht","%lld ungelesene Nachrichten") : plural("%lld unread message","%lld unread messages"),
                "%lld mentions or followed replies":language == "de" ? plural("%lld Erwähnung oder verfolgte Antwort","%lld Erwähnungen oder verfolgte Antworten") : plural("%lld mention or followed reply","%lld mentions or followed replies")]
            try PropertyListSerialization.data(fromPropertyList:plurals,format:.xml,options:0).write(to:local.appendingPathComponent("Localizable.stringsdict"))
        }
        return try XCTUnwrap(Bundle(url:root))
    }
    private func channel(type:String = "public",unread:Int = 0,mentions:Int = 0,threads:[String:Int] = [:],encrypted:Bool = false) throws -> ChatChannel {
        let value:[String:Any] = ["channel_id":23,"name":"Raw 100% %@ 日本語","type":type,"unread":unread,"unread_mention":mentions,"unread_thread":threads,"encrypted":encrypted]
        return try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:value))
    }
    func testUnreadZeroSingularPluralAndReorderedMentionSummary() throws {
        let bundle = try resources()
        XCTAssertEqual(try channel().sidebarUnreadDescription(language:.german,bundle:bundle),"Keine ungelesenen Nachrichten")
        XCTAssertEqual(try channel(unread:1,mentions:1).sidebarUnreadDescription(language:.german,bundle:bundle),"1 ungelesene Nachricht")
        XCTAssertEqual(try channel(unread:3,mentions:1).sidebarUnreadDescription(language:.german,bundle:bundle),"[1 Erwähnung oder verfolgte Antwort] 3 ungelesene Nachrichten")
        XCTAssertEqual(try channel(unread:3,mentions:2).sidebarUnreadDescription(language:.german,bundle:bundle),"[2 Erwähnungen oder verfolgte Antworten] 3 ungelesene Nachrichten")
        XCTAssertEqual(try channel(unread:3,mentions:0).sidebarUnreadDescription(language:.french,bundle:bundle),"3 unread messages, 0 mentions or followed replies")
    }
    func testMentionSummaryPolicyKeepsEncryptedAndDirectMessagesPrivate() throws {
        let bundle = try resources()
        for (type,encrypted) in [("public",true),("private",true),("anonymous",false),("synobot",false),("chatbot",false)] {
            let value = try channel(type:type,unread:3,mentions:1,encrypted:encrypted)
            XCTAssertEqual(value.sidebarUnreadDescription(language:.german,bundle:bundle),"3 ungelesene Nachrichten")
        }
        let ordinary = try channel(type:"private",unread:3,mentions:1,threads:["4":2])
        XCTAssertEqual(ordinary.sidebarUnreadCount,5)
        XCTAssertEqual(ordinary.badgeUnreadCount,3)
        XCTAssertEqual(ordinary.sidebarUnreadDescription(language:.german,bundle:bundle),"[3 Erwähnungen oder verfolgte Antworten] 5 ungelesene Nachrichten")
    }
    func testCapsNegativeCountsAndStableGroupIdentitySurviveLocalization() throws {
        let bundle = try resources()
        let capped = try channel(unread:Int.max,mentions:Int.max,threads:["4":Int.max,"5":Int.max])
        XCTAssertEqual(capped.sidebarUnreadCount,9999)
        XCTAssertEqual(capped.badgeUnreadCount,9999)
        XCTAssertEqual(capped.sidebarUnreadDescription(language:.german,bundle:bundle),NativeLocalizedStrings.count("%lld unread messages",9999,language:.german,bundle:bundle))
        XCTAssertEqual(try channel(unread:-50,mentions:-2,threads:["4":-3]).sidebarUnreadDescription(language:.german,bundle:bundle),"Keine ungelesenen Nachrichten")
        XCTAssertEqual(ChatSidebarGroup.allCases.map(\.rawValue),["Unread","Starred","Channels","Conversations","Bots"])
    }
    func testEveryConnectionTitleUsesSelectedCatalogAndEnglishFallback() throws {
        let bundle = try resources()
        for (status,english,german) in liveLabels {
            XCTAssertEqual(status.title(language:.german,bundle:bundle),german)
            XCTAssertEqual(status.title(language:.french,bundle:bundle),english)
            XCTAssertEqual(status.title(language:.english,bundle:bundle),english)
        }
        XCTAssertNotEqual(ChatLiveStatus.live,ChatLiveStatus.reconnecting)
    }
}
