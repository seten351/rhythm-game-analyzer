import Foundation
import FoundationModels
import AppKit
import XCTest
@testable import OurNotesApp
@testable import ResultCore

@MainActor
final class OCRCorrectionTests: XCTestCase {
    private final class Provider: OCRCorrectionProviding {
        var availability: OCRCorrectionAvailability = .available
        var response: [OCRCorrectionSelection] = []
        var failure: Error?
        var callCount = 0
        var continuation: CheckedContinuation<[OCRCorrectionSelection], Error>?
        var shouldSuspend = false

        func select(from context: OCRCorrectionContext) async throws -> [OCRCorrectionSelection] {
            callCount += 1
            if shouldSuspend {
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            if let failure { throw failure }
            return response
        }

        func resume() {
            continuation?.resume(returning: response)
            continuation = nil
        }
    }

    private final class Repository: StateRepository {
        let storeURL = URL(fileURLWithPath: "/tmp/ocr-correction-test.store")
        var state = AppState()
        var failSaves = false
        func load() throws -> AppState { state }
        func save(_ state: AppState) throws {
            if failSaves { throw CoreError.invalid("injected save failure") }
            self.state = state
        }
    }

    private func draft(score: Int? = 900_000, combo: Int? = 500) -> ResultDraft {
        ResultDraft(gameID: "our-notes", presetID: "our-notes-v1", presetVersion: 1,
                    title: "Song", difficulty: "MASTER", level: 30, score: score, combo: combo,
                    achievement: .unknown, judgments: [:],
                    fingerprint: .init(sha256: "draft-sha", layout: "result"), kind: "normal")
    }

    private func evidence(_ field: OCRField, _ text: String) -> OCRReadEvidence {
        .init(sourceID: "source-1", fieldKey: field.evidenceKey, route: "primary",
              observations: [[OCRToken(text: text, confidence: 0.2,
                                       rect: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.1))]])
    }

    private func pending(_ result: ResultDraft, evidence: [OCRReadEvidence]) -> PendingImport {
        PendingImport(name: "screen.png", result: result, settings: nil, image: nil,
                      fingerprints: [result.fingerprint], error: nil, evidence: evidence)
    }

    private func makeModel(_ provider: Provider, timeout: Duration = .seconds(30)) -> AppModel {
        AppModel(inMemory: true, loadBundledCatalog: false, correctionProvider: provider, correctionTimeout: timeout)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath,
                           line: UInt = #line) async {
        for _ in 0..<2_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for async correction state", file: file, line: line)
    }

    func testGenerationOnlyAddsSuggestionsAndNeverChangesPendingOrAppState() async throws {
        let provider = Provider()
        let model = makeModel(provider)
        let result = draft()
        let item = pending(result, evidence: [evidence(.score, "900001")])
        model.pending = [item]
        let stateBefore = model.state
        provider.response = [OCRCorrectionSelection(fieldID: "score", candidateID: "c0_0")]

        model.requestCorrections(item.id, editorRevision: 4)
        await waitUntil { !model.correction.isRunning }

        XCTAssertEqual(model.state, stateBefore)
        XCTAssertEqual(model.pending.first?.result?.score, result.score)
        XCTAssertEqual(model.pending.first?.editedFields, Set<OCRField>())
        XCTAssertEqual(model.correction.suggestions.map(\.value), ["900001"])
        XCTAssertEqual(model.correction.editorRevision, 4)
    }

    func testUnavailableProviderFallsBackWithoutCallingProviderOrChangingResult() {
        let provider = Provider()
        provider.availability = .unavailable("Apple Intelligenceが無効です")
        let model = makeModel(provider)
        let result = draft()
        let item = pending(result, evidence: [evidence(.score, "900001")])
        model.pending = [item]

        model.requestCorrections(item.id, editorRevision: 0)

        XCTAssertEqual(provider.callCount, 0)
        XCTAssertFalse(model.correction.isRunning)
        XCTAssertTrue(model.correction.suggestions.isEmpty)
        XCTAssertTrue(model.correction.message.contains("無効"))
        XCTAssertEqual(model.pending.first?.result?.score, result.score)
    }

    func testEmptyAndInvalidProviderResponsesNeverCreateSuggestions() async {
        let provider = Provider()
        let model = makeModel(provider)
        let item = pending(draft(), evidence: [evidence(.score, "900001")])
        model.pending = [item]

        provider.response = []
        model.requestCorrections(item.id, editorRevision: 0)
        await waitUntil { !model.correction.isRunning }
        XCTAssertTrue(model.correction.suggestions.isEmpty)
        XCTAssertTrue(model.correction.message.contains("確かな候補"))

        provider.response = [OCRCorrectionSelection(fieldID: "score", candidateID: "invented")]
        model.requestCorrections(item.id, editorRevision: 1)
        await waitUntil { !model.correction.isRunning }
        XCTAssertTrue(model.correction.suggestions.isEmpty)
        XCTAssertTrue(model.correction.message.contains("手動で確認"))
    }

    func testEditingPendingInvalidatesDelayedResponse() async throws {
        let provider = Provider(); provider.shouldSuspend = true
        let model = makeModel(provider)
        let original = draft()
        let item = pending(original, evidence: [evidence(.score, "900001")])
        model.pending = [item]

        model.requestCorrections(item.id, editorRevision: 10)
        await waitUntil { provider.continuation != nil }
        var edited = original; edited.score = 900_002
        try model.updatePending(item.id, draft: edited)
        provider.response = [OCRCorrectionSelection(fieldID: "score", candidateID: "c0_0")]
        provider.resume()
        await waitUntil { !model.correction.isRunning }

        XCTAssertEqual(model.pending.first?.result?.score, 900_002)
        XCTAssertTrue(model.correction.suggestions.isEmpty)
        XCTAssertNil(model.correction.targetID)
    }

    func testDiscardInvalidatesDelayedResponse() async {
        let provider = Provider(); provider.shouldSuspend = true
        let model = makeModel(provider)
        let item = pending(draft(), evidence: [evidence(.score, "900001")])
        model.pending = [item]

        model.requestCorrections(item.id, editorRevision: 1)
        await waitUntil { provider.continuation != nil }
        model.discardPending(item.id)
        provider.response = [OCRCorrectionSelection(fieldID: "score", candidateID: "c0_0")]
        provider.resume()
        await waitUntil { !model.correction.isRunning }

        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertTrue(model.correction.suggestions.isEmpty)
        XCTAssertNil(model.correction.targetID)
    }

    func testMergeInvalidatesDelayedResponseForBothSourceItems() async throws {
        let provider = Provider(); provider.shouldSuspend = true
        let model = makeModel(provider)
        let first = pending(draft(), evidence: [evidence(.score, "900001")])
        var second = pending(draft(), evidence: [evidence(.score, "900001")])
        second.name = "detail.png"
        second.fingerprints = [.init(sha256: "detail-sha", layout: "result")]
        model.pending = [first, second]

        model.requestCorrections(first.id, editorRevision: 1)
        await waitUntil { provider.continuation != nil }
        try model.mergePending(first.id, second.id)
        provider.response = [OCRCorrectionSelection(fieldID: "score", candidateID: "c0_0")]
        provider.resume()
        await waitUntil { !model.correction.isRunning }

        XCTAssertEqual(model.pending.count, 1)
        XCTAssertEqual(model.pending.first?.name, "screen.png ＋ detail.png")
        XCTAssertTrue(model.correction.suggestions.isEmpty)
        XCTAssertNil(model.correction.targetID)
    }

    func testSuccessfulManualRegistrationInvalidatesDelayedResponse() async throws {
        let provider = Provider(); provider.shouldSuspend = true
        let model = makeModel(provider)
        let result = draft()
        let item = pending(result, evidence: [evidence(.score, "900001")])
        model.pending = [item]

        model.requestCorrections(item.id, editorRevision: 1)
        await waitUntil { provider.continuation != nil }
        try model.register(item.id, draft: result, chartID: nil, mergeID: nil, playedAt: nil, timing: RegistrationTiming(environment: model.activeEnvironment))
        let registeredState = model.state
        provider.response = [OCRCorrectionSelection(fieldID: "score", candidateID: "c0_0")]
        provider.resume()
        await waitUntil { !model.correction.isRunning }

        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertEqual(model.state, registeredState)
        XCTAssertEqual(model.state.plays.count, 1)
        XCTAssertTrue(model.correction.suggestions.isEmpty)
    }

    func testDeadlineClearsSuggestionsAndPreventsOverlappingGeneration() async {
        let provider = Provider(); provider.shouldSuspend = true
        let model = makeModel(provider, timeout: .milliseconds(25))
        let item = pending(draft(), evidence: [evidence(.score, "900001")])
        model.pending = [item]

        model.requestCorrections(item.id, editorRevision: 1)
        await waitUntil { provider.continuation != nil }
        await waitUntil { model.correction.message.contains("時間切れ") }
        XCTAssertTrue(model.correction.suggestions.isEmpty)
        XCTAssertTrue(model.correction.isRunning, "The provider has not returned; its slot must stay occupied")

        model.requestCorrections(item.id, editorRevision: 2)
        XCTAssertEqual(provider.callCount, 1)

        provider.resume()
        await waitUntil { !model.correction.isRunning }
        XCTAssertTrue(model.correction.suggestions.isEmpty)
        XCTAssertEqual(provider.callCount, 1)
    }

    func testSaveFailureKeepsSuggestionsPendingImportAndAppState() async throws {
        let provider = Provider()
        let repository = Repository()
        let originalSong = Song(gameID: "our-notes", masterTitle: "Stored Song")
        repository.state.songs = [originalSong]
        let model = AppModel(inMemory: true, loadBundledCatalog: false, correctionProvider: provider, repository: repository)
        let item = pending(draft(), evidence: [evidence(.score, "900001")])
        model.pending = [item]
        provider.response = [OCRCorrectionSelection(fieldID: "score", candidateID: "c0_0")]
        model.requestCorrections(item.id, editorRevision: 0)
        await waitUntil { !model.correction.isRunning }
        let stateBefore = model.state
        let suggestionsBefore = model.correction.suggestions

        repository.failSaves = true
        var changed = stateBefore
        changed.songs[0].userTitle = "Edited Song"
        XCTAssertThrowsError(try model.commit(changed))
        XCTAssertThrowsError(try model.register(item.id, draft: draft(), chartID: nil, mergeID: nil, playedAt: nil, timing: RegistrationTiming(environment: model.activeEnvironment)))

        XCTAssertEqual(model.state, stateBefore)
        XCTAssertEqual(model.pending.first?.id, item.id)
        XCTAssertEqual(model.pending.first?.result?.score, 900_000)
        XCTAssertEqual(model.correction.suggestions, suggestionsBefore)
        XCTAssertEqual(repository.state, stateBefore)
    }

    func testVersionOneDiskRoundTripPreservesMasterOverridesSnapshotsAndEnvironmentWithoutEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-correction-v1-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalRepository(inMemory: false, storageDirectory: directory)

        let songID = UUID(), chartID = UUID(), playID = UUID(), environmentID = UUID()
        let song = Song(id: songID, gameID: "our-notes", masterTitle: "Master title",
                        masterAliases: ["Master alias"], userTitle: "User title", userAliases: ["User alias"])
        let chart = Chart(id: chartID, songID: songID, masterDifficulty: "MASTER", masterLevel: 30,
                          userDifficulty: "EXPERT", userLevel: 28)
        let environment = PlayEnvironment(id: environmentID, name: "Desk", device: "Headphones",
                                          audioOutput: "Wired", conditions: "Quiet",
                                          settings: .init(noteSpeed: 10, noteTiming: -1, chartPosition: 2, mirror: false))
        let fingerprint = SourceFingerprint(sha256: "persisted-image-sha", perceptualHash: 42, layout: "result")
        let play = PlayRecord(id: playID, chartID: chartID, gameID: "our-notes",
                              titleAtPlay: "Historical title", difficultyAtPlay: "SPECIAL", levelAtPlay: 29,
                              score: 987_654, combo: 321, achievement: .fc,
                              judgments: [.perfect: .init(total: 100, fast: 40, slow: 60)],
                              importedAt: Date(timeIntervalSince1970: 1_700_000_000),
                              playedAt: Date(timeIntervalSince1970: 1_700_000_100),
                              presetID: "preset-v1", presetVersion: 1, environment: environment,
                              fingerprints: [fingerprint], confirmed: true)
        var state = AppState()
        state.songs = [song]; state.charts = [chart]; state.plays = [play]; state.environments = [environment]

        try repository.save(state)
        let reopened = try LocalRepository(inMemory: false, storageDirectory: directory)
        let reloaded = try reopened.load()
        XCTAssertEqual(reloaded.schemaVersion, 1)
        XCTAssertEqual(reloaded.songs, [song])
        XCTAssertEqual(reloaded.charts, [chart])
        XCTAssertEqual(reloaded.plays, [play])
        XCTAssertEqual(reloaded.environments, [environment])
        XCTAssertEqual(reloaded.plays.first?.id, playID)
        XCTAssertEqual(reloaded.charts.first?.id, chartID)
        XCTAssertEqual(reloaded.songs.first?.id, songID)

        let provider = Provider()
        let model = AppModel(inMemory: true, loadBundledCatalog: false, correctionProvider: provider, repository: Repository())
        let transient = pending(draft(), evidence: [.init(sourceID: "source-secret", fieldKey: "score", route: "private-route",
                                                          observations: [[OCRToken(text: "PRIVATE-OCR-EVIDENCE-SHOULD-NOT-PERSIST")]])])
        model.pending = [transient]
        let encodedState = try JSONEncoder().encode(model.state)
        let encodedText = String(decoding: encodedState, as: UTF8.self)
        XCTAssertFalse(encodedText.contains("PRIVATE-OCR-EVIDENCE-SHOULD-NOT-PERSIST"))
        XCTAssertFalse(encodedText.contains("private-route"))
    }

    func testClearPendingInvalidatesDelayedResponseAndReleasesEvidenceAndImages() async {
        let provider = Provider(); provider.shouldSuspend = true
        let model = makeModel(provider)
        var item = pending(draft(), evidence: [evidence(.score, "900001")])
        item.image = NSImage(size: NSSize(width: 4, height: 4))
        item.sourcePreviews = ["source-1": NSImage(size: NSSize(width: 2, height: 2))]
        model.pending = [item]
        model.requestCorrections(item.id, editorRevision: 1)
        await waitUntil { provider.continuation != nil }

        model.clearPending()
        provider.response = [OCRCorrectionSelection(fieldID: "score", candidateID: "c0_0")]
        provider.resume()
        await waitUntil { !model.correction.isRunning }

        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertTrue(model.correction.suggestions.isEmpty)
        XCTAssertNil(model.correction.targetID)
    }

    func testFinishSessionInvalidatesDelayedResponseAndReleasesEvidenceAndImages() async {
        let provider = Provider(); provider.shouldSuspend = true
        let model = makeModel(provider)
        var item = pending(draft(), evidence: [evidence(.score, "900001")])
        item.image = NSImage(size: NSSize(width: 4, height: 4))
        item.sourcePreviews = ["source-1": NSImage(size: NSSize(width: 2, height: 2))]
        model.pending = [item]
        model.requestCorrections(item.id, editorRevision: 1)
        await waitUntil { provider.continuation != nil }

        model.finishSession()
        provider.response = [OCRCorrectionSelection(fieldID: "score", candidateID: "c0_0")]
        provider.resume()
        await waitUntil { !model.correction.isRunning }

        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertTrue(model.correction.suggestions.isEmpty)
        XCTAssertNil(model.correction.targetID)
    }

    func testCorrectionEditorTracksCandidateAdoptionAndInvalidatesChartSelection() throws {
        var editor = ImportCorrectionEditor()
        var selection = ImportEditorSelection(chartID: UUID(), mergeID: UUID())
        let correctionContext = OCRCorrectionService.context(
            draft: draft(), evidence: [evidence(.score, "900001"), evidence(.title, "Song Updated")],
            knownTitles: [], confidenceThreshold: 0.8)
        let scoreCandidate = try XCTUnwrap(correctionContext.fields.first { $0.field == .score }?.candidates.first)
        let titleCandidate = try XCTUnwrap(correctionContext.fields.first { $0.field == .title }?.candidates.first)

        editor.adopting(scoreCandidate, selection: &selection)
        XCTAssertEqual(editor.revision, 1)
        XCTAssertEqual(editor.editedFields, [.score])
        XCTAssertNil(selection.mergeID)
        XCTAssertNotNil(selection.chartID)

        selection.mergeID = UUID()
        editor.adopting(titleCandidate, selection: &selection)
        XCTAssertEqual(editor.revision, 2)
        XCTAssertEqual(editor.editedFields, [.score, .title])
        XCTAssertNil(selection.chartID)
        XCTAssertNil(selection.mergeID)
    }

    func testCandidateConsumptionIsFieldByFieldWithoutSavingAndRejectsStaleRevision() async throws {
        let provider = Provider()
        let model = makeModel(provider)
        let item = pending(draft(), evidence: [evidence(.score, "900001"), evidence(.combo, "501")])
        model.pending = [item]
        let context = model.correctionContext(item.id)
        let score = try XCTUnwrap(context.fields.first { $0.field == .score }?.candidates.first)
        let combo = try XCTUnwrap(context.fields.first { $0.field == .combo }?.candidates.first)
        provider.response = [.init(fieldID: score.field.rawValue, candidateID: score.id), .init(fieldID: combo.field.rawValue, candidateID: combo.id)]
        model.requestCorrections(item.id, editorRevision: 3)
        await waitUntil { !model.correction.isRunning }
        let stateBefore = model.state

        XCTAssertTrue(model.correction.consume(score, itemID: item.id, revision: 3))
        XCTAssertEqual(model.correction.suggestions, [combo])
        XCTAssertFalse(model.correction.consume(combo, itemID: item.id, revision: 3))
        XCTAssertTrue(model.correction.consume(combo, itemID: item.id, revision: 4))
        XCTAssertEqual(model.state, stateBefore)
        XCTAssertEqual(model.pending.first?.result?.score, 900_000)
        XCTAssertTrue(model.correction.suggestions.isEmpty)
    }

    func testStructuredIDsAllowOmissionAndNullWithoutCreatingValues() throws {
        let context = OCRCorrectionService.context(draft: draft(), evidence: [evidence(.score, "900001"), evidence(.combo, "501")], knownTitles: [], confidenceThreshold: 0.8)
        let score = try XCTUnwrap(context.fields.first { $0.field == .score }?.candidates.first)
        let content = try GeneratedContent(json: "{\"score\":\"\(score.id)\",\"combo\":null}")
        let selections = try FoundationOCRCorrectionProvider.selections(from: content, fields: context.fields)
        XCTAssertEqual(try OCRCorrectionService.validate(selections, in: context), [score])
        XCTAssertEqual(try FoundationOCRCorrectionProvider.selections(from: GeneratedContent(json: "{}"), fields: context.fields), [])
    }

    func testStructuredResponseRejectsUnknownFieldsValuesAndCrossFieldIDsAsWhole() throws {
        let context = OCRCorrectionService.context(draft: draft(), evidence: [evidence(.score, "900001"), evidence(.combo, "501")], knownTitles: [], confidenceThreshold: 0.8)
        let score = try XCTUnwrap(context.fields.first { $0.field == .score }?.candidates.first)
        let combo = try XCTUnwrap(context.fields.first { $0.field == .combo }?.candidates.first)
        for json in ["{\"score\":\"\(score.id)\",\"unknown\":\"\(score.id)\"}", "{\"score\":900001}", "{\"score\":\"900001\"}", "{\"score\":\"\(combo.id)\"}", "[]"] {
            XCTAssertThrowsError(try FoundationOCRCorrectionProvider.selections(from: GeneratedContent(json: json), fields: context.fields))
        }
    }

    func testGenerationFailureFallsBackWithoutChangingValuesOrState() async {
        let provider = Provider(); provider.failure = NSError(domain: "synthetic-model-failure", code: 1)
        let model = makeModel(provider)
        let item = pending(draft(), evidence: [evidence(.score, "900001")]); model.pending = [item]
        let state = model.state
        model.requestCorrections(item.id, editorRevision: 0)
        await waitUntil { !model.correction.isRunning }
        XCTAssertEqual(OCRField.allCases.map { $0.value(in: model.pending[0].result!) }, OCRField.allCases.map { $0.value(in: item.result!) })
        XCTAssertEqual(model.state, state)
        XCTAssertTrue(model.correction.suggestions.isEmpty)
        XCTAssertFalse(model.correction.succeeded)
        XCTAssertTrue(model.correction.message.contains("手動で確認"))
        XCTAssertFalse(model.correction.message.contains("synthetic-model-failure"))
    }


    func testMergePreservesExplicitEditedFieldsEvenWhenValueMatchesOriginalOCR() throws {
        let provider = Provider(), model = makeModel(provider)
        let first = pending(draft(), evidence: [evidence(.score, "900001")])
        var second = pending(draft(), evidence: [evidence(.score, "900002")])
        second.fingerprints = [.init(sha256: "detail-sha", layout: "detail")]
        model.pending = [first, second]
        try model.mergePending(first.id, second.id, corrected: first.result, editedFields: [.score])
        XCTAssertTrue(model.pending[0].editedFields.contains(.score))
        XCTAssertFalse(model.correctionContext(first.id).fields.contains { $0.field == .score })
        XCTAssertEqual(model.pending[0].evidence.count, 2)
    }


    func testSixNineRequestsNeverContainOtherJudgmentCountsOrTotals() throws {
        let competing = OCRReadEvidence(sourceID: "source-1", fieldKey: "GREAT.total", route: "region", observations: [[OCRToken(text: "6", confidence: 0.99), OCRToken(text: "9", confidence: 0.95)]])
        let second = OCRReadEvidence(sourceID: "source-1", fieldKey: "MISS.total", route: "region", observations: [[OCRToken(text: "16", confidence: 0.99), OCRToken(text: "19", confidence: 0.95)]])
        let context = OCRCorrectionService.context(draft: draft(), evidence: [competing, second, evidence(.perfectTotal, "100"), evidence(.score, "900001")], knownTitles: [], confidenceThreshold: 0.8)
        let requests = FoundationOCRCorrectionProvider.isolatedRequests(from: context)
        XCTAssertEqual(requests.count, 3)
        for request in requests where request.fields.contains(where: \.isSixNineAmbiguous) {
            XCTAssertEqual(request.fields.count, 1)
            XCTAssertTrue(request.fields[0].candidates.allSatisfy { $0.field == request.fields[0].field })
        }
        XCTAssertFalse(requests[0].fields.contains(where: \.isSixNineAmbiguous))
    }

    func testSixNineSelectionRemainsManualAndEmptySelectionPreservesBothValues() async throws {
        let provider = Provider(), model = makeModel(provider)
        let competing = OCRReadEvidence(sourceID: "source-1", fieldKey: "GREAT.total", route: "region", observations: [[OCRToken(text: "6", confidence: 0.99), OCRToken(text: "9", confidence: 0.95)]])
        var result = draft(combo: nil); result.judgments = [.great: .init(total: 6, fast: 3, slow: 3)]
        let item = pending(result, evidence: [competing]); model.pending = [item]
        let context = model.correctionContext(item.id)
        let nine = try XCTUnwrap(context.fields.first?.candidates.first { $0.value == "9" })
        let before = model.state
        provider.response = []
        model.requestCorrections(item.id, editorRevision: 0)
        await waitUntil { !model.correction.isRunning }
        XCTAssertTrue(model.correction.message.contains("手動で確認"))
        XCTAssertEqual(model.pending[0].result?.judgments[.great]?.total, 6)
        XCTAssertEqual(Set(model.correctionContext(item.id).fields[0].candidates.map(\.value)), ["6", "9"])
        provider.response = [.init(fieldID: nine.field.rawValue, candidateID: nine.id)]
        model.requestCorrections(item.id, editorRevision: 1)
        await waitUntil { !model.correction.isRunning }
        XCTAssertEqual(model.correction.suggestions, [nine])
        XCTAssertEqual(model.pending[0].result?.judgments[.great]?.total, 6)
        XCTAssertEqual(model.state, before)
        XCTAssertTrue(model.correction.consume(nine, itemID: item.id, revision: 1))
        XCTAssertEqual(model.state, before)
        XCTAssertEqual(model.pending[0].result?.judgments[.great]?.total, 6)
    }

}
