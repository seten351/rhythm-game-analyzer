import Foundation
import XCTest
@testable import OurNotesApp
@testable import ResultCore

@MainActor
final class ImportTests: XCTestCase {
    private func makeModel() -> AppModel {
        let model = AppModel(inMemory: true, loadBundledCatalog: false)
        XCTAssertNil(model.startupError)
        return model
    }

    private func draft(
        score: Int? = 900_000,
        combo: Int? = 500,
        achievement: Achievement = .unknown,
        judgments: [Judgment: JudgmentCount] = [:],
        title: String = "Song"
    ) -> ResultDraft {
        ResultDraft(
            gameID: "our-notes",
            presetID: "our-notes-v1",
            presetVersion: 1,
            title: title,
            difficulty: "MASTER",
            level: 30,
            score: score,
            combo: combo,
            achievement: achievement,
            judgments: judgments,
            fingerprint: .init(sha256: "draft-sha", layout: "result"),
            issues: [],
            kind: "normal"
        )
    }

    private func pending(_ result: ResultDraft, name: String, sha: String) -> PendingImport {
        PendingImport(
            name: name,
            result: result,
            settings: nil,
            image: nil,
            fingerprints: [.init(sha256: sha, layout: "result")],
            error: nil
        )
    }

    func testInvalidCorrectedDraftLeavesBothPendingImportsUntouched() async throws {
        let model = makeModel()
        let first = pending(draft(), name: "normal.png", sha: "normal-sha")
        let second = pending(draft(judgments: [.perfect: .init(fast: 200, slow: 300)]), name: "detail.png", sha: "detail-sha")
        model.pending = [first, second]
        let invalidCorrection = draft(score: nil)

        XCTAssertThrowsError(try model.mergePending(first.id, second.id, corrected: invalidCorrection))

        XCTAssertEqual(model.pending.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.pending[0].name, "normal.png")
        XCTAssertEqual(model.pending[0].result?.score, first.result?.score)
        XCTAssertEqual(model.pending[0].fingerprints, first.fingerprints)
        XCTAssertEqual(model.pending[1].name, "detail.png")
        XCTAssertEqual(model.pending[1].fingerprints, second.fingerprints)
    }

    func testValidCorrectionCanBeIntegratedAndPersistsMergedPendingResult() async throws {
        let model = makeModel()
        let first = pending(draft(score: 899_999, judgments: [.perfect: .init(total: 100)]), name: "normal.png", sha: "normal-sha")
        let second = pending(draft(judgments: [.perfect: .init(fast: 40, slow: 60)]), name: "detail.png", sha: "detail-sha")
        model.pending = [first, second]
        let correction = draft(score: 900_000, judgments: [.perfect: .init(total: 100)])

        try model.mergePending(first.id, second.id, corrected: correction)

        XCTAssertEqual(model.pending.count, 1)
        XCTAssertEqual(model.pending[0].id, first.id)
        XCTAssertEqual(model.pending[0].name, "normal.png ＋ detail.png")
        XCTAssertEqual(model.pending[0].result?.score, 900_000)
        XCTAssertEqual(model.pending[0].result?.judgments[.perfect], .init(total: 100, fast: 40, slow: 60))
        XCTAssertEqual(model.pending[0].fingerprints.map(\.sha256), ["normal-sha", "detail-sha"])
    }

    func testContradictoryCountsRejectMergeWithoutMutatingEitherPendingItem() async throws {
        let model = makeModel()
        let first = pending(draft(judgments: [.perfect: .init(total: 100)]), name: "normal.png", sha: "normal-sha")
        let second = pending(draft(judgments: [.perfect: .init(total: 99)]), name: "detail.png", sha: "detail-sha")
        model.pending = [first, second]

        XCTAssertThrowsError(try model.mergePending(first.id, second.id))

        XCTAssertEqual(model.pending.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.pending[0].result?.judgments[.perfect], .init(total: 100))
        XCTAssertEqual(model.pending[1].result?.judgments[.perfect], .init(total: 99))
        XCTAssertEqual(model.pending.map(\.fingerprints), [first.fingerprints, second.fingerprints])
    }

    func testPendingEditsMergeAndRegistrationAreRejectedWhileImporting() async throws {
        let model = makeModel()
        let first = pending(draft(), name: "normal.png", sha: "normal-sha")
        let second = pending(draft(), name: "detail.png", sha: "detail-sha")
        model.pending = [first, second]
        model.importing = true

        XCTAssertThrowsError(try model.updatePending(first.id, draft: draft(score: 900_001)))
        XCTAssertThrowsError(try model.mergePending(first.id, second.id))
        XCTAssertThrowsError(try model.register(first.id, draft: draft(), chartID: nil, mergeID: nil, playedAt: nil, timing: RegistrationTiming(environment: model.activeEnvironment)))

        XCTAssertEqual(model.pending.map(\.id), [first.id, second.id])
        XCTAssertTrue(model.state.plays.isEmpty)
    }

    func testEditorSelectionClearsTargetsWhenIdentityOrValuesChange() async throws {
        var selection = ImportEditorSelection(chartID: UUID(), mergeID: UUID())

        selection.valuesChanged()

        XCTAssertNotNil(selection.chartID)
        XCTAssertNil(selection.mergeID)

        selection.mergeID = UUID()
        selection.identityChanged()

        XCTAssertNil(selection.chartID)
        XCTAssertNil(selection.mergeID)
    }

    func testFailedSaveKeepsPendingImportAndStoredAppState() async throws {
        let model = makeModel()
        let existing = PlayRecord(
            chartID: UUID(),
            gameID: "our-notes",
            titleAtPlay: "Song",
            difficultyAtPlay: "MASTER",
            levelAtPlay: 30,
            score: 800_000,
            combo: 400,
            importedAt: Date(timeIntervalSince1970: 10),
            presetID: "old",
            presetVersion: 1,
            fingerprints: [.init(sha256: "already-saved-sha", layout: "result")]
        )
        var stored = AppState()
        stored.plays = [existing]
        try model.commit(stored)
        let item = pending(draft(), name: "duplicate.png", sha: "already-saved-sha")
        model.pending = [item]

        XCTAssertThrowsError(try model.register(item.id, draft: draft(), chartID: nil, mergeID: nil, playedAt: nil, timing: RegistrationTiming(environment: model.activeEnvironment)))

        XCTAssertEqual(model.state, stored)
        XCTAssertEqual(model.pending.count, 1)
        XCTAssertEqual(model.pending.first?.id, item.id)
        XCTAssertEqual(model.pending.first?.fingerprints, item.fingerprints)
    }

    func testBatchSummaryTracksPendingCountAfterRegisterMergeAndDiscard() async throws {
        let model = makeModel()
        model.processed = 4
        model.importCount = 4
        model.duplicateCount = 1
        let registered = pending(draft(), name: "registered.png", sha: "registered-sha")
        let first = pending(draft(judgments: [.perfect: .init(total: 100)]), name: "normal.png", sha: "normal-sha")
        let second = pending(draft(judgments: [.perfect: .init(fast: 40, slow: 60)]), name: "detail.png", sha: "detail-sha")
        model.pending = [registered, first, second]

        XCTAssertTrue(model.batchSummary.contains("3件が確認待ちです。"))
        try model.register(registered.id, draft: draft(), chartID: nil, mergeID: nil, playedAt: nil, timing: RegistrationTiming(environment: model.activeEnvironment))
        XCTAssertTrue(model.batchSummary.contains("2件が確認待ちです。"))

        try model.mergePending(first.id, second.id)
        XCTAssertTrue(model.batchSummary.contains("1件が確認待ちです。"))

        model.clearPending()
        XCTAssertTrue(model.batchSummary.contains("0件が確認待ちです。"))
    }

    func testGOODFCMergesRegistersAndRetainsCountsAndBothFingerprints() throws {
        let model = makeModel()
        let normal = draft(combo: 102, achievement: .fc, judgments: [.perfect: .init(total: 100), .great: .init(total: 0), .good: .init(total: 2), .bad: .init(total: 0), .miss: .init(total: 0)])
        let detail = draft(combo: 102, achievement: .fc, judgments: [.perfect: .init(fast: 60, slow: 40), .great: .init(fast: 0, slow: 0), .good: .init(fast: 2, slow: 0), .bad: .init(fast: 0, slow: 0), .miss: .init(fast: 0, slow: 0)])
        let first = pending(normal, name: "normal.png", sha: "normal-sha"), second = pending(detail, name: "detail.png", sha: "detail-sha")
        model.pending = [first, second]
        try model.mergePending(first.id, second.id)
        let merged = try XCTUnwrap(model.pending.first?.result)
        try model.register(first.id, draft: merged, chartID: nil, mergeID: nil, playedAt: nil, timing: RegistrationTiming(environment: model.activeEnvironment))
        XCTAssertEqual(model.state.plays.first?.achievement, .fc)
        XCTAssertEqual(model.state.plays.first?.judgments[.good], .init(total: 2, fast: 2, slow: 0))
        XCTAssertEqual(model.state.plays.first?.fingerprints.map(\.sha256), ["normal-sha", "detail-sha"])
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertEqual(model.state.schemaVersion, 1)
    }

    func testAssistCannotBecomeSupportedByMergingInEitherOrder() {
        let model = makeModel()
        let supported = pending(draft(), name: "normal.png", sha: "normal")
        var unsupported = pending(draft(), name: "assist.png", sha: "assist")
        unsupported.result?.kind = "unsupported-assist"
        for (first, second) in [(supported, unsupported), (unsupported, supported)] {
            model.pending = [first, second]
            let stored = model.state
            XCTAssertThrowsError(try model.mergePending(first.id, second.id))
            XCTAssertEqual(model.pending.map(\.id), [first.id, second.id])
            XCTAssertEqual(model.state, stored)
        }
    }

}
