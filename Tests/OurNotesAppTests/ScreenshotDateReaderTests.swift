import XCTest
import ImageIO
import ResultCore
@testable import OurNotesApp

final class ScreenshotDateReaderTests: XCTestCase {
    func testExifUsesOriginalDateSubsecondsAndExplicitOffset() throws {
        let props: [CFString: Any] = [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2024:02:29 12:34:56",
            kCGImagePropertyExifSubsecTimeOriginal: "125",
            kCGImagePropertyExifOffsetTimeOriginal: "+09:00"
        ] as [CFString: Any]]

        let candidates = ScreenshotDateReader.read(properties: props)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].source, .metadata)
        XCTAssertEqual(candidates[0].metadataField, "EXIF.DateTimeOriginal")
        XCTAssertEqual(candidates[0].timeZone, "+09:00")
        XCTAssertFalse(candidates[0].timeZoneAssumed)
        XCTAssertEqual(candidates[0].capturedAt.timeIntervalSince1970, utcDate(2024, 2, 29, 3, 34, 56).timeIntervalSince1970 + 0.125, accuracy: 0.0001)
    }

    func testExifWithoutOffsetAssumesTokyoAndRejectsInvalidCalendarDate() {
        let valid: [CFString: Any] = [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2024:02:29 23:59:59"
        ] as [CFString: Any]]
        let invalid: [CFString: Any] = [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2023:02:29 23:59:59"
        ] as [CFString: Any]]

        let candidates = ScreenshotDateReader.read(properties: valid)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].timeZone, "Asia/Tokyo")
        XCTAssertTrue(candidates[0].timeZoneAssumed)
        XCTAssertEqual(candidates[0].capturedAt, utcDate(2024, 2, 29, 14, 59, 59))
        XCTAssertTrue(ScreenshotDateReader.read(properties: invalid).isEmpty)
    }

    func testIPTCCreationDateAndTimeWithOffset() {
        let props: [CFString: Any] = [kCGImagePropertyIPTCDictionary: [
            kCGImagePropertyIPTCDateCreated: "20250102",
            kCGImagePropertyIPTCTimeCreated: "030405+0930"
        ] as [CFString: Any]]

        let candidates = ScreenshotDateReader.read(properties: props)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].metadataField, "IPTC.DateCreated")
        XCTAssertEqual(candidates[0].timeZone, "+09:30")
        XCTAssertEqual(candidates[0].capturedAt, utcDate(2025, 1, 1, 17, 34, 5))
    }

    func testXMPCandidatesPreserveConflictsAndSortByDateThenField() throws {
        let metadata = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.adobe.com/exif/1.0/" as CFString, "exif" as CFString, nil))
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.adobe.com/xap/1.0/" as CFString, "xmp" as CFString, nil))
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.adobe.com/photoshop/1.0/" as CFString, "photoshop" as CFString, nil))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "exif:DateTimeOriginal" as CFString, "2025-01-03T03:04:05+09:00" as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:CreateDate" as CFString, "2025-01-02T03:04:05Z" as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "photoshop:DateCreated" as CFString, "2024-12-31T20:00:00-05:00" as CFString))

        let candidates = ScreenshotDateReader.read(properties: [:], metadata: metadata)

        XCTAssertEqual(candidates.map(\.metadataField), ["XMP.photoshop.DateCreated", "XMP.xmp.CreateDate", "XMP.exif.DateTimeOriginal"])
        XCTAssertEqual(candidates[0].capturedAt, utcDate(2025, 1, 1, 1, 0, 0))
        XCTAssertEqual(candidates[1].capturedAt, utcDate(2025, 1, 2, 3, 4, 5))
        XCTAssertEqual(candidates[2].capturedAt, utcDate(2025, 1, 2, 18, 4, 5))
        XCTAssertEqual(candidates.map(\.timeZoneAssumed), [false, false, false])
    }

    func testFilenameFallbackRequiresFullValidSupportedNameAndMetadataWins() {
        let filename = "screenshot_20251031_235959_007.HEIC"

        let fallback = ScreenshotDateReader.read(data: Data("not an image".utf8), filename: filename)

        XCTAssertEqual(fallback.count, 1)
        XCTAssertEqual(fallback[0].source, .filename)
        XCTAssertNil(fallback[0].metadataField)
        XCTAssertEqual(fallback[0].timeZone, "Asia/Tokyo")
        XCTAssertTrue(fallback[0].timeZoneAssumed)
        XCTAssertEqual(fallback[0].capturedAt, utcDate(2025, 10, 31, 14, 59, 59).addingTimeInterval(0.007))

        let metadataProps: [CFString: Any] = [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2025:10:30 12:00:00"
        ] as [CFString: Any]]
        let metadataWins = ScreenshotDateReader.read(properties: metadataProps, filename: filename)
        XCTAssertEqual(metadataWins.map(\.source), [.metadata])
        XCTAssertEqual(ScreenshotDateReader.read(data: Data(), filename: "prefix_\(filename)").count, 0)
        XCTAssertEqual(ScreenshotDateReader.read(data: Data(), filename: "screenshot_20250230_120000_000.png").count, 0)
        XCTAssertEqual(ScreenshotDateReader.read(data: Data(), filename: "screenshot_20250101_120000_000.gif").count, 0)
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }
}
