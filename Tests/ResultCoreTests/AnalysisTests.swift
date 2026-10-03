import Foundation
import XCTest
@testable import ResultCore

final class AnalysisTests: XCTestCase {
    private let gameID = "rhythm-game"
    private let fingerprint = SourceFingerprint(sha256: "image-hash", layout: "result")
    private let settings = PlaySettings(noteSpeed: 10, noteTiming: 0, chartPosition: 0, mirror: false)

    private func play(
        score: Int = 0,
        difficulty: String = "MASTER",
        level: Int? = 30,
        achievement: Achievement = .unknown,
        judgments: [Judgment: JudgmentCount] = [:],
        chartID: UUID = UUID(),
        environment: PlayEnvironment? = nil,
        playedAt: TimeInterval = 0,
        confirmed: Bool = true
    ) -> PlayRecord {
        PlayRecord(
            chartID: chartID,
            gameID: gameID,
            titleAtPlay: "Song snapshot",
            difficultyAtPlay: difficulty,
            levelAtPlay: level,
            score: score,
            achievement: achievement,
            judgments: judgments,
            importedAt: Date(timeIntervalSince1970: playedAt),
            playedAt: Date(timeIntervalSince1970: playedAt),
            presetID: "preset",
            presetVersion: 1,
            environment: environment,
            fingerprints: [fingerprint],
            confirmed: confirmed
        )
    }

    private func totals(
        perfect: Int = 0,
        great: Int = 0,
        good: Int = 0,
        bad: Int = 0,
        miss: Int = 0
    ) -> [Judgment: JudgmentCount] {
        [.perfect: .init(total: perfect), .great: .init(total: great), .good: .init(total: good), .bad: .init(total: bad), .miss: .init(total: miss)]
    }

    private func detailed(
        perfectFast: Int = 0,
        perfectSlow: Int = 0,
        greatFast: Int = 0,
        greatSlow: Int = 0,
        missFast: Int? = nil,
        missSlow: Int? = nil
    ) -> [Judgment: JudgmentCount] {
        [
            .perfect: .init(fast: perfectFast, slow: perfectSlow),
            .great: .init(fast: greatFast, slow: greatSlow),
            .good: .init(fast: 0, slow: 0),
            .bad: .init(fast: 0, slow: 0),
            .miss: .init(fast: missFast, slow: missSlow)
        ]
    }

    private func completeFields(detailedResult: Bool, title: String = "Song") -> [String: [OCRToken]] {
        var fields: [String: [OCRToken]] = [
            "title": [.init(text: title)],
            "difficulty": [.init(text: "MASTER 30")],
            "score": [.init(text: "1,000,000")],
            "combo": [.init(text: "500")],
            "achievement": [.init(text: "ALL PERFECT")],
            "timingHeader": [.init(text: detailedResult ? "FAST SLOW" : "NORMAL")]
        ]
        for judgment in Judgment.allCases {
            if detailedResult {
                fields[judgment.rawValue + ".fast"] = [.init(text: "1")]
                fields[judgment.rawValue + ".slow"] = [.init(text: "2")]
            } else {
                fields[judgment.rawValue + ".total"] = [.init(text: "3")]
            }
        }
        return fields
    }

    private func preset() -> GamePreset {
        let required = ["title", "difficulty", "score", "combo", "achievement", "timingHeader", "settingsMarker", "noteSpeed", "noteTiming", "chartPosition", "mirror"] + Judgment.allCases.flatMap { [$0.rawValue + ".total", $0.rawValue + ".fast", $0.rawValue + ".slow"] }
        let regions = Dictionary(uniqueKeysWithValues: required.map { ($0, NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1)) })
        return GamePreset(
            formatVersion: 1,
            id: "preset",
            version: 1,
            gameId: gameID,
            name: "Test preset",
            parserId: "our-notes-v1",
            aspectRatio: 16.0 / 9.0,
            aspectTolerance: 0.05,
            confidenceThreshold: 0.8,
            regions: regions,
            timing: nil
        )
    }

    func testJudgmentRatesUseCompletePlaySamplesAndWeightEveryNote() {
        let completeA = play(judgments: totals(perfect: 90, great: 10))
        let completeB = play(judgments: totals(perfect: 0, great: 0, good: 100))
        var incompleteCounts = totals(perfect: 100)
        incompleteCounts[.miss] = .init(total: nil)
        let incomplete = play(judgments: incompleteCounts)

        let result = StatisticsService.summarize([completeA, completeB, incomplete])

        XCTAssertEqual(result.judgmentSampleCount, 2)
        XCTAssertEqual(result.judgmentNoteCount, 200)
        XCTAssertEqual(result.judgmentRates[.perfect] ?? -1, 0.45, accuracy: 0.000_001)
        XCTAssertEqual(result.judgmentRates[.great] ?? -1, 0.05, accuracy: 0.000_001)
        XCTAssertEqual(result.judgmentRates[.good] ?? -1, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(result.judgmentRates[.bad] ?? -1, 0, accuracy: 0.000_001)
        XCTAssertEqual(result.judgmentRates[.miss] ?? -1, 0, accuracy: 0.000_001)
    }

    func testFastSlowUsesPerfectAndGreatOnlyAndExcludesPlaysMissingDetail() {
        let complete = play(judgments: detailed(perfectFast: 1, perfectSlow: 2, greatFast: 3, greatSlow: 4, missFast: 20, missSlow: 30))
        let missing = play(judgments: [.perfect: .init(fast: 1, slow: 1), .great: .init(fast: 1, slow: nil)])

        let result = StatisticsService.summarize([complete, missing])

        XCTAssertEqual(result.timingSampleCount, 1)
        XCTAssertEqual(result.timingNoteCount, 10)
        XCTAssertEqual(result.fastRate ?? -1, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(result.slowRate ?? -1, 0.6, accuracy: 0.000_001)
        XCTAssertEqual(result.timingBias ?? -1, 0.2, accuracy: 0.000_001)
    }

    func testFCAndAPRatesExcludeUnknownAndUseKnownAchievementsAsDenominator() {
        let rows = [
            play(achievement: .unknown),
            play(achievement: .none),
            play(achievement: .fc),
            play(achievement: .ap)
        ]

        let result = StatisticsService.summarize(rows)

        XCTAssertEqual(result.achievementSampleCount, 3)
        XCTAssertEqual(result.fcRate ?? -1, 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(result.apRate ?? -1, 1.0 / 3.0, accuracy: 0.000_001)
    }

    func testScoreMeanMedianAndSampleStandardDeviation() {
        let result = StatisticsService.summarize([play(score: 1), play(score: 3), play(score: 8)])

        XCTAssertEqual(result.scoreMean ?? -1, 4, accuracy: 0.000_001)
        XCTAssertEqual(result.scoreMedian ?? -1, 3, accuracy: 0.000_001)
        XCTAssertEqual(result.scoreStandardDeviation ?? -1, sqrt(13), accuracy: 0.000_001)
    }

    func testGroupsUsePlaySnapshotsAndKeepUnknownLevelGroup() {
        let rows = [
            play(score: 100, difficulty: "MASTER", level: 30),
            play(score: 200, difficulty: "EXPERT", level: 27),
            play(score: 300, difficulty: "MASTER", level: nil)
        ]

        let byDifficulty = StatisticsService.grouped(rows, by: .difficulty)
        let byLevel = StatisticsService.grouped(rows, by: .level)

        XCTAssertEqual(byDifficulty.map(\.id), ["EXPERT", "MASTER"])
        XCTAssertEqual(byDifficulty.first?.statistics.scoreMean ?? -1, 200)
        XCTAssertEqual(byDifficulty.last?.statistics.playCount, 2)
        XCTAssertEqual(byLevel.map(\.id), ["27", "30", "不明"])
        XCTAssertEqual(byLevel.map(\.label), ["Lv.27", "Lv.30", "不明"])
        XCTAssertEqual(byLevel.last?.statistics.scoreMean ?? -1, 300)
    }

    func testLibraryProgressCountsUnplayedMasterCharts() {
        let first = Chart(songID: UUID(), masterDifficulty: "MASTER", masterLevel: 30)
        let second = Chart(songID: UUID(), masterDifficulty: "EXPERT", masterLevel: 27)
        let third = Chart(songID: UUID(), masterDifficulty: "SPECIAL", masterLevel: 29)
        let plays = [
            play(achievement: .fc, chartID: first.id),
            play(achievement: .ap, chartID: first.id)
        ]

        let progress = LibraryProgress.calculate(charts: [first, second, third], plays: plays)

        XCTAssertEqual(progress.charts, 3)
        XCTAssertEqual(progress.played, 1)
        XCTAssertEqual(progress.unplayed, 2)
        XCTAssertEqual(progress.fc, 1)
        XCTAssertEqual(progress.ap, 1)
        XCTAssertEqual(progress.notFC, 2)
        XCTAssertEqual(progress.notAP, 2)
    }

    func testTimingRecommendationRequiresThreePlaysFiveHundredEventsAndTenPercentBias() {
        let chartID = UUID()
        let environment = PlayEnvironment(device: "Headphones", audioOutput: "Wired", conditions: "Quiet", settings: settings)
        let rows = [
            play(judgments: detailed(perfectFast: 58, perfectSlow: 108), chartID: chartID, environment: environment, playedAt: 1),
            play(judgments: detailed(perfectFast: 58, perfectSlow: 109), chartID: chartID, environment: environment, playedAt: 2),
            play(judgments: detailed(perfectFast: 109, perfectSlow: 58), chartID: chartID, environment: environment, playedAt: 3)
        ]
        let spec = TimingSpecification(unit: "ms", step: 1, minimum: -10, maximum: 10, slowCorrectionDirection: 1)

        let recommendation = TimingService.recommend(chartID: chartID, environment: environment, plays: rows, specification: spec)

        XCTAssertEqual(recommendation.playCount, 3)
        XCTAssertEqual(recommendation.noteCount, 500)
        XCTAssertEqual(recommendation.bias ?? 0, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(recommendation.proposed, 1)
    }

    func testTimingRecommendationHoldsForMissingSpecificationAndOutOfRangeCurrentValue() {
        let chartID = UUID()
        let environment = PlayEnvironment(device: "Headphones", audioOutput: "Wired", conditions: "Quiet", settings: settings)
        let rows = (0..<3).map { index in
            play(judgments: detailed(perfectFast: 50, perfectSlow: 150), chartID: chartID, environment: environment, playedAt: Double(index))
        }
        let spec = TimingSpecification(unit: "ms", step: 1, minimum: -10, maximum: 10, slowCorrectionDirection: 1)

        let noSpec = TimingService.recommend(chartID: chartID, environment: environment, plays: rows, specification: nil)
        var outsideEnvironment = environment
        outsideEnvironment.settings.noteTiming = 11
        let outsideRange = TimingService.recommend(chartID: chartID, environment: outsideEnvironment, plays: rows, specification: spec)

        XCTAssertNil(noSpec.proposed)
        XCTAssertEqual(noSpec.current, 0)
        XCTAssertNil(outsideRange.proposed)
        XCTAssertEqual(outsideRange.reason, "現在値がプリセットの許容範囲外です。")
    }

    func testTimingRecommendationHoldsWhenOneStepWouldCrossRangeBoundary() {
        let chartID = UUID()
        var boundarySettings = settings
        boundarySettings.noteTiming = 10
        let environment = PlayEnvironment(device: "Headphones", audioOutput: "Wired", conditions: "Quiet", settings: boundarySettings)
        let rows = (0..<3).map { index in
            play(judgments: detailed(perfectFast: 50, perfectSlow: 150), chartID: chartID, environment: environment, playedAt: Double(index))
        }
        let spec = TimingSpecification(unit: "ms", step: 1, minimum: -10, maximum: 10, slowCorrectionDirection: 1)

        let recommendation = TimingService.recommend(chartID: chartID, environment: environment, plays: rows, specification: spec)

        XCTAssertNil(recommendation.proposed)
        XCTAssertEqual(recommendation.current, 10)
        XCTAssertEqual(recommendation.reason, "1ステップの変更が許容範囲を超えます。")
    }

    func testTimingSpecificationRejectsExtremeDirectionWithoutOverflow() {
        let specification = TimingSpecification(unit: "ms", step: 1, minimum: -10, maximum: 10, slowCorrectionDirection: Int.min)

        XCTAssertThrowsError(try specification.validate())
    }

    func testTimingFiltersMixedSettingsAndSuggestsOppositeStepForFastBias() {
        let chartID = UUID()
        let environment = PlayEnvironment(device: "Headphones", audioOutput: "Wired", conditions: "Quiet", settings: settings)
        var mixedSettings = settings
        mixedSettings.noteTiming = 1
        let mixedEnvironment = PlayEnvironment(id: environment.id, device: environment.device, audioOutput: environment.audioOutput, conditions: environment.conditions, settings: mixedSettings)
        let otherEnvironment = PlayEnvironment(device: "Speakers", audioOutput: "Wired", conditions: "Quiet", settings: settings)
        let otherChartID = UUID()
        let rows = [
            play(judgments: detailed(perfectFast: 150, perfectSlow: 50), chartID: chartID, environment: environment, playedAt: 1),
            play(judgments: detailed(perfectFast: 150, perfectSlow: 50), chartID: chartID, environment: environment, playedAt: 2),
            play(judgments: detailed(perfectFast: 150, perfectSlow: 50), chartID: chartID, environment: mixedEnvironment, playedAt: 3),
            play(judgments: detailed(perfectFast: 150, perfectSlow: 50), chartID: chartID, environment: otherEnvironment, playedAt: 4),
            play(judgments: detailed(perfectFast: 150, perfectSlow: 50), chartID: otherChartID, environment: environment, playedAt: 5)
        ]
        let spec = TimingSpecification(unit: "ms", step: 1, minimum: -10, maximum: 10, slowCorrectionDirection: 1)

        let recommendation = TimingService.recommend(chartID: chartID, environment: environment, plays: rows, specification: spec)

        XCTAssertEqual(recommendation.playCount, 2)
        XCTAssertNil(recommendation.proposed)
        XCTAssertEqual(recommendation.reason, "同一譜面・同一環境・同一設定の詳細結果が3プレイ以上必要です。")
        let fastRows = (0..<3).map { index in
            play(judgments: detailed(perfectFast: 150, perfectSlow: 50), chartID: chartID, environment: environment, playedAt: Double(index))
        }
        let fastRecommendation = TimingService.recommend(chartID: chartID, environment: environment, plays: fastRows, specification: spec)
        XCTAssertEqual(fastRecommendation.proposed, -1)
    }

    func testConfirmedOurNotesDecimalStepDirectionsAndFixedChangeExcludesOldResults() {
        let chartID = UUID()
        var fixed = settings; fixed.noteTiming = Decimal(string: "0.10")
        let environment = PlayEnvironment(device: "iPad", audioOutput: "Wired", conditions: "Quiet", settings: fixed)
        let spec = TimingSpecification(unit: "ゲーム内単位", step: Decimal(string: "0.01")!, minimum: -3, maximum: 3, slowCorrectionDirection: 1)
        let slowRows = (0..<3).map { play(judgments: detailed(perfectFast: 50, perfectSlow: 150), chartID: chartID, environment: environment, playedAt: Double($0)) }
        let fastRows = (0..<3).map { play(judgments: detailed(perfectFast: 150, perfectSlow: 50), chartID: chartID, environment: environment, playedAt: Double($0)) }
        XCTAssertEqual(TimingService.recommend(chartID: chartID, environment: environment, plays: slowRows, specification: spec).proposed, Decimal(string: "0.11"))
        XCTAssertEqual(TimingService.recommend(chartID: chartID, environment: environment, plays: fastRows, specification: spec).proposed, Decimal(string: "0.09"))
        var changed = environment; changed.settings.noteTiming = Decimal(string: "0.11")
        let held = TimingService.recommend(chartID: chartID, environment: changed, plays: slowRows, specification: spec)
        XCTAssertNil(held.proposed); XCTAssertEqual(held.playCount, 0)
        XCTAssertEqual(slowRows.first?.environment, environment)
        for (value, rows) in [(Decimal(3), slowRows), (Decimal(-3), fastRows)] {
            var edge = environment; edge.settings.noteTiming = value
            var edgeRows = rows
            for i in edgeRows.indices { edgeRows[i].environment = edge }
            XCTAssertNil(TimingService.recommend(chartID: chartID, environment: edge, plays: edgeRows, specification: spec).proposed)
        }
    }

    func testTimingHoldsBelowThresholdsAndShowsCountsWithoutSpecification() {
        let chartID = UUID()
        let environment = PlayEnvironment(device: "iPad", audioOutput: "Wired", conditions: "Quiet", settings: settings)
        let spec = TimingSpecification(unit: "game", step: 1, minimum: -3, maximum: 3, slowCorrectionDirection: 1)
        let belowCount = (0..<3).map { play(judgments: detailed(perfectFast: 50, perfectSlow: $0 == 0 ? 115 : 117), chartID: chartID, environment: environment) }
        let lowCount = TimingService.recommend(chartID: chartID, environment: environment, plays: belowCount, specification: spec)
        XCTAssertEqual(lowCount.noteCount, 499); XCTAssertNil(lowCount.proposed)
        let belowBias = (0..<3).map { _ in play(judgments: detailed(perfectFast: 91, perfectSlow: 109), chartID: chartID, environment: environment) }
        XCTAssertNil(TimingService.recommend(chartID: chartID, environment: environment, plays: belowBias, specification: spec).proposed)
        let unknownSpec = TimingService.recommend(chartID: chartID, environment: environment, plays: belowBias, specification: nil)
        XCTAssertNil(unknownSpec.proposed); XCTAssertEqual(unknownSpec.playCount, 3); XCTAssertEqual(unknownSpec.noteCount, 600)
        XCTAssertEqual(unknownSpec.bias ?? -1, 0.09, accuracy: 0.000_001)
    }

    func testTimingUsesLatestTenConfirmedCompleteSameConditionPlaysAndRequiresDirectionAgreement() {
        let chartID = UUID()
        let environment = PlayEnvironment(device: "iPad", audioOutput: "Wired", conditions: "Quiet", settings: settings)
        let spec = TimingSpecification(unit: "game", step: 1, minimum: -3, maximum: 3, slowCorrectionDirection: 1)
        var rows = (1...10).map { play(judgments: detailed(perfectFast: 150, perfectSlow: 50), chartID: chartID, environment: environment, playedAt: Double($0)) }
        rows.append(play(judgments: detailed(perfectFast: 0, perfectSlow: 100_000), chartID: chartID, environment: environment, playedAt: 0))
        rows.append(play(judgments: detailed(perfectFast: 0, perfectSlow: 100_000), chartID: chartID, environment: environment, playedAt: 20, confirmed: false))
        rows.append(play(judgments: [.perfect: .init(fast: 0, slow: 100_000)], chartID: chartID, environment: environment, playedAt: 21))
        var other = environment; other.audioOutput = "Bluetooth"
        rows.append(play(judgments: detailed(perfectFast: 0, perfectSlow: 100_000), chartID: chartID, environment: other, playedAt: 22))
        let recent = TimingService.recommend(chartID: chartID, environment: environment, plays: rows.reversed(), specification: spec)
        XCTAssertEqual(recent.playCount, 10); XCTAssertEqual(recent.noteCount, 2000); XCTAssertEqual(recent.proposed, -1)
        let inconsistent = [play(judgments: detailed(perfectFast: 0, perfectSlow: 1000), chartID: chartID, environment: environment)] + (0..<2).map { _ in play(judgments: detailed(perfectFast: 200, perfectSlow: 0), chartID: chartID, environment: environment) }
        XCTAssertNil(TimingService.recommend(chartID: chartID, environment: environment, plays: inconsistent, specification: spec).proposed)
    }

    func testTimingDoesNotRecommendForUnspecifiedEnvironmentIncompleteSettingsOrOffGridValue() {
        let chartID = UUID()
        let spec = TimingSpecification(unit: "game", step: Decimal(string: "0.01")!, minimum: -3, maximum: 3, slowCorrectionDirection: 1)
        let environment = PlayEnvironment(device: "iPad", audioOutput: "Wired", conditions: "Quiet", settings: settings)
        var noAudio = environment; noAudio.audioOutput = ""
        var incomplete = environment; incomplete.settings.chartPosition = nil
        var offGrid = environment; offGrid.settings.noteTiming = Decimal(string: "0.105")
        for held in [noAudio, incomplete, offGrid] {
            let rows = (0..<3).map { _ in play(judgments: detailed(perfectFast: 50, perfectSlow: 150), chartID: chartID, environment: held) }
            XCTAssertNil(TimingService.recommend(chartID: chartID, environment: held, plays: rows, specification: spec).proposed)
        }
    }

    func testParserCombinesThreeFieldTokenBatchesAndDistinguishesNormalAndDetailedCounts() {
        let firstImage: [String: [OCRToken]] = ["title": [.init(text: "Song")], "score": [.init(text: "1,000,000")]]
        let secondImage: [String: [OCRToken]] = ["title": [.init(text: "Name")], "difficulty": [.init(text: "MASTER 30")], "combo": [.init(text: "500")]]
        var thirdImage = completeFields(detailedResult: false)
        for key in ["title", "difficulty", "score", "combo"] { thirdImage.removeValue(forKey: key) }
        let mergedNormal = [firstImage, secondImage, thirdImage].reduce(into: [String: [OCRToken]]()) { merged, part in
            for (key, tokens) in part { merged[key, default: []].append(contentsOf: tokens) }
        }
        let normal = OurNotesParser.result(fields: mergedNormal, preset: preset(), fingerprint: fingerprint, knownTitles: [])

        XCTAssertEqual(normal.title, "Song Name")
        XCTAssertEqual(normal.kind, "normal")
        XCTAssertEqual(normal.judgments[.perfect]?.total, 3)
        XCTAssertNil(normal.judgments[.perfect]?.fast)

        let detailed = OurNotesParser.result(fields: completeFields(detailedResult: true), preset: preset(), fingerprint: fingerprint, knownTitles: [])
        XCTAssertEqual(detailed.kind, "detail")
        XCTAssertNil(detailed.judgments[.perfect]?.total)
        XCTAssertEqual(detailed.judgments[.perfect]?.fast, 1)
        XCTAssertEqual(detailed.judgments[.perfect]?.slow, 2)
    }

    func testParserKeepsZeroDistinctFromMissingAndInfersNoAchievement() {
        var fields = completeFields(detailedResult: false)
        fields["achievement"] = [.init(text: "-")]
        fields["PERFECT.total"] = [.init(text: "0")]
        fields.removeValue(forKey: "GREAT.total")
        fields["MISS.total"] = [.init(text: "1")]

        let result = OurNotesParser.result(fields: fields, preset: preset(), fingerprint: fingerprint, knownTitles: [])

        XCTAssertEqual(result.judgments[.perfect]?.total, 0)
        XCTAssertNil(result.judgments[.great]?.total)
        XCTAssertEqual(result.achievement, .none)
    }

    func testParserReportsNegativeJudgmentCountAsInvalid() {
        var fields = completeFields(detailedResult: false)
        fields["PERFECT.total"] = [.init(text: "-1")]

        let result = OurNotesParser.result(fields: fields, preset: preset(), fingerprint: fingerprint, knownTitles: [])

        XCTAssertTrue(result.issues.contains { $0.contains("判定数には0以上") })
    }

    func testParserDoesNotExtractDigitsFromMalformedNumericText() {
        var fields = completeFields(detailedResult: false)
        fields["score"] = [.init(text: "1O0")]

        let result = OurNotesParser.result(fields: fields, preset: preset(), fingerprint: fingerprint, knownTitles: [])

        XCTAssertNil(result.score)
        XCTAssertTrue(result.issues.contains { $0.contains("整数として読めません") })
    }

    func testParserReportsContradictoryAPAndDoesNotTreatTimingHeaderAsSetting() {
        var fields = completeFields(detailedResult: false)
        fields["MISS.total"] = [.init(text: "1")]
        fields["timingHeader"] = [.init(text: "54ms")]

        let result = OurNotesParser.result(fields: fields, preset: preset(), fingerprint: fingerprint, knownTitles: [])
        let parsedSettings = OurNotesParser.settings(fields: fields)

        XCTAssertEqual(result.achievement, .ap)
        XCTAssertTrue(result.issues.contains { $0.contains("AP表示と判定数が矛盾") })
        XCTAssertNil(parsedSettings.noteTiming)
    }

    func testDuplicateTitleCandidatesAreNotAutomaticallyReplaced() {
        let originalTitle = "Song"
        let fields = completeFields(detailedResult: false, title: originalTitle)

        let result = OurNotesParser.result(fields: fields, preset: preset(), fingerprint: fingerprint, knownTitles: ["Song", "SONG"])

        XCTAssertEqual(result.title, originalTitle)
    }
}
