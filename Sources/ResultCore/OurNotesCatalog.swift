import Foundation

/// Web values replace previous masters and overrides. Historical snapshots survive.
public enum OurNotesCatalog {
    public static let sourceID = "our-notes-community"
    public static let gameID = "our-notes"
    public static let difficulties: Set<String> = ["EASY", "NORMAL", "HARD", "EXPERT"]

    public static func install(_ document: CatalogDocument, digest: String, into original: AppState, now: Date = Date()) throws -> AppState {
        try CatalogService.validate(document, supportedGames: [gameID])
        guard document.sourceId == sourceID, document.isComplete, !document.songs.isEmpty,
              document.songs.allSatisfy({ song in
                  song.status == .active && song.charts.count == 4 && Set(song.charts.map(\.difficulty)) == difficulties &&
                  song.charts.allSatisfy { $0.status == .active && $0.level != nil }
              }) else { throw CoreError.invalid("同梱マスタの全曲・全難易度データが不正です。") }
        let prior = original.catalogs.first { $0.gameID == gameID && $0.sourceID == sourceID }
        // An older app must not overwrite a newer installed web catalog.
        if let prior, prior.revision > document.revision { return original }
        _ = try CatalogService.preview(document, digest: digest, state: original, supportedGames: [gameID])

        let inputs = Dictionary(uniqueKeysWithValues: document.songs.map { ($0.id, $0) })
        var names: [String: Set<String>] = [:]
        for song in document.songs {
            for name in [song.title] + song.aliases { names[normalizedName(name), default: []].insert(song.id) }
        }
        let oldSongs = original.songs.filter { $0.gameID == gameID }
        let oldSongIDs = Set(oldSongs.map(\.id))
        let oldCharts = original.charts.filter { oldSongIDs.contains($0.songID) }
        let trusted = original.bindings.filter { $0.gameID == gameID && ($0.sourceID == sourceID || $0.sourceID == "sample-verified-screenshots") }
        var songTargets: [UUID: String] = [:]
        for song in oldSongs {
            let bound = Set(trusted.filter { $0.kind == .song && $0.internalID == song.id && inputs[$0.externalID] != nil }.map(\.externalID))
            let byName = ([song.masterTitle] + song.masterAliases).reduce(into: Set<String>()) { $0.formUnion(names[normalizedName($1)] ?? []) }
            let candidates = bound.isEmpty ? byName : bound
            if candidates.count == 1 { songTargets[song.id] = candidates.first }
        }

        var next = original
        next.songs.removeAll { $0.gameID == gameID }
        next.charts.removeAll { oldSongIDs.contains($0.songID) }
        next.bindings.removeAll { $0.gameID == gameID }
        next.catalogs.removeAll { $0.gameID == gameID }
        var chartRemapping: [UUID: UUID] = [:]
        for input in document.songs {
            let candidates = oldSongs.filter { songTargets[$0.id] == input.id }
            let boundSong = trusted.first { $0.kind == .song && $0.sourceID == sourceID && $0.externalID == input.id }
            let songID = boundSong?.internalID ?? candidates.first?.id ?? UUID()
            next.songs.append(Song(id: songID, gameID: gameID, masterTitle: input.title, masterAliases: input.aliases))
            next.bindings.append(.init(gameID: gameID, sourceID: sourceID, kind: .song, externalID: input.id, internalID: songID))
            for chart in input.charts {
                let candidates = oldCharts.filter { old in
                    guard songTargets[old.songID] == input.id else { return false }
                    let bound = trusted.filter { binding in
                        binding.kind == .chart && binding.internalID == old.id && input.charts.contains { $0.id == binding.externalID }
                    }.map(\.externalID)
                    return bound.isEmpty ? normalizedName(old.masterDifficulty) == normalizedName(chart.difficulty) : bound.contains(chart.id)
                }
                let boundChart = trusted.first { $0.kind == .chart && $0.sourceID == sourceID && $0.externalID == chart.id }
                let chartID = boundChart?.internalID ?? candidates.first?.id ?? UUID()
                for old in candidates {
                    guard chartRemapping[old.id] == nil else { throw CoreError.invalid("既存譜面の対応が複数あります。マスタの適用を中止しました。") }
                    chartRemapping[old.id] = chartID
                }
                next.charts.append(Chart(id: chartID, songID: songID, masterDifficulty: chart.difficulty, masterLevel: chart.level, noteCount: chart.noteCount))
                next.bindings.append(.init(gameID: gameID, sourceID: sourceID, kind: .chart, externalID: chart.id, internalID: chartID))
            }
        }
        for index in next.plays.indices where next.plays[index].gameID == gameID {
            if let chartID = chartRemapping[next.plays[index].chartID] { next.plays[index].chartID = chartID }
        }
        // Unmatched historical records remain accessible in the archive, outside the master.
        let historicalIDs = Set(next.plays.map(\.chartID))
        for var chart in oldCharts where chartRemapping[chart.id] == nil && historicalIDs.contains(chart.id) {
            if !next.songs.contains(where: { $0.id == chart.songID }), var song = oldSongs.first(where: { $0.id == chart.songID }) {
                song.availability = .retired; song.provisional = true
                song.userTitle = nil; song.userAliases = []
                next.songs.append(song)
            }
            chart.availability = .retired; chart.userDifficulty = nil; chart.userLevel = nil
            next.charts.append(chart)
        }
        let importedAt = prior.flatMap { $0.revision == document.revision && $0.digest == digest ? $0.importedAt : nil } ?? now
        next.catalogs.append(CatalogImportState(gameID: gameID, sourceID: sourceID, revision: document.revision, digest: digest,
                                                isComplete: true, generatedAt: document.generatedAt, importedAt: importedAt))
        return next
    }
}
