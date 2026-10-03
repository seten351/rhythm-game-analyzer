import Foundation
import XCTest
@testable import OurNotesApp
import ResultCore

final class LibraryPresentationTests: XCTestCase {
    private func chart(_ state: inout AppState, title: String = "楽曲", difficulty: String = "EXPERT", level: Int? = 26, aliases: [String] = [], retired: Bool = false, game: String = "our-notes") -> ResultCore.Chart {
        let song = Song(gameID: game, masterTitle: title, masterAliases: aliases)
        let chart = ResultCore.Chart(songID: song.id, masterDifficulty: difficulty, masterLevel: level, availability: retired ? .retired : .active)
        state.songs.append(song); state.charts.append(chart)
        return chart
    }
    private func play(_ chart: ResultCore.Chart, achievement: Achievement = .none, score: Int = 900_000, imported: TimeInterval = 100, played: TimeInterval? = nil, environment: PlayEnvironment? = nil) -> PlayRecord {
        PlayRecord(chartID: chart.id, gameID: "our-notes", titleAtPlay: "当時の曲名", difficultyAtPlay: chart.difficulty, score: score, achievement: achievement, judgments: [.perfect: .init(total: 100), .great: .init(total: 0), .good: .init(total: 0), .bad: .init(total: 0), .miss: .init(total: 0)], importedAt: Date(timeIntervalSince1970: imported), playedAt: played.map { Date(timeIntervalSince1970: $0) }, presetID: "test", presetVersion: 1, environment: environment, fingerprints: [])
    }
    private func rows(_ state: AppState, _ browser: LibraryBrowserState = .init()) -> [LibraryChartRow] {
        LibraryPresentation.visibleRows(LibraryPresentation.scopedRows(LibraryPresentation.rows(in: state, gameID: "our-notes"), browser: browser), browser: browser)
    }

    func testAchievementFiltersKeepUnplayedUnknownAndKnownNonFCDistinct() throws {
        var state = AppState()
        let unplayed = chart(&state, title: "未プレイ"), unknown = chart(&state, title: "不明"), none = chart(&state, title: "通常"), fc = chart(&state, title: "FC"), ap = chart(&state, title: "AP")
        state.plays = [play(unknown, achievement: .unknown), play(none), play(fc, achievement: .fc), play(ap, achievement: .ap)]
        let all = rows(state)
        XCTAssertEqual(all.first { $0.id == unplayed.id }?.achievementLabel, "未プレイ")
        XCTAssertEqual(all.first { $0.id == unknown.id }?.achievementLabel, "達成不明")
        XCTAssertEqual(all.first { $0.id == none.id }?.achievementLabel, "FC記録なし")
        XCTAssertEqual(Set(all.filter(LibraryFilter.notFC.includes).map(\.id)), [unplayed.id, unknown.id, none.id])
        XCTAssertEqual(Set(all.filter(LibraryFilter.fc.includes).map(\.id)), [fc.id, ap.id])
        XCTAssertEqual(all.filter(LibraryFilter.notAP.includes).count, 4)
    }

    func testHistoricalAPSurvivesNewerNonFCAndBestScoreRetainsItsEnvironment() throws {
        var state = AppState(); let c = chart(&state)
        let speakers = PlayEnvironment(name: "スピーカー", settings: .init(noteTiming: 0.1))
        let wired = PlayEnvironment(name: "有線", settings: .init(noteTiming: 0.2))
        state.plays = [play(c, achievement: .ap, score: 980_000, imported: 10, environment: speakers), play(c, score: 970_000, imported: 20, environment: wired)]
        let row = try XCTUnwrap(rows(state).first)
        XCTAssertEqual(row.achievementLabel, "AP"); XCTAssertTrue(row.hasFC)
        XCTAssertEqual(row.latestPlay?.achievement, Achievement.none)
        XCTAssertEqual(row.bestPlay?.environment, speakers)
        XCTAssertEqual(row.latestPlay?.environment, wired)
        state.plays.append(play(c, achievement: .unknown, score: 980_000, imported: 30, environment: wired))
        XCTAssertEqual(rows(state).first?.bestPlay?.environment, wired)
    }

    func testCombinedSearchAliasDifficultyLevelArchiveAndGameScope() {
        var state = AppState()
        let match = chart(&state, title: "正式曲名", aliases: ["Ave Mujica"])
        _ = chart(&state, title: "Ave Mujica", difficulty: "HARD", level: 21)
        _ = chart(&state, title: "Ave Mujica", retired: true)
        _ = chart(&state, title: "Ave Mujica", game: "other-game")
        var browser = LibraryBrowserState(); browser.search = "ＡＶＥ　ｍｕｊｉｃａ"; browser.difficulty = "EXPERT"; browser.level = 26
        XCTAssertEqual(rows(state, browser).map(\.id), [match.id])
        browser.includeArchived = true
        XCTAssertEqual(rows(state, browser).count, 2)
        browser.level = 27
        XCTAssertTrue(rows(state, browser).isEmpty)
    }

    func testRecentSortUsesPlayDateAndFallsBackToRegistrationDate() {
        var state = AppState(); let a = chart(&state, title: "A"), b = chart(&state, title: "B"), c = chart(&state, title: "C")
        state.plays = [play(a, imported: 900, played: 100), play(b, imported: 500)]
        XCTAssertEqual(rows(state).map(\.id), [b.id, a.id, c.id])
        XCTAssertNil(rows(state).first?.latestPlay?.playedAt)
    }

    func testLevelSortKeepsMissingLastAndTitleSortUsesDifficultyOrder() {
        var state = AppState(); let unknown = chart(&state, title: "A", level: nil), low = chart(&state, title: "B", level: 20), high = chart(&state, title: "C", level: 29)
        var browser = LibraryBrowserState(); browser.sort = .level
        XCTAssertEqual(rows(state, browser).map(\.id), [high.id, low.id, unknown.id])
        state = AppState()
        for difficulty in ["EXPERT", "HARD", "EASY", "NORMAL"] { _ = chart(&state, difficulty: difficulty) }
        browser.sort = .title
        XCTAssertEqual(rows(state, browser).map { $0.chart.difficulty }, ["EASY", "NORMAL", "HARD", "EXPERT"])
    }

    func testMissingValuesStayMissingAndObservedZeroStaysZero() throws {
        var state = AppState(); let c = chart(&state, level: nil)
        state.plays = [play(c, achievement: .unknown, score: 0)]
        let row = try XCTUnwrap(rows(state).first)
        XCTAssertNil(row.chart.level); XCTAssertEqual(row.bestPlay?.score, 0)
        XCTAssertNil(row.latestPlay?.timingCounts)
        XCTAssertEqual(row.latestPlay?.judgments[.miss]?.total, 0)
        XCTAssertEqual(libraryEnvironmentLabel(try XCTUnwrap(row.latestPlay)), "環境不明")
    }

    func testSelectionOnlyClearsWhenChartLeavesVisibleRows() {
        var state = AppState(); let a = chart(&state, title: "A"), b = chart(&state, title: "B")
        var browser = LibraryBrowserState(); browser.selectedID = b.id; browser.detailTab = .history
        browser.retainVisibleSelection(in: rows(state))
        XCTAssertEqual(browser.selectedID, b.id)
        browser.search = "A"; browser.retainVisibleSelection(in: rows(state, browser))
        XCTAssertNil(browser.selectedID); XCTAssertEqual(browser.detailTab, .history)
        XCTAssertEqual(rows(state, browser).map(\.id), [a.id])
    }

    func testPresentationDoesNotMutateStoredDataAndUpdatesAfterEditOrDeletion() throws {
        var state = AppState(); let c = chart(&state)
        state.plays = [play(c, achievement: .fc, score: 900_000), play(c, score: 910_000, imported: 200)]
        let original = state
        _ = rows(state)
        XCTAssertEqual(state, original)
        state.plays[0].score = 920_000
        XCTAssertEqual(rows(state).first?.bestPlay?.score, 920_000)
        state.plays.removeFirst()
        XCTAssertFalse(try XCTUnwrap(rows(state).first).hasFC)
        XCTAssertEqual(rows(state).first?.plays.count, 1)
        state.plays.removeAll()
        XCTAssertEqual(rows(state).first?.achievementLabel, "未プレイ")
        XCTAssertNil(rows(state).first?.bestPlay)
        XCTAssertEqual(state.schemaVersion, 1)
    }
}
