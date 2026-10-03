import Foundation
import ImageIO
import ResultCore

/// Reads only capture/creation dates embedded in an image or encoded in the
/// supported screenshot filename convention. File-system dates are never used.
public enum ScreenshotDateReader {
    private static let tokyoTimeZone = TimeZone(identifier: "Asia/Tokyo")!

    /// Returns an empty array when the image cannot be opened or has no usable date.
    public static func read(data: Data, filename: String? = nil) -> [ScreenshotDateCandidate] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return read(properties: [:], filename: filename)
        }
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        return read(properties: properties, metadata: metadata, filename: filename)
    }

    /// Exposed for deterministic tests and callers that already decoded ImageIO metadata.
    public static func read(properties: [CFString: Any], metadata: CGImageMetadata? = nil, filename: String? = nil) -> [ScreenshotDateCandidate] {
        var candidates: [ScreenshotDateCandidate] = []

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if let raw = stringValue(exif[kCGImagePropertyExifDateTimeOriginal]) {
            let subsecond = stringValue(exif[kCGImagePropertyExifSubsecTimeOriginal])
            let offset = stringValue(exif[kCGImagePropertyExifOffsetTimeOriginal])
            if let parsed = parseExif(raw, subsecond: subsecond, offset: offset) {
                candidates.append(candidate(parsed, field: "EXIF.DateTimeOriginal"))
            }
        }

        let xmpFields: [(String, String)] = [
            ("exif:DateTimeOriginal", "XMP.exif.DateTimeOriginal"),
            ("xmp:CreateDate", "XMP.xmp.CreateDate"),
            ("photoshop:DateCreated", "XMP.photoshop.DateCreated")
        ]
        if let metadata {
            for (path, field) in xmpFields {
                guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
                      let raw = stringValue(CGImageMetadataTagCopyValue(tag)) else { continue }
                if let parsed = parseISO8601(raw) {
                    candidates.append(candidate(parsed, field: field))
                }
            }
        }

        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        if let date = stringValue(iptc[kCGImagePropertyIPTCDateCreated]),
           let time = stringValue(iptc[kCGImagePropertyIPTCTimeCreated]),
           let parsed = parseIPTC(date: date, time: time) {
            candidates.append(candidate(parsed, field: "IPTC.DateCreated"))
        }

        // A single metadata field can surface through both ImageIO properties and XMP.
        // Keep one copy of identical evidence while preserving distinct conflicting fields.
        var seen = Set<String>()
        candidates = candidates.filter {
            let key = "\($0.metadataField ?? "")|\($0.capturedAt.timeIntervalSince1970)|\($0.timeZone)|\($0.timeZoneAssumed)"
            return seen.insert(key).inserted
        }
        candidates.sort {
            if $0.capturedAt != $1.capturedAt { return $0.capturedAt < $1.capturedAt }
            return ($0.metadataField ?? "") < ($1.metadataField ?? "")
        }
        if !candidates.isEmpty { return candidates }

        if let filename, let parsed = parseFilename(filename) {
            return [ScreenshotDateCandidate(capturedAt: parsed.date, source: .filename, metadataField: nil,
                                            timeZone: parsed.timeZone, timeZoneAssumed: true)]
        }
        return []
    }

    private static func candidate(_ value: ParsedDate, field: String) -> ScreenshotDateCandidate {
        ScreenshotDateCandidate(capturedAt: value.date, source: .metadata, metadataField: field,
                                timeZone: value.timeZone, timeZoneAssumed: value.assumed)
    }

    private struct ParsedDate {
        var date: Date
        var timeZone: String
        var assumed: Bool
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func parseExif(_ raw: String, subsecond: String?, offset: String?) -> ParsedDate? {
        let pattern = #"^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})$"#
        guard let match = match(raw, pattern: pattern), match.count == 7,
              let year = Int(match[1]), let month = Int(match[2]), let day = Int(match[3]),
              let hour = Int(match[4]), let minute = Int(match[5]), let second = Int(match[6]),
              let fraction = fractionValue(subsecond ?? ""),
              let zone = parseOffset(offset, colonOptional: false) else { return nil }
        return makeDate(year: year, month: month, day: day, hour: hour, minute: minute,
                        second: second, fraction: fraction, zone: zone)
    }

    private static func parseISO8601(_ raw: String) -> ParsedDate? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:?\d{2})?$"#
        guard let match = match(raw, pattern: pattern), match.count == 9,
              let year = Int(match[1]), let month = Int(match[2]), let day = Int(match[3]),
              let hour = Int(match[4]), let minute = Int(match[5]), let second = Int(match[6]),
              let fraction = fractionValue(match[7]),
              let zone = parseOffset(match[8], colonOptional: true) else { return nil }
        return makeDate(year: year, month: month, day: day, hour: hour, minute: minute,
                        second: second, fraction: fraction, zone: zone)
    }

    private static func parseIPTC(date: String, time: String) -> ParsedDate? {
        let datePattern = #"^(\d{4})(\d{2})(\d{2})$"#
        let timePattern = #"^(\d{2})(\d{2})(\d{2})(?:\.(\d{1,9}))?([+-]\d{2}:?\d{2})?$"#
        guard let dateParts = match(date, pattern: datePattern), dateParts.count == 4,
              let timeParts = match(time, pattern: timePattern), timeParts.count == 6,
              let year = Int(dateParts[1]), let month = Int(dateParts[2]), let day = Int(dateParts[3]),
              let hour = Int(timeParts[1]), let minute = Int(timeParts[2]), let second = Int(timeParts[3]),
              let fraction = fractionValue(timeParts[4]),
              let zone = parseOffset(timeParts[5], colonOptional: true) else { return nil }
        return makeDate(year: year, month: month, day: day, hour: hour, minute: minute,
                        second: second, fraction: fraction, zone: zone)
    }

    private static func parseFilename(_ filename: String) -> ParsedDate? {
        // Match only the entire base filename, with the exact supported naming convention.
        let pattern = #"(?i)^screenshot_(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})_(\d{3})\.(png|jpg|jpeg|heic)$"#
        guard let parts = match(URL(fileURLWithPath: filename).lastPathComponent, pattern: pattern), parts.count == 9,
              let year = Int(parts[1]), let month = Int(parts[2]), let day = Int(parts[3]),
              let hour = Int(parts[4]), let minute = Int(parts[5]), let second = Int(parts[6]),
              let millis = Int(parts[7]),
              let value = makeDate(year: year, month: month, day: day, hour: hour, minute: minute,
                                   second: second, fraction: Double(millis) / 1000,
                                   zone: .assumedTokyo) else { return nil }
        return value
    }

    private enum ZoneValue {
        case assumedTokyo
        case explicit(TimeZone, label: String)
    }

    private static func parseOffset(_ value: String?, colonOptional: Bool) -> ZoneValue? {
        guard let value else { return .assumedTokyo }
        if value.isEmpty || value == "Z" { return value == "Z" ? .explicit(TimeZone(secondsFromGMT: 0)!, label: "UTC") : .assumedTokyo }
        let pattern = colonOptional ? #"^([+-])(\d{2}):?(\d{2})$"# : #"^([+-])(\d{2}):(\d{2})$"#
        guard let parts = match(value, pattern: pattern), parts.count == 4,
              let hours = Int(parts[2]), let minutes = Int(parts[3]),
              hours <= 14, minutes <= 59, (hours < 14 || minutes == 0) else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (parts[1] == "-" ? -1 : 1)
        guard let zone = TimeZone(secondsFromGMT: seconds) else { return nil }
        return .explicit(zone, label: String(format: "%@%02d:%02d", parts[1], hours, minutes))
    }

    private static func fractionValue(_ raw: String) -> Double? {
        guard raw.isEmpty || raw.range(of: #"^\d{1,9}$"#, options: .regularExpression) != nil else { return nil }
        guard !raw.isEmpty else { return 0 }
        return Double("0." + raw)
    }

    private static func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int,
                                 second: Int, fraction: Double, zone: ZoneValue) -> ParsedDate? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second),
              fraction >= 0, fraction < 1 else { return nil }
        let timeZone: TimeZone
        let label: String
        let assumed: Bool
        switch zone {
        case .assumedTokyo:
            timeZone = tokyoTimeZone; label = "Asia/Tokyo"; assumed = true
        case .explicit(let explicit, let explicitLabel):
            timeZone = explicit; label = explicitLabel; assumed = false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        guard let date = calendar.date(from: components) else { return nil }
        let checked = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard checked.year == year, checked.month == month, checked.day == day,
              checked.hour == hour, checked.minute == minute, checked.second == second else { return nil }
        return ParsedDate(date: date.addingTimeInterval(fraction), timeZone: label, assumed: assumed)
    }

    private static func match(_ value: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              result.range.location == 0, result.range.length == (value as NSString).length else { return nil }
        let nsValue = value as NSString
        return (0..<result.numberOfRanges).map { index in
            let range = result.range(at: index)
            return range.location == NSNotFound ? "" : nsValue.substring(with: range)
        }
    }
}
