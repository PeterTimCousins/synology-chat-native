import Foundation
import XCTest
@testable import SynologyChatNative

final class NativeLocalizedStringsTests:XCTestCase {
    private func bundle(english:[String:String]?,german:[String:String]?) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-localization-test-"+UUID().uuidString+".bundle")
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        let info:[String:Any] = ["CFBundleIdentifier":"synthetic.localization."+UUID().uuidString,"CFBundlePackageType":"BNDL","CFBundleDevelopmentRegion":"en"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:root.appendingPathComponent("Contents/Info.plist"))
        for (id,values) in [("en",english),("de",german)] {
            guard let values else { continue }
            let folder = resources.appendingPathComponent(id+".lproj")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
            try PropertyListSerialization.data(fromPropertyList:values,format:.xml,options:0).write(to:folder.appendingPathComponent("Localizable.strings"))
        }
        return try XCTUnwrap(Bundle(url:root))
    }
    func testModuleEnglishResourceIsActuallyLoadableAndUnshippedTargetFallsBack() {
        XCTAssertTrue(NativeLocalizedStrings.resourceBundle.localizations.contains("en"))
        XCTAssertEqual(NativeLocalizedStrings.text("Settings",language:.english),"Settings")
        XCTAssertEqual(NativeLocalizedStrings.text("native.app.name",language:.english),"Chat Native")
        XCTAssertEqual(NativeLocalizedStrings.text("Cancel",language:.german),"Cancel")
    }
    func testExplicitCatalogThenEnglishFallbackThenSourceKey() throws {
        let resources = try bundle(english:["Settings":"English settings","Only English":"English fallback"],german:["Settings":"Einstellungen"])
        XCTAssertEqual(NativeLocalizedStrings.text("Settings",language:.german,bundle:resources),"Einstellungen")
        XCTAssertEqual(NativeLocalizedStrings.text("Only English",language:.german,bundle:resources),"English fallback")
        XCTAssertEqual(NativeLocalizedStrings.text("Unknown source key",language:.german,bundle:resources),"Unknown source key")
        XCTAssertEqual(NativeLocalizedStrings.text("Settings",language:.french,bundle:resources),"English settings")
    }
    func testSystemResolutionUsesInjectedPreferenceOrderAndExplicitChoiceWins() throws {
        let resources = try bundle(english:["Settings":"English settings"],german:["Settings":"Einstellungen"])
        XCTAssertEqual(NativeLocalizedStrings.text("Settings",language:.system,preferredLanguages:["fi-FI","de-AT"],bundle:resources),"Einstellungen")
        XCTAssertEqual(NativeLocalizedStrings.text("Settings",language:.english,preferredLanguages:["de-DE"],bundle:resources),"English settings")
    }
    func testMissingEnglishNeverChoosesAnUnrelatedAvailableLanguage() throws {
        let resources = try bundle(english:nil,german:["Settings":"Einstellungen"])
        XCTAssertEqual(NativeLocalizedStrings.text("Settings",language:.french,bundle:resources),"Settings")
        XCTAssertEqual(NativeLocalizedStrings.text("Settings",language:.english,bundle:resources),"Settings")
        XCTAssertEqual(NativeLocalizedStrings.text("Settings",language:.german,bundle:resources),"Einstellungen")
    }
    func testEmptySelectedTranslationFallsBackWithoutReturningBlankInterfaceText() throws {
        let resources = try bundle(english:["Settings":"English settings"],german:["Settings":""])
        XCTAssertEqual(NativeLocalizedStrings.text("Settings",language:.german,bundle:resources),"English settings")
    }
    func testPackagedEnglishCountsUseSingularAndPluralRules() {
        for (key,singular,plural) in [
            ("%lld replies","1 reply","2 replies"),
            ("Open thread with %lld replies","Open thread with 1 reply","Open thread with 2 replies"),
            ("Open thread · %lld replies","Open thread · 1 reply","Open thread · 2 replies"),
            ("%lld archived replies","1 archived reply","2 archived replies"),
            ("%lld lines","1 line","2 lines"),
            ("%lld results","1 result","2 results"),
            ("%lld conversations","1 conversation","2 conversations"),
            ("%lld members","1 member","2 members"),
            ("%lld minutes","1 minute","2 minutes"),
            ("%lld messages shown","1 message shown","2 messages shown")
        ] {
            XCTAssertEqual(NativeLocalizedStrings.count(key,1,language:.english),singular)
            XCTAssertEqual(NativeLocalizedStrings.count(key,2,language:.english),plural)
        }
        XCTAssertEqual(NativeLocalizedStrings.count("%lld replies",0,language:.english),"0 replies")
        XCTAssertEqual(NativeLocalizedStrings.count("%lld replies",1,language:.russian),"1 reply")
        XCTAssertEqual(NativeLocalizedStrings.count("%lld replies",1,language:.system,preferredLanguages:["ru-RU"]),"1 reply")
    }
    func testCountMissingCatalogReturnsSourceKeyWithoutFormattingUntrustedFallback() throws {
        let resources = try bundle(english:nil,german:["Settings":"Einstellungen"])
        XCTAssertEqual(NativeLocalizedStrings.count("Missing %lld",1,language:.french,bundle:resources),"Missing %lld")
    }
    func testCountUsesSelectedResourcePluralRulesAndEnglishFallbackRules() throws {
        let resources = try bundle(english:["Count":"%lld English"],german:nil)
        let folder = try XCTUnwrap(resources.resourceURL).appendingPathComponent("ru.lproj")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        let plural:[String:Any] = ["Count":["NSStringLocalizedFormatKey":"%#@count@","count":[
            "NSStringFormatSpecTypeKey":"NSStringPluralRuleType","NSStringFormatValueTypeKey":"lld",
            "one":"%lld RU-one","few":"%lld RU-few","many":"%lld RU-many","other":"%lld RU-other"]]]
        try PropertyListSerialization.data(fromPropertyList:plural,format:.xml,options:0).write(to:folder.appendingPathComponent("Localizable.stringsdict"))
        // Load a fresh Bundle after writing resources; Foundation caches lookups.
        let fresh = try XCTUnwrap(Bundle(url:resources.bundleURL))
        XCTAssertEqual(NativeLocalizedStrings.count("Count",1,language:.russian,bundle:fresh),"1 RU-one")
        XCTAssertEqual(NativeLocalizedStrings.count("Count",2,language:.russian,bundle:fresh),"2 RU-few")
        XCTAssertEqual(NativeLocalizedStrings.count("Count",5,language:.russian,bundle:fresh),"5 RU-many")
        XCTAssertEqual(NativeLocalizedStrings.count("Count",21,language:.russian,bundle:fresh),"21 RU-one")
        XCTAssertEqual(NativeLocalizedStrings.count("Count",2,language:.system,preferredLanguages:["ru-RU"],bundle:fresh),"2 RU-few")
        XCTAssertEqual(NativeLocalizedStrings.count("Count",2,language:.french,bundle:fresh),"2 English")
    }
    func testObjectTemplateSubstitutesNamesVerbatimAndFallsBackToEnglish() throws {
        let resources = try bundle(english:["About %@":"About %@"],german:["About %@":"Über %1$@"])
        let name = "Chat %@ 100% %n 日本語"
        XCTAssertEqual(NativeLocalizedStrings.object("About %@",name,language:.german,bundle:resources),"Über "+name)
        XCTAssertEqual(NativeLocalizedStrings.object("About %@",name,language:.french,bundle:resources),"About "+name)
        XCTAssertEqual(NativeLocalizedStrings.object("Missing %@",name,language:.french,bundle:resources),"Missing %@")
    }
    func testNativeMenuTitlesUseInjectedLanguageWhileWrapperTitlesStayOriginal() throws {
        let resources = try bundle(english:["Settings...":"Settings...","Quit %@":"Quit %@"],german:["Settings...":"Einstellungen…","Quit %@":"%1$@ beenden"])
        let native = NativeMenuText(native:true,language:.german,bundle:resources)
        let wrapper = NativeMenuText(native:false,language:.german,bundle:resources)
        XCTAssertEqual(native.text("Settings..."),"Einstellungen…")
        XCTAssertEqual(native.application("Quit %@",name:"Chat Native"),"Chat Native beenden")
        XCTAssertEqual(wrapper.text("Settings..."),"Settings...")
        XCTAssertEqual(wrapper.application("Quit %@",name:"Synology Chat Native 100%"),"Quit Synology Chat Native 100%")
        let wrapperWithoutResources = NativeMenuText(native:false,language:.german,bundle:nil)
        XCTAssertNil(wrapperWithoutResources.bundle)
        XCTAssertEqual(wrapperWithoutResources.text("Settings..."),"Settings...")
        XCTAssertEqual(wrapperWithoutResources.application("Quit %@",name:"Synology Chat Native"),"Quit Synology Chat Native")
    }
    func testTwoObjectTemplatesAllowReorderingWithoutInterpretingEitherValue() throws {
        let resources = try bundle(english:["%@, %@":"%@, %@"],german:["%@, %@":"%2$@ — %1$@"])
        XCTAssertEqual(NativeLocalizedStrings.objects("%@, %@","Peter 100% %@","2 unread %n 日本語",language:.german,bundle:resources),"2 unread %n 日本語 — Peter 100% %@")
        XCTAssertEqual(NativeLocalizedStrings.objects("%@, %@","Peter 100% %@","2 unread %n 日本語",language:.french,bundle:resources),"Peter 100% %@, 2 unread %n 日本語")
    }
    func testNumericReferencesPreserveDigitsWithoutLocaleGrouping() throws {
        let resources = try bundle(english:["Code %lld":"Code %lld"],german:["Code %lld":"Fehler %1$lld"])
        XCTAssertEqual(NativeLocalizedStrings.integer("Code %lld",9_007_199_254_740_993,language:.german,bundle:resources),"Fehler 9007199254740993")
        XCTAssertEqual(NativeLocalizedStrings.integer("Code %lld",Int64.min,language:.french,bundle:resources),"Code -9223372036854775808")
        XCTAssertEqual(ChatSignInError.rejected(10_001).errorDescription,"Sign-in was rejected by the server (10001).")
    }
    func testEnglishAuthenticationErrorsKeepMeaningAndNumericCodes() {
        let errors:[(ChatSignInError,String)] = [
            (.invalidAddress,"Enter a direct HTTPS server address, including its port, or a QuickConnect ID."),
            (.credentials,"The username or password was not accepted."),
            (.otpRequired,"Enter your verification code to finish signing in."),
            (.otpInvalid,"The verification code was not accepted. Enter a current code and try again."),
            (.rejected(119),"Sign-in was rejected by the server (119)."),
            (.rejected(-1),"Sign-in was rejected by the server (-1)."),
            (.response,"The server returned an unexpected sign-in response."),
            (.connection,"Could not connect securely to the server. Check the address and certificate."),
            (.storage,"Could not save this sign-in in macOS Keychain."),
            (.sessionRequired,"Sign in to Synology Chat to connect.")]
        for (error,text) in errors { XCTAssertEqual(error.errorDescription,text) }
        XCTAssertEqual(ChatQuickConnectError.invalidID.errorDescription,"Enter a valid QuickConnect ID or a direct HTTPS server address.")
        XCTAssertEqual(ChatQuickConnectError.discovery.errorDescription,"QuickConnect could not find this NAS. Check the ID and try again.")
        XCTAssertEqual(ChatQuickConnectError.trustedConnection.errorDescription,"QuickConnect found the NAS, but could not establish a trusted HTTPS connection. Try its direct HTTPS address.")
    }
    @MainActor func testLocalizedSavedFilePromptKeepsFilenameAndSafeButtonRouting() throws {
        let warning = "Opening a downloaded file may run a program. Only open it if you trust its source."
        let resources = try bundle(english:["Open “%@”?":"Open “%@”?",warning:warning,"Show in Folder":"Show in Folder","Open":"Open","Cancel":"Cancel"],
            german:["Open “%@”?":"„%1$@“ öffnen?",warning:"Synthetischer Warnhinweis.","Show in Folder":"Im Ordner zeigen","Open":"Öffnen","Cancel":"Abbrechen"])
        let name = "100% %@ 日本語.txt"
        let alert = NativeSavedFileOpenPrompt.makeAlert(.init(localURL:URL(fileURLWithPath:"/synthetic/fixture.txt"),displayName:name),language:.german,bundle:resources)
        XCTAssertEqual(alert.messageText,"„"+name+"“ öffnen?")
        XCTAssertEqual(alert.informativeText,"Synthetischer Warnhinweis.")
        XCTAssertEqual(alert.buttons.map(\.title),["Im Ordner zeigen","Öffnen","Abbrechen"])
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent),["\r","","\u{1b}"])
    }
    @MainActor func testModelNotificationEnablementAndPersistenceDoNotDependOnTranslatedStatus() async throws {
        let initialDiagnostic = "No server notification events received this session"
        let resources = try bundle(english:["Enable notifications":"Enable notifications","Notifications enabled":"Notifications enabled",initialDiagnostic:initialDiagnostic,"Notification delivery test":"Notification delivery test"],
            german:["Enable notifications":"Benachrichtigungen aktivieren","Notifications enabled":"Benachrichtigungen aktiviert",initialDiagnostic:"Noch keine Serverbenachrichtigung","Notification delivery test":"Benachrichtigungstest"])
        let suite = "synthetic.notification-state."+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        var authorizations = 0
        let notifications = NativeChatNotifications(submit:{ _ in XCTFail("Toggle must not submit a message") },authorize:{ authorizations += 1;return true },language:.german,bundle:resources)
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,notifications:notifications,notificationDefaults:defaults)
        XCTAssertEqual(notifications.testMessageBody,"Benachrichtigungstest")
        XCTAssertEqual(model.notificationStatus,"Benachrichtigungen aktivieren")
        XCTAssertEqual(model.notificationDiagnostic,"Noch keine Serverbenachrichtigung")
        XCTAssertFalse(model.notificationHasStatusNotice)
        model.connected = true
        await model.toggleNotifications()
        XCTAssertTrue(notifications.isEnabled)
        XCTAssertTrue(model.notificationsEnabled)
        XCTAssertEqual(model.notificationStatus,"Benachrichtigungen aktiviert")
        XCTAssertTrue(defaults.bool(forKey:"nativePreviewNotificationsEnabled"))
        await model.toggleNotifications(restoreOnly:true)
        XCTAssertEqual(authorizations,1)
        XCTAssertTrue(model.notificationsEnabled)
        await model.toggleNotifications()
        XCTAssertFalse(notifications.isEnabled)
        XCTAssertFalse(model.notificationsEnabled)
        XCTAssertEqual(model.notificationStatus,"Benachrichtigungen aktivieren")
        XCTAssertFalse(model.notificationHasStatusNotice)
        XCTAssertFalse(defaults.bool(forKey:"nativePreviewNotificationsEnabled"))
    }
    @MainActor func testCancelledModelNotificationToggleCannotPersistLateAuthorization() async throws {
        let suite = "synthetic.cancelled-notification-state."+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let started = expectation(description:"Synthetic permission pending")
        var resume:CheckedContinuation<Bool,Error>?
        let notifications = NativeChatNotifications(submit:{ _ in XCTFail("Cancelled toggle must not submit") },authorize:{
            try await withCheckedThrowingContinuation { resume = $0;started.fulfill() }
        })
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,notifications:notifications,notificationDefaults:defaults)
        model.connected = true
        let toggle = Task { await model.toggleNotifications() }
        await fulfillment(of:[started],timeout:2)
        toggle.cancel();resume?.resume(returning:true)
        await toggle.value
        XCTAssertFalse(notifications.isEnabled)
        XCTAssertFalse(model.notificationsEnabled)
        XCTAssertNil(defaults.object(forKey:"nativePreviewNotificationsEnabled"))
    }
}
