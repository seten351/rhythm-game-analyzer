import Foundation
import XCTest
@testable import OurNotesApp
@testable import ResultCore

@MainActor final class AnalysisExportIntegrationTests: XCTestCase {
    private final class Repository: StateRepository {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("export-test/results.store")
        var stored = AppState()
        var saves = 0
        func load() throws -> AppState { stored }
        func save(_ state: AppState) throws { stored = state; saves += 1 }
    }
    private func fixture() -> (AppModel, Repository) {
        let repository = Repository()
        let song = Song(gameID: "our-notes", masterTitle: "Song")
        let chart = Chart(songID: song.id, masterDifficulty: "EXPERT", masterLevel: 26)
        repository.stored.songs = [song]; repository.stored.charts = [chart]
        let model = AppModel(inMemory: true, loadBundledCatalog: false, repository: repository)
        return (model, repository)
    }
    private func evidence(_ kind: ScreenshotImageKind = .normal, date: Date = Date(timeIntervalSince1970: 100)) -> ScreenshotDateEvidence {
        .init(imageKind: kind, candidates: [.init(capturedAt: date, source: .filename, timeZone: "Asia/Tokyo", timeZoneAssumed: true)])
    }
    private func pending(_ sha: String, dates: [ScreenshotDateEvidence]) -> PendingImport {
        let fp = SourceFingerprint(sha256: sha, layout: "normal")
        let draft = ResultDraft(gameID: "our-notes", presetID: "preset", presetVersion: 1, title: "Song", difficulty: "EXPERT", level: 26, score: 900000, combo: 100, achievement: .fc, judgments: [.perfect: .init(total: 100), .great: .init(total: 0), .good: .init(total: 0), .bad: .init(total: 0), .miss: .init(total: 0)], fingerprint: fp, kind: "normal")
        return PendingImport(name: "FORBIDDEN_FILENAME.png", result: draft, fingerprints: [fp], screenshotDates: dates)
    }
    func testDateSelectionUsesEarliestMergedSourceAndRetainsManualChangesOnReload() {
        let normal = evidence(date: Date(timeIntervalSince1970: 100)), detail = evidence(.detail, date: Date(timeIntervalSince1970: 102))
        var selection = ImportDateSelection(); selection.updateEvidence([detail, normal])
        XCTAssertEqual(selection.playedAt, normal.candidates[0].capturedAt)
        XCTAssertEqual(selection.context.playedAtSource, .screenshot)
        XCTAssertEqual(selection.context.selectedScreenshotDate?.screenshotID, normal.id)
        selection.setDate(Date(timeIntervalSince1970: 50)); selection.updateEvidence([detail, normal])
        XCTAssertEqual(selection.playedAt, Date(timeIntervalSince1970: 50))
        XCTAssertEqual(selection.context.playedAtSource, .manual)
        selection.setUseDate(false); selection.updateEvidence([normal, detail])
        XCTAssertNil(selection.playedAt); XCTAssertNil(selection.context.playedAtSource)
    }
    func testMetadataConflictRequiresExplicitSelectionAndUnknownDatesStayUnknown() {
        var conflict = evidence(); conflict.candidates.append(.init(capturedAt: Date(timeIntervalSince1970: 101), source: .metadata, metadataField: "XMP.xmp.CreateDate", timeZone: "UTC", timeZoneAssumed: false))
        var selection = ImportDateSelection(); selection.updateEvidence([conflict])
        XCTAssertNil(selection.playedAt); XCTAssertNil(selection.context.selectedScreenshotDate)
        selection.select(selection.choices.last!.id)
        XCTAssertEqual(selection.playedAt, Date(timeIntervalSince1970: 101))
        var unknown = ImportDateSelection(); unknown.updateEvidence([.init(imageKind: .normal)])
        XCTAssertNil(unknown.playedAt); XCTAssertNil(unknown.context.selectedScreenshotDate)
    }
    func testPendingAndSavedMergeKeepBothImageDatesWithoutReplacingHistoricalDate() throws {
        let (model, _) = fixture(); let normal = evidence(), detail = evidence(.detail, date: Date(timeIntervalSince1970: 102))
        let first = pending("one", dates: [normal]), second = pending("two", dates: [detail])
        model.pending = [first, second]
        try model.mergePending(first.id, second.id)
        XCTAssertEqual(model.pending[0].screenshotDates, [normal, detail])
        var selection = ImportDateSelection(); selection.updateEvidence(model.pending[0].screenshotDates)
        try model.register(first.id, draft: model.pending[0].result!, chartID: model.state.charts[0].id, mergeID: nil, playedAt: selection.playedAt, timing: RegistrationTiming(environment: model.activeEnvironment), dateContext: selection.context)
        let saved = model.state.plays[0]
        XCTAssertEqual(saved.screenshotDates, [normal, detail]); XCTAssertEqual(saved.playedAt, normal.candidates[0].capturedAt)
        let extraDate = evidence(.detail, date: Date(timeIntervalSince1970: 103)), extra = pending("three", dates: [])
        var item = extra; item.screenshotDates = [extraDate]; model.pending = [item]
        try model.register(item.id, draft: item.result!, chartID: nil, mergeID: saved.id, playedAt: Date(timeIntervalSince1970: 999))
        XCTAssertEqual(model.state.plays[0].screenshotDates, [normal, detail, extraDate])
        XCTAssertEqual(model.state.plays[0].playedAt, saved.playedAt)
        XCTAssertEqual(model.state.plays[0].dateContext, saved.dateContext)
        XCTAssertEqual(model.state.plays[0].environment, saved.environment)
        let persisted = String(decoding: try JSONEncoder().encode(model.state), as: UTF8.self)
        XCTAssertFalse(persisted.contains("FORBIDDEN_FILENAME"))
    }
    func testExportAndWriteSuccessFailureDoNotSaveDatabaseOrIncludePendingImports() throws {
        let (model, repository) = fixture()
        model.pending = [pending("FORBIDDEN_FINGERPRINT", dates: [evidence()])]
        let before = model.state, pendingBefore = model.pending.map(\.id), saveCount = repository.saves
        let data = try model.analysisExportData(exportedAt: Date(timeIntervalSince1970: 100))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["exportedPlayCount"] as? Int, 0)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("FORBIDDEN_"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-write-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("analysis.json")
        try model.writeAnalysisExport(data, to: file, playCount: 0)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertThrowsError(try model.writeAnalysisExport(data, to: dir.appendingPathComponent("missing/analysis.json"), playCount: 0))
        XCTAssertThrowsError(try model.writeAnalysisExport(data, to: dir.appendingPathComponent("results.store"), playCount: 0))
        XCTAssertEqual(model.state, before); XCTAssertEqual(repository.stored, before)
        XCTAssertEqual(repository.saves, saveCount); XCTAssertEqual(model.pending.map(\.id), pendingBefore)
        model.importing = true; XCTAssertThrowsError(try model.analysisExportData())
    }
    func testVersionResourceMatchesDistributionPlist() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Config/Info.plist")), format: nil) as? [String: Any])
        let app = try AppVersion.current()
        XCTAssertEqual(app.version, plist["CFBundleShortVersionString"] as? String)
        XCTAssertEqual(app.build, plist["CFBundleVersion"] as? String)
    }
    func testDateEvidenceSurvivesDiskReopenWithoutImageOrSourcePath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("date-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try LocalRepository(storageDirectory: directory)
        let model = AppModel(inMemory: true, loadBundledCatalog: false, repository: repository)
        let normal = evidence(); let item = pending("disk", dates: [normal]); model.pending = [item]
        var selection = ImportDateSelection(); selection.updateEvidence(item.screenshotDates)
        try model.register(item.id, draft: item.result!, chartID: nil, mergeID: nil, playedAt: selection.playedAt, timing: RegistrationTiming(environment: model.activeEnvironment), dateContext: selection.context)
        let reopened = try LocalRepository(storageDirectory: directory).load()
        XCTAssertEqual(reopened, model.state)
        XCTAssertEqual(reopened.plays.first?.selectedScreenshotDate, normal.candidates.first)
        XCTAssertEqual(reopened.schemaVersion, 1)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(reopened), as: UTF8.self).contains("FORBIDDEN_FILENAME"))
    }
}
