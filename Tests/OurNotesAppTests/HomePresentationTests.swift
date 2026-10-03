import Foundation
import XCTest
@testable import OurNotesApp
import ResultCore

final class HomePresentationTests: XCTestCase {
    private func chart(_ state: inout AppState, title: String = "楽曲", game: String = "our-notes", retired: Bool = false) -> ResultCore.Chart {
        let song = Song(gameID: game, masterTitle: title, availability: retired ? .retired : .active)
        let chart = ResultCore.Chart(songID: song.id, masterDifficulty: "EXPERT", masterLevel: 26, availability: retired ? .retired : .active)
        state.songs.append(song); state.charts.append(chart)
        return chart
    }

    private func play(_ chart: ResultCore.Chart, game: String = "our-notes", achievement: Achievement = .none,
                      combo: Int? = nil, score: Int = 900_000, imported: TimeInterval = 100,
                      played: TimeInterval? = nil, judgments: [Judgment: JudgmentCount]? = nil,
                      confirmed: Bool = true) -> PlayRecord {
        let counts = judgments ?? [.perfect: .init(total: 100), .great: .init(total: 0), .good: .init(total: 0), .bad: .init(total: 0), .miss: .init(total: 0)]
        return PlayRecord(chartID: chart.id, gameID: game, titleAtPlay: "当時の曲名", difficultyAtPlay: "EXPERT", score: score,
                          combo: combo, achievement: achievement, judgments: counts,
                          importedAt: Date(timeIntervalSince1970: imported), playedAt: played.map { Date(timeIntervalSince1970: $0) },
                          presetID: "test", presetVersion: 1, fingerprints: [], confirmed: confirmed)
    }

    func testAPIsOneAchievementAndFCThenAPIsFirstAP() throws {
        var state = AppState(); let c = chart(&state)
        let old = play(c, achievement: .fc, imported: 10)
        let ap = play(c, achievement: .ap, imported: 20)
        state.plays = [old, ap]
        let snapshot = HomePresentation.snapshot(state: state, gameID: "our-notes", batchPlayIDs: [ap.id])
        XCTAssertEqual(snapshot.achievements.count, 1)
        XCTAssertEqual(snapshot.achievements.first?.kind, .firstAP)
        XCTAssertEqual(snapshot.achievements.first?.record.play.id, ap.id)
        XCTAssertEqual(snapshot.fcCount, 1)
        XCTAssertEqual(snapshot.apCount, 1)
    }

    func testFirstKnownComboIsNotImprovementAndNilDiffersFromZero() throws {
        var state = AppState(); let c = chart(&state)
        let initial = play(c, combo: 0)
        state.plays = [initial]
        XCTAssertTrue(HomePresentation.snapshot(state: state, gameID: "our-notes", batchPlayIDs: [initial.id]).achievements.isEmpty)
        state.plays[0].combo = nil
        let nilRecord = try XCTUnwrap(HomePresentation.snapshot(state: state, gameID: "our-notes").recentRecords.first)
        XCTAssertNil(nilRecord.play.combo)
        state.plays[0].combo = 0
        let zeroRecord = try XCTUnwrap(HomePresentation.snapshot(state: state, gameID: "our-notes").recentRecords.first)
        XCTAssertEqual(zeroRecord.play.combo, 0)
    }

    func testComboImprovementIsChartScopedAndScoreAloneIsNotAnAchievement() {
        var state = AppState(); let a = chart(&state, title: "A"), b = chart(&state, title: "B")
        let old = play(a, combo: 100, score: 900_000, imported: 10)
        let unrelated = play(b, combo: 500, score: 900_000, imported: 20)
        let scoreOnly = play(a, combo: 100, score: 999_999, imported: 30)
        state.plays = [old, unrelated, scoreOnly]
        XCTAssertTrue(HomePresentation.snapshot(state: state, gameID: "our-notes", batchPlayIDs: [scoreOnly.id]).achievements.isEmpty)
        let improved = play(a, combo: 150, score: 800_000, imported: 40)
        state.plays.append(improved)
        let achievement = HomePresentation.snapshot(state: state, gameID: "our-notes", batchPlayIDs: [improved.id]).achievements.first
        XCTAssertEqual(achievement?.kind, .comboImproved)
        XCTAssertEqual(achievement?.previousCombo, 100)
    }

    func testBatchIDsDeduplicateAndDeletedIDsDoNotBecomeRecentAchievements() {
        var state = AppState(); let c = chart(&state)
        let old = play(c, achievement: .fc, imported: 10)
        let ap = play(c, achievement: .ap, imported: 20)
        state.plays = [old, ap]
        var snapshot = HomePresentation.snapshot(state: state, gameID: "our-notes", batchPlayIDs: [ap.id, ap.id])
        XCTAssertEqual(snapshot.focusCount, 1)
        XCTAssertEqual(snapshot.achievements.map(\.kind), [.firstAP])
        state.plays.removeAll { $0.id == ap.id }
        snapshot = HomePresentation.snapshot(state: state, gameID: "our-notes", batchPlayIDs: [ap.id])
        XCTAssertEqual(snapshot.focusCount, 0)
        XCTAssertTrue(snapshot.achievements.isEmpty)
    }

    func testEmptyBatchDoesNotSurfaceOldAchievementsAndReopenedHomeUsesRegistrationOrder() throws {
        var state = AppState(); let a = chart(&state, title: "A"), b = chart(&state, title: "B")
        let first = play(a, achievement: .fc, imported: 10, played: 900)
        let latestRegistered = play(b, imported: 20, played: 1)
        state.plays = [first, latestRegistered]
        let empty = HomePresentation.snapshot(state: state, gameID: "our-notes", batchPlayIDs: [])
        XCTAssertTrue(empty.hasBatch); XCTAssertEqual(empty.focusCount, 0); XCTAssertTrue(empty.achievements.isEmpty)
        let reopened = HomePresentation.snapshot(state: state, gameID: "our-notes")
        XCTAssertFalse(reopened.hasBatch)
        XCTAssertEqual(reopened.recentRecords.first?.play.id, latestRegistered.id)
        XCTAssertEqual(reopened.recentRecords.first?.play.playedAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(reopened.recentRecords.first?.play.importedAt, Date(timeIntervalSince1970: 20))
    }

    func testEqualRegistrationTimeBatchDoesNotInventComboSequence() {
        var state = AppState(); let c = chart(&state)
        let baseline = play(c, combo: 100, imported: 10)
        let sameA = play(c, combo: 200, imported: 20)
        let sameB = play(c, combo: 300, imported: 20)
        state.plays = [baseline, sameA, sameB]
        let snapshot = HomePresentation.snapshot(state: state, gameID: "our-notes", batchPlayIDs: [sameA.id, sameB.id])
        XCTAssertEqual(snapshot.achievements.count, 1)
        XCTAssertEqual(snapshot.achievements.first?.kind, .comboImproved)
        XCTAssertEqual(snapshot.achievements.first?.previousCombo, 100)
        XCTAssertEqual(snapshot.achievements.first?.record.play.id, sameB.id)
        XCTAssertEqual(snapshot.achievements.first?.comboIncrease, 200)
        state.plays.removeAll { $0.id == baseline.id }
        XCTAssertTrue(HomePresentation.snapshot(state: state, gameID: "our-notes", batchPlayIDs: [sameA.id, sameB.id]).achievements.isEmpty)
    }

    func testReopenedHomeLimitsFocusToTwentyButComparesAgainstOlderHistory() {
        var state = AppState(); let c = chart(&state)
        let old = play(c, achievement: .fc, combo: 100, imported: 1)
        state.plays = [old] + (2...22).map { play(c, achievement: .fc, combo: 100, imported: Double($0)) }
        let unchanged = HomePresentation.snapshot(state: state, gameID: "our-notes")
        XCTAssertEqual(unchanged.focusCount, 20)
        XCTAssertEqual(unchanged.recentRecords.count, 6)
        XCTAssertTrue(unchanged.achievements.isEmpty)
        state.plays[state.plays.count - 1].combo = 150
        let improved = HomePresentation.snapshot(state: state, gameID: "our-notes")
        XCTAssertEqual(improved.achievements.first?.kind, .comboImproved)
        XCTAssertEqual(improved.achievements.first?.comboIncrease, 50)
    }

    func testSameTimeFCAndAPAppearOnceWithAPTakingPriority() {
        var state = AppState(); let c = chart(&state)
        let fc = play(c, achievement: .fc, combo: 100, imported: 20)
        let ap = play(c, achievement: .ap, combo: 100, imported: 20)
        state.plays = [fc, ap]
        let snapshot = HomePresentation.snapshot(state: state, gameID: "our-notes", batchPlayIDs: [fc.id, ap.id])
        XCTAssertEqual(snapshot.achievements.map(\.kind), [.firstAP])
        XCTAssertEqual(snapshot.achievements.first?.record.play.id, ap.id)
        XCTAssertEqual(snapshot.fcCount, 1)
        XCTAssertEqual(snapshot.apCount, 1)
    }

    func testCurrentChartCountsIncludeAPAsFCAndExcludeRetiredOtherGameAndUnconfirmed() {
        var state = AppState()
        let ap = chart(&state, title: "AP"), fc = chart(&state, title: "FC"), retired = chart(&state, title: "退役", retired: true)
        let other = chart(&state, title: "別ゲーム", game: "other")
        state.plays = [play(ap, achievement: .ap), play(fc, achievement: .fc), play(retired, achievement: .ap),
                       play(other, game: "other", achievement: .ap), play(fc, achievement: .ap, confirmed: false)]
        let snapshot = HomePresentation.snapshot(state: state, gameID: "our-notes")
        XCTAssertEqual(snapshot.totalPlays, 3)
        XCTAssertEqual(snapshot.chartCount, 2)
        XCTAssertEqual(snapshot.playedChartCount, 2)
        XCTAssertEqual(snapshot.fcCount, 2)
        XCTAssertEqual(snapshot.apCount, 1)
    }

    func testPerfectRateRequiresAllFiveJudgmentTotalsAndUsesObservedZero() throws {
        var state = AppState(); let c = chart(&state)
        let incomplete = play(c, judgments: [.perfect: .init(total: 10), .great: .init(total: 0)])
        let complete = play(c, imported: 200, judgments: [.perfect: .init(total: 10), .great: .init(total: 0), .good: .init(total: 0), .bad: .init(total: 0), .miss: .init(total: 0)])
        state.plays = [incomplete, complete]
        let records = HomePresentation.snapshot(state: state, gameID: "our-notes").recentRecords
        XCTAssertNil(try XCTUnwrap(records.first { $0.play.id == incomplete.id }).perfectRate)
        XCTAssertEqual(try XCTUnwrap(records.first { $0.play.id == complete.id }).perfectRate, 1)
        let zero = play(c, imported: 300, judgments: [.perfect: .init(total: 0), .great: .init(total: 0), .good: .init(total: 0), .bad: .init(total: 0), .miss: .init(total: 0)])
        state.plays.append(zero)
        XCTAssertNil(HomePresentation.snapshot(state: state, gameID: "our-notes").recentRecords.first { $0.play.id == zero.id }?.perfectRate)
    }

    func testSnapshotDoesNotMutateStateAndReflectsEditsAndDeletion() {
        var state = AppState(); let c = chart(&state)
        let old = play(c, achievement: .none, combo: 100, imported: 10)
        let edited = play(c, achievement: .fc, combo: 120, imported: 20)
        state.plays = [old, edited]
        let before = state
        _ = HomePresentation.snapshot(state: state, gameID: "our-notes")
        XCTAssertEqual(state, before)
        XCTAssertEqual(HomePresentation.snapshot(state: state, gameID: "our-notes").achievements.first?.kind, .firstFC)
        state.plays[1].combo = 100
        state.plays[1].achievement = .none
        XCTAssertTrue(HomePresentation.snapshot(state: state, gameID: "our-notes").achievements.isEmpty)
        state.plays.removeAll { $0.id == old.id }
        XCTAssertEqual(HomePresentation.snapshot(state: state, gameID: "our-notes").fcCount, 0)
    }
}
