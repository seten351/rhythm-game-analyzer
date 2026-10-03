import Foundation
import XCTest
@testable import ResultCore

final class AutomaticRegistrationTests: XCTestCase {
    private let gameID = OurNotesCatalog.gameID

    private struct Fixture {
        var state: AppState
        var song: Song
        var chart: Chart
        var draft: ResultDraft
        var evidence: [OCRReadEvidence]
    }

    private func fixture(
        title: String = "Song",
        aliases: [String] = [],
        achievement: Achievement = .none,
        noteCount: Int? = 100,
        totals: [Judgment: Int] = [.perfect: 80, .great: 10, .good: 5, .bad: 3, .miss: 2],
        combo: Int? = 100
    ) -> Fixture {
        let song = Song(gameID: gameID, masterTitle: "Song", masterAliases: aliases)
        let chart = Chart(songID: song.id, masterDifficulty: "EXPERT", masterLevel: 30, noteCount: noteCount)
        var state = AppState()
        state.songs = [song]
        state.charts = [chart]

        let judgments = Dictionary(uniqueKeysWithValues: Judgment.allCases.map { ($0, JudgmentCount(total: totals[$0])) })
        let draft = ResultDraft(
            gameID: gameID, presetID: "our-notes-v1", presetVersion: 1,
            title: title, difficulty: "EXPERT", level: 30, score: 900_000,
            combo: combo, achievement: achievement, judgments: judgments,
            fingerprint: .init(sha256: "draft-sha", layout: "normal"), kind: "normal"
        )

        var evidence: [OCRReadEvidence] = []
        func add(_ key: String, _ text: String, alternatives: [String] = []) {
            let tokens = ([text] + alternatives).map { OCRToken(text: $0, confidence: 1) }
            evidence.append(.init(sourceID: "source-\(evidence.count)", fieldKey: key, route: "region", observations: [tokens]))
        }
        add("title", title)
        add("difficulty", "EXPERT")
        add("difficulty", "30")
        add("score", "900000")
        add("combo", combo.map(String.init) ?? "")
        let achievementText: String
        switch achievement {
        case .fc: achievementText = "FULL COMBO"
        case .ap: achievementText = "ALL PERFECT"
        case .none: achievementText = "FC/APなし"
        case .unknown: achievementText = ""
        }
        add("achievement", achievementText)
        for judgment in Judgment.allCases {
            add(judgment.rawValue + ".total", totals[judgment].map(String.init) ?? "")
        }
        return Fixture(state: state, song: song, chart: chart, draft: draft, evidence: evidence)
    }

    private func assess(
        _ f: Fixture,
        draft: ResultDraft? = nil,
        evidence: [OCRReadEvidence]? = nil,
        confirmedFields: Set<OCRField> = []
    ) -> RegistrationAssessment {
        AutomaticRegistrationService.assess(
            draft ?? f.draft, evidence: evidence ?? f.evidence, state: f.state,
            threshold: 0.9, confirmedFields: confirmedFields
        )
    }

    private func read(_ f: Fixture, key: String) -> OCRReadEvidence {
        try! XCTUnwrap(f.evidence.first { $0.fieldKey == key })
    }

    private func replacing(_ f: Fixture, key: String, with replacement: OCRReadEvidence) -> [OCRReadEvidence] {
        f.evidence.filter { $0.fieldKey != key } + [replacement]
    }

    func testHighConfidenceCompleteNormalResultCanRegisterWithoutDate() {
        let f = fixture()

        let result = assess(f)

        XCTAssertTrue(result.canAutomaticallyRegister)
        XCTAssertEqual(result.chartID, f.chart.id)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertNil(AutomaticDateSelection.resolve([]).playedAt)
        XCTAssertGreaterThanOrEqual(result.confidenceScore, 90)
    }

    func testOneConfusableCharacterInTitleStillUniquelyMatchesMaster() {
        let f = fixture(title: "S0ng")

        let result = assess(f)

        XCTAssertTrue(result.canAutomaticallyRegister)
        XCTAssertEqual(result.chartID, f.chart.id)
        XCTAssertEqual(result.draft.title, f.song.title)
    }

    func testQuestionMarkInTitleCanBeResolvedByUniqueMasterMatch() {
        let f = fixture(title: "S?ng")

        let result = assess(f)

        XCTAssertTrue(result.canAutomaticallyRegister)
        XCTAssertEqual(result.chartID, f.chart.id)
        XCTAssertEqual(result.draft.title, f.song.title)
    }

    func testLowConfidenceJapaneseTitleResolvedByCatalogAndChartIdentity() {
        let f = fixture(title: "六兆年と一夜物語", aliases: ["六兆年と一夜物語"])
        let evidence = replacing(f, key: "title", with: .init(sourceID: "title", fieldKey: "title", route: "region",
            observations: [["六兆年と一夜物語", "六兆と一夜物語", "六兆年一夜物語"].map { OCRToken(text: $0, confidence: 0.3) }]))
        let result = assess(f, evidence: evidence)
        XCTAssertTrue(result.canAutomaticallyRegister)
        XCTAssertEqual(result.chartID, f.chart.id)
    }

    func testDifficultyAndLevelAlternativesUseAllMasterCombinations() {
        let f = fixture()
        let evidence = replacing(f, key: "difficulty", with: .init(sourceID: "identity", fieldKey: "difficulty", route: "region",
            observations: [[OCRToken(text: "EXPERT 30", confidence: 1), OCRToken(text: "HARD 31", confidence: 1)]]))
        let resolved = assess(f, evidence: evidence)
        XCTAssertTrue(resolved.canAutomaticallyRegister)
        XCTAssertEqual(resolved.draft.difficulty, "EXPERT")
        XCTAssertEqual(resolved.draft.level, 30)
        var ambiguous = f
        ambiguous.state.charts.append(Chart(songID: f.song.id, masterDifficulty: "HARD", masterLevel: 31))
        let unresolved = assess(ambiguous, evidence: evidence)
        XCTAssertFalse(unresolved.canAutomaticallyRegister)
        XCTAssertEqual(unresolved.chartCandidates.count, 2)
    }

    func testConfirmedDifficultyCannotSilentlyUseStaleChartSelection() {
        var f = fixture()
        f.draft.difficulty = "HARD"
        let result = AutomaticRegistrationService.assess(f.draft, evidence: f.evidence, state: f.state,
            confirmedFields: [.difficulty], selectedChartID: f.chart.id)
        XCTAssertFalse(result.canAutomaticallyRegister)
        XCTAssertTrue(result.issues.contains { $0.field == .difficulty })
    }

    func testLowConfidenceTitleAlternativesForDifferentSongsRemainUnresolved() {
        var f = fixture()
        let other = Song(gameID: gameID, masterTitle: "Other")
        f.state.songs.append(other)
        f.state.charts.append(Chart(songID: other.id, masterDifficulty: "EXPERT", masterLevel: 30))
        let evidence = replacing(f, key: "title", with: .init(sourceID: "title", fieldKey: "title", route: "region",
            observations: [["Song", "Other"].map { OCRToken(text: $0, confidence: 0.3) }]))
        let result = assess(f, evidence: evidence)
        XCTAssertFalse(result.canAutomaticallyRegister)
        XCTAssertTrue(result.issues.contains { $0.field == .title })
        XCTAssertEqual(result.level, .medium)
        XCTAssertEqual(result.chartCandidates.count, 2)
    }

    func testLowConfidenceJudgmentNeedsUniqueCatalogSum() {
        var f = fixture()
        let evidence = replacing(f, key: "PERFECT.total", with: .init(sourceID: "perfect", fieldKey: "PERFECT.total", route: "region",
            observations: [[OCRToken(text: "80", confidence: 0.3)]]))
        XCTAssertTrue(assess(f, evidence: evidence).canAutomaticallyRegister)
        f.state.charts[0].noteCount = nil
        XCTAssertFalse(assess(f, evidence: evidence).canAutomaticallyRegister)
    }

    func testDetailedFCComboMustEqualKnownNoteCountWithoutInferringPerfectTotal() {
        var f = fixture(achievement: .fc)
        f.draft.kind = "detail"
        f.draft.combo = 99
        f.draft.judgments = [.perfect: .init(fast: 20, slow: 30), .great: .init(fast: 1, slow: 0),
                            .good: .init(fast: 0, slow: 0), .bad: .init(fast: 0, slow: 0), .miss: .init(fast: 0, slow: 0)]
        XCTAssertTrue(ResultIntegrity.issues(f.draft, chart: f.chart).contains { $0.field == .combo })
        f.draft.combo = 100
        XCTAssertTrue(ResultIntegrity.issues(f.draft, chart: f.chart).isEmpty)
        XCTAssertNil(f.draft.judgments[.perfect]?.total)
    }

    func testNonPerfectTotalDifferenceRequiresReviewWithoutInferringCounts() {
        var f = fixture(noteCount: nil, combo: 90)
        f.draft.kind = "merged"
        f.draft.judgments[.great] = .init(total: 9, fast: 1, slow: 5)
        f.draft.judgments[.perfect] = .init(total: 80, fast: 20, slow: 30)
        let issues = ResultIntegrity.issues(f.draft, chart: f.chart)
        XCTAssertEqual(Set(issues.compactMap(\.field)), Set([.greatTotal, .greatFast, .greatSlow]))
        XCTAssertEqual(f.draft.judgments[.great]?.total, 9)
        XCTAssertEqual(f.draft.judgments[.perfect]?.total, 80)
    }

    func testSixNineOnlyReadAfterImageConversionRequiresCorroboration() {
        let f = fixture(noteCount: nil, combo: 90)
        let transformed = OCRReadEvidence(sourceID: "great", fieldKey: "GREAT.total", route: "inverted-padded",
                                         observations: [[OCRToken(text: "9", confidence: 1)]])
        let evidence = replacing(f, key: "GREAT.total", with: transformed)
        XCTAssertFalse(assess(f, evidence: evidence).canAutomaticallyRegister)
        let corroborated = evidence + [.init(sourceID: "great", fieldKey: "GREAT.total", route: "judgment-panel",
                                              observations: [[OCRToken(text: "9", confidence: 1)]])]
        XCTAssertTrue(assess(f, evidence: corroborated).canAutomaticallyRegister)
    }

    func testCompetingScoreAlternativesRequireReview() {
        let f = fixture()
        let original = read(f, key: "score")
        let ambiguous = OCRReadEvidence(
            sourceID: original.sourceID, fieldKey: "score", route: original.route,
            observations: [[OCRToken(text: "900000", confidence: 1), OCRToken(text: "900001", confidence: 0.96)]]
        )

        let result = assess(f, evidence: replacing(f, key: "score", with: ambiguous))

        XCTAssertFalse(result.canAutomaticallyRegister)
        XCTAssertTrue(result.issues.contains { $0.field == .score })
        XCTAssertEqual(result.issues.first { $0.field == .score }?.candidates, ["900000", "900001"])
    }

    func testOneIncorrectOrUnreadJudgmentRequiresReview() {
        let f = fixture()
        let greatRead = read(f, key: "GREAT.total")
        let incorrect = OCRReadEvidence(sourceID: greatRead.sourceID, fieldKey: greatRead.fieldKey, route: greatRead.route,
                                        observations: [[OCRToken(text: "9", confidence: 1)]])
        let wrongResult = assess(f, evidence: replacing(f, key: "GREAT.total", with: incorrect))
        XCTAssertFalse(wrongResult.canAutomaticallyRegister)
        XCTAssertTrue(wrongResult.issues.contains { $0.reason.contains("総ノーツ数") })

        let missing = assess(f, evidence: f.evidence.filter { $0.fieldKey != "GREAT.total" })
        XCTAssertFalse(missing.canAutomaticallyRegister)
        XCTAssertTrue(missing.issues.contains { $0.field == .greatTotal })
    }

    func testKnownMasterNoteCountRejectsMismatchedJudgmentTotal() {
        let f = fixture(totals: [.perfect: 80, .great: 10, .good: 5, .bad: 3, .miss: 1])

        let result = assess(f)

        XCTAssertFalse(result.canAutomaticallyRegister)
        XCTAssertTrue(result.issues.contains { $0.reason.contains("総ノーツ数") })
    }

    func testFullComboAllowsGoodJudgmentsWhenComboMatchesTotal() {
        let f = fixture(achievement: .fc, totals: [.perfect: 80, .great: 10, .good: 10, .bad: 0, .miss: 0])

        let result = assess(f)

        XCTAssertTrue(result.canAutomaticallyRegister)
        XCTAssertEqual(result.draft.achievement, .fc)
        XCTAssertEqual(result.draft.judgments[.good]?.total, 10)
    }

    func testAllPerfectRejectsAnyNonPerfectJudgment() {
        let f = fixture(achievement: .ap, totals: [.perfect: 99, .great: 0, .good: 1, .bad: 0, .miss: 0])

        let result = assess(f)

        XCTAssertFalse(result.canAutomaticallyRegister)
        XCTAssertTrue(result.issues.contains { $0.field == .achievement })
    }

    func testExistingSameChartAndScoreIsReportedAsDuplicateCandidate() {
        let f = fixture()
        var state = f.state
        state.plays = [PlayRecord(
            chartID: f.chart.id, gameID: gameID, titleAtPlay: f.song.title,
            difficultyAtPlay: f.chart.difficulty, levelAtPlay: f.chart.level,
            score: 900_000, combo: 100, achievement: .none,
            judgments: f.draft.judgments, presetID: "old", presetVersion: 1,
            fingerprints: [.init(sha256: "old-sha", layout: "normal")]
        )]

        let result = AutomaticRegistrationService.assess(f.draft, evidence: f.evidence, state: state)

        XCTAssertFalse(result.canAutomaticallyRegister)
        XCTAssertEqual(result.duplicateIDs, state.plays.map(\.id))
        XCTAssertTrue(result.issues.contains { $0.reason.contains("登録済み") })
    }

    func testOnlyExplicitlyConfirmedFieldClearsItsOwnAmbiguity() {
        let f = fixture()
        let scoreRead = read(f, key: "score")
        let ambiguousScore = OCRReadEvidence(sourceID: scoreRead.sourceID, fieldKey: "score", route: scoreRead.route,
                                             observations: [[OCRToken(text: "900000", confidence: 1), OCRToken(text: "900001", confidence: 0.96)]])
        let comboRead = read(f, key: "combo")
        let ambiguousCombo = OCRReadEvidence(sourceID: comboRead.sourceID, fieldKey: "combo", route: comboRead.route,
                                             observations: [[OCRToken(text: "100", confidence: 1), OCRToken(text: "101", confidence: 0.96)]])
        let evidence = replacing(f, key: "score", with: ambiguousScore).filter { $0.fieldKey != "combo" } + [ambiguousCombo]

        let result = assess(f, evidence: evidence, confirmedFields: [.score])

        XCTAssertFalse(result.canAutomaticallyRegister)
        XCTAssertFalse(result.issues.contains { $0.field == .score })
        XCTAssertTrue(result.issues.contains { $0.field == .combo })
    }

    func testMasterNoteCountSelectsUniqueCombinationOfObservedOCRAlternatives() {
        let f = fixture(totals: [.perfect: 88, .great: 8, .good: 2, .bad: 1, .miss: 1])
        let perfectRead = read(f, key: "PERFECT.total")
        let alternatives = OCRReadEvidence(sourceID: perfectRead.sourceID, fieldKey: perfectRead.fieldKey, route: perfectRead.route,
                                           observations: [[OCRToken(text: "88", confidence: 1), OCRToken(text: "89", confidence: 0.96)]])

        let result = assess(f, evidence: replacing(f, key: "PERFECT.total", with: alternatives))

        XCTAssertTrue(result.canAutomaticallyRegister)
        XCTAssertEqual(result.draft.judgments[.perfect]?.total, 88)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testMasterNoteCountLeavesMultipleValidOCRCombinationsForReview() {
        let f = fixture(totals: [.perfect: 88, .great: 8, .good: 2, .bad: 1, .miss: 1])
        let perfectRead = read(f, key: "PERFECT.total")
        let greatRead = read(f, key: "GREAT.total")
        let perfectAlternatives = OCRReadEvidence(sourceID: perfectRead.sourceID, fieldKey: perfectRead.fieldKey, route: perfectRead.route,
                                                   observations: [[OCRToken(text: "88", confidence: 1), OCRToken(text: "89", confidence: 0.96)]])
        let greatAlternatives = OCRReadEvidence(sourceID: greatRead.sourceID, fieldKey: greatRead.fieldKey, route: greatRead.route,
                                                 observations: [[OCRToken(text: "8", confidence: 1), OCRToken(text: "7", confidence: 0.96)]])
        let evidence = replacing(f, key: "PERFECT.total", with: perfectAlternatives).filter { $0.fieldKey != "GREAT.total" } + [greatAlternatives]

        let result = assess(f, evidence: evidence)

        XCTAssertFalse(result.canAutomaticallyRegister)
        XCTAssertTrue(result.issues.contains { $0.field == .perfectTotal || $0.field == .greatTotal })
    }

    func testAliasAndFullWidthUppercaseTitleAndDifficultyMatch() {
        let f = fixture(title: "ｓｏｎｇ", aliases: ["ＳＯＮＧ"])
        let titleRead = read(f, key: "title")
        let fullWidthDifficulty = OCRReadEvidence(sourceID: "difficulty-fullwidth", fieldKey: "difficulty", route: "region",
                                                  observations: [[OCRToken(text: "ＥＸＰＥＲＴ", confidence: 1)]])
        let fullWidthLevel = OCRReadEvidence(sourceID: "difficulty-level", fieldKey: "difficulty", route: "region",
                                             observations: [[OCRToken(text: "３０", confidence: 1)]])
        let evidence = replacing(f, key: "title", with: OCRReadEvidence(sourceID: titleRead.sourceID, fieldKey: "title", route: titleRead.route,
                                                                        observations: [[OCRToken(text: "ＳＯＮＧ", confidence: 1)]]))
            .filter { $0.fieldKey != "difficulty" } + [fullWidthDifficulty, fullWidthLevel]

        let result = assess(f, evidence: evidence)

        XCTAssertTrue(result.canAutomaticallyRegister)
        XCTAssertEqual(result.chartID, f.chart.id)
        XCTAssertEqual(result.draft.title, f.song.title)
        XCTAssertEqual(result.draft.difficulty, f.chart.difficulty)
    }

    func testLevelMismatchWithExactTitleDoesNotRedirectToAnotherMasterEntry() {
        let f = fixture()
        var state = f.state
        let otherSong = Song(gameID: gameID, masterTitle: "Other Song")
        let otherChart = Chart(songID: otherSong.id, masterDifficulty: "EXPERT", masterLevel: 31, noteCount: 100)
        state.songs.append(otherSong)
        state.charts.append(otherChart)
        let updated = Fixture(state: state, song: f.song, chart: f.chart, draft: f.draft, evidence: f.evidence)
        let mismatch = OCRReadEvidence(sourceID: "difficulty-level", fieldKey: "difficulty", route: "region",
                                       observations: [[OCRToken(text: "EXPERT 31", confidence: 1)]])
        let evidence = replacing(updated, key: "difficulty", with: mismatch)

        let result = assess(updated, evidence: evidence)

        XCTAssertFalse(result.canAutomaticallyRegister)
        XCTAssertNil(result.chartID)
        XCTAssertTrue(result.issues.contains { $0.field == .title })
        XCTAssertNotEqual(result.chartID, otherChart.id)
    }

    func testChartWithoutNoteCountDecodesFromLegacyJSON() throws {
        let chart = Chart(songID: UUID(), masterDifficulty: "EXPERT", masterLevel: 30)
        let encoded = try JSONEncoder().encode(chart)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "noteCount")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Chart.self, from: legacyData)

        XCTAssertNil(decoded.noteCount)
        XCTAssertEqual(decoded.masterDifficulty, "EXPERT")
        XCTAssertEqual(decoded.masterLevel, 30)
    }
}
