import Foundation
import XCTest
@testable import OurNotesApp
@testable import ResultCore

@MainActor final class TimingTests: XCTestCase {
    private final class Repository: StateRepository {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("timing-test/results.store")
        var stored = AppState()
        var fail = false
        func load() throws -> AppState { stored }
        func save(_ state: AppState) throws {
            if fail { throw CoreError.invalid("注入した保存失敗") }
            stored = state
        }
    }
    private func fixture() throws -> (AppModel, Repository) {
        let repository = Repository()
        repository.stored.environments = [PlayEnvironment(name: "iPad", device: TimingEnvironmentPolicy.fixedDeviceName, audioOutput: "有線", conditions: "通常", settings: .init(noteSpeed: Decimal(string: "10.50"), noteTiming: Decimal(string: "0.10"), chartPosition: 0, mirror: false))]
        let model = AppModel(inMemory: true, loadBundledCatalog: false, repository: repository)
        XCTAssertNil(model.startupError)
        return (model, repository)
    }
    private func item(_ sha: String = UUID().uuidString) -> PendingImport {
        let fingerprint = SourceFingerprint(sha256: sha, layout: "normal")
        let draft = ResultDraft(gameID: "our-notes", presetID: "our-notes-results", presetVersion: 2, title: "Song", difficulty: "EXPERT", level: 25, score: 900_000, combo: 100, achievement: .fc, judgments: [.perfect: .init(total: 99), .great: .init(total: 0), .good: .init(total: 1), .bad: .init(total: 0), .miss: .init(total: 0)], fingerprint: fingerprint, kind: "normal")
        return PendingImport(name: "normal.png", result: draft, fingerprints: [fingerprint])
    }
    private func register(_ item: PendingImport, model: AppModel, timing: RegistrationTiming) throws {
        model.pending.append(item)
        try model.register(item.id, draft: try XCTUnwrap(item.result), chartID: nil, mergeID: nil, playedAt: nil, timing: timing)
    }

    func testUnchangedTimingNeedsNoSettingsImageAndSurvivesDiskReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("timing-persistence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalRepository(storageDirectory: directory)
        let model = AppModel(inMemory: true, loadBundledCatalog: false, repository: repository)
        let baseline = PlayEnvironment(device: TimingEnvironmentPolicy.fixedDeviceName, audioOutput: "有線", settings: .init(noteSpeed: 10, noteTiming: Decimal(string: "0.10"), chartPosition: 0, mirror: false))
        var state = model.state; state.environments = [baseline]; try model.commit(state); model.selectedEnvironmentID = baseline.id
        for _ in 0..<2 { try register(item(), model: model, timing: RegistrationTiming(environment: model.activeEnvironment)) }
        XCTAssertEqual(model.state.plays.map(\.environment), [baseline, baseline])
        XCTAssertEqual(model.activeEnvironment, baseline)
        let reopened = AppModel(inMemory: true, loadBundledCatalog: false, repository: try LocalRepository(storageDirectory: directory))
        XCTAssertEqual(reopened.state, model.state)
        XCTAssertEqual(reopened.activeEnvironment?.settings.noteTiming, Decimal(string: "0.10"))
        XCTAssertEqual(reopened.state.schemaVersion, 1)
    }

    func testChangedTimingUpdatesOnlyCurrentAndNewSnapshotAtomically() throws {
        let (model, repository) = try fixture()
        let baseline = try XCTUnwrap(model.activeEnvironment)
        try register(item(), model: model, timing: RegistrationTiming(environment: baseline))
        let oldPlay = try XCTUnwrap(model.state.plays.first)
        var changed = RegistrationTiming(environment: baseline); changed.choice = .changed; changed.input = "0.11"
        try register(item(), model: model, timing: changed)
        var expected = baseline; expected.settings.noteTiming = Decimal(string: "0.11")
        XCTAssertEqual(model.activeEnvironment, expected)
        XCTAssertEqual(model.state.plays.last?.environment, expected)
        XCTAssertEqual(model.state.plays.first, oldPlay)
        XCTAssertEqual(repository.stored, model.state)
        XCTAssertTrue(model.pending.isEmpty)
    }

    func testInitialConfirmationOffersCurrentValueButDoesNotPersistUntilSave() throws {
        let (model, _) = try fixture()
        model.state.environments[0].settings.noteTiming = nil
        let initial = RegistrationTiming(environment: model.activeEnvironment)
        XCTAssertEqual(initial.choice, .changed); XCTAssertEqual(initial.input, "0.10")
        XCTAssertNil(model.activeEnvironment?.settings.noteTiming)
        try register(item(), model: model, timing: initial)
        XCTAssertEqual(model.activeEnvironment?.settings.noteTiming, Decimal(string: "0.10"))
        XCTAssertEqual(model.state.plays.first?.environment?.settings.noteTiming, Decimal(string: "0.10"))
    }

    func testUnknownSnapshotDoesNotEraseFixedTimingOrInferFromHistory() throws {
        let (model, _) = try fixture()
        let baseline = model.activeEnvironment
        var unknown = RegistrationTiming(environment: baseline); unknown.choice = .unknown
        try register(item(), model: model, timing: unknown)
        XCTAssertNil(model.state.plays.first?.environment?.settings.noteTiming)
        XCTAssertEqual(model.state.plays.first?.environment?.settings.noteSpeed, baseline?.settings.noteSpeed)
        XCTAssertEqual(model.activeEnvironment, baseline)
        try register(item(), model: model, timing: RegistrationTiming(environment: baseline))
        XCTAssertEqual(model.state.plays.last?.environment, baseline)
    }

    func testNoEnvironmentCanSaveUnknownButCannotChangeFixedValue() throws {
        let (model, _) = try fixture(); model.selectedEnvironmentID = nil
        let unknown = RegistrationTiming(environment: nil)
        try register(item(), model: model, timing: unknown)
        XCTAssertNil(model.state.plays.first?.environment)
        var changed = unknown; changed.choice = .changed; changed.input = "0.12"
        XCTAssertThrowsError(try changed.snapshot(current: nil, specification: model.timingSpecification))
    }

    func testMissingConfirmationCannotRegisterClearGOODFC() throws {
        let (model, repository) = try fixture(); let pending = item(); model.pending = [pending]
        let state = model.state
        XCTAssertThrowsError(try model.register(pending.id, draft: try XCTUnwrap(pending.result), chartID: nil, mergeID: nil, playedAt: nil))
        XCTAssertEqual(model.state, state); XCTAssertEqual(repository.stored, state)
        XCTAssertEqual(model.pending.map(\.id), [pending.id])
    }

    func testStaleFixedValueOrEnvironmentSelectionRequiresReconfirmation() throws {
        let (model, _) = try fixture(); let pending = item(); model.pending = [pending]
        let baseline = try XCTUnwrap(model.activeEnvironment)
        let confirmation = RegistrationTiming(environment: baseline)
        try model.confirmFixedTiming(Decimal(string: "0.11")!, expected: baseline)
        let state = model.state
        XCTAssertThrowsError(try model.register(pending.id, draft: try XCTUnwrap(pending.result), chartID: nil, mergeID: nil, playedAt: nil, timing: confirmation))
        XCTAssertThrowsError(try model.confirmFixedTiming(Decimal(string: "0.12")!, expected: baseline))
        XCTAssertEqual(model.state, state); XCTAssertEqual(model.pending.map(\.id), [pending.id])
        model.selectedEnvironmentID = nil
        XCTAssertThrowsError(try confirmation.snapshot(current: model.activeEnvironment, specification: model.timingSpecification))
    }

    func testInvalidChangedTimingAndFailedPersistenceLeaveAllStatePendingAndBatchIDsUntouched() throws {
        let (model, repository) = try fixture(); let pending = item(); model.pending = [pending]
        let state = model.state
        var changed = RegistrationTiming(environment: model.activeEnvironment); changed.choice = .changed
        for input in ["", "text", "NaN", "3.01", "-3.01", "0.105"] {
            changed.input = input
            XCTAssertThrowsError(try model.register(pending.id, draft: try XCTUnwrap(pending.result), chartID: nil, mergeID: nil, playedAt: nil, timing: changed))
            XCTAssertEqual(model.state, state); XCTAssertEqual(repository.stored, state)
            XCTAssertEqual(model.pending.map(\.id), [pending.id]); XCTAssertTrue(model.lastBatchPlayIDs.isEmpty)
        }
        changed.input = "0.11"; repository.fail = true
        XCTAssertThrowsError(try model.register(pending.id, draft: try XCTUnwrap(pending.result), chartID: nil, mergeID: nil, playedAt: nil, timing: changed))
        XCTAssertEqual(model.state, state); XCTAssertEqual(repository.stored, state)
        XCTAssertEqual(model.pending.map(\.id), [pending.id]); XCTAssertTrue(model.lastBatchPlayIDs.isEmpty)
        XCTAssertThrowsError(try model.confirmFixedTiming(Decimal(string: "0.11")!, expected: try XCTUnwrap(model.activeEnvironment)))
        XCTAssertEqual(model.state, state); XCTAssertEqual(repository.stored, state)
    }

    func testExistingPlayMergeRetainsHistoricalTimingAndDoesNotChangeFixedValue() throws {
        let (model, _) = try fixture(); let baseline = try XCTUnwrap(model.activeEnvironment)
        try register(item(), model: model, timing: RegistrationTiming(environment: baseline))
        let oldPlay = try XCTUnwrap(model.state.plays.first)
        try model.confirmFixedTiming(Decimal(string: "0.11")!, expected: baseline)
        let incoming = item(); model.pending = [incoming]
        var changed = RegistrationTiming(environment: model.activeEnvironment); changed.choice = .changed; changed.input = "0.12"
        try model.register(incoming.id, draft: try XCTUnwrap(incoming.result), chartID: nil, mergeID: oldPlay.id, playedAt: nil, timing: changed)
        XCTAssertEqual(model.state.plays.count, 1)
        XCTAssertEqual(model.state.plays.first?.environment, oldPlay.environment)
        XCTAssertEqual(model.state.plays.first?.fingerprints.count, 2)
        XCTAssertEqual(model.activeEnvironment?.settings.noteTiming, Decimal(string: "0.11"))
        // An unknown historical environment also stays unknown on additional-image merge.
        model.state.plays[0].environment = nil
        let third = item(); model.pending = [third]
        try model.register(third.id, draft: try XCTUnwrap(third.result), chartID: nil, mergeID: oldPlay.id, playedAt: nil)
        XCTAssertNil(model.state.plays.first?.environment)
    }

    func testFixedTimingEditorPreservesSnapshotsAndOtherSettings() throws {
        let (model, _) = try fixture(); let baseline = try XCTUnwrap(model.activeEnvironment)
        try register(item(), model: model, timing: RegistrationTiming(environment: baseline))
        let plays = model.state.plays
        try model.confirmFixedTiming(Decimal(string: "0.09")!, expected: baseline)
        var expected = baseline; expected.settings.noteTiming = Decimal(string: "0.09")
        XCTAssertEqual(model.activeEnvironment, expected); XCTAssertEqual(model.state.plays, plays)
        let before = model.state
        var bypass = expected; bypass.settings.noteTiming = Decimal(string: "0.08")
        XCTAssertThrowsError(try model.saveEnvironment(bypass, expected: expected))
        XCTAssertThrowsError(try model.saveEnvironment(baseline, expected: baseline))
        XCTAssertEqual(model.state, before)
    }

    func testSettingImageValidationAndUnreadTimingPreserveFixedValue() throws {
        let (model, repository) = try fixture(); let baseline = model.activeEnvironment
        var invalid = try XCTUnwrap(baseline).settings; invalid.noteTiming = Decimal(string: "0.105")
        model.applySettings(invalid, toBatch: false)
        XCTAssertNotNil(model.errorMessage); XCTAssertEqual(model.activeEnvironment, baseline)
        XCTAssertEqual(repository.stored, model.state)
        model.errorMessage = nil
        var unread = try XCTUnwrap(baseline).settings; unread.noteTiming = nil; unread.noteSpeed = 11
        model.applySettings(unread, toBatch: false)
        XCTAssertNil(model.errorMessage); XCTAssertEqual(model.activeEnvironment?.settings.noteTiming, Decimal(string: "0.10"))
        XCTAssertEqual(model.activeEnvironment?.settings.noteSpeed, 11)
    }

    func testConfirmedBundledRulesAndLegacyImportedPresetFallback() throws {
        let (model, _) = try fixture()
        let specification = try XCTUnwrap(model.timingSpecification)
        XCTAssertEqual(model.preset?.version, 2)
        XCTAssertEqual(specification.unit, "ゲーム内単位")
        XCTAssertEqual(specification.step, Decimal(string: "0.01"))
        XCTAssertEqual(specification.minimum, -3); XCTAssertEqual(specification.maximum, 3)
        XCTAssertEqual(specification.slowCorrectionDirection, 1)
        model.preset?.version = 1; model.preset?.timing = nil
        XCTAssertEqual(model.timingSpecification, specification)
        let custom = TimingSpecification(unit: "ゲーム内単位", step: Decimal(string: "0.02")!, minimum: -2, maximum: 2, slowCorrectionDirection: -1)
        model.preset?.timing = custom
        XCTAssertEqual(model.timingSpecification, custom)
    }

    func testTimingInputRequiresRangeGridAndStrictNumericSyntax() throws {
        let (model, _) = try fixture(); let spec = model.timingSpecification
        for input in ["-3.00", "3.00", "0", "+0.10", " -0.01 "] { XCTAssertNoThrow(try RegistrationTiming.parse(input, specification: spec)) }
        for input in ["−3", "1e-2", "0,10", "0.105", "3.01", "-3.01", ".1", "NaN"] { XCTAssertThrowsError(try RegistrationTiming.parse(input, specification: spec)) }
    }

    func testLegacySettingImageCanUpdateCurrentAndExplicitlySelectedBatchOnly() throws {
        let (model, repository) = try fixture()
        let baseline = try XCTUnwrap(model.activeEnvironment)
        try register(item(), model: model, timing: RegistrationTiming(environment: baseline))
        let historical = try XCTUnwrap(model.state.plays.first)
        model.lastBatchPlayIDs = []
        try register(item(), model: model, timing: RegistrationTiming(environment: baseline))
        let batchID = try XCTUnwrap(model.lastBatchPlayIDs.first)
        let screenshot = PlaySettings(noteSpeed: 11, noteTiming: Decimal(string: "0.12"), chartPosition: Decimal(string: "0.01"), mirror: true)
        model.applySettings(screenshot, toBatch: true)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.activeEnvironment?.settings, screenshot)
        XCTAssertEqual(model.state.plays.first, historical)
        XCTAssertEqual(model.state.plays.first(where: { $0.id == batchID })?.environment?.settings, screenshot)
        XCTAssertEqual(repository.stored, model.state)
        var currentOnly = screenshot; currentOnly.noteTiming = Decimal(string: "0.13")
        let plays = model.state.plays
        model.applySettings(currentOnly, toBatch: false)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.activeEnvironment?.settings, currentOnly)
        XCTAssertEqual(model.state.plays, plays)
    }

    func testOlderImportedOCRPresetUsesConfirmedTimingWithoutRewritingPresetOrStoredHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("timing-legacy-preset-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalRepository(storageDirectory: directory)
        let model = AppModel(inMemory: true, loadBundledCatalog: false, repository: repository)
        var old = try XCTUnwrap(model.preset); old.version = 1; old.timing = nil
        var legacy = item(); legacy.result?.presetVersion = 1
        try register(legacy, model: model, timing: RegistrationTiming(environment: model.activeEnvironment))
        let data = try JSONEncoder().encode(old)
        let url = directory.appendingPathComponent("preset.json"); try data.write(to: url)
        let reopened = AppModel(loadBundledCatalog: false, repository: try LocalRepository(storageDirectory: directory))
        XCTAssertNil(reopened.startupError)
        XCTAssertEqual(reopened.preset, old)
        XCTAssertEqual(reopened.timingSpecification, model.timingSpecification)
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(reopened.state, model.state)
        XCTAssertEqual(reopened.state.plays.first?.presetVersion, 1)
    }

    func testFixedDeviceIsRecordedOnlyOnFutureSaveAndLegacyHistorySurvivesReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fixed-device-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(inMemory: true, loadBundledCatalog: false, repository: try LocalRepository(storageDirectory: directory))
        let legacy = PlayEnvironment(settings: .init(noteSpeed: 10, noteTiming: Decimal(string: "0.10"), chartPosition: 0, mirror: false))
        var state = model.state; state.environments = [legacy]
        let historical = PlayRecord(chartID: UUID(), gameID: "our-notes", titleAtPlay: "Past", difficultyAtPlay: "EXPERT", score: 1, achievement: .unknown, judgments: [:], presetID: "old", presetVersion: 1, environment: legacy, fingerprints: [])
        state.plays = [historical]; try model.commit(state)
        let reopened = AppModel(inMemory: true, loadBundledCatalog: false, repository: try LocalRepository(storageDirectory: directory))
        XCTAssertEqual(reopened.state, state) // No startup migration or inferred history write.
        XCTAssertEqual(reopened.timingEnvironmentPolicy, .ourNotesFixedDevice)
        var unknown = RegistrationTiming(environment: reopened.activeEnvironment); unknown.choice = .unknown
        try register(item(), model: reopened, timing: unknown)
        XCTAssertEqual(reopened.activeEnvironment?.device, TimingEnvironmentPolicy.fixedDeviceName)
        XCTAssertEqual(reopened.activeEnvironment?.settings.noteTiming, legacy.settings.noteTiming)
        XCTAssertEqual(reopened.state.plays.first, historical)
        XCTAssertEqual(reopened.state.plays.last?.environment?.device, TimingEnvironmentPolicy.fixedDeviceName)
        XCTAssertNil(reopened.state.plays.last?.environment?.settings.noteTiming)
        let final = AppModel(inMemory: true, loadBundledCatalog: false, repository: try LocalRepository(storageDirectory: directory))
        XCTAssertEqual(final.state, reopened.state); XCTAssertEqual(final.state.schemaVersion, 1)
    }

    func testEnvironmentAudioSaveKeepsLegacyHistoryAndOtherSettings() throws {
        let (model, repository) = try fixture()
        try register(item(), model: model, timing: RegistrationTiming(environment: model.activeEnvironment))
        let baseline = try XCTUnwrap(model.activeEnvironment), historical = model.state.plays
        var edited = baseline; edited.device = "自由入力"; edited.audioOutput = "イヤホン"; edited.conditions = ""
        try model.saveEnvironment(edited, expected: baseline)
        XCTAssertEqual(model.activeEnvironment?.device, TimingEnvironmentPolicy.fixedDeviceName)
        XCTAssertEqual(model.activeEnvironment?.audioOutput, "イヤホン")
        XCTAssertEqual(model.activeEnvironment?.settings, baseline.settings)
        XCTAssertEqual(model.state.plays, historical); XCTAssertEqual(repository.stored, model.state)
        let new = PlayEnvironment(audioOutput: "スピーカー")
        try model.saveEnvironment(new)
        XCTAssertEqual(model.activeEnvironment?.device, TimingEnvironmentPolicy.fixedDeviceName)
        XCTAssertNil(model.activeEnvironment?.settings.noteTiming)
    }

    func testFixedDevicePreviewPoolsBlankSpeakerAndEarphoneRecordsWithoutMutatingState() throws {
        let model = TimingVerification.previewModel(), before = model.state
        let analysis = TimingTrendService.analyze(gameID: model.gameID, environment: try XCTUnwrap(model.activeEnvironment), plays: model.state.plays, charts: model.state.charts, specification: model.timingSpecification, environmentPolicy: model.timingEnvironmentPolicy)
        XCTAssertEqual(analysis.overall.songCount, 8); XCTAssertEqual(analysis.overall.playCount, 22)
        XCTAssertEqual(analysis.overall.proposed, Decimal(string: "0.11"))
        XCTAssertEqual(analysis.levels.map(\.level), [25, 26, 28, nil])
        XCTAssertEqual(analysis.levels.first { $0.level == 28 }?.recommendation.status, .insufficientData)
        XCTAssertNil(analysis.levels.first { $0.level == nil }?.recommendation.proposed)
        let conflicting = TimingTrendService.analyze(gameID: model.gameID, environment: model.state.environments[1], plays: model.state.plays, charts: model.state.charts, specification: model.timingSpecification, environmentPolicy: model.timingEnvironmentPolicy)
        XCTAssertEqual(conflicting.overall.status, .mixedDirections); XCTAssertNil(conflicting.overall.proposed)
        XCTAssertEqual(conflicting.levels.map { $0.recommendation.proposed }, [Decimal(string: "0.09"), Decimal(string: "0.11")])
        XCTAssertEqual(model.state, before)
    }
}
