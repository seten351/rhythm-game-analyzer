import Foundation
import XCTest
@testable import OurNotesApp
@testable import ResultCore

@MainActor final class BundledCatalogTests: XCTestCase {
    private final class Repository: StateRepository {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-fixture/results.store")
        var stored = AppState()
        var saves = 0
        var fail = false
        func load() throws -> AppState { stored }
        func save(_ state: AppState) throws {
            if fail { throw CoreError.invalid("保存失敗の検証") }
            stored = state; saves += 1
        }
    }

    private func document(_ name: String = "our-notes-catalog") throws -> CatalogDocument {
        let model = AppModel(inMemory: true, loadBundledCatalog: false)
        let url = model.resourceDirectory.appendingPathComponent(name + ".json")
        return try JSONDecoder().decode(CatalogDocument.self, from: Data(contentsOf: url))
    }
    private func play(_ chartID: UUID, title: String = "プレイ時の曲名") -> PlayRecord {
        PlayRecord(chartID: chartID, gameID: "our-notes", titleAtPlay: title, difficultyAtPlay: "EXPERT", levelAtPlay: 99,
                   score: 900_000, presetID: "old", presetVersion: 1, fingerprints: [.init(sha256: UUID().uuidString, layout: "normal")])
    }

    func testFirstLaunchInstallsEverySongAndSecondLaunchDoesNotSaveAgain() throws {
        let repository = Repository()
        let model = AppModel(inMemory: true, repository: repository)
        XCTAssertNil(model.startupError)
        XCTAssertEqual(model.state.songs.count, 84)
        XCTAssertEqual(model.state.activeCharts(gameID: "our-notes").count, 336)
        XCTAssertEqual(model.state.catalogs.map(\.sourceID), [OurNotesCatalog.sourceID])
        XCTAssertEqual(model.state.bindings.count, 420)
        XCTAssertEqual(repository.saves, 1)
        let reopened = AppModel(inMemory: true, repository: repository)
        XCTAssertNil(reopened.startupError)
        XCTAssertEqual(reopened.state, model.state)
        XCTAssertEqual(repository.saves, 1)
    }

    func testResetReplacesSampleAndUserValuesWhileKeepingIDsAndHistoricalSnapshots() throws {
        let sample = try document("sample-catalog")
        let preview = try CatalogService.preview(sample, digest: "sample", state: AppState(), supportedGames: ["our-notes"])
        let repository = Repository()
        repository.stored = try CatalogService.apply(preview, to: AppState())
        let oldSongIDs = repository.stored.songs.map(\.id), oldChartIDs = repository.stored.charts.map(\.id)
        for i in repository.stored.songs.indices {
            repository.stored.songs[i].masterTitle = "以前のマスターの誤表記"
            repository.stored.songs[i].userTitle = "手動の表示名"
            repository.stored.songs[i].userAliases = ["手動の別名"]
        }
        for i in repository.stored.charts.indices {
            repository.stored.charts[i].masterLevel = 99
            repository.stored.charts[i].masterDifficulty = "誤った難易度"
            repository.stored.charts[i].userLevel = 98
            repository.stored.charts[i].userDifficulty = "手動難易度"
        }
        let plays = oldChartIDs.map { play($0) }
        repository.stored.plays = plays
        let environment = repository.stored.environments
        let model = AppModel(inMemory: true, repository: repository)
        XCTAssertNil(model.startupError)
        XCTAssertTrue(Set(oldSongIDs).isSubset(of: Set(model.state.songs.map(\.id))))
        XCTAssertTrue(Set(oldChartIDs).isSubset(of: Set(model.state.charts.map(\.id))))
        XCTAssertEqual(model.state.plays, plays)
        XCTAssertEqual(model.state.environments, environment)
        XCTAssertTrue(model.state.songs.allSatisfy { $0.userTitle == nil && $0.userAliases.isEmpty })
        XCTAssertTrue(model.state.charts.allSatisfy { $0.userLevel == nil && $0.userDifficulty == nil })
        XCTAssertFalse(model.state.songs.contains { $0.title == "以前のマスターの誤表記" })
        XCTAssertEqual(model.state.charts.first { $0.id == oldChartIDs[0] }?.level, 25)
        XCTAssertEqual(model.state.activeCharts(gameID: "our-notes").count, 336)
    }

    func testDuplicateMastersMergeHistoryAndUnmatchedHistoryIsArchived() throws {
        let repository = Repository()
        let a = Song(gameID: "our-notes", masterTitle: "焚音打")
        let b = Song(gameID: "our-notes", masterTitle: "焚音打", provisional: true)
        let unknown = Song(gameID: "our-notes", masterTitle: "不明な旧楽曲")
        let unused = Song(gameID: "our-notes", masterTitle: "履歴なしの手動曲")
        let ca = Chart(songID: a.id, masterDifficulty: "EXPERT", masterLevel: 9)
        let cb = Chart(songID: b.id, masterDifficulty: "EXPERT", masterLevel: 10)
        let cu = Chart(songID: unknown.id, masterDifficulty: "EXPERT", masterLevel: 20)
        repository.stored.songs = [a, b, unknown, unused]
        repository.stored.charts = [ca, cb, cu]
        let plays = [play(ca.id), play(cb.id), play(cu.id)]
        repository.stored.plays = plays
        let model = AppModel(inMemory: true, repository: repository)
        XCTAssertNil(model.startupError)
        XCTAssertEqual(model.state.activeCharts(gameID: "our-notes").count, 336)
        XCTAssertEqual(model.state.songs.filter { $0.title == "焚音打" }.count, 1)
        XCTAssertEqual(model.state.plays.map(\.chartID), [ca.id, ca.id, cu.id])
        XCTAssertEqual(model.state.plays.map(\.titleAtPlay), plays.map(\.titleAtPlay))
        XCTAssertEqual(model.state.plays.map(\.levelAtPlay), [99, 99, 99])
        XCTAssertEqual(model.state.charts.first { $0.id == cu.id }?.availability, .retired)
        XCTAssertEqual(model.state.songs.first { $0.id == unknown.id }?.availability, .retired)
        XCTAssertFalse(model.state.songs.contains { $0.id == unused.id })
        let again = AppModel(inMemory: true, repository: repository)
        XCTAssertEqual(again.state, model.state)
    }

    func testUnknownResultCannotCreateOrSelectAnUnregisteredMaster() throws {
        let model = AppModel(inMemory: true)
        let original = model.state
        let draft = ResultDraft(gameID: "our-notes", presetID: "test", presetVersion: 1, title: "存在しない曲", difficulty: "EXPERT", level: 25,
                                score: 100, combo: nil, achievement: .unknown, judgments: [:], fingerprint: .init(sha256: "new-image", layout: "normal"), kind: "normal")
        XCTAssertThrowsError(try ResultService.save(draft, to: original, environment: nil))
        XCTAssertEqual(model.state, original)
        let known = try XCTUnwrap(original.charts.first)
        let result = try ResultService.save(draft, to: original, environment: nil, targetChartID: known.id)
        XCTAssertEqual(result.songs, original.songs)
        XCTAssertEqual(result.charts, original.charts)
        XCTAssertEqual(result.plays.first?.chartID, known.id)
    }

    func testSaveFailureLeavesExistingDatabaseAndMemoryUntouched() throws {
        let repository = Repository()
        repository.stored.songs = [Song(gameID: "our-notes", masterTitle: "既存データ")]
        let original = repository.stored
        repository.fail = true
        let model = AppModel(inMemory: true, repository: repository)
        XCTAssertNotNil(model.startupError)
        XCTAssertEqual(repository.stored, original)
        XCTAssertEqual(model.state, original)
        XCTAssertEqual(repository.saves, 0)
    }

    func testSnapshotHasCurrentSongsCorrectedLevelsAndSeparateVersions() throws {
        let catalog = try document()
        XCTAssertTrue(catalog.isComplete)
        XCTAssertEqual(Set(catalog.songs.map(\.id)).count, 84)
        XCTAssertEqual(Set(catalog.songs.flatMap { $0.charts.map(\.id) }).count, 336)
        XCTAssertTrue(catalog.songs.allSatisfy { Set($0.charts.map(\.difficulty)) == OurNotesCatalog.difficulties })
        XCTAssertTrue(catalog.songs.contains { $0.title == "夢我夢中" })
        XCTAssertTrue(catalog.songs.contains { $0.title == "微笑みの爆弾" })
        XCTAssertTrue(catalog.songs.contains { $0.title == "春日影(MyGO!!!!! ver.)" })
        XCTAssertFalse(catalog.songs.contains { $0.title == "春日影" || $0.title == "過去を喰らう" })
        XCTAssertEqual(catalog.songs.first { $0.title == "堕天" }?.charts.map(\.level), [9, 14, 18, 26])
        XCTAssertEqual(catalog.songs.first { $0.title == "ないものねだり" }?.charts.first?.level, 7)
        XCTAssertTrue(try XCTUnwrap(catalog.songs.first { $0.title == "証命讃歌" }).aliases.contains("証明讃歌"))
    }

    func testDiskReopenRetainsAutomaticMasterWithoutDuplicatingCharts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-persistence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = AppModel(inMemory: true, repository: try LocalRepository(storageDirectory: directory))
        XCTAssertNil(first.startupError)
        let second = AppModel(inMemory: true, repository: try LocalRepository(storageDirectory: directory))
        XCTAssertNil(second.startupError)
        XCTAssertEqual(second.state, first.state)
        XCTAssertEqual(second.state.activeCharts(gameID: "our-notes").count, 336)
    }

    func testWebRevisionKeepsIdentitiesAndRejectsSameRevisionEdits() throws {
        let initial = try document()
        let first = try OurNotesCatalog.install(initial, digest: "first", into: AppState())
        var edited = initial
        edited.songs[0].title = "更新後の正規曲名"
        XCTAssertThrowsError(try OurNotesCatalog.install(edited, digest: "changed", into: first))
        edited.revision += 1
        let updated = try OurNotesCatalog.install(edited, digest: "changed", into: first)
        XCTAssertEqual(updated.songs.map(\.id), first.songs.map(\.id))
        XCTAssertEqual(updated.charts.map(\.id), first.charts.map(\.id))
        XCTAssertEqual(updated.songs[0].title, "更新後の正規曲名")
        XCTAssertEqual(try OurNotesCatalog.install(initial, digest: "first", into: updated), updated)
    }

    func testUnqualifiedHaruhikageIsNotMergedWithMyGOVersion() throws {
        let repository = Repository()
        let song = Song(gameID: "our-notes", masterTitle: "春日影", userTitle: "春日影(MyGO!!!!! ver.)")
        let chart = Chart(songID: song.id, masterDifficulty: "EXPERT", masterLevel: 22)
        let oldPlay = play(chart.id, title: "春日影")
        repository.stored.songs = [song]; repository.stored.charts = [chart]; repository.stored.plays = [oldPlay]
        let model = AppModel(inMemory: true, repository: repository)
        XCTAssertNil(model.startupError)
        XCTAssertEqual(model.state.plays, [oldPlay])
        XCTAssertEqual(model.state.songs.first { $0.id == song.id }?.availability, .retired)
        let canonical = try XCTUnwrap(model.state.songs.first { $0.title == "春日影(MyGO!!!!! ver.)" })
        XCTAssertNotEqual(canonical.id, song.id)
        XCTAssertEqual(model.state.activeCharts(gameID: "our-notes").count, 336)
    }
}
