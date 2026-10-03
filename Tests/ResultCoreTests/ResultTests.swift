import Foundation
import XCTest
@testable import ResultCore

final class ResultTests: XCTestCase {
    private let gameID = "rhythm-game"

    private func counts(
        _ perfect: JudgmentCount = .init(),
        _ great: JudgmentCount = .init(),
        _ good: JudgmentCount = .init(),
        _ bad: JudgmentCount = .init(),
        _ miss: JudgmentCount = .init()
    ) -> [Judgment: JudgmentCount] {
        [.perfect: perfect, .great: great, .good: good, .bad: bad, .miss: miss]
    }

    private func draft(
        title: String = "Song",
        difficulty: String = "MASTER",
        level: Int? = 30,
        score: Int = 900_000,
        combo: Int? = nil,
        achievement: Achievement = .unknown,
        judgments: [Judgment: JudgmentCount] = [:],
        fingerprint: SourceFingerprint = .init(sha256: "incoming-sha", layout: "result"),
        kind: String = "normal"
    ) -> ResultDraft {
        ResultDraft(gameID: gameID, presetID: "preset", presetVersion: 1, title: title, difficulty: difficulty, level: level, score: score, combo: combo, achievement: achievement, judgments: judgments, fingerprint: fingerprint, kind: kind)
    }

    private func record(
        id: UUID = UUID(),
        chartID: UUID = UUID(),
        title: String = "Song",
        difficulty: String = "MASTER",
        level: Int? = 29,
        score: Int = 900_000,
        combo: Int? = nil,
        achievement: Achievement = .unknown,
        judgments: [Judgment: JudgmentCount] = [:],
        fingerprints: [SourceFingerprint] = [],
        environment: PlayEnvironment? = nil,
        playedAt: TimeInterval = 0,
        confirmed: Bool = true
    ) -> PlayRecord {
        PlayRecord(id: id, chartID: chartID, gameID: gameID, titleAtPlay: title, difficultyAtPlay: difficulty, levelAtPlay: level, score: score, combo: combo, achievement: achievement, judgments: judgments, importedAt: Date(timeIntervalSince1970: playedAt), playedAt: Date(timeIntervalSince1970: playedAt), presetID: "old-preset", presetVersion: 4, environment: environment, fingerprints: fingerprints, confirmed: confirmed)
    }

    func testNormalAndDetailedCountsMergeByFillingUnknownFields() throws {
        let normal = counts(.init(total: 100), .init(total: 20), .init(total: 3), .init(total: 2), .init(total: 1))
        let detailed = counts(.init(fast: 60, slow: 40), .init(fast: 10, slow: 10), .init(fast: 2, slow: 1), .init(fast: 1, slow: 1), .init(fast: 0, slow: 1))

        let result = try ResultService.merged(normal, detailed)

        XCTAssertEqual(result[.perfect], .init(total: 100, fast: 60, slow: 40))
        XCTAssertEqual(result[.great], .init(total: 20, fast: 10, slow: 10))
        XCTAssertEqual(result[.miss], .init(total: 1, fast: 0, slow: 1))
    }

    func testMergeRejectsConflictingCounts() {
        let normal = counts(.init(total: 100))
        let conflictingDetail = counts(.init(total: 99, fast: 60, slow: 40))

        XCTAssertThrowsError(try ResultService.merged(normal, conflictingDetail))
    }

    func testSimilarResultCandidatesRemainSeparateAndAreSortedByPlayDate() {
        let older = record(playedAt: 10)
        let newest = record(playedAt: 30)
        let differentScore = record(score: 800_000, playedAt: 40)
        var state = AppState()
        state.plays = [older, differentScore, newest]

        let candidates = ResultService.candidates(for: draft(), in: state)

        XCTAssertEqual(candidates.map(\.id), [newest.id, older.id])
        XCTAssertEqual(state.plays.count, 3)
    }

    func testPerceptualCandidateRequiresMatchingLayoutAndHammingDistanceAtMostSix() {
        let withinThreshold = record(fingerprints: [
            .init(sha256: "old-near", perceptualHash: 0, layout: "result")
        ])
        let tooFar = record(fingerprints: [
            .init(sha256: "old-far", perceptualHash: 0b111_1110_0000, layout: "result")
        ])
        let differentLayout = record(fingerprints: [
            .init(sha256: "old-layout", perceptualHash: 0, layout: "detail")
        ])
        var state = AppState()
        state.plays = [withinThreshold, tooFar, differentLayout]
        let similar = draft(
            score: 900_001,
            combo: 501,
            fingerprint: .init(sha256: "new-near", perceptualHash: 0b11_1111, layout: "result")
        )

        XCTAssertEqual(ResultService.candidates(for: similar, in: state).map(\.id), [withinThreshold.id])
    }

    func testPerceptualMatchIsOnlyCandidateAndMergeStillRequiresExactScoreAndCombo() {
        let existing = record(
            score: 900_000,
            combo: 500,
            fingerprints: [.init(sha256: "old-image", perceptualHash: 0, layout: "result")]
        )
        var state = AppState()
        state.plays = [existing]
        let scoreMismatch = draft(
            score: 900_001,
            combo: 500,
            fingerprint: .init(sha256: "new-score", perceptualHash: 0b11_1111, layout: "result")
        )
        let comboMismatch = draft(
            score: 900_000,
            combo: 501,
            fingerprint: .init(sha256: "new-combo", perceptualHash: 0b11_1111, layout: "result")
        )
        let original = state

        XCTAssertEqual(ResultService.candidates(for: scoreMismatch, in: state).map(\.id), [existing.id])
        XCTAssertThrowsError(try ResultService.merge(scoreMismatch, into: existing.id, in: state))
        XCTAssertEqual(ResultService.candidates(for: comboMismatch, in: state).map(\.id), [existing.id])
        XCTAssertThrowsError(try ResultService.merge(comboMismatch, into: existing.id, in: state))
        XCTAssertEqual(state, original)
    }

    func testSavingRejectsSHAAlreadyOwnedByAnExistingPlay() throws {
        let existing = record(fingerprints: [.init(sha256: "duplicate-sha", layout: "result")])
        var state = AppState()
        state.plays = [existing]
        let incoming = draft(fingerprint: .init(sha256: "duplicate-sha", layout: "detail"))
        let original = state

        XCTAssertThrowsError(try ResultService.save(incoming, to: state, environment: nil))
        XCTAssertEqual(state, original)
    }

    func testSavingRejectsDuplicateSHAValuesWithinIncomingImages() throws {
        let original = AppState()
        let duplicated = [
            SourceFingerprint(sha256: "same-incoming-sha", layout: "normal"),
            SourceFingerprint(sha256: "same-incoming-sha", layout: "detail")
        ]

        XCTAssertThrowsError(try ResultService.save(draft(), to: original, environment: nil, fingerprints: duplicated))
        XCTAssertTrue(original.plays.isEmpty)
    }

    func testSameNameMultipleChartsRequireExplicitTargetAndKeepInternalIDs() throws {
        let songID = UUID()
        let masterID = UUID()
        let expertID = UUID()
        let song = Song(id: songID, gameID: gameID, masterTitle: "Song")
        let master = Chart(id: masterID, songID: songID, masterDifficulty: "MASTER", masterLevel: 30)
        let expert = Chart(id: expertID, songID: songID, masterDifficulty: "MASTER", masterLevel: 31)
        var state = AppState()
        state.songs = [song]
        state.charts = [master, expert]
        let incoming = draft()
        let original = state

        XCTAssertThrowsError(try ResultService.save(incoming, to: state, environment: nil))
        XCTAssertEqual(state, original)

        let saved = try ResultService.save(incoming, to: state, environment: nil, targetChartID: expertID)

        XCTAssertEqual(saved.songs.map(\.id), [songID])
        XCTAssertEqual(Set(saved.charts.map(\.id)), [masterID, expertID])
        XCTAssertEqual(saved.plays.count, 1)
        XCTAssertEqual(saved.plays.first?.chartID, expertID)
    }

    func testExplicitTargetRegistrationDoesNotCreateReplacementSongOrChart() throws {
        let songID = UUID()
        let chartID = UUID()
        var state = AppState()
        state.songs = [Song(id: songID, gameID: gameID, masterTitle: "Song")]
        state.charts = [Chart(id: chartID, songID: songID, masterDifficulty: "MASTER", masterLevel: 30)]

        let saved = try ResultService.save(draft(), to: state, environment: nil, targetChartID: chartID)

        XCTAssertEqual(saved.songs.map(\.id), [songID])
        XCTAssertEqual(saved.charts.map(\.id), [chartID])
        XCTAssertEqual(saved.plays.first?.chartID, chartID)
    }

    func testMergingDetailedResultPreservesHistoryFieldsAndAddsImageFingerprint() throws {
        let songID = UUID()
        let chartID = UUID()
        let oldImage = SourceFingerprint(sha256: "old-image", layout: "normal")
        let environment = PlayEnvironment(device: "Headphones", audioOutput: "Wired", conditions: "Quiet")
        let existing = record(
            chartID: chartID,
            level: 28,
            score: 987_654,
            combo: 500,
            fingerprints: [oldImage],
            environment: environment,
            playedAt: 123,
            confirmed: false
        )
        var state = AppState()
        state.songs = [Song(id: songID, gameID: gameID, masterTitle: "Song")]
        state.charts = [Chart(id: chartID, songID: songID, masterDifficulty: "MASTER", masterLevel: 30)]
        state.plays = [existing]
        let detail = draft(
            level: 30,
            score: 987_654,
            combo: 500,
            achievement: .fc,
            judgments: counts(.init(fast: 400, slow: 500), .init(fast: 20, slow: 10), .init(fast: 0, slow: 0), .init(fast: 0, slow: 0), .init(fast: 0, slow: 0)),
            fingerprint: .init(sha256: "detail-image", layout: "detail"),
            kind: "detail"
        )
        let original = state

        let result = try ResultService.merge(detail, into: existing.id, in: state, environment: PlayEnvironment(device: "Other", audioOutput: "BT", conditions: "Noisy"))

        XCTAssertEqual(state, original)
        let merged = try XCTUnwrap(result.plays.first)
        XCTAssertEqual(merged.id, existing.id)
        XCTAssertEqual(merged.chartID, chartID)
        XCTAssertEqual(merged.titleAtPlay, existing.titleAtPlay)
        XCTAssertEqual(merged.difficultyAtPlay, existing.difficultyAtPlay)
        XCTAssertEqual(merged.levelAtPlay, 28)
        XCTAssertEqual(merged.score, 987_654)
        XCTAssertEqual(merged.combo, 500)
        XCTAssertEqual(merged.playedAt, existing.playedAt)
        XCTAssertEqual(merged.presetID, "old-preset")
        XCTAssertEqual(merged.environment, environment)
        XCTAssertEqual(merged.achievement, .fc)
        XCTAssertEqual(merged.judgments[.perfect], .init(fast: 400, slow: 500))
        XCTAssertEqual(merged.fingerprints.map(\.sha256), ["old-image", "detail-image"])
        XCTAssertTrue(merged.confirmed)
    }

    func testMergeRejectsTargetThatIsNotOneOfTheCurrentPlayCandidates() {
        let matching = record()
        let other = record(title: "Another song")
        var state = AppState()
        state.plays = [matching, other]

        XCTAssertThrowsError(try ResultService.merge(draft(), into: other.id, in: state))
    }

    func testMergeRejectsExplicitEmptyFingerprintListWithoutChangingHistory() {
        let existing = record()
        var state = AppState()
        state.plays = [existing]
        let original = state

        XCTAssertThrowsError(try ResultService.merge(draft(), into: existing.id, in: state, fingerprints: []))
        XCTAssertEqual(state, original)
    }

    func testUpdateRetainsEditedHistoryValueAndLeavesOriginalStateUntouched() throws {
        let originalRecord = record(level: 28, score: 800_000)
        var edited = originalRecord
        edited.score = 950_000
        edited.levelAtPlay = 30
        edited.confirmed = true
        var state = AppState()
        state.plays = [originalRecord]
        let originalState = state

        let result = try ResultService.update(edited, in: state)

        XCTAssertEqual(state, originalState)
        XCTAssertEqual(try XCTUnwrap(result.plays.first).id, originalRecord.id)
        XCTAssertEqual(result.plays.first?.score, 950_000)
        XCTAssertEqual(result.plays.first?.levelAtPlay, 30)
    }
}
