import Foundation
import Combine

/// The official desktop locale targets, not a declaration that translated
/// catalogs are installed. This preference is independent of DSM Personal.lang.
enum NativeInterfaceLanguage:String,CaseIterable,Codable,Identifiable {
    case system = "def"
    case english = "enu"
    case french = "fre"
    case german = "ger"
    case italian = "ita"
    case spanish = "spn"
    case traditionalChinese = "cht"
    case simplifiedChinese = "chs"
    case japanese = "jpn"
    case korean = "krn"
    case thai = "tha"
    case russian = "rus"
    case dutch = "nld"
    case czech = "csy"
    case polish = "plk"
    case danish = "dan"
    case swedish = "sve"
    case hungarian = "hun"
    case turkish = "trk"
    case norwegian = "nor"
    case portuguese = "ptg"
    case brazilianPortuguese = "ptb"

    var id:String { rawValue }
    var nativeName:String {
        switch self {
        case .system: return "System default"
        case .english: return "English"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .italian: return "Italiano"
        case .spanish: return "Español"
        case .traditionalChinese: return "繁體中文"
        case .simplifiedChinese: return "简体中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .thai: return "ไทย"
        case .russian: return "Русский"
        case .dutch: return "Nederlands"
        case .czech: return "Čeština"
        case .polish: return "Polski"
        case .danish: return "Dansk"
        case .swedish: return "Svenska"
        case .hungarian: return "Magyar"
        case .turkish: return "Türkçe"
        case .norwegian: return "Norsk"
        case .portuguese: return "Português (Portugal)"
        case .brazilianPortuguese: return "Português (Brasil)"
        }
    }
    var appleLocalizationID:String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .french: return "fr"
        case .german: return "de"
        case .italian: return "it"
        case .spanish: return "es"
        case .traditionalChinese: return "zh-Hant"
        case .simplifiedChinese: return "zh-Hans"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .thai: return "th"
        case .russian: return "ru"
        case .dutch: return "nl"
        case .czech: return "cs"
        case .polish: return "pl"
        case .danish: return "da"
        case .swedish: return "sv"
        case .hungarian: return "hu"
        case .turkish: return "tr"
        case .norwegian: return "nb"
        case .portuguese: return "pt-PT"
        case .brazilianPortuguese: return "pt-BR"
        }
    }

    /// Resolve the requested target once at launch. Resource availability is a
    /// separate concern for the catalog loader; this never changes AppleLanguages.
    static func resolve(selection:Self,preferredLanguages:[String]) -> Self {
        guard selection == .system else { return selection }
        for tag in preferredLanguages {
            if let language = target(for:tag) { return language }
        }
        return .english
    }

    private static func target(for identifier:String) -> Self? {
        let tag = identifier.trimmingCharacters(in:.whitespacesAndNewlines)
            .replacingOccurrences(of:"_",with:"-").lowercased()
        let parts = tag.split(separator:"-",omittingEmptySubsequences:false).map(String.init)
        func alphabetic(_ value:String) -> Bool { !value.isEmpty && value.utf8.allSatisfy { (97...122).contains($0) } }
        func numeric(_ value:String) -> Bool { !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) } }
        guard let primary = parts.first,(2...8).contains(primary.count),alphabetic(primary),
              parts.dropFirst().allSatisfy({ part in
                  (1...8).contains(part.count) && part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
              }) else { return nil }
        // The grandfathered Nynorsk forms must not silently become Bokmål.
        if primary == "nn" || tag == "no-nyn" || tag == "no-no-ny" { return nil }
        if tag == "no-bok" { return .norwegian }
        var index = 1
        // BCP47 extlang subtags precede script and region. Unknown primary
        // languages remain unsupported even if a later subtag resembles one.
        if primary.count <= 3 {
            var extlangs = 0
            while index < parts.count,parts[index].count == 3,alphabetic(parts[index]),extlangs < 3 {
                index += 1;extlangs += 1
            }
        }
        var script:String?
        if index < parts.count,parts[index].count == 4,alphabetic(parts[index]) {
            script = parts[index];index += 1
        }
        var region:String?
        if index < parts.count {
            let candidate = parts[index]
            if (candidate.count == 2 && alphabetic(candidate)) || (candidate.count == 3 && numeric(candidate)) {
                region = candidate;index += 1
            }
        }
        // Validate remaining variants/extensions rather than deriving a target
        // from malformed identifiers such as en--US or en-US-u.
        while index < parts.count,parts[index].count > 1 {
            let part = parts[index]
            guard (5...8).contains(part.count) || (part.count == 4 && numeric(String(part.prefix(1)))) else { return nil }
            index += 1
        }
        var extensions = Set<String>()
        while index < parts.count {
            let singleton = parts[index]
            guard singleton.count == 1,extensions.insert(singleton).inserted else { return nil }
            index += 1
            let start = index
            if singleton == "x" {
                guard index < parts.count else { return nil };index = parts.count
            } else {
                while index < parts.count,parts[index].count >= 2 { index += 1 }
            }
            guard index > start else { return nil }
        }
        switch primary {
        case "en": return .english
        case "fr": return .french
        case "de": return .german
        case "it": return .italian
        case "es": return .spanish
        case "zh":
            if let script {
                if script == "hant" { return .traditionalChinese }
                if script == "hans" { return .simplifiedChinese }
                return nil
            }
            return ["tw","hk","mo"].contains(region ?? "") ? .traditionalChinese : .simplifiedChinese
        case "ja": return .japanese
        case "ko": return .korean
        case "th": return .thai
        case "ru": return .russian
        case "nl": return .dutch
        case "cs": return .czech
        case "pl": return .polish
        case "da": return .danish
        case "sv": return .swedish
        case "hu": return .hungarian
        case "tr": return .turkish
        case "nb","no": return .norwegian
        case "pt": return region == "br" ? .brazilianPortuguese : .portuguese
        default: return nil
        }
    }
}

/// Construct explicitly at the owning launch boundary. There is deliberately no
/// singleton or startup side effect; nil defaults keep the selection in memory.
@MainActor final class NativeInterfaceLanguagePreferences:ObservableObject {
    static let preferenceKey = "nativeDesktop.interfaceLanguage"
    @Published private(set) var selection:NativeInterfaceLanguage
    let activeLanguage:NativeInterfaceLanguage
    private let defaults:UserDefaults?
    private let preferredLanguages:[String]
    var requestedLanguage:NativeInterfaceLanguage { .resolve(selection:selection,preferredLanguages:preferredLanguages) }
    var requiresRestart:Bool { requestedLanguage != activeLanguage }

    init(defaults:UserDefaults? = nil,preferredLanguages:[String] = Locale.preferredLanguages) {
        self.defaults = defaults;self.preferredLanguages = preferredLanguages
        let stored = defaults?.object(forKey:Self.preferenceKey) as? String
        let selected = stored.flatMap(NativeInterfaceLanguage.init(rawValue:)) ?? .system
        selection = selected
        activeLanguage = .resolve(selection:selected,preferredLanguages:preferredLanguages)
        // Invalid or absent stored values remain untouched until a real change.
    }
    func setSelection(_ value:NativeInterfaceLanguage) {
        guard value != selection else { return }
        selection = value;defaults?.set(value.rawValue,forKey:Self.preferenceKey)
    }
}
