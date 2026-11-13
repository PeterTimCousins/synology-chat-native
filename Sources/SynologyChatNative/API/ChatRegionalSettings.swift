import Foundation

struct ChatDesktopPersonalSettings:Decodable {
    let Personal:[String:ChatJSON]
    var language:String { Personal["lang"]?.string ?? "def" }
    var dateFormat:String { Personal["dateFormat"]?.string ?? "system" }
    var timeFormat:String { Personal["timeFormat"]?.string ?? "system" }
}
struct ChatRegionalDefaults:Decodable {
    struct Values:Decodable { let date_format:String?;let time_format:String? }
    let Session:Values
}
enum ChatTimePrecision { case minutes, seconds, milliseconds }

struct ChatRegionalDisplay {
    let personal:ChatDesktopPersonalSettings
    let defaults:ChatRegionalDefaults
    static let dateFormats = ["Y-m-d","Y/m/d","Y.m.d","d-m-Y","d/m/Y","d.m.Y","m-d-Y","m/d/Y","m.d.Y"]
    static let timeFormats = ["h:i a","H:i"]
    static let languages:[(String,String)] = [("def","Device default"),("enu","English"),("fre","Français"),("ger","Deutsch"),("ita","Italiano"),("spn","Español"),("cht","繁體中文"),("chs","简体中文"),("jpn","日本語"),("krn","한국어"),("tha","ไทย"),("rus","Русский"),("nld","Nederlands"),("csy","Čeština"),("plk","Polski"),("dan","Dansk"),("sve","Svenska"),("hun","Magyar"),("trk","Türkçe"),("nor","Norsk"),("ptg","Português"),("ptb","Português (Brasil)")]
    func format(_ date:Date,dateOnly:Bool = false,timeOnly:Bool = false,zone:TimeZone = .current,precision:ChatTimePrecision = .minutes) -> String {
        let rawDate = personal.dateFormat == "system" ? defaults.Session.date_format ?? "Y-m-d" : personal.dateFormat
        let rawTime = personal.timeFormat == "system" ? defaults.Session.time_format ?? "H:i" : personal.timeFormat
        let f = DateFormatter();f.locale = Locale(identifier:"en_US_POSIX");f.calendar = Calendar(identifier:.gregorian);f.timeZone = zone
        if Self.dateFormats.contains(rawDate),Self.timeFormats.contains(rawTime) {
            let d = rawDate.replacingOccurrences(of:"Y",with:"yyyy").replacingOccurrences(of:"m",with:"MM").replacingOccurrences(of:"d",with:"dd")
            let seconds = precision == .minutes ? "" : precision == .seconds ? ":ss" : ":ss.SSS"
            let t = rawTime == "H:i" ? "HH:mm" + seconds : "hh:mm" + seconds + " a"
            f.amSymbol = "am";f.pmSymbol = "pm";f.dateFormat = timeOnly ? t : dateOnly ? d : d+" "+t
        } else { f.dateStyle = timeOnly ? .none : .short;f.timeStyle = dateOnly ? .none : precision == .minutes ? .short : .medium
            if !dateOnly,precision == .milliseconds { f.dateFormat = f.dateFormat.replacingOccurrences(of:"ss",with:"ss.SSS") }
        }
        return f.string(from:date)
    }
}
struct ChatRegionalDraft {
    var language:String
    var dateFormat:String
    var timeFormat:String
    init(_ settings:ChatDesktopPersonalSettings) { language = settings.language;dateFormat = settings.dateFormat;timeFormat = settings.timeFormat }
    func changes(from original:ChatDesktopPersonalSettings) throws -> [String:String] {
        var result:[String:String] = [:]
        for (key,value,before,allowed) in [("lang",language,original.language,ChatRegionalDisplay.languages.map(\.0)),("dateFormat",dateFormat,original.dateFormat,["system"]+ChatRegionalDisplay.dateFormats),("timeFormat",timeFormat,original.timeFormat,["system"]+ChatRegionalDisplay.timeFormats)] where value != before {
            guard allowed.contains(value) else { throw ChatTransferError(message:"Choose a supported regional preference.") };result[key] = value
        }
        return result
    }
}
struct ChatTimeZoneOption:Decodable,Identifiable,Equatable {
    let value:String
    let display:String
    let offset:Int
    var id:String { value }
}
struct ChatRegionalSnapshot {
    let personal:ChatDesktopPersonalSettings
    let defaults:ChatRegionalDefaults
    let zones:[ChatTimeZoneOption]
    let userID:Int64
    let timezone:String
    let policy:ChatProfileEditingPolicy
    let accountGeneration:Int
    var selectedTimeZone:String {timezone.isEmpty ? "def" : timezone}
    var display:ChatRegionalDisplay { .init(personal:personal,defaults:defaults) }
}
