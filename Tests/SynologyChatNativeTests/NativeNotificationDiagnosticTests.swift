import Foundation
import XCTest
@testable import SynologyChatNative

final class NativeNotificationDiagnosticTests:XCTestCase {
    private let english:[String:String] = [
        "No server notification events received this session":"No server notification events received this session",
        "Submitting local test to macOS":"Submitting local test to macOS",
        "Server notification events: %lld":"Server notification events: %lld",
        "Server notification events: %lld · notifications disabled":"Server notification events: %lld · notifications disabled",
        "Notification held: could not validate snooze timing":"Notification held: could not validate snooze timing",
        "Submitting notification to macOS":"Submitting notification to macOS",
        "Server notification filtered: snoozed, own, deleted, visible, or unsupported event":"Server notification filtered: snoozed, own, deleted, visible, or unsupported event",
        "Post events: %lld · no server notification event yet":"Post events: %lld · no server notification event yet",
        "Last notification accepted by macOS":"Last notification accepted by macOS",
        "macOS rejected the last notification (code %lld)":"macOS rejected the last notification (code %lld)"
    ]
    private func bundle(german:[String:String]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-notification-diagnostic-"+UUID().uuidString+".bundle")
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        let info:[String:Any] = ["CFBundleIdentifier":"synthetic.notification-diagnostic."+UUID().uuidString,"CFBundlePackageType":"BNDL","CFBundleDevelopmentRegion":"en"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:root.appendingPathComponent("Contents/Info.plist"))
        for (id,values) in [("en",english),("de",german)] {
            let folder = resources.appendingPathComponent(id+".lproj")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
            try PropertyListSerialization.data(fromPropertyList:values,format:.xml,options:0).write(to:folder.appendingPathComponent("Localizable.strings"))
        }
        return try XCTUnwrap(Bundle(url:root))
    }
    func testEveryEnglishDiagnosticRetainsItsMeaningAndFormatting() throws {
        let resources = try bundle(german:[:])
        let cases:[(NativeNotificationDiagnostic,String)] = [
            (.noEvents,"No server notification events received this session"),
            (.submittingTest,"Submitting local test to macOS"),
            (.serverEvents(7,enabled:true),"Server notification events: 7"),
            (.serverEvents(7,enabled:false),"Server notification events: 7 · notifications disabled"),
            (.snoozeClockUnavailable,"Notification held: could not validate snooze timing"),
            (.submitting,"Submitting notification to macOS"),
            (.filtered,"Server notification filtered: snoozed, own, deleted, visible, or unsupported event"),
            (.postsWithoutNotification(3),"Post events: 3 · no server notification event yet"),
            (.accepted,"Last notification accepted by macOS"),
            (.rejected(-1),"macOS rejected the last notification (code -1)")]
        for (value,expected) in cases { XCTAssertEqual(value.text(language:.english,bundle:resources),expected) }
    }
    func testSelectedCatalogPreservesTypedCountAndEnabledVariant() throws {
        let resources = try bundle(german:[
            "No server notification events received this session":"Noch keine Serverereignisse",
            "Submitting local test to macOS":"Lokalen Test an macOS übergeben",
            "Server notification events: %lld":"%1$lld Serverereignisse",
            "Server notification events: %lld · notifications disabled":"Benachrichtigungen aus · %1$lld Serverereignisse",
            "Notification held: could not validate snooze timing":"Zeitprüfung ausstehend",
            "Submitting notification to macOS":"Benachrichtigung an macOS übergeben",
            "Server notification filtered: snoozed, own, deleted, visible, or unsupported event":"Serverereignis gefiltert",
            "Post events: %lld · no server notification event yet":"Noch kein Benachrichtigungsereignis · %1$lld Nachrichtenereignisse",
            "Last notification accepted by macOS":"Letzte Benachrichtigung angenommen",
            "macOS rejected the last notification (code %lld)":"Fehler %1$lld bei letzter Benachrichtigung"])
        let cases:[(NativeNotificationDiagnostic,String)] = [
            (.noEvents,"Noch keine Serverereignisse"),
            (.submittingTest,"Lokalen Test an macOS übergeben"),
            (.serverEvents(12,enabled:true),"12 Serverereignisse"),
            (.serverEvents(12,enabled:false),"Benachrichtigungen aus · 12 Serverereignisse"),
            (.snoozeClockUnavailable,"Zeitprüfung ausstehend"),
            (.submitting,"Benachrichtigung an macOS übergeben"),
            (.filtered,"Serverereignis gefiltert"),
            (.postsWithoutNotification(2),"Noch kein Benachrichtigungsereignis · 2 Nachrichtenereignisse"),
            (.accepted,"Letzte Benachrichtigung angenommen"),
            (.rejected(-42),"Fehler -42 bei letzter Benachrichtigung")]
        for (value,expected) in cases { XCTAssertEqual(value.text(language:.german,bundle:resources),expected) }
    }
    func testUnshippedLanguageUsesEnglishAndFullWidthCodesRemainExact() throws {
        let resources = try bundle(german:["macOS rejected the last notification (code %lld)":"Fehler %1$lld"])
        XCTAssertEqual(NativeNotificationDiagnostic.serverEvents(0,enabled:false).text(language:.french,bundle:resources),"Server notification events: 0 · notifications disabled")
        XCTAssertEqual(NativeNotificationDiagnostic.rejected(9_007_199_254_740_993).text(language:.german,bundle:resources),"Fehler 9007199254740993")
        XCTAssertEqual(NativeNotificationDiagnostic.rejected(Int.max).text(language:.english,bundle:resources),"macOS rejected the last notification (code 9223372036854775807)")
    }
    func testIdenticalTranslatedSentencesCannotCollapseDistinctTypedDiagnostics() throws {
        let resources = try bundle(german:[
            "No server notification events received this session":"Gleich",
            "Last notification accepted by macOS":"Gleich"])
        XCTAssertEqual(NativeNotificationDiagnostic.noEvents.text(language:.german,bundle:resources),NativeNotificationDiagnostic.accepted.text(language:.german,bundle:resources))
        XCTAssertNotEqual(NativeNotificationDiagnostic.noEvents,.accepted)
        XCTAssertNotEqual(NativeNotificationDiagnostic.serverEvents(1,enabled:true),.serverEvents(1,enabled:false))
        XCTAssertNotEqual(NativeNotificationDiagnostic.rejected(1),.rejected(2))
    }
}
