import Foundation
import XCTest
@testable import ResultCore

final class ScreenshotDatePersistenceTests: XCTestCase {
    private let gameID = "test-game"

    private func candidate(_ seconds: TimeInterval, source: ScreenshotDateSource = .metadata) -> ScreenshotDateCandidate {
        ScreenshotDateCandidate(capturedAt: Date(timeIntervalSince1970: seconds), source: source,
                                metadataField: source == .metadata ? "EXIF DateTimeOriginal" : nil,
                                timeZone: "Asia/Tokyo", timeZoneAssumed: false)
    }

    private func draft(fingerprint: String, kind: String = "normal", score: Int = 900_000) -> ResultDraft {
        ResultDraft(gameID: gameID, presetID: "preset", presetVersion: 1, title: "Song",
                    difficulty: "EXPERT", level: 30, score: score, combo: 100,
                    achievement: .unknown, judgments: [:],
                    fingerprint: .init(sha256: fingerprint, layout: kind), kind: kind)
    }

    func testSaveRetainsCaptureEvidenceAndSelectedImageReference() throws {
        let song = Song(gameID: gameID, masterTitle: "Song")
        let chart = Chart(songID: song.id, masterDifficulty: "EXPERT", masterLevel: 30)
        let normal = ScreenshotDateEvidence(imageKind: .normal, candidates: [candidate(100)])
        let detail = ScreenshotDateEvidence(imageKind: .detail, candidates: [candidate(101, source: .filename)])
        let environment = PlayEnvironment(device: "Tablet", audioOutput: "Wired", conditions: "Quiet",
                                          settings: .init(noteSpeed: 10, noteTiming: 0, chartPosition: 2, mirror: false))
        var state = AppState(); state.songs = [song]; state.charts = [chart]

        let saved = try ResultService.save(draft(fingerprint: "normal-image"), to: state,
                                           environment: environment, targetChartID: chart.id,
                                           playedAt: normal.candidates[0].capturedAt,
                                           screenshotDates: [normal, detail],
                                           dateContext: .init(selectedScreenshotDate: .init(screenshotID: normal.id, candidateIndex: 0), playedAtSource: .screenshot))

        let play = try XCTUnwrap(saved.plays.first)
        XCTAssertEqual(play.screenshotDates, [normal, detail])
        XCTAssertEqual(play.dateContext?.selectedScreenshotDate, .init(screenshotID: normal.id, candidateIndex: 0))
        XCTAssertEqual(play.selectedScreenshotDate, normal.candidates[0])
        XCTAssertEqual(play.playedAt, normal.candidates[0].capturedAt)
        XCTAssertEqual(play.environment, environment)
        XCTAssertEqual(state.plays.count, 0, "save must preserve value semantics")
    }

    func testMergingNormalAndDetailKeepsBothImagesDateEvidenceAndOriginalPlayContext() throws {
        let song = Song(gameID: gameID, masterTitle: "Song")
        let chart = Chart(songID: song.id, masterDifficulty: "EXPERT", masterLevel: 30)
        let normal = ScreenshotDateEvidence(imageKind: .normal, candidates: [candidate(200)])
        let detail = ScreenshotDateEvidence(imageKind: .detail, candidates: [candidate(201, source: .filename)])
        let originalEnvironment = PlayEnvironment(device: "Tablet A", audioOutput: "Wired", conditions: "Quiet",
                                                  settings: .init(noteSpeed: 10, noteTiming: -1, chartPosition: 2, mirror: false))
        let playedAt = Date(timeIntervalSince1970: 200)
        let existing = PlayRecord(chartID: chart.id, gameID: gameID, titleAtPlay: "Song",
                                  difficultyAtPlay: "EXPERT", levelAtPlay: 30, score: 900_000,
                                  combo: 100, achievement: .unknown, importedAt: Date(timeIntervalSince1970: 300),
                                  playedAt: playedAt, presetID: "preset-v1", presetVersion: 1,
                                  environment: originalEnvironment, fingerprints: [.init(sha256: "normal-image", layout: "normal")],
                                  confirmed: false, screenshotDates: [normal],
                                  dateContext: .init(selectedScreenshotDate: .init(screenshotID: normal.id, candidateIndex: 0), playedAtSource: .screenshot))
        var state = AppState(); state.songs = [song]; state.charts = [chart]; state.plays = [existing]
        let detailDraft = draft(fingerprint: "detail-image", kind: "detail")

        let merged = try ResultService.merge(detailDraft, into: existing.id, in: state,
                                             environment: PlayEnvironment(device: "Tablet B", audioOutput: "BT", conditions: "Noisy"),
                                             screenshotDates: [detail])

        let result = try XCTUnwrap(merged.plays.first)
        XCTAssertEqual(result.screenshotDates, [normal, detail])
        XCTAssertEqual(result.screenshotDates?.map(\.imageKind), [.normal, .detail])
        XCTAssertEqual(result.dateContext, existing.dateContext)
        XCTAssertEqual(result.selectedScreenshotDate, normal.candidates[0])
        XCTAssertEqual(result.playedAt, playedAt)
        XCTAssertEqual(result.environment, originalEnvironment)
        XCTAssertEqual(result.fingerprints.map(\.sha256), ["normal-image", "detail-image"])
        XCTAssertTrue(result.confirmed)
        XCTAssertEqual(state.plays.first?.screenshotDates, [normal], "merge must preserve value semantics")
    }

    func testAppendingScreenshotEvidencePreservesPlayedAtDateContextAndEnvironment() throws {
        let chart = Chart(songID: UUID(), masterDifficulty: "EXPERT")
        let first = ScreenshotDateEvidence(imageKind: .normal, candidates: [candidate(400)])
        let appended = ScreenshotDateEvidence(imageKind: .detail, candidates: [candidate(401)])
        let environment = PlayEnvironment(device: "Original device", audioOutput: "Original output", conditions: "Original conditions")
        let playedAt = Date(timeIntervalSince1970: 400)
        var play = PlayRecord(chartID: chart.id, gameID: gameID, titleAtPlay: "Song", difficultyAtPlay: "EXPERT",
                              levelAtPlay: 30, score: 900_000, combo: 100, importedAt: Date(timeIntervalSince1970: 500),
                              playedAt: playedAt, presetID: "preset", presetVersion: 7, environment: environment,
                              fingerprints: [.init(sha256: "first", layout: "normal")], confirmed: true,
                              screenshotDates: [first], dateContext: .init(selectedScreenshotDate: .init(screenshotID: first.id, candidateIndex: 0), playedAtSource: .screenshot))
        // A repeated detail import should append only its evidence and leave the selected play context intact.
        var state = AppState(); state.songs = [Song(id: chart.songID, gameID: gameID, masterTitle: "Song")]
        state.charts = [chart]; state.plays = [play]

        let result = try ResultService.merge(draft(fingerprint: "second", kind: "detail"), into: play.id, in: state,
                                             screenshotDates: [appended])
        play = try XCTUnwrap(result.plays.first)

        XCTAssertEqual(play.screenshotDates, [first, appended])
        XCTAssertEqual(play.playedAt, playedAt)
        XCTAssertEqual(play.dateContext?.selectedScreenshotDate, .init(screenshotID: first.id, candidateIndex: 0))
        XCTAssertEqual(play.environment, environment)
    }

    func testLegacyAppStateWithoutScreenshotDateKeysDecodesAsUnknownAndRoundTrips() throws {
        let song = Song(gameID: gameID, masterTitle: "Song")
        let chart = Chart(songID: song.id, masterDifficulty: "EXPERT", masterLevel: 30)
        let evidence = ScreenshotDateEvidence(imageKind: .normal, candidates: [candidate(600)])
        let play = PlayRecord(chartID: chart.id, gameID: gameID, titleAtPlay: "Song", difficultyAtPlay: "EXPERT",
                              levelAtPlay: 30, score: 900_000, importedAt: Date(timeIntervalSince1970: 700),
                              presetID: "preset", presetVersion: 1, screenshotDates: [evidence],
                              dateContext: .init(selectedScreenshotDate: .init(screenshotID: evidence.id, candidateIndex: 0), playedAtSource: .screenshot))
        var state = AppState(); state.songs = [song]; state.charts = [chart]; state.plays = [play]
        let encoder = JSONEncoder()
        let fullJSON = try JSONSerialization.jsonObject(with: encoder.encode(state)) as! [String: Any]
        var legacyJSON = fullJSON
        var plays = try XCTUnwrap(legacyJSON["plays"] as? [[String: Any]])
        plays[0].removeValue(forKey: "screenshotDates")
        plays[0].removeValue(forKey: "dateContext")
        legacyJSON["plays"] = plays
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)

        let decoded = try JSONDecoder().decode(AppState.self, from: legacyData)
        let decodedPlay = try XCTUnwrap(decoded.plays.first)
        XCTAssertNil(decodedPlay.screenshotDates)
        XCTAssertNil(decodedPlay.dateContext)
        let roundTripped = try JSONDecoder().decode(AppState.self, from: encoder.encode(decoded))
        XCTAssertEqual(roundTripped, decoded)
    }
}
