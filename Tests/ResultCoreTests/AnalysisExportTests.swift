import Foundation
import XCTest
@testable import ResultCore

final class AnalysisExportTests: XCTestCase {
    private let gameID = "test-game"
    private let exportedAt = Date(timeIntervalSince1970: 1_800_000_000.125)

    private func makePlay(
        id: UUID = UUID(), chartID: UUID, gameID: String = "test-game",
        title: String = "Song", difficulty: String = "EXPERT", level: Int? = 30,
        score: Int = 900_000, confirmed: Bool = true, playedAt: Date? = nil,
        importedAt: Date = Date(timeIntervalSince1970: 100),
        achievement: Achievement = .unknown,
        judgments: [Judgment: JudgmentCount] = [:],
        environment: PlayEnvironment? = nil,
        screenshotDates: [ScreenshotDateEvidence]? = nil,
        dateContext: PlayDateContext? = nil,
        fingerprints: [SourceFingerprint] = []
    ) -> PlayRecord {
        PlayRecord(id: id, chartID: chartID, gameID: gameID, titleAtPlay: title,
                   difficultyAtPlay: difficulty, levelAtPlay: level, score: score,
                   achievement: achievement, judgments: judgments, importedAt: importedAt,
                   playedAt: playedAt, presetID: "preset", presetVersion: 4,
                   environment: environment, fingerprints: fingerprints, confirmed: confirmed,
                   screenshotDates: screenshotDates, dateContext: dateContext)
    }

    private func encode(_ state: AppState, gameID: String? = nil) throws -> (AnalysisExportDocument, [String: Any], Data) {
        let document = try AnalysisExportService.document(
            state: state, gameID: gameID ?? self.gameID,
            app: .init(version: "9.8.7", build: "123"), exportedAt: exportedAt
        )
        let data = try AnalysisExportService.encode(document)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (document, json, data)
    }

    func testExportsConfirmedHistoryAndCompleteGameCatalogIncludingRetiredAndUnplayed() throws {
        let activeSong = Song(gameID: gameID, masterTitle: "Active")
        let retiredSong = Song(gameID: gameID, masterTitle: "Retired", availability: .retired)
        let otherGameSong = Song(gameID: "other-game", masterTitle: "Out of scope")
        let activeChart = Chart(songID: activeSong.id, masterDifficulty: "EXPERT", masterLevel: 30)
        let retiredChart = Chart(songID: retiredSong.id, masterDifficulty: "MASTER", masterLevel: 31, availability: .retired)
        let unplayedChart = Chart(songID: activeSong.id, masterDifficulty: "HARD", masterLevel: 20)
        let otherChart = Chart(songID: otherGameSong.id, masterDifficulty: "EXPERT", masterLevel: 10)
        var state = AppState()
        state.songs = [activeSong, retiredSong, otherGameSong]
        state.charts = [activeChart, retiredChart, unplayedChart, otherChart]
        state.plays = [
            makePlay(chartID: activeChart.id, title: "Active", confirmed: true),
            makePlay(chartID: activeChart.id, confirmed: false),
            makePlay(chartID: otherChart.id, gameID: "other-game")
        ]

        let (document, json, _) = try encode(state)

        XCTAssertEqual(document.exportedPlayCount, 1)
        XCTAssertEqual(document.excludedUnconfirmedPlayCount, 1)
        XCTAssertEqual(document.songs.map(\.id).sorted { $0.uuidString < $1.uuidString }, [activeSong.id, retiredSong.id].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(Set(document.charts.map(\.id)), [activeChart.id, retiredChart.id, unplayedChart.id])
        XCTAssertEqual(document.plays.map(\.id), [state.plays[0].id])
        XCTAssertEqual(json["format"] as? String, "our-notes-analysis")
        XCTAssertEqual(json["formatVersion"] as? Int, AnalysisExportService.formatVersion)
        XCTAssertEqual(json["analysisRulesVersion"] as? Int, AnalysisExportService.analysisRulesVersion)
        XCTAssertEqual((json["app"] as? [String: Any])?["version"] as? String, "9.8.7")
        XCTAssertEqual((json["app"] as? [String: Any])?["build"] as? String, "123")
        XCTAssertEqual(json["exportedAt"] as? String, "2027-01-15T08:00:00.125Z")
    }

    func testNullZeroFalseAndUnknownAchievementStayDistinctInJSON() throws {
        let song = Song(gameID: gameID, masterTitle: "Song")
        let chart = Chart(songID: song.id, masterDifficulty: "EXPERT")
        let environment = PlayEnvironment(name: " ", device: "", audioOutput: "", conditions: "", settings: .init(noteSpeed: 0, noteTiming: nil, chartPosition: 0, mirror: false))
        let play = makePlay(chartID: chart.id, level: nil, achievement: .unknown,
                            judgments: [.perfect: .init(total: 0, fast: 0, slow: nil)], environment: environment)
        var state = AppState(); state.songs = [song]; state.charts = [chart]; state.plays = [play]

        let (_, json, _) = try encode(state)
        let exported = try XCTUnwrap((json["plays"] as? [[String: Any]])?.first)
        let settings = try XCTUnwrap((exported["environmentSnapshot"] as? [String: Any])?["settings"] as? [String: Any])
        let judgments = try XCTUnwrap(exported["judgments"] as? [String: Any])
        let perfect = try XCTUnwrap(judgments["PERFECT"] as? [String: Any])

        XCTAssertEqual(exported["achievement"] as? String, "unknown")
        XCTAssertTrue(exported["levelAtPlay"] is NSNull)
        XCTAssertEqual(settings["noteSpeed"] as? Int, 0)
        XCTAssertTrue(settings["noteTiming"] is NSNull)
        XCTAssertEqual(settings["chartPosition"] as? Int, 0)
        XCTAssertEqual(settings["mirror"] as? Bool, false)
        XCTAssertEqual(perfect["total"] as? Int, 0)
        XCTAssertEqual(perfect["fast"] as? Int, 0)
        XCTAssertTrue(perfect["slow"] is NSNull)
        XCTAssertTrue((judgments["MISS"] as? [String: Any])?["total"] is NSNull)
        let snapshot = try XCTUnwrap(exported["environmentSnapshot"] as? [String: Any])
        XCTAssertTrue(snapshot["name"] is NSNull)
        XCTAssertTrue(snapshot["device"] is NSNull)
    }

    func testRepeatedPlaysUsePlayedAtOrImportedAtAndDeterministicUUIDTieBreak() throws {
        let song = Song(gameID: gameID, masterTitle: "Song")
        let chart = Chart(songID: song.id, masterDifficulty: "EXPERT")
        let tieEarlyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let tieLateID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let fallbackID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let first = makePlay(id: tieLateID, chartID: chart.id, score: 1, playedAt: Date(timeIntervalSince1970: 20), importedAt: Date(timeIntervalSince1970: 2))
        let second = makePlay(id: tieEarlyID, chartID: chart.id, score: 2, playedAt: Date(timeIntervalSince1970: 20), importedAt: Date(timeIntervalSince1970: 3))
        let fallback = makePlay(id: fallbackID, chartID: chart.id, score: 3, importedAt: Date(timeIntervalSince1970: 10))
        var state = AppState(); state.songs = [song]; state.charts = [chart]; state.plays = [first, fallback, second]

        let (document, json, _) = try encode(state)

        XCTAssertEqual(document.plays.map(\.id), [fallbackID, tieEarlyID, tieLateID])
        let rows = try XCTUnwrap(json["plays"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["orderDateSource"] as? String }, ["importedAt", "playedAt", "playedAt"])
        XCTAssertEqual(rows.map { $0["orderDate"] as? String }, ["1970-01-01T00:00:10.000Z", "1970-01-01T00:00:20.000Z", "1970-01-01T00:00:20.000Z"])
        XCTAssertEqual(Set(rows.compactMap { $0["id"] as? String }).count, 3)
        XCTAssertTrue(document.analysisRules.chronology.contains("UUID ties do not imply actual play order"))
    }

    func testHistoricalEnvironmentSnapshotSurvivesCurrentEnvironmentChange() throws {
        let song = Song(gameID: gameID, masterTitle: "Song")
        let chart = Chart(songID: song.id, masterDifficulty: "EXPERT")
        let envID = UUID()
        let historical = PlayEnvironment(id: envID, name: "Old", device: "Tablet A", audioOutput: "Wired", conditions: "Quiet", settings: .init(noteSpeed: 10, noteTiming: 0, chartPosition: 2, mirror: false))
        let current = PlayEnvironment(id: envID, name: "Current", device: "Tablet B", audioOutput: "Bluetooth", conditions: "Noisy", settings: .init(noteSpeed: 11, noteTiming: 1, chartPosition: 3, mirror: true))
        let play = makePlay(chartID: chart.id, environment: historical)
        var state = AppState(); state.songs = [song]; state.charts = [chart]; state.plays = [play]; state.environments = [current]

        let (document, json, _) = try encode(state)

        XCTAssertEqual(document.plays.first?.environmentSnapshot?.settings.noteSpeed, 10)
        XCTAssertEqual(document.currentEnvironments.first?.settings.noteSpeed, 11)
        let row = try XCTUnwrap((json["plays"] as? [[String: Any]])?.first)
        let snapshot = try XCTUnwrap(row["environmentSnapshot"] as? [String: Any])
        XCTAssertEqual(snapshot["device"] as? String, "Tablet A")
        XCTAssertEqual(((snapshot["settings"] as? [String: Any])?["noteTiming"] as? Int), 0)
    }

    func testScreenshotEvidenceIsExportedButFingerprintsPathsAndOCRSentinelsAreNot() throws {
        let song = Song(gameID: gameID, masterTitle: "Song")
        let chart = Chart(songID: song.id, masterDifficulty: "EXPERT")
        let evidence = ScreenshotDateEvidence(imageKind: .normal, candidates: [
            .init(capturedAt: exportedAt, source: .metadata, metadataField: "EXIF DateTimeOriginal", timeZone: "Asia/Tokyo", timeZoneAssumed: false)
        ])
        let reference = ScreenshotDateReference(screenshotID: evidence.id, candidateIndex: 0)
        let play = makePlay(chartID: chart.id, playedAt: exportedAt, screenshotDates: [evidence], dateContext: .init(selectedScreenshotDate: reference, playedAtSource: .screenshot), fingerprints: [.init(sha256: "FORBIDDEN_FINGERPRINT_SENTINEL", perceptualHash: 123, layout: "FORBIDDEN_LAYOUT_SENTINEL")])
        var state = AppState(); state.songs = [song]; state.charts = [chart]; state.plays = [play]

        let (_, json, data) = try encode(state)
        let text = String(decoding: data, as: UTF8.self)
        let row = try XCTUnwrap((json["plays"] as? [[String: Any]])?.first)
        let dates = try XCTUnwrap(row["screenshotDates"] as? [[String: Any]])
        XCTAssertEqual(dates.count, 1)
        XCTAssertEqual(dates[0]["imageKind"] as? String, "normal")
        XCTAssertEqual(row["playedAtSource"] as? String, "screenshot")
        for forbidden in ["FORBIDDEN_FINGERPRINT_SENTINEL", "FORBIDDEN_LAYOUT_SENTINEL", "sha256", "perceptualHash", "filePath", "imagePath", "rawOCR", "OCRCandidate", "confidence"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden), "Unexpected forbidden export content: \(forbidden)")
        }
    }

    func testBrokenChartReferenceThrowsInsteadOfSilentlyDroppingPlay() {
        let song = Song(gameID: gameID, masterTitle: "Song")
        var state = AppState(); state.songs = [song]
        state.plays = [makePlay(chartID: UUID())]
        XCTAssertThrowsError(try AnalysisExportService.document(state: state, gameID: gameID, app: .init(version: "1", build: "1")))
    }

    func testExportIdentifiesCrossSongRulesSeparatelyFromLegacyChartRules() throws {
        let (_, json, _) = try encode(AppState())
        let rules = try XCTUnwrap(json["analysisRules"] as? [String: Any])
        let timing = try XCTUnwrap(rules["timingRecommendation"] as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, 1)
        XCTAssertEqual(json["analysisRulesVersion"] as? Int, 2)
        XCTAssertEqual(timing["minimumSongs"] as? Int, 3)
        XCTAssertEqual(timing["maximumRecentPlays"] as? Int, 10)
        XCTAssertTrue((timing["scope"] as? String ?? "").contains("levelAtPlay"))
        XCTAssertTrue((timing["aggregation"] as? String ?? "").contains("equal-weight"))
        XCTAssertTrue((timing["aggregation"] as? String ?? "").contains("minimumPlays alone is insufficient"))
        XCTAssertTrue((timing["eligible"] as? String ?? "").contains("select once before level splitting"))
        XCTAssertFalse((timing["eligible"] as? String ?? "").contains("same chartID"))
        XCTAssertNotNil(timing["levelConflict"])
        XCTAssertNotNil(timing["unknownLevel"])
    }

    func testExportStatisticsCanBeRecomputedAndMatchStatisticsService() throws {
        let song = Song(gameID: gameID, masterTitle: "Song")
        let chart = Chart(songID: song.id, masterDifficulty: "EXPERT")
        let completeCounts: [Judgment: JudgmentCount] = [
            .perfect: .init(total: 80, fast: 40, slow: 40), .great: .init(total: 10, fast: 7, slow: 3),
            .good: .init(total: 5, fast: 2, slow: 3), .bad: .init(total: 3, fast: 1, slow: 2), .miss: .init(total: 2, fast: 0, slow: 2)
        ]
        let rows = [
            makePlay(chartID: chart.id, score: 900_000, achievement: .fc, judgments: completeCounts),
            makePlay(chartID: chart.id, score: 950_000, achievement: .ap, judgments: completeCounts),
            makePlay(chartID: chart.id, score: 800_000, achievement: .unknown, judgments: [.perfect: .init(total: 100)])
        ]
        var state = AppState(); state.songs = [song]; state.charts = [chart]; state.plays = rows

        let (document, json, _) = try encode(state)
        let stats = StatisticsService.summarize(rows)
        let exported = try XCTUnwrap(json["plays"] as? [[String: Any]])
        let achievementKnown = exported.filter { ($0["achievement"] as? String) != "unknown" }
        let fcCount = achievementKnown.filter { ["fc", "ap"].contains($0["achievement"] as? String ?? "") }.count
        let apCount = achievementKnown.filter { ($0["achievement"] as? String) == "ap" }.count
        let complete = exported.filter { row in
            guard let judgments = row["judgments"] as? [String: [String: Any]] else { return false }
            return ["PERFECT", "GREAT", "GOOD", "BAD", "MISS"].allSatisfy { judgments[$0]?["total"] is Int }
        }
        var noteTotal = 0
        var totals: [String: Int] = [:]
        for row in complete {
            let judgments = row["judgments"] as! [String: [String: Any]]
            for key in ["PERFECT", "GREAT", "GOOD", "BAD", "MISS"] {
                let count = judgments[key]!["total"] as! Int
                noteTotal += count; totals[key, default: 0] += count
            }
        }
        let timingRows = exported.compactMap { row -> (Int, Int)? in
            guard let judgments = row["judgments"] as? [String: [String: Any]],
                  let pf = judgments["PERFECT"]?["fast"] as? Int, let ps = judgments["PERFECT"]?["slow"] as? Int,
                  let gf = judgments["GREAT"]?["fast"] as? Int, let gs = judgments["GREAT"]?["slow"] as? Int,
                  pf + ps + gf + gs > 0 else { return nil }
            return (pf + gf, ps + gs)
        }

        XCTAssertEqual(document.exportedPlayCount, rows.count)
        XCTAssertEqual(fcCount, 2)
        XCTAssertEqual(Double(fcCount) / Double(stats.achievementSampleCount), try XCTUnwrap(stats.fcRate), accuracy: 0.000001)
        XCTAssertEqual(Double(apCount) / Double(stats.achievementSampleCount), try XCTUnwrap(stats.apRate), accuracy: 0.000001)
        XCTAssertEqual(apCount, 1)
        XCTAssertEqual(complete.count, stats.judgmentSampleCount)
        XCTAssertEqual(noteTotal, stats.judgmentNoteCount)
        for (judgment, rate) in stats.judgmentRates {
            XCTAssertEqual(Double(totals[judgment.rawValue] ?? 0) / Double(noteTotal), rate, accuracy: 0.000001)
        }
        let fast = timingRows.reduce(0) { $0 + $1.0 }
        let slow = timingRows.reduce(0) { $0 + $1.1 }
        XCTAssertEqual(timingRows.count, stats.timingSampleCount)
        XCTAssertEqual(Double(fast) / Double(fast + slow), try XCTUnwrap(stats.fastRate), accuracy: 0.000001)
        XCTAssertEqual(Double(slow) / Double(fast + slow), try XCTUnwrap(stats.slowRate), accuracy: 0.000001)
    }
}
