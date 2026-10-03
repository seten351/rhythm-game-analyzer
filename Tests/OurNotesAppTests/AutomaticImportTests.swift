import Foundation
import XCTest
@testable import OurNotesApp
@testable import ResultCore

@MainActor
final class AutomaticImportTests: XCTestCase {
    private final class Repository: StateRepository {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("automatic-import-tests/results.store")
        var stored = AppState()
        var failSaves = false

        func load() throws -> AppState { stored }
        func save(_ state: AppState) throws {
            if failSaves { throw CoreError.invalid("fixture save failure") }
            stored = state
        }
    }

    private struct Fixture {
        var model: AppModel
        var repository: Repository
        var song: Song
        var chart: Chart
    }

    private let gameID = OurNotesCatalog.gameID

    private func fixture(noteTiming: Decimal? = nil, oldPlays: [PlayRecord] = []) -> Fixture {
        let repository = Repository()
        let song = Song(gameID: gameID, masterTitle: "Song")
        let chart = Chart(songID: song.id, masterDifficulty: "EXPERT", masterLevel: 30, noteCount: 100)
        repository.stored.songs = [song]
        repository.stored.charts = [chart]
        repository.stored.plays = oldPlays
        if let noteTiming {
            repository.stored.environments[0].settings.noteTiming = noteTiming
        }
        let model = AppModel(inMemory: true, loadBundledCatalog: false, repository: repository)
        model.batchEnvironment = model.activeEnvironment
        return Fixture(model: model, repository: repository, song: song, chart: chart)
    }

    private func normalCounts() -> [Judgment: JudgmentCount] {
        [.perfect: .init(total: 80), .great: .init(total: 10), .good: .init(total: 10), .bad: .init(total: 0), .miss: .init(total: 0)]
    }

    private func detailCounts() -> [Judgment: JudgmentCount] {
        [.perfect: .init(fast: 40, slow: 40), .great: .init(fast: 5, slow: 5), .good: .init(fast: 5, slow: 5),
         .bad: .init(fast: 0, slow: 0), .miss: .init(fast: 0, slow: 0)]
    }

    private func evidence(for draft: ResultDraft, sourcePrefix: String) -> [OCRReadEvidence] {
        var reads: [OCRReadEvidence] = []
        func add(_ key: String, _ value: String) {
            reads.append(.init(sourceID: "\(sourcePrefix)-source-\(reads.count)", fieldKey: key, route: "region",
                               observations: [[OCRToken(text: value, confidence: 1)]]))
        }
        add("title", draft.title)
        add("difficulty", "EXPERT")
        add("difficulty", "30")
        add("score", String(draft.score ?? 0))
        add("combo", String(draft.combo ?? 0))
        add("achievement", draft.achievement == .fc ? "FULL COMBO" : draft.achievement == .ap ? "ALL PERFECT" : "FC/APなし")
        for judgment in Judgment.allCases {
            let count = draft.judgments[judgment] ?? .init()
            if draft.kind == "detail" {
                add(judgment.rawValue + ".fast", String(count.fast ?? 0))
                add(judgment.rawValue + ".slow", String(count.slow ?? 0))
            } else {
                add(judgment.rawValue + ".total", String(count.total ?? 0))
            }
        }
        return reads
    }

    private func pending(
        _ sha: String,
        kind: String = "normal",
        score: Int = 900_000,
        combo: Int = 100,
        title: String = "Song",
        date: Date? = nil,
        judgments: [Judgment: JudgmentCount]? = nil
    ) -> PendingImport {
        let fingerprint = SourceFingerprint(sha256: sha, layout: kind)
        let achievement: Achievement = .fc
        let draft = ResultDraft(
            gameID: gameID, presetID: "our-notes-v1", presetVersion: 1,
            title: title, difficulty: "EXPERT", level: 30, score: score, combo: combo,
            achievement: achievement, judgments: judgments ?? (kind == "detail" ? detailCounts() : normalCounts()),
            fingerprint: fingerprint, kind: kind
        )
        let screenshotDates: [ScreenshotDateEvidence]
        if let date {
            screenshotDates = [.init(imageKind: kind == "detail" ? .detail : .normal,
                                     candidates: [.init(capturedAt: date, source: .filename, timeZone: "UTC", timeZoneAssumed: false)])]
        } else {
            screenshotDates = []
        }
        return PendingImport(name: "transient-(sha).png", result: draft, fingerprints: [fingerprint],
                             evidence: evidence(for: draft, sourcePrefix: sha), screenshotDates: screenshotDates)
    }

    private func seed(_ fixture: Fixture, _ items: [PendingImport]) {
        fixture.model.pending = items
        fixture.model.processed = items.count
        fixture.model.importCount = items.count
        fixture.model.lastBatchPlayIDs = []
        fixture.model.importReceipts = []
    }

    func testBatchAutomaticallySavesClearResultAndLeavesAmbiguousResultPending() {
        let f = fixture()
        var ambiguous = pending("ambiguous-sha")
        if var draft = ambiguous.result {
            draft.score = 900_001
            ambiguous.result = draft
        }
        let scoreRead = ambiguous.evidence.first { $0.fieldKey == "score" }!
        ambiguous.evidence.removeAll { $0.fieldKey == "score" }
        ambiguous.evidence.append(.init(sourceID: scoreRead.sourceID, fieldKey: "score", route: "region",
                                        observations: [[OCRToken(text: "900000", confidence: 1), OCRToken(text: "900001", confidence: 0.96)]]))
        let clear = pending("clear-sha")
        seed(f, [clear, ambiguous])

        f.model.finalizeImportBatch()

        XCTAssertEqual(f.model.state.plays.count, 1)
        XCTAssertTrue(f.model.pending.contains { $0.id == ambiguous.id })
        XCTAssertTrue(f.model.pending.contains { $0.id == ambiguous.id && $0.assessment?.issues.contains { $0.field == .score } == true })
        XCTAssertEqual(f.model.automaticCount, 1)
        XCTAssertEqual(f.model.importReceipts.first?.status, .automatic)
        XCTAssertEqual(f.model.state.plays.first?.registrationMethod, .automatic)
        XCTAssertEqual(f.model.lastBatchPlayIDs, f.model.state.plays.map(\.id))
    }

    func testSameResultWithDifferentImageHashesLeavesSecondAsDuplicateCandidate() {
        let f = fixture()
        let first = pending("first-sha")
        let second = pending("second-sha")
        seed(f, [first, second])

        f.model.finalizeImportBatch()

        XCTAssertEqual(f.model.state.plays.count, 1)
        XCTAssertEqual(f.model.automaticCount, 1)
        XCTAssertEqual(f.model.pending.map(\.id), [second.id])
        XCTAssertFalse(f.model.pending[0].assessment?.duplicateIDs.isEmpty ?? true)
    }

    func testReimportWithSameSHAIsBlockedFromSaving() {
        let f = fixture()
        let first = pending("same-sha")
        seed(f, [first])
        f.model.finalizeImportBatch()
        let saved = try! XCTUnwrap(f.model.state.plays.first)

        let repeated = pending("same-sha")
        seed(f, [repeated])
        f.model.finalizeImportBatch()

        XCTAssertEqual(f.model.state.plays.count, 1)
        XCTAssertEqual(f.model.state.plays.first?.id, saved.id)
        XCTAssertEqual(f.model.pending.map(\.id), [repeated.id])
        XCTAssertEqual(f.model.pending.first?.assessment?.duplicateIDs, [saved.id])
        XCTAssertEqual(f.model.automaticCount, 0)
    }

    func testUnknownScreenshotDateIsSavedAsNil() {
        let f = fixture()
        seed(f, [pending("unknown-date-sha")])

        f.model.finalizeImportBatch()

        XCTAssertEqual(f.model.automaticCount, 1)
        XCTAssertNil(f.model.state.plays.first?.playedAt)
        XCTAssertEqual(f.model.state.plays.first?.orderDate, f.model.state.plays.first?.importedAt)
    }

    func testFailedRepositorySavePreservesStatePendingAndLastBatchIDs() {
        let f = fixture()
        let existing = PlayRecord(chartID: f.chart.id, gameID: gameID, titleAtPlay: "Song", difficultyAtPlay: "EXPERT",
                                  levelAtPlay: 30, score: 700_000, combo: 100, achievement: .fc,
                                  judgments: normalCounts(), presetID: "old", presetVersion: 1,
                                  fingerprints: [.init(sha256: "old-sha", layout: "normal")])
        var before = f.model.state
        before.plays = [existing]
        try! f.model.commit(before)
        let original = f.model.state
        let oldBatchIDs = [UUID()]
        f.model.lastBatchPlayIDs = oldBatchIDs
        let item = pending("save-fails-sha")
        seed(f, [item])
        f.model.lastBatchPlayIDs = oldBatchIDs
        f.repository.failSaves = true

        f.model.finalizeImportBatch()

        XCTAssertEqual(f.model.state, original)
        XCTAssertEqual(f.repository.stored, original)
        XCTAssertEqual(f.model.pending.map(\.id), [item.id])
        XCTAssertEqual(f.model.lastBatchPlayIDs, oldBatchIDs)
        XCTAssertEqual(f.model.automaticCount, 0)
        XCTAssertTrue(f.model.pending.first?.automationBlockReason?.contains("保存できませんでした") == true)
    }

    func testAutomaticSavePreservesExistingHistoryAndAddsOnlyNewPlay() {
        let f = fixture()
        let oldEnvironment = PlayEnvironment(name: "Historical", device: "Old tablet", audioOutput: "Wired", conditions: "Quiet",
                                             settings: .init(noteSpeed: 7, noteTiming: Decimal(string: "0.2"), chartPosition: 3, mirror: false))
        let oldPlay = PlayRecord(chartID: f.chart.id, gameID: gameID, titleAtPlay: "Song", difficultyAtPlay: "EXPERT",
                                 levelAtPlay: 30, score: 700_000, combo: 100, achievement: .fc,
                                 judgments: normalCounts(), importedAt: Date(timeIntervalSince1970: 100),
                                 presetID: "old", presetVersion: 1, environment: oldEnvironment,
                                 fingerprints: [.init(sha256: "old-history-sha", layout: "normal")])
        var state = f.model.state
        state.plays = [oldPlay]
        try! f.model.commit(state)
        seed(f, [pending("new-history-sha")])

        f.model.finalizeImportBatch()

        XCTAssertEqual(f.model.state.plays.count, 2)
        XCTAssertEqual(f.model.state.plays.first, oldPlay)
        XCTAssertEqual(f.model.state.plays.first?.environment, oldEnvironment)
        XCTAssertEqual(f.model.state.plays.last?.registrationMethod, .automatic)
    }

    func testNormalAndDetailedImagesWithinOneMinuteMergeIntoOneAutomaticPlay() {
        let f = fixture()
        let captureDate = Date().addingTimeInterval(-120)
        let normal = pending("normal-image-sha", kind: "normal", date: captureDate)
        let detail = pending("detail-image-sha", kind: "detail", date: captureDate.addingTimeInterval(35))
        seed(f, [normal, detail])

        f.model.finalizeImportBatch()

        XCTAssertEqual(f.model.state.plays.count, 1)
        let play = try! XCTUnwrap(f.model.state.plays.first)
        XCTAssertEqual(play.registrationMethod, .automatic)
        XCTAssertEqual(play.fingerprints.map(\.sha256), ["normal-image-sha", "detail-image-sha"])
        XCTAssertEqual(play.judgments[.perfect], .init(total: 80, fast: 40, slow: 40))
        XCTAssertEqual(play.judgments[.good], .init(total: 10, fast: 5, slow: 5))
        XCTAssertEqual(play.playedAt, captureDate)
        XCTAssertEqual(play.screenshotDates?.map(\.imageKind), [.normal, .detail])
        XCTAssertEqual(f.model.automaticCount, 1)
        XCTAssertTrue(f.model.pending.isEmpty)
    }

    func testEqualResultsFarApartInTimeRemainSeparatePlays() {
        let f = fixture()
        let earlier = Date().addingTimeInterval(-400)
        let later = earlier.addingTimeInterval(120)
        let first = pending("repeat-first-sha", date: earlier)
        let second = pending("repeat-second-sha", date: later)
        seed(f, [first, second])

        f.model.finalizeImportBatch()

        XCTAssertEqual(f.model.state.plays.count, 2)
        XCTAssertEqual(Set(f.model.state.plays.map(\.playedAt)), [earlier, later])
        XCTAssertEqual(f.model.automaticCount, 2)
        XCTAssertTrue(f.model.pending.isEmpty)
    }

    func testUnreadSettingDoesNotInventDefaultTiming() {
        let f = fixture(noteTiming: Decimal(string: "0.10"))
        let result = pending("setting-test-sha")
        let setting = PendingImport(name: "setting.png", result: nil, settings: .init(), fingerprints: [], error: nil)
        seed(f, [result, setting])

        f.model.finalizeImportBatch()

        XCTAssertEqual(f.model.automaticCount, 1)
        XCTAssertNil(f.model.state.plays.first?.environment)
        XCTAssertNil(f.model.state.plays.first?.environment?.settings.noteTiming)
        XCTAssertTrue(f.model.pending.contains { $0.id == setting.id })
    }

    func testApplyingBatchSettingsDoesNotChangeOlderPlaySnapshot() {
        let f = fixture()
        let oldEnvironment = PlayEnvironment(name: "Old", device: "Old device", audioOutput: "Wired", conditions: "Quiet",
                                             settings: .init(noteSpeed: 7, noteTiming: Decimal(string: "0.2"), chartPosition: 3, mirror: false))
        let oldPlay = PlayRecord(chartID: f.chart.id, gameID: gameID, titleAtPlay: "Song", difficultyAtPlay: "EXPERT",
                                 levelAtPlay: 30, score: 700_000, combo: 100, achievement: .fc,
                                 judgments: normalCounts(), presetID: "old", presetVersion: 1,
                                 environment: oldEnvironment, fingerprints: [.init(sha256: "old-settings-sha", layout: "normal")])
        var state = f.model.state
        state.plays = [oldPlay]
        try! f.model.commit(state)
        seed(f, [pending("new-settings-sha")])
        f.model.finalizeImportBatch()
        let newlyRegisteredID = try! XCTUnwrap(f.model.state.plays.last?.id)
        let newSettings = PlaySettings(noteSpeed: 9, noteTiming: Decimal(string: "0.1"), chartPosition: 2, mirror: true)

        f.model.applySettings(newSettings, toBatch: true)

        XCTAssertEqual(f.model.state.plays.first(where: { $0.id == oldPlay.id })?.environment, oldEnvironment)
        XCTAssertEqual(f.model.state.plays.first(where: { $0.id == newlyRegisteredID })?.environment?.settings, newSettings)
    }

    func testDisabledAutomaticRegistrationKeepsHighConfidenceResultPending() throws {
        let f = fixture()
        let item = pending("disabled-auto-sha")
        seed(f, [item])
        try f.model.setAutomaticRegistration(false)

        f.model.finalizeImportBatch()

        XCTAssertTrue(f.model.state.plays.isEmpty)
        XCTAssertEqual(f.model.pending.map(\.id), [item.id])
        XCTAssertTrue(f.model.pending.first?.assessment?.canAutomaticallyRegister == true)
        XCTAssertEqual(f.model.automaticCount, 0)
    }

    func testReviewedScoreConfirmsOnlyThatFieldAndSavesManually() throws {
        let f = fixture()
        var item = pending("reviewed-score-sha")
        let scoreRead = item.evidence.first { $0.fieldKey == "score" }!
        item.evidence.removeAll { $0.fieldKey == "score" }
        item.evidence.append(.init(sourceID: scoreRead.sourceID, fieldKey: "score", route: scoreRead.route,
                                   observations: [[OCRToken(text: "900000", confidence: 1), OCRToken(text: "900001", confidence: 0.96)]]))
        seed(f, [item])
        f.model.finalizeImportBatch()
        XCTAssertTrue(f.model.state.plays.isEmpty)
        XCTAssertTrue(f.model.pending.first?.assessment?.issues.contains { $0.field == .score } == true)

        try f.model.registerReviewed(item.id, values: [.score: "900000"], chartID: nil)

        XCTAssertTrue(f.model.pending.isEmpty)
        XCTAssertEqual(f.model.state.plays.count, 1)
        XCTAssertEqual(f.model.state.plays.first?.score, 900_000)
        XCTAssertEqual(f.model.state.plays.first?.judgments, normalCounts())
        XCTAssertEqual(f.model.state.plays.first?.registrationMethod, .manual)
        XCTAssertEqual(f.model.importReceipts.last?.status, .manual)
        XCTAssertEqual(f.model.automaticCount, 0)
    }

    func testContradictoryNormalAndDetailPairRemainsPending() {
        let f = fixture()
        let date = Date().addingTimeInterval(-120)
        let normal = pending("fc-normal-sha", kind: "normal", date: date)
        var detail = pending("ap-detail-sha", kind: "detail", date: date.addingTimeInterval(20))
        var apDraft = detail.result!
        apDraft.achievement = .ap
        apDraft.judgments = [.perfect: .init(fast: 50, slow: 50), .great: .init(fast: 0, slow: 0),
                             .good: .init(fast: 0, slow: 0), .bad: .init(fast: 0, slow: 0), .miss: .init(fast: 0, slow: 0)]
        detail.result = apDraft
        detail.evidence = evidence(for: apDraft, sourcePrefix: "ap-detail-sha")
        seed(f, [normal, detail])

        f.model.finalizeImportBatch()

        XCTAssertTrue(f.model.state.plays.isEmpty)
        XCTAssertEqual(Set(f.model.pending.map(\.id)), Set([normal.id, detail.id]))
        XCTAssertTrue(f.model.pending.allSatisfy { $0.automationBlockReason?.contains("矛盾") == true })
        XCTAssertEqual(f.model.automaticCount, 0)
    }

    func testMultiplePossibleNormalDetailPartnersPreventAutomaticMergeAndSave() {
        let f = fixture()
        let date = Date().addingTimeInterval(-120)
        let normal = pending("ambiguous-normal-sha", kind: "normal", date: date)
        let firstDetail = pending("ambiguous-detail-one-sha", kind: "detail", date: date.addingTimeInterval(10))
        let secondDetail = pending("ambiguous-detail-two-sha", kind: "detail", date: date.addingTimeInterval(20))
        seed(f, [normal, firstDetail, secondDetail])

        f.model.finalizeImportBatch()

        XCTAssertTrue(f.model.state.plays.isEmpty)
        XCTAssertEqual(Set(f.model.pending.map(\.id)), Set([normal.id, firstDetail.id, secondDetail.id]))
        XCTAssertTrue(f.model.pending.allSatisfy { $0.automationBlockReason?.contains("複数") == true })
        XCTAssertEqual(f.model.automaticCount, 0)
    }
}
