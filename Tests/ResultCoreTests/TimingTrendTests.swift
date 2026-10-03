import Foundation
import XCTest
@testable import ResultCore

final class TimingTrendTests: XCTestCase {
    private let gameID = "our-notes"
    private let specification = TimingSpecification(
        unit: "ゲーム内単位",
        step: Decimal(string: "0.01")!,
        minimum: -3,
        maximum: 3,
        slowCorrectionDirection: 1
    )
    private var environment: PlayEnvironment {
        PlayEnvironment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            device: "iPad",
            audioOutput: "イヤホン",
            conditions: "通常プレイ",
            settings: PlaySettings(noteSpeed: 10, noteTiming: Decimal(string: "0.10"), chartPosition: 0, mirror: false)
        )
    }

    private func chart(_ songID: UUID, level: Int? = 12, id: UUID = UUID()) -> Chart {
        Chart(id: id, songID: songID, masterDifficulty: "EXPERT", masterLevel: level)
    }

    /// Counts are expressed directly so tests can cover both note-weighted and song-weighted bias.
    private func play(
        chart: Chart,
        levelAtPlay: Int? = nil,
        fast: Int = 40,
        slow: Int = 60,
        date: TimeInterval = 0,
        id: UUID = UUID(),
        environment snapshot: PlayEnvironment? = nil,
        game: String? = nil,
        confirmed: Bool = true
    ) -> PlayRecord {
        PlayRecord(
            id: id,
            chartID: chart.id,
            gameID: game ?? gameID,
            titleAtPlay: "Test song",
            difficultyAtPlay: "EXPERT",
            levelAtPlay: levelAtPlay,
            score: 1,
            judgments: [
                .perfect: JudgmentCount(fast: fast / 2, slow: slow / 2),
                .great: JudgmentCount(fast: fast - fast / 2, slow: slow - slow / 2)
            ],
            importedAt: Date(timeIntervalSince1970: date),
            presetID: "test",
            presetVersion: 1,
            environment: snapshot ?? environment,
            confirmed: confirmed
        )
    }

    private func analyze(
        _ plays: [PlayRecord],
        charts: [Chart],
        in environment: PlayEnvironment? = nil,
        specification: TimingSpecification? = nil,
        policy: TimingEnvironmentPolicy = .strict
    ) -> TimingTrendAnalysis {
        TimingTrendService.analyze(
            gameID: gameID,
            environment: environment ?? self.environment,
            plays: plays,
            charts: charts,
            specification: specification ?? self.specification,
            environmentPolicy: policy
        )
    }

    func testRepeatedPlaysAndMultipleChartsOfOneSongStillCountAsOneSong() {
        let song = UUID()
        let first = chart(song)
        let second = chart(song, level: 13)
        let rows = (0..<8).map { play(chart: first, fast: 40, slow: 60, date: Double($0)) }
            + (0..<8).map { play(chart: second, fast: 40, slow: 60, date: Double($0 + 8)) }

        let result = analyze(rows, charts: [first, second]).overall

        XCTAssertEqual(result.matchingSongCount, 1)
        XCTAssertEqual(result.statistics.timingNoteCount, 1_600)
        XCTAssertEqual(result.status, .insufficientData)
        XCTAssertNil(result.proposed)
    }

    func testSongEvidenceIsEqualWeightedWhileOverallBiasRemainsNoteWeighted() throws {
        let songs = (0..<3).map { _ in UUID() }
        let charts = songs.map { chart($0) }
        // One song has many mildly FAST details; two songs have one strongly SLOW detail each.
        // Equal song weighting points SLOW, while the total note-weighted bias points FAST.
        let rows = (0..<20).map { play(chart: charts[0], fast: 60, slow: 40, date: Double($0)) }
            + [play(chart: charts[1], fast: 10, slow: 90, date: 30)]
            + [play(chart: charts[2], fast: 10, slow: 90, date: 31)]

        let result = analyze(rows, charts: charts).overall

        XCTAssertEqual(result.matchingSongCount, 2)
        XCTAssertEqual(result.songs.count, 3)
        XCTAssertEqual(result.statistics.timingNoteCount, 1_200)
        XCTAssertLessThan(try XCTUnwrap(result.statistics.timingBias), 0)
        XCTAssertGreaterThan(try XCTUnwrap(result.songBias), 0.1)
        XCTAssertEqual(result.status, .mixedDirections)
        XCTAssertNil(result.proposed)
    }

    func testPerChartRecentTenAreSelectedBeforeSongAggregation() {
        let songs = (0..<3).map { _ in UUID() }
        let charts = songs.map { chart($0) }
        var rows: [PlayRecord] = []
        for item in charts {
            // The two old FAST results must fall outside the ten most recent results for this chart.
            rows += [
                play(chart: item, fast: 100, slow: 0, date: 0),
                play(chart: item, fast: 100, slow: 0, date: 1)
            ]
            rows += (2..<12).map { play(chart: item, fast: 40, slow: 60, date: Double($0)) }
        }

        let result = analyze(rows, charts: charts).overall

        XCTAssertEqual(result.statistics.playCount, 30)
        XCTAssertEqual(result.statistics.timingNoteCount, 3_000)
        XCTAssertEqual(result.matchingSongCount, 3)
        XCTAssertEqual(result.status, .candidate)
        XCTAssertEqual(result.proposed, Decimal(string: "0.11"))
    }

    func testOnlyCurrentEnvironmentAndSettingsHistoryContributes() {
        let songs = (0..<3).map { _ in UUID() }
        let charts = songs.map { chart($0) }
        let currentRows = charts.map { play(chart: $0, fast: 40, slow: 60) }
        var changedSettings = environment
        changedSettings.settings.noteTiming = Decimal(string: "0.11")
        var changedEnvironmentID = environment
        changedEnvironmentID.id = UUID()
        var wrongDevice = environment
        wrongDevice.device = "別の端末"
        var wrongConditions = environment
        wrongConditions.conditions = "譜面研究"
        let excluded = [
            play(chart: charts[0], fast: 0, slow: 100, environment: changedSettings),
            play(chart: charts[1], fast: 0, slow: 100, environment: changedEnvironmentID),
            play(chart: charts[2], fast: 0, slow: 100, environment: wrongDevice),
            play(chart: charts[0], fast: 0, slow: 100, environment: wrongConditions),
            play(chart: charts[1], fast: 0, slow: 100, game: "another-game"),
            play(chart: charts[2], fast: 0, slow: 100, confirmed: false)
        ]
        var unmapped = play(chart: charts[0], fast: 0, slow: 100)
        unmapped.chartID = UUID()

        let result = analyze(currentRows + excluded + [unmapped], charts: charts).overall

        XCTAssertEqual(result.matchingSongCount, 3)
        XCTAssertEqual(result.statistics.playCount, 3)
        XCTAssertEqual(result.statistics.timingNoteCount, 300)
        XCTAssertEqual(result.status, .insufficientData)
        XCTAssertNil(result.proposed)
    }

    func testLevelGroupsUseLevelAtPlayAndUnknownLevelNeverBecomesCandidate() {
        let songs = (0..<3).map { _ in UUID() }
        let charts = songs.map { chart($0, level: 12) }
        var rows: [PlayRecord] = []
        for item in charts {
            rows.append(play(chart: item, levelAtPlay: 11, fast: 40, slow: 60))
            rows.append(play(chart: item, levelAtPlay: 12, fast: 60, slow: 40))
            rows.append(play(chart: item, levelAtPlay: 11, fast: 40, slow: 60, date: 1))
            rows.append(play(chart: item, levelAtPlay: 12, fast: 60, slow: 40, date: 1))
            rows.append(play(chart: item, levelAtPlay: nil, fast: 40, slow: 60))
        }

        let result = analyze(rows, charts: charts)
        let byLevel = Dictionary(uniqueKeysWithValues: result.levels.map { ($0.level, $0.recommendation) })

        XCTAssertEqual(Set(result.levels.compactMap(\.level)), Set([11, 12]))
        XCTAssertEqual(byLevel[11]?.status, .candidate)
        XCTAssertEqual(byLevel[11]?.statistics.playCount, 6)
        XCTAssertEqual(byLevel[12]?.statistics.playCount, 6)
        XCTAssertEqual(byLevel[nil]?.statistics.playCount, 3)
        XCTAssertNotEqual(byLevel[nil]?.status, .candidate)
        XCTAssertNil(byLevel[nil]?.proposed)
    }

    func testOpposingQualifiedLevelTrendsHoldTheOverallRecommendation() {
        let songs = (0..<3).map { _ in UUID() }
        let charts = songs.map { chart($0, level: 12) }
        let rows = charts.flatMap { item in
            [
                play(chart: item, levelAtPlay: 11, fast: 40, slow: 60),
                play(chart: item, levelAtPlay: 11, fast: 40, slow: 60, date: 1),
                play(chart: item, levelAtPlay: 12, fast: 60, slow: 40, date: 2),
                play(chart: item, levelAtPlay: 12, fast: 60, slow: 40, date: 3)
            ]
        }

        let result = analyze(rows, charts: charts)

        XCTAssertEqual(result.levels.first(where: { $0.level == 11 })?.recommendation.status, .candidate)
        XCTAssertEqual(result.levels.first(where: { $0.level == 12 })?.recommendation.status, .candidate)
        XCTAssertEqual(result.overall.status, .mixedDirections)
        XCTAssertNil(result.overall.proposed)
    }

    func testMissingSpecificationInvalidCurrentAndRangeBoundaryDoNotPropose() {
        let songs = (0..<3).map { _ in UUID() }
        let charts = songs.map { chart($0) }
        let rows = charts.map { play(chart: $0, fast: 400, slow: 600) }

        let missingSpecification = TimingTrendService.analyze(
            gameID: gameID,
            environment: environment,
            plays: rows,
            charts: charts,
            specification: nil
        )
        XCTAssertEqual(missingSpecification.overall.status, .unavailable)

        var offGrid = environment
        offGrid.settings.noteTiming = Decimal(string: "0.105")
        let offGridRows = charts.map { play(chart: $0, fast: 400, slow: 600, environment: offGrid) }
        XCTAssertEqual(analyze(offGridRows, charts: charts, in: offGrid).overall.status, .unavailable)

        var atUpperBound = environment
        atUpperBound.settings.noteTiming = 3
        let upperBoundRows = charts.map { play(chart: $0, fast: 400, slow: 600, environment: atUpperBound) }
        XCTAssertEqual(analyze(upperBoundRows, charts: charts, in: atUpperBound).overall.status, .limit)
        XCTAssertNil(analyze(upperBoundRows, charts: charts, in: atUpperBound).overall.proposed)
    }

    func testFastDominanceProposesOneStepDownAndWeakBiasMaintains() {
        let songs = (0..<3).map { _ in UUID() }
        let charts = songs.map { chart($0) }
        let fastRows = charts.map { play(chart: $0, fast: 120, slow: 80) }
        let weakRows = charts.map { play(chart: $0, fast: 490, slow: 510) }

        let candidate = analyze(fastRows, charts: charts).overall
        let maintained = analyze(weakRows, charts: charts).overall

        XCTAssertEqual(candidate.status, .candidate)
        XCTAssertEqual(candidate.proposed, Decimal(string: "0.09"))
        XCTAssertEqual(maintained.status, .maintain)
        XCTAssertNil(maintained.proposed)
    }

    func testFixedDevicePolicyPoolsAudioAndConditionAliases() {
        let songs = (0..<3).map { _ in UUID() }
        let charts = songs.map { chart($0) }
        var current = environment
        current.device = TimingEnvironmentPolicy.fixedDeviceName
        let aliases = ["iPad Pro 11 (M2)", "", "iPad Pro 11インチ (M2)"]
        let rows = charts.enumerated().map { index, item -> PlayRecord in
            var snapshot = current
            snapshot.device = aliases[index]
            snapshot.audioOutput = "出力\(index)"
            snapshot.conditions = "条件\(index)"
            return play(chart: item, fast: 400, slow: 600, environment: snapshot)
        }

        let result = analyze(rows, charts: charts, in: current, policy: .ourNotesFixedDevice).overall

        XCTAssertEqual(result.status, .candidate)
        XCTAssertEqual(result.matchingSongCount, 3)
        XCTAssertEqual(result.statistics.timingNoteCount, 3_000)
    }

    func testDateTiesUseUUIDOrderWhenApplyingPerChartLimit() throws {
        let song = UUID()
        let item = chart(song)
        let tiedRows = (1...11).map { number -> PlayRecord in
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
            return play(chart: item, fast: number == 11 ? 100 : 0, slow: number == 11 ? 0 : 100, date: 10, id: id)
        }

        let result = analyze(tiedRows, charts: [item]).overall

        XCTAssertEqual(result.statistics.timingSampleCount, 10)
        XCTAssertEqual(result.statistics.timingNoteCount, 1_000)
        XCTAssertEqual(try XCTUnwrap(result.statistics.timingBias), 1)
    }

    func testTwoThirdsSongAgreementPassesButHalfDoesNot() {
        let charts = (0..<4).map { _ in chart(UUID()) }
        let agreed = [
            play(chart: charts[0], fast: 20, slow: 180),
            play(chart: charts[1], fast: 20, slow: 180),
            play(chart: charts[2], fast: 190, slow: 10)
        ]
        let candidate = analyze(agreed, charts: charts).overall
        XCTAssertEqual(candidate.matchingSongCount, 2)
        XCTAssertEqual(candidate.proposed, Decimal(string: "0.11"))
        let divided = [
            play(chart: charts[0], fast: 10, slow: 190),
            play(chart: charts[1], fast: 10, slow: 190),
            play(chart: charts[2], fast: 130, slow: 70),
            play(chart: charts[3], fast: 130, slow: 70)
        ]
        let held = analyze(divided, charts: charts).overall
        XCTAssertEqual(held.matchingSongCount, 2)
        XCTAssertEqual(held.status, .mixedDirections)
        XCTAssertNil(held.proposed)
    }

    func testDetailAndBiasThresholdsAndWeakOpposingLevel() {
        let charts = (0..<4).map { _ in chart(UUID()) }
        let below = [
            play(chart: charts[0], fast: 50, slow: 116),
            play(chart: charts[1], fast: 50, slow: 116),
            play(chart: charts[2], fast: 50, slow: 117)
        ]
        XCTAssertEqual(analyze(below, charts: charts).overall.noteCount, 499)
        XCTAssertEqual(analyze(below, charts: charts).overall.status, .insufficientData)
        let exactBias = charts.prefix(3).map { play(chart: $0, levelAtPlay: 25, fast: 90, slow: 110) }
        XCTAssertEqual(analyze(exactBias, charts: charts).overall.proposed, Decimal(string: "0.11"))
        let mixed = charts.prefix(3).map { play(chart: $0, levelAtPlay: 25, fast: 40, slow: 160) }
            + [play(chart: charts[3], levelAtPlay: 28, fast: 120, slow: 80)]
        let result = analyze(mixed, charts: charts)
        XCTAssertEqual(result.overall.status, .candidate)
        XCTAssertEqual(result.levels.first { $0.level == 28 }?.recommendation.status, .insufficientData)
    }

    func testLevelSamplesPartitionRecentOverallAndChangingTimingStartsNewSample() {
        let charts = (0..<3).map { _ in chart(UUID()) }
        let rows = charts.flatMap { item in
            (0..<12).map { play(chart: item, levelAtPlay: $0 < 6 ? 25 : 26, fast: 40, slow: 160, date: Double($0)) }
        }
        let result = analyze(rows, charts: charts)
        XCTAssertEqual(result.overall.playCount, 30)
        XCTAssertEqual(result.levels.map { $0.recommendation.playCount }, [12, 18])
        XCTAssertEqual(result.levels.reduce(0) { $0 + $1.recommendation.noteCount }, result.overall.noteCount)
        var changed = environment; changed.settings.noteTiming = Decimal(string: "0.11")
        let fresh = analyze(rows, charts: charts, in: changed)
        XCTAssertEqual(fresh.overall.playCount, 0)
        XCTAssertTrue(fresh.levels.isEmpty)
        XCTAssertNil(fresh.overall.proposed)
    }
}
