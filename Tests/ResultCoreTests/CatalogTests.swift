import Foundation
import XCTest
@testable import ResultCore

final class CatalogTests: XCTestCase {
    private let gameID = "rhythm-game"
    private let sourceID = "official"
    private let generatedAt = "2026-10-01T00:00:00Z"

    private func document(
        revision: Int = 1,
        complete: Bool = true,
        songs: [CatalogSong]
    ) -> CatalogDocument {
        CatalogDocument(
            gameId: gameID,
            sourceId: sourceID,
            revision: revision,
            generatedAt: generatedAt,
            isComplete: complete,
            songs: songs
        )
    }

    private func song(
        _ id: String = "song-1",
        title: String = "Master title",
        aliases: [String] = [],
        charts: [CatalogChart] = [.init(id: "chart-1", difficulty: "MASTER", level: 30)]
    ) -> CatalogSong {
        CatalogSong(id: id, title: title, aliases: aliases, charts: charts)
    }

    private func importCatalog(_ doc: CatalogDocument, into state: AppState, digest: String) throws -> AppState {
        let preview = try CatalogService.preview(doc, digest: digest, state: state, supportedGames: [gameID])
        return try CatalogService.apply(preview, to: state, now: Date(timeIntervalSince1970: 100))
    }

    private func importedState(
        with doc: CatalogDocument? = nil,
        digest: String = "digest-1"
    ) throws -> AppState {
        try importCatalog(doc ?? document(songs: [song()]), into: AppState(), digest: digest)
    }

    func testCatalogUpdatesKeepInternalIDsUserOverridesAndPlaySnapshots() throws {
        var state = try importedState()
        let songID = try XCTUnwrap(state.songs.first?.id)
        let chartID = try XCTUnwrap(state.charts.first?.id)
        state.songs[0].userTitle = "My title"
        state.songs[0].userAliases = ["Personal alias"]
        state.charts[0].userDifficulty = "MY MASTER"
        state.charts[0].userLevel = 31
        let playedAt = Date(timeIntervalSince1970: 50)
        let play = PlayRecord(
            chartID: chartID,
            gameID: gameID,
            titleAtPlay: "Title at play",
            difficultyAtPlay: "MASTER",
            levelAtPlay: 29,
            score: 987_654,
            importedAt: Date(timeIntervalSince1970: 60),
            playedAt: playedAt,
            presetID: "import-v1",
            presetVersion: 1,
            fingerprints: [.init(sha256: "image-hash", layout: "result-screen")]
        )
        state.plays = [play]

        let update = document(revision: 2, songs: [song(title: "Renamed master", charts: [.init(id: "chart-1", difficulty: "EXPERT", level: 32)])])
        let result = try importCatalog(update, into: state, digest: "digest-2")

        XCTAssertEqual(result.songs.first?.id, songID)
        XCTAssertEqual(result.charts.first?.id, chartID)
        XCTAssertEqual(result.songs.first?.masterTitle, "Renamed master")
        XCTAssertEqual(result.songs.first?.userTitle, "My title")
        XCTAssertEqual(result.songs.first?.userAliases, ["Personal alias"])
        XCTAssertEqual(result.charts.first?.masterDifficulty, "EXPERT")
        XCTAssertEqual(result.charts.first?.masterLevel, 32)
        XCTAssertEqual(result.charts.first?.userDifficulty, "MY MASTER")
        XCTAssertEqual(result.charts.first?.userLevel, 31)
        XCTAssertEqual(result.plays, [play])
        XCTAssertEqual(result.plays.first?.titleAtPlay, "Title at play")
        XCTAssertEqual(result.plays.first?.levelAtPlay, 29)
        XCTAssertEqual(result.plays.first?.fingerprints, play.fingerprints)
    }

    func testCompleteSnapshotArchivesOmittedItemsAndRelistingRestoresThem() throws {
        let initial = try importedState()
        let songID = try XCTUnwrap(initial.songs.first?.id)
        let chartID = try XCTUnwrap(initial.charts.first?.id)

        let omitted = try importCatalog(document(revision: 2, complete: true, songs: []), into: initial, digest: "digest-2")
        XCTAssertEqual(omitted.songs.first(where: { $0.id == songID })?.availability, .retired)
        XCTAssertEqual(omitted.charts.first(where: { $0.id == chartID })?.availability, .retired)

        let relisted = try importCatalog(document(revision: 3, songs: [song()]), into: omitted, digest: "digest-3")
        XCTAssertEqual(relisted.songs.first?.id, songID)
        XCTAssertEqual(relisted.charts.first?.id, chartID)
        XCTAssertEqual(relisted.songs.first?.availability, .active)
        XCTAssertEqual(relisted.charts.first?.availability, .active)
    }

    func testPartialSnapshotDoesNotArchiveOmittedItems() throws {
        let initial = try importedState()
        let songID = try XCTUnwrap(initial.songs.first?.id)
        let chartID = try XCTUnwrap(initial.charts.first?.id)

        let result = try importCatalog(document(revision: 2, complete: false, songs: []), into: initial, digest: "digest-2")

        XCTAssertEqual(result.songs.first(where: { $0.id == songID })?.availability, .active)
        XCTAssertEqual(result.charts.first(where: { $0.id == chartID })?.availability, .active)
    }

    func testRejectsDifferentDigestAtSameRevisionAndOlderRevision() throws {
        let state = try importedState(with: document(revision: 2, songs: [song()]))
        let sameRevision = document(revision: 2, songs: [song(title: "Different")])
        let olderRevision = document(revision: 1, songs: [song()])

        XCTAssertThrowsError(try CatalogService.preview(sameRevision, digest: "other-digest", state: state, supportedGames: [gameID]))
        XCTAssertThrowsError(try CatalogService.preview(olderRevision, digest: "digest-0", state: state, supportedGames: [gameID]))
    }

    func testRejectsDuplicateSongAndChartIDs() {
        let duplicateSongs = document(songs: [song("same"), song("same", title: "Other")])
        XCTAssertThrowsError(try CatalogService.validate(duplicateSongs, supportedGames: [gameID]))

        let duplicateCharts = document(songs: [
            song("first", charts: [.init(id: "duplicate-chart", difficulty: "EXPERT")]),
            song("second", charts: [.init(id: "duplicate-chart", difficulty: "MASTER")])
        ])
        XCTAssertThrowsError(try CatalogService.validate(duplicateCharts, supportedGames: [gameID]))
    }

    func testRejectsReusingChartIDUnderDifferentParentSong() throws {
        let state = try importedState()
        let changedParent = document(revision: 2, songs: [
            song("song-1", charts: []),
            song("song-2", charts: [.init(id: "chart-1", difficulty: "MASTER", level: 30)])
        ])

        XCTAssertThrowsError(try CatalogService.preview(changedParent, digest: "digest-2", state: state, supportedGames: [gameID]))
    }

    func testExplicitLinkPreservesProvisionalSongChartAndPlayHistory() throws {
        let songID = UUID()
        let chartID = UUID()
        let localSong = Song(id: songID, gameID: gameID, masterTitle: "Official title", userTitle: "My title", provisional: true)
        let localChart = Chart(id: chartID, songID: songID, masterDifficulty: "MASTER", masterLevel: 29, userLevel: 31)
        let play = PlayRecord(chartID: chartID, gameID: gameID, titleAtPlay: "Old capture", difficultyAtPlay: "MASTER", levelAtPlay: 29, score: 900_000, presetID: "manual", presetVersion: 1)
        var state = AppState()
        state.songs = [localSong]
        state.charts = [localChart]
        state.plays = [play]
        let doc = document(songs: [song("incoming", title: "Official title")])
        let preview = try CatalogService.preview(doc, digest: "digest-1", state: state, supportedGames: [gameID])

        let result = try CatalogService.apply(preview, to: state, links: ["incoming": songID])

        XCTAssertEqual(result.songs.count, 1)
        XCTAssertEqual(result.songs.first?.id, songID)
        XCTAssertEqual(result.songs.first?.masterTitle, "Official title")
        XCTAssertEqual(result.songs.first?.userTitle, "My title")
        XCTAssertFalse(try XCTUnwrap(result.songs.first).provisional)
        XCTAssertEqual(result.charts.count, 1)
        XCTAssertEqual(result.charts.first?.id, chartID)
        XCTAssertEqual(result.charts.first?.userLevel, 31)
        XCTAssertEqual(result.plays, [play])
    }

    func testRejectsDuplicateAndInvalidExplicitLinksWithoutChangingOriginalState() throws {
        var state = AppState()
        let first = Song(gameID: gameID, masterTitle: "Shared title")
        let second = Song(gameID: gameID, masterTitle: "Shared title")
        state.songs = [first, second]
        let doc = document(songs: [
            song("incoming-a", title: "Shared title", charts: [.init(id: "chart-a", difficulty: "MASTER", level: 30)]),
            song("incoming-b", title: "Shared title", charts: [.init(id: "chart-b", difficulty: "MASTER", level: 30)])
        ])
        let preview = try CatalogService.preview(doc, digest: "digest-1", state: state, supportedGames: [gameID])
        XCTAssertEqual(preview.matches.count, 2)
        let original = state

        XCTAssertThrowsError(try CatalogService.apply(preview, to: state, links: ["incoming-a": first.id, "incoming-b": first.id]))
        XCTAssertEqual(state, original)
        XCTAssertThrowsError(try CatalogService.apply(preview, to: state, links: ["incoming-a": UUID()]))
        XCTAssertEqual(state, original)
    }

    func testSameDigestApplyIsNoOp() throws {
        let state = try importedState()
        let original = state
        let doc = document(revision: 1, songs: [song(title: "Changed despite same digest")])
        let preview = try CatalogService.preview(doc, digest: "digest-1", state: state, supportedGames: [gameID])

        let result = try CatalogService.apply(preview, to: state)

        XCTAssertTrue(preview.unchanged)
        XCTAssertEqual(result, original)
    }
}
