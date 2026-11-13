import Foundation
import XCTest
@testable import SynologyChatNative

final class ChatAPIErrorLocalizationTests:XCTestCase {
    private let english:[String:String] = [
        "Use a direct HTTPS server address for the native preview.":"Use a direct HTTPS server address for the native preview.",
        "This server does not support the required Chat API version.":"This server does not support the required Chat API version.",
        "The server returned an unexpected response.":"The server returned an unexpected response.",
        "The sign-in session was rejected (%lld). Sign in to Synology Chat again and reconnect.":"The sign-in session was rejected (%lld). Sign in to Synology Chat again and reconnect.",
        "The server could not complete this request. Wait a moment and try again.":"The server could not complete this request. Wait a moment and try again.",
        "One of the fields was not accepted. Check its format and length.":"One of the fields was not accepted. Check its format and length.",
        "Messages are being sent too quickly. Wait a moment before sending again.":"Messages are being sent too quickly. Wait a moment before sending again.",
        "Synology Chat returned error %lld.":"Synology Chat returned error %lld.",
        "The server returned HTTP %lld.":"The server returned HTTP %lld.",
        "Could not connect securely. Check the server connection and try again.":"Could not connect securely. Check the server connection and try again."
    ]
    private func bundle(german:[String:String] = [:]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-api-errors-"+UUID().uuidString+".bundle")
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        let info:[String:Any] = ["CFBundleIdentifier":"synthetic.api-errors."+UUID().uuidString,"CFBundlePackageType":"BNDL","CFBundleDevelopmentRegion":"en"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:root.appendingPathComponent("Contents/Info.plist"))
        for (id,values) in [("en",english),("de",german)] {
            let folder = resources.appendingPathComponent(id+".lproj")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
            try PropertyListSerialization.data(fromPropertyList:values,format:.xml,options:0).write(to:folder.appendingPathComponent("Localizable.strings"))
        }
        return try XCTUnwrap(Bundle(url:root))
    }
    func testEveryEnglishBranchPreservesItsMeaningAndSessionCodes() throws {
        let resources = try bundle()
        let cases:[(ChatAPIError,String)] = [
            (.invalidServer,"Use a direct HTTPS server address for the native preview."),
            (.unsupportedAPI,"This server does not support the required Chat API version."),
            (.invalidResponse,"The server returned an unexpected response."),
            (.server(117),"The server could not complete this request. Wait a moment and try again."),
            (.server(407),"One of the fields was not accepted. Check its format and length."),
            (.server(411),"Messages are being sent too quickly. Wait a moment before sending again."),
            (.server(500),"Synology Chat returned error 500."),
            (.http(503),"The server returned HTTP 503."),
            (.connection,"Could not connect securely. Check the server connection and try again.")]
        for (value,expected) in cases { XCTAssertEqual(value.message(language:.english,bundle:resources),expected) }
        for code in [105,106,107,119] {
            XCTAssertEqual(ChatAPIError.server(code).message(language:.english,bundle:resources),"The sign-in session was rejected (\(code)). Sign in to Synology Chat again and reconnect.")
        }
    }
    func testGermanSelectedCatalogAndPositionalIntegerTemplates() throws {
        let resources = try bundle(german:[
            "Use a direct HTTPS server address for the native preview.":"Direkte HTTPS-Adresse verwenden.",
            "This server does not support the required Chat API version.":"Chat-Version nicht unterstützt.",
            "The server returned an unexpected response.":"Unerwartete Antwort.",
            "The sign-in session was rejected (%lld). Sign in to Synology Chat again and reconnect.":"Sitzung %1$lld abgelehnt. Erneut anmelden.",
            "The server could not complete this request. Wait a moment and try again.":"Anfrage später wiederholen.",
            "One of the fields was not accepted. Check its format and length.":"Feldformat prüfen.",
            "Messages are being sent too quickly. Wait a moment before sending again.":"Vor dem Senden warten.",
            "Synology Chat returned error %lld.":"Fehler %1$lld von Synology Chat.",
            "The server returned HTTP %lld.":"HTTP %1$lld vom Server.",
            "Could not connect securely. Check the server connection and try again.":"Sichere Verbindung fehlgeschlagen."])
        let cases:[(ChatAPIError,String)] = [(.invalidServer,"Direkte HTTPS-Adresse verwenden."),(.unsupportedAPI,"Chat-Version nicht unterstützt."),(.invalidResponse,"Unerwartete Antwort."),(.server(119),"Sitzung 119 abgelehnt. Erneut anmelden."),(.server(117),"Anfrage später wiederholen."),(.server(407),"Feldformat prüfen."),(.server(411),"Vor dem Senden warten."),(.server(-42),"Fehler -42 von Synology Chat."),(.http(503),"HTTP 503 vom Server."),(.connection,"Sichere Verbindung fehlgeschlagen.")]
        for (value,expected) in cases { XCTAssertEqual(value.message(language:.german,bundle:resources),expected) }
    }
    func testFallbackAndFullWidthCodesKeepEveryDigitWithoutGrouping() throws {
        let resources = try bundle(german:["Synology Chat returned error %lld.":"Fehler %1$lld"])
        XCTAssertEqual(ChatAPIError.server(9_007_199_254_740_993).message(language:.german,bundle:resources),"Fehler 9007199254740993")
        XCTAssertEqual(ChatAPIError.server(Int.min).message(language:.french,bundle:resources),"Synology Chat returned error -9223372036854775808.")
        XCTAssertEqual(ChatAPIError.http(Int.max).message(language:.german,bundle:resources),"The server returned HTTP 9223372036854775807.")
        XCTAssertEqual(ChatAPIError.server(-1).message(language:.french,bundle:resources),"Synology Chat returned error -1.")
    }
    func testDisplayTranslationCannotChangeTheErrorCaseOrPayload() throws {
        let resources = try bundle(german:["The server returned an unexpected response.":"Gleich","Synology Chat returned error %lld.":"Gleich %lld"])
        let value = ChatAPIError.server(117)
        if case .server(let code) = value { XCTAssertEqual(code,117) } else { XCTFail("Server payload changed") }
        XCTAssertEqual(value.message(language:.german,bundle:resources),"The server could not complete this request. Wait a moment and try again.")
        let transport = ChatAPIError.http(119)
        if case .http(let code) = transport { XCTAssertEqual(code,119) } else { XCTFail("HTTP case changed") }
        XCTAssertEqual(transport.message(language:.german,bundle:resources),"The server returned HTTP 119.")
    }
}
