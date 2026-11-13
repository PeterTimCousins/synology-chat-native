import Foundation

/// Presentation only: the archive's original wire timestamps remain untouched.
struct ChatArchivePeriodPresentation {
    let summary: String
    let identifier: String
    let exactRange: String
    let label: String
    let isAvailable: Bool

    init(archive: ChatArchive, regional: ChatRegionalDisplay? = nil,
         locale: Locale = .current, timeZone: TimeZone = .current) {
        identifier = "Archive \(archive.id)"
        let start = archive.post_start, end = archive.post_end
        // Restrict formatting to Gregorian years 1...9999, including the local
        // calendar date at either edge. ICU never sees nonfinite/extreme dates.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        func date(_ milliseconds: Double) -> Date? {
            guard milliseconds.isFinite, milliseconds >= -62_135_596_800_000,
                  milliseconds < 253_402_300_800_000 else { return nil }
            let value = Date(timeIntervalSince1970: milliseconds / 1000)
            let fields = calendar.dateComponents([.era, .year], from: value)
            guard fields.era == 1, let year = fields.year, (1...9999).contains(year) else { return nil }
            return value
        }
        guard start <= end, let first = date(start), let last = date(end) else {
            summary = "Unavailable archive period"; exactRange = summary
            label = identifier + " · " + summary; isAvailable = false; return
        }
        func offset(_ value: Date) -> String {
            let seconds = timeZone.secondsFromGMT(for: value)
            let magnitude = abs(seconds)
            let base = String(format: "UTC%@%02d:%02d", seconds < 0 ? "-" : "+", magnitude / 3600, (magnitude % 3600) / 60)
            return magnitude % 60 == 0 ? base : base + String(format: ":%02d", magnitude % 60)
        }
        let precise = DateFormatter()
        precise.locale = Locale(identifier: "en_US_POSIX"); precise.calendar = calendar; precise.timeZone = timeZone
        precise.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        func exact(_ value: Date) -> String { precise.string(from: value) + " " + offset(value) }
        let exactStart = exact(first), exactEnd = exact(last)
        let milliseconds = start.truncatingRemainder(dividingBy: 1000) != 0 || end.truncatingRemainder(dividingBy: 1000) != 0
        let precision: ChatTimePrecision = milliseconds ? .milliseconds : .seconds
        let localized = DateFormatter()
        localized.locale = locale; localized.calendar = calendar; localized.timeZone = timeZone
        localized.dateStyle = .medium; localized.timeStyle = .medium
        if milliseconds { localized.dateFormat = localized.dateFormat.replacingOccurrences(of: "ss", with: "ss.SSS") }
        func brief(_ value: Date) -> String {
            regional?.format(value, zone: timeZone, precision: precision) ?? localized.string(from: value)
        }
        let changingOffset = timeZone.secondsFromGMT(for: first) != timeZone.secondsFromGMT(for: last)
        let briefStart = brief(first) + (changingOffset ? " " + offset(first) : "")
        let briefEnd = brief(last) + (changingOffset ? " " + offset(last) : "")
        let submillisecondRange = start != end && exactStart == exactEnd
        let wireSuffix = submillisecondRange ? " (\(start)–\(end) ms since epoch)" : ""
        summary = submillisecondRange ? briefStart + " (less than 1 millisecond)" : (start == end ? briefStart : briefStart + " – " + briefEnd)
        exactRange = (start == end ? exactStart : exactStart + " – " + exactEnd) + wireSuffix
        label = identifier + " · " + summary
        isAvailable = true
    }
}
