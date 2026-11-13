import XCTest
@testable import SynologyChatNative

@MainActor final class NativeInterfaceLanguageTests:XCTestCase {
    private func isolatedDefaults() throws -> (UserDefaults,String) {
        let suite = "NativeInterfaceLanguageTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defaults.removePersistentDomain(forName:suite)
        addTeardownBlock { defaults.removePersistentDomain(forName:suite) }
        return (defaults,suite)
    }
    private func resolve(_ tags:[String]) -> NativeInterfaceLanguage {
        .resolve(selection:.system,preferredLanguages:tags)
    }

    func testOfficialTargetInventoryAndAppleIdentifiersAreCompleteAndDistinct() {
        let expected:[String:String] = ["enu":"en","fre":"fr","ger":"de","ita":"it","spn":"es","cht":"zh-Hant","chs":"zh-Hans","jpn":"ja","krn":"ko","tha":"th","rus":"ru","nld":"nl","csy":"cs","plk":"pl","dan":"da","sve":"sv","hun":"hu","trk":"tr","nor":"nb","ptg":"pt-PT","ptb":"pt-BR"]
        let targets = NativeInterfaceLanguage.allCases.filter { $0 != .system }
        XCTAssertEqual(targets.count,21);XCTAssertEqual(NativeInterfaceLanguage.allCases.count,22)
        XCTAssertEqual(Set(targets.map(\.rawValue)),Set(expected.keys))
        XCTAssertEqual(Set(targets.compactMap(\.appleLocalizationID)).count,21)
        for language in targets {
            XCTAssertEqual(language.appleLocalizationID,expected[language.rawValue],language.rawValue)
            XCTAssertFalse(language.nativeName.isEmpty)
            XCTAssertEqual(resolve([language.appleLocalizationID!]),language,language.rawValue)
        }
        XCTAssertEqual(NativeInterfaceLanguage.system.rawValue,"def");XCTAssertNil(NativeInterfaceLanguage.system.appleLocalizationID)
    }
    func testAllTargetNativeNamesAreStableAndUseTheirOwnLanguage() {
        let names:[String:String] = ["enu":"English","fre":"Français","ger":"Deutsch","ita":"Italiano","spn":"Español","cht":"繁體中文","chs":"简体中文","jpn":"日本語","krn":"한국어","tha":"ไทย","rus":"Русский","nld":"Nederlands","csy":"Čeština","plk":"Polski","dan":"Dansk","sve":"Svenska","hun":"Magyar","trk":"Türkçe","nor":"Norsk","ptg":"Português (Portugal)","ptb":"Português (Brasil)"]
        for language in NativeInterfaceLanguage.allCases where language != .system {
            XCTAssertEqual(language.nativeName,names[language.rawValue])
        }
    }
    func testEveryExplicitSelectionOverridesSystemPreferences() {
        for language in NativeInterfaceLanguage.allCases where language != .system {
            XCTAssertEqual(NativeInterfaceLanguage.resolve(selection:language,preferredLanguages:["fi-FI","nn-NO","en-GB"]),language)
        }
    }
    func testRegionalLanguageFallbackForAllOrdinaryTargets() {
        let vectors:[(String,NativeInterfaceLanguage)] = [("en-AU",.english),("fr-CA",.french),("de-AT",.german),("it-CH",.italian),("es-MX",.spanish),("ja-JP",.japanese),("ko-KR",.korean),("th-TH",.thai),("ru-RU",.russian),("nl-BE",.dutch),("cs-CZ",.czech),("pl-PL",.polish),("da-DK",.danish),("sv-FI",.swedish),("hu-HU",.hungarian),("tr-TR",.turkish)]
        for (tag,expected) in vectors { XCTAssertEqual(resolve([tag]),expected,tag) }
        for tag in ["en-US","en-GB","en-CA","en-NZ","en-Latn-GB","en-US-u-ca-gregory"] {
            XCTAssertEqual(resolve([tag]),.english,tag)
        }
    }
    func testUnsupportedPreferencesFallThroughInOrderBeforeEnglishFallback() {
        XCTAssertEqual(resolve(["fi-FI","nn-NO","fr-CA","de-DE"]),.french)
        XCTAssertEqual(resolve(["ar","sv-SE","ja-JP"]),.swedish)
        XCTAssertEqual(resolve(["", "zz-ZZ", "fi-FI"]),.english)
        XCTAssertEqual(resolve([]),.english)
        XCTAssertEqual(resolve(["not a locale","en--GB","en-US-u","de-DE"]),.german)
        XCTAssertEqual(resolve(["FR_ca"]),.french)
        XCTAssertEqual(resolve(["  de-AT\n"]),.german)
    }
    func testChineseScriptOverridesRegionAndRegionFallbackIsDeterministic() {
        for tag in ["zh","zh-CN","zh-SG","zh-Hans","zh-Hans-TW","zh-Hans-HK","zh_Hans_CN"] {
            XCTAssertEqual(resolve([tag]),.simplifiedChinese,tag)
        }
        for tag in ["zh-TW","zh-HK","zh-MO","zh-Hant","zh-Hant-CN","zh-Hant-SG","zh_Hant_TW"] {
            XCTAssertEqual(resolve([tag]),.traditionalChinese,tag)
        }
        XCTAssertEqual(resolve(["zh-Latn-CN","ja-JP"]),.japanese)
        XCTAssertEqual(resolve(["yue-Hant-HK","zh-Hant-HK"]),.traditionalChinese)
    }
    func testPortugueseAndNorwegianDoNotConflateDistinctTargets() {
        for tag in ["pt-BR","pt-br","pt_Latn_BR","pt-BR-u-ca-gregory"] {
            XCTAssertEqual(resolve([tag]),.brazilianPortuguese,tag)
        }
        for tag in ["pt","pt-PT","pt-AO","pt-MZ","pt-Latn-PT"] {
            XCTAssertEqual(resolve([tag]),.portuguese,tag)
        }
        for tag in ["nb","nb-NO","no","no-NO","no-bok"] {
            XCTAssertEqual(resolve([tag]),.norwegian,tag)
        }
        for tag in ["nn","nn-NO","no-nyn","no-NO-NY"] {
            XCTAssertEqual(resolve([tag,"de-DE"]),.german,tag)
        }
    }
    func testMissingAndInvalidStoredValuesCauseNoInitializationWritesOrRepairs() throws {
        let (defaults,suite) = try isolatedDefaults()
        defaults.set("fre",forKey:"Personal.lang")
        defaults.set(["ja-JP"],forKey:"AppleLanguages")
        let baseline = NSDictionary(dictionary:defaults.persistentDomain(forName:suite) ?? [:])
        let missing = NativeInterfaceLanguagePreferences(defaults:defaults,preferredLanguages:["de-DE"])
        XCTAssertEqual(missing.selection,.system);XCTAssertEqual(missing.activeLanguage,.german)
        XCTAssertEqual(NSDictionary(dictionary:defaults.persistentDomain(forName:suite) ?? [:]),baseline)
        let invalidValues:[Any] = ["unknown-code","ENGLISH","en","",42,["enu"],["language":"fre"]]
        for value in invalidValues {
            defaults.set(value,forKey:NativeInterfaceLanguagePreferences.preferenceKey)
            let before = NSDictionary(dictionary:defaults.persistentDomain(forName:suite) ?? [:])
            let preferences = NativeInterfaceLanguagePreferences(defaults:defaults,preferredLanguages:["ja-JP"])
            XCTAssertEqual(preferences.selection,.system);XCTAssertEqual(preferences.activeLanguage,.japanese)
            XCTAssertFalse(preferences.requiresRestart)
            XCTAssertEqual(NSDictionary(dictionary:defaults.persistentDomain(forName:suite) ?? [:]),before)
        }
    }
    func testPersistenceRelaunchAndRestartDependOnEffectiveLanguage() throws {
        let (defaults,_) = try isolatedDefaults()
        defaults.set("ger",forKey:"Personal.lang");defaults.set(["it-IT"],forKey:"AppleLanguages")
        let preferences = NativeInterfaceLanguagePreferences(defaults:defaults,preferredLanguages:["fr-CA"])
        XCTAssertEqual(preferences.selection,.system);XCTAssertEqual(preferences.activeLanguage,.french)
        preferences.setSelection(.english)
        XCTAssertEqual(preferences.selection,.english);XCTAssertEqual(preferences.requestedLanguage,.english)
        XCTAssertEqual(preferences.activeLanguage,.french);XCTAssertTrue(preferences.requiresRestart)
        XCTAssertEqual(defaults.string(forKey:NativeInterfaceLanguagePreferences.preferenceKey),"enu")
        preferences.setSelection(.system);XCTAssertFalse(preferences.requiresRestart)
        preferences.setSelection(.french);XCTAssertFalse(preferences.requiresRestart,"Changing preference mode does not require restart when the effective language is unchanged")
        let relaunched = NativeInterfaceLanguagePreferences(defaults:defaults,preferredLanguages:["ja-JP"])
        XCTAssertEqual(relaunched.selection,.french);XCTAssertEqual(relaunched.activeLanguage,.french);XCTAssertFalse(relaunched.requiresRestart)
        relaunched.setSelection(.system)
        XCTAssertEqual(relaunched.requestedLanguage,.japanese);XCTAssertTrue(relaunched.requiresRestart)
        XCTAssertEqual(relaunched.activeLanguage,.french)
        let nextLaunch = NativeInterfaceLanguagePreferences(defaults:defaults,preferredLanguages:["ja-JP"])
        XCTAssertEqual(nextLaunch.selection,.system);XCTAssertEqual(nextLaunch.activeLanguage,.japanese);XCTAssertFalse(nextLaunch.requiresRestart)
        XCTAssertEqual(defaults.string(forKey:"Personal.lang"),"ger");XCTAssertEqual(defaults.stringArray(forKey:"AppleLanguages"),["it-IT"])
    }
    func testNilDefaultsAreMemoryOnlyAndDoNotShareSelections() {
        let first = NativeInterfaceLanguagePreferences(defaults:nil,preferredLanguages:["sv-SE"])
        XCTAssertEqual(first.activeLanguage,.swedish)
        first.setSelection(.traditionalChinese)
        XCTAssertEqual(first.selection,.traditionalChinese);XCTAssertEqual(first.requestedLanguage,.traditionalChinese)
        XCTAssertEqual(first.activeLanguage,.swedish);XCTAssertTrue(first.requiresRestart)
        let second = NativeInterfaceLanguagePreferences(defaults:nil,preferredLanguages:["sv-SE"])
        XCTAssertEqual(second.selection,.system);XCTAssertEqual(second.activeLanguage,.swedish);XCTAssertFalse(second.requiresRestart)
        first.setSelection(.system);XCTAssertFalse(first.requiresRestart)
    }
}
