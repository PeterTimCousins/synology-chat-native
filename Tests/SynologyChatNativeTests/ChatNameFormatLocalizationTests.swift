import Foundation
import XCTest
@testable import SynologyChatNative

final class ChatNameFormatLocalizationTests:XCTestCase {
    private func bundle() throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-name-format-"+UUID().uuidString+".bundle")
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        let info:[String:Any] = ["CFBundleIdentifier":"synthetic.name-format."+UUID().uuidString,"CFBundlePackageType":"BNDL","CFBundleDevelopmentRegion":"en"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:root.appendingPathComponent("Contents/Info.plist"))
        let english = ["Usernames":"Usernames","Nicknames":"Nicknames","User %lld":"User %lld","%@ (Guest)":"%@ (Guest)"]
        let german = ["Usernames":"Benutzernamen","Nicknames":"Spitznamen","User %lld":"Benutzer %1$lld","%@ (Guest)":"%1$@ (Gast)"]
        for (id,values) in [("en",english),("de",german)] {
            let folder = resources.appendingPathComponent(id+".lproj")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
            try PropertyListSerialization.data(fromPropertyList:values,format:.xml,options:0).write(to:folder.appendingPathComponent("Localizable.strings"))
        }
        return try XCTUnwrap(Bundle(url:root))
    }
    private func user(id:Int64 = 6,username:String? = "account",nickname:String = "Nickname",type:String = "human",human:String = "dsm") throws -> ChatUser {
        var value:[String:Any] = ["user_id":id,"nickname":nickname,"type":type,"human_type":human]
        if let username { value["username"] = username }
        return try JSONDecoder().decode(ChatUser.self,from:JSONSerialization.data(withJSONObject:value))
    }
    func testLocalizedTitlesDoNotChangeWireIdentity() throws {
        let resources = try bundle()
        XCTAssertEqual(ChatNameFormat.username.title(language:.german,bundle:resources),"Benutzernamen")
        XCTAssertEqual(ChatNameFormat.nickname.title(language:.german,bundle:resources),"Spitznamen")
        XCTAssertEqual(ChatNameFormat.username.title(language:.french,bundle:resources),"Usernames")
        XCTAssertEqual(String(decoding:try JSONEncoder().encode(ChatNameFormat.nickname),as:UTF8.self),"\"nickname\"")
        XCTAssertEqual(try JSONDecoder().decode(ChatNameFormat.self,from:Data("\"username\"".utf8)),.username)
        XCTAssertEqual(ChatNameFormat.allCases.map(\.rawValue),["username","nickname"])
    }
    func testHumanAndBotNamesRemainLiteralEvenWhenTheyMatchInterfaceKeys() throws {
        let resources = try bundle()
        let person = try user(username:"Usernames",nickname:"Nicknames")
        XCTAssertEqual(ChatNameFormat.username.display(person,language:.german,bundle:resources),"Usernames")
        XCTAssertEqual(ChatNameFormat.nickname.display(person,language:.german,bundle:resources),"Nicknames")
        let literal = "100% %@ %n 東京"
        for format in ChatNameFormat.allCases {
            XCTAssertEqual(format.display(try user(username:nil,nickname:literal),language:.german,bundle:resources),literal)
            XCTAssertEqual(format.display(try user(username:literal,nickname:""),language:.german,bundle:resources),literal)
            XCTAssertEqual(format.display(try user(username:"internal",nickname:literal,type:"bot"),language:.german,bundle:resources),literal)
            XCTAssertEqual(format.display(try user(username:literal,nickname:"",type:"bot"),language:.german,bundle:resources),literal)
        }
    }
    func testGuestSuffixLocalizesWithoutChangingGuestNameOrShortMode() throws {
        let resources = try bundle(),name = "100% %@ 日本語"
        for format in ChatNameFormat.allCases {
            let guest = try user(username:"guest_"+name,nickname:"",human:"guest")
            XCTAssertEqual(format.display(guest,language:.german,bundle:resources),name+" (Gast)")
            XCTAssertEqual(format.display(guest,shortGuest:true,language:.german,bundle:resources),name)
            XCTAssertEqual(format.display(try user(username:"guest_handle",nickname:name,human:"guest"),language:.german,bundle:resources),name+" (Gast)")
            XCTAssertEqual(format.display(guest,language:.french,bundle:resources),name+" (Guest)")
            XCTAssertEqual(format.display(try user(username:"Guest_handle",nickname:"",human:"guest"),shortGuest:true,language:.german,bundle:resources),"Guest_handle")
        }
    }
    func testUnknownUserReferencesKeepExactDigitsAcrossHumanGuestAndBotFallbacks() throws {
        let resources = try bundle(),id:Int64 = 9_007_199_254_740_993
        for format in ChatNameFormat.allCases {
            XCTAssertEqual(format.display(try user(id:id,username:nil,nickname:""),language:.german,bundle:resources),"Benutzer 9007199254740993")
            XCTAssertEqual(format.display(try user(id:id,username:"",nickname:"",type:"bot"),language:.german,bundle:resources),"Benutzer 9007199254740993")
            let guest = try user(id:id,username:"guest_",nickname:"",human:"guest")
            XCTAssertEqual(format.display(guest,language:.german,bundle:resources),"Benutzer 9007199254740993 (Gast)")
            XCTAssertEqual(format.display(guest,shortGuest:true,language:.french,bundle:resources),"User 9007199254740993")
        }
    }
    func testSearchAndAdditionalNamesUseOriginalAccountFields() throws {
        let resources = try bundle(),person = try user(username:"Usernames",nickname:"東京 Nicknames")
        _ = ChatNameFormat.username.title(language:.german,bundle:resources)
        XCTAssertEqual(ChatNameFormat.username.additional(person),"東京 Nicknames")
        XCTAssertEqual(ChatNameFormat.nickname.additional(person),"Usernames")
        XCTAssertTrue(ChatNameFormat.matches(person,query:"USERNAMES"))
        XCTAssertTrue(ChatNameFormat.matches(person,query:"東京"))
        XCTAssertFalse(ChatNameFormat.matches(person,query:"Benutzernamen"))
        XCTAssertNil(ChatNameFormat.username.additional(try user(type:"bot")))
        XCTAssertNil(ChatNameFormat.username.additional(try user(human:"guest")))
        XCTAssertNil(ChatNameFormat.nickname.additional(try user(username:"same",nickname:"same")))
    }
}
