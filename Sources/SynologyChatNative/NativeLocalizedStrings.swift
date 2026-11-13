import Foundation

/// Explicit interface-key lookup for AppKit and non-SwiftUI presentation.
/// User messages, names and server content must remain verbatim at call sites.
/// Catalog availability is separate from the language resolver's target list.
enum NativeLocalizedStrings {
    static var resourceBundle:Bundle { .module }

    static func text(_ key:String,language:NativeInterfaceLanguage = .system,
                     preferredLanguages:[String] = Locale.preferredLanguages,
                     bundle:Bundle = resourceBundle,table:String = "Localizable")->String {
        value(key,language:language,preferredLanguages:preferredLanguages,bundle:bundle,table:table)?.text ?? key
    }

    /// Only pass application-owned count keys, never message text or names.
    /// Use the language of the resource actually found, including English fallback,
    /// so plural selection does not borrow the machine's unrelated language.
    static func count(_ key:String,_ count:Int64,language:NativeInterfaceLanguage = .system,
                      preferredLanguages:[String] = Locale.preferredLanguages,
                      bundle:Bundle = resourceBundle,table:String = "Localizable")->String {
        guard let value = value(key,language:language,preferredLanguages:preferredLanguages,bundle:bundle,table:table) else { return key }
        return String(format:value.text,locale:Locale(identifier:value.localization),arguments:[count])
    }

    /// Non-plural numeric references (IDs/error codes) keep their exact ASCII
    /// digits. A formatting locale would add grouping separators even to %lld.
    static func integer(_ key:String,_ integer:Int64,language:NativeInterfaceLanguage = .system,
                        preferredLanguages:[String] = Locale.preferredLanguages,
                        bundle:Bundle = resourceBundle,table:String = "Localizable")->String {
        guard let value = value(key,language:language,preferredLanguages:preferredLanguages,bundle:bundle,table:table) else { return key }
        return String(format:value.text,arguments:[integer])
    }

    /// Application-owned single-string templates only. The substituted name is
    /// data, so percent signs, punctuation and non-Latin text remain verbatim.
    static func object(_ key:String,_ argument:String,language:NativeInterfaceLanguage = .system,
                       preferredLanguages:[String] = Locale.preferredLanguages,
                       bundle:Bundle = resourceBundle,table:String = "Localizable")->String {
        guard let value = value(key,language:language,preferredLanguages:preferredLanguages,bundle:bundle,table:table) else { return key }
        return String(format:value.text,locale:Locale(identifier:value.localization),arguments:[argument])
    }

    /// Two named pieces of presentation data; translators may reorder them
    /// using positional arguments without treating either value as a key.
    static func objects(_ key:String,_ first:String,_ second:String,language:NativeInterfaceLanguage = .system,
                        preferredLanguages:[String] = Locale.preferredLanguages,
                        bundle:Bundle = resourceBundle,table:String = "Localizable")->String {
        guard let value = value(key,language:language,preferredLanguages:preferredLanguages,bundle:bundle,table:table) else { return key }
        return String(format:value.text,locale:Locale(identifier:value.localization),arguments:[first,second])
    }

    private static func value(_ key:String,language:NativeInterfaceLanguage,preferredLanguages:[String],bundle:Bundle,table:String)->(text:String,localization:String)? {
        let resolved = NativeInterfaceLanguage.resolve(selection:language,preferredLanguages:preferredLanguages)
        if let id = resolved.appleLocalizationID,id != "en",let text = lookup(key,localization:id,bundle:bundle,table:table) { return (text,id) }
        if let text = lookup(key,localization:"en",bundle:bundle,table:table) { return (text,"en") }
        // Do not ask the outer bundle to choose an unrelated process language.
        return nil
    }

    private static func lookup(_ key:String,localization:String,bundle:Bundle,table:String)->String? {
        guard let url = bundle.url(forResource:localization,withExtension:"lproj"),let localized = Bundle(url:url) else { return nil }
        let missing = "__native_localization_missing_826b60a0_9513_45be__"
        let result = localized.localizedString(forKey:key,value:missing,table:table)
        return result == missing || result.isEmpty ? nil : result
    }
}
