import Foundation

public struct CatalogDocument: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var gameId: String
    public var sourceId: String
    public var revision: Int
    public var generatedAt: String
    public var isComplete: Bool
    public var songs: [CatalogSong]
    public init(formatVersion: Int = 1, gameId: String, sourceId: String, revision: Int, generatedAt: String, isComplete: Bool, songs: [CatalogSong]) { self.formatVersion = formatVersion; self.gameId = gameId; self.sourceId = sourceId; self.revision = revision; self.generatedAt = generatedAt; self.isComplete = isComplete; self.songs = songs }
}
public struct CatalogSong: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var aliases: [String]
    public var status: Availability
    public var charts: [CatalogChart]
    public init(id: String, title: String, aliases: [String] = [], status: Availability = .active, charts: [CatalogChart]) { self.id = id; self.title = title; self.aliases = aliases; self.status = status; self.charts = charts }
}
public struct CatalogChart: Codable, Equatable, Sendable {
    public var id: String
    public var difficulty: String
    public var level: Int?
    public var noteCount: Int?
    public var status: Availability
    public init(id: String, difficulty: String, level: Int? = nil, status: Availability = .active, noteCount: Int? = nil) { self.id = id; self.difficulty = difficulty; self.level = level; self.status = status; self.noteCount = noteCount }
}

public struct CatalogMatch: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var candidates: [UUID]
}
public struct CatalogPreview: Sendable {
    public var document: CatalogDocument
    public var digest: String
    public var addedSongs: Int
    public var changedSongs: Int
    public var addedCharts: Int
    public var changedCharts: Int
    public var archivedSongs: Int
    public var archivedCharts: Int
    public var matches: [CatalogMatch]
    public var unchanged: Bool
}

public enum CatalogService {
    public static func preview(_ doc: CatalogDocument, digest: String, state: AppState, supportedGames: Set<String>) throws -> CatalogPreview {
        try validate(doc, supportedGames: supportedGames)
        let prior = state.catalogs.first { $0.gameID == doc.gameId && $0.sourceID == doc.sourceId }
        if let prior {
            if doc.revision < prior.revision { throw CoreError.invalid("旧版のマスタです。現在の改訂番号は \(prior.revision) です。") }
            if doc.revision == prior.revision && prior.digest != digest { throw CoreError.invalid("同じ改訂番号で内容が異なります。収集側で改訂番号を増やしてください。") }
        }
        var p = CatalogPreview(document: doc, digest: digest, addedSongs: 0, changedSongs: 0, addedCharts: 0, changedCharts: 0, archivedSongs: 0, archivedCharts: 0, matches: [], unchanged: prior?.digest == digest && prior?.revision == doc.revision)
        let bindings = state.bindings.filter { $0.gameID == doc.gameId && $0.sourceID == doc.sourceId }
        for song in doc.songs {
            if let binding = bindings.first(where: { $0.kind == .song && $0.externalID == song.id }) {
                guard let current = state.songs.first(where: { $0.id == binding.internalID && $0.gameID == doc.gameId }) else { throw CoreError.invalid("楽曲のID対応が壊れています。更新を中止しました。") }
                if current.masterTitle != song.title || current.masterAliases != song.aliases || current.availability != song.status { p.changedSongs += 1 }
                for chart in song.charts {
                    if let cb = bindings.first(where: { $0.kind == .chart && $0.externalID == chart.id }) {
                        guard let currentChart = state.charts.first(where: { $0.id == cb.internalID && $0.songID == current.id }) else { throw CoreError.invalid("譜面IDが別の楽曲を指しています。IDを再利用しないでください。") }
                        if currentChart.masterDifficulty != chart.difficulty || currentChart.masterLevel != chart.level || currentChart.availability != chart.status || currentChart.noteCount != chart.noteCount { p.changedCharts += 1 }
                    } else { p.addedCharts += 1 }
                }
            } else {
                // Reused chart IDs cannot be moved to a different song, including a newly added one.
                if song.charts.contains(where: { incoming in bindings.contains { $0.kind == .chart && $0.externalID == incoming.id } }) { throw CoreError.invalid("既存の譜面IDを新しい楽曲へ移せません。") }
                p.addedSongs += 1; p.addedCharts += song.charts.count
                let names = Set(([song.title] + song.aliases).map(normalizedName))
                let candidates = state.songs.filter { local in
                    local.gameID == doc.gameId && !Set(local.allNames.map(normalizedName)).isDisjoint(with: names) && !state.bindings.contains { $0.gameID == doc.gameId && $0.sourceID == doc.sourceId && $0.kind == .song && $0.internalID == local.id }
                }.map(\.id)
                if !candidates.isEmpty { p.matches.append(CatalogMatch(id: song.id, title: song.title, candidates: candidates)) }
            }
        }
        if doc.isComplete {
            let songs = Set(doc.songs.map(\.id)), charts = Set(doc.songs.flatMap { $0.charts.map(\.id) })
            for b in bindings {
                if b.kind == .song && !songs.contains(b.externalID), state.songs.contains(where: { $0.id == b.internalID && $0.availability == .active }) { p.archivedSongs += 1 }
                if b.kind == .chart && !charts.contains(b.externalID), state.charts.contains(where: { $0.id == b.internalID && $0.availability == .active }) { p.archivedCharts += 1 }
            }
        }
        return p
    }

    public static func apply(_ preview: CatalogPreview, to original: AppState, links: [String: UUID] = [:], now: Date = Date()) throws -> AppState {
        // Revalidate against current state; callers may have edited histories while previewing.
        let p = try self.preview(preview.document, digest: preview.digest, state: original, supportedGames: [preview.document.gameId])
        if p.unchanged { return original }
        let doc = p.document
        let allowed = Dictionary(uniqueKeysWithValues: p.matches.map { ($0.id, Set($0.candidates)) })
        guard Set(links.values).count == links.count else { throw CoreError.invalid("複数の楽曲を同じ楽曲に紐付けることはできません。") }
        for (external, local) in links { guard allowed[external]?.contains(local) == true else { throw CoreError.invalid("照合候補が変わりました。マスタを再確認してください。") } }
        var state = original
        func binding(_ kind: BindingKind, _ external: String) -> UUID? { state.bindings.first { $0.gameID == doc.gameId && $0.sourceID == doc.sourceId && $0.kind == kind && $0.externalID == external }?.internalID }
        for input in doc.songs {
            let songID: UUID
            if let id = binding(.song, input.id) { songID = id }
            else if let id = links[input.id] { songID = id; state.bindings.append(.init(gameID: doc.gameId, sourceID: doc.sourceId, kind: .song, externalID: input.id, internalID: id)) }
            else { let song = Song(gameID: doc.gameId, masterTitle: input.title); songID = song.id; state.songs.append(song); state.bindings.append(.init(gameID: doc.gameId, sourceID: doc.sourceId, kind: .song, externalID: input.id, internalID: songID)) }
            guard let si = state.songs.firstIndex(where: { $0.id == songID }) else { throw CoreError.invalid("楽曲が見つかりません。") }
            state.songs[si].masterTitle = input.title; state.songs[si].masterAliases = input.aliases; state.songs[si].availability = input.status; state.songs[si].provisional = false
            for incoming in input.charts {
                let chartID: UUID
                if let id = binding(.chart, incoming.id) { chartID = id }
                else {
                    // Matching a song explicitly authorizes matching its single unbound difficulty.
                    let candidates = state.charts.filter { c in c.songID == songID && normalizedName(c.difficulty) == normalizedName(incoming.difficulty) && !state.bindings.contains { $0.gameID == doc.gameId && $0.sourceID == doc.sourceId && $0.kind == .chart && $0.internalID == c.id } }
                    if links[input.id] != nil && candidates.count > 1 { throw CoreError.invalid("同じ難易度に複数譜面があります。履歴側で整理してから紐付けてください。") }
                    if links[input.id] != nil, let c = candidates.first { chartID = c.id }
                    else { let c = Chart(songID: songID, masterDifficulty: incoming.difficulty, masterLevel: incoming.level); chartID = c.id; state.charts.append(c) }
                    state.bindings.append(.init(gameID: doc.gameId, sourceID: doc.sourceId, kind: .chart, externalID: incoming.id, internalID: chartID))
                }
                guard let ci = state.charts.firstIndex(where: { $0.id == chartID && $0.songID == songID }) else { throw CoreError.invalid("譜面の対応が矛盾しています。") }
                state.charts[ci].masterDifficulty = incoming.difficulty; state.charts[ci].masterLevel = incoming.level; state.charts[ci].availability = incoming.status; state.charts[ci].noteCount = incoming.noteCount
            }
        }
        if doc.isComplete {
            let songs = Set(doc.songs.map(\.id)), charts = Set(doc.songs.flatMap { $0.charts.map(\.id) })
            for b in state.bindings where b.gameID == doc.gameId && b.sourceID == doc.sourceId {
                if b.kind == .song && !songs.contains(b.externalID), let i = state.songs.firstIndex(where: { $0.id == b.internalID }) { state.songs[i].availability = .retired }
                if b.kind == .chart && !charts.contains(b.externalID), let i = state.charts.firstIndex(where: { $0.id == b.internalID }) { state.charts[i].availability = .retired }
            }
        }
        state.catalogs.removeAll { $0.gameID == doc.gameId && $0.sourceID == doc.sourceId }
        state.catalogs.append(CatalogImportState(gameID: doc.gameId, sourceID: doc.sourceId, revision: doc.revision, digest: p.digest, isComplete: doc.isComplete, generatedAt: doc.generatedAt, importedAt: now))
        return state
    }

    public static func validate(_ doc: CatalogDocument, supportedGames: Set<String>) throws {
        guard doc.formatVersion == 1 else { throw CoreError.invalid("未対応のマスタ形式です。") }
        guard supportedGames.contains(doc.gameId), !doc.sourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, doc.revision > 0 else { throw CoreError.invalid("ゲームID、収集元ID、改訂番号を確認してください。") }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard iso.date(from: doc.generatedAt) != nil || ISO8601DateFormatter().date(from: doc.generatedAt) != nil else { throw CoreError.invalid("generatedAtにはISO 8601形式の日時が必要です。") }
        var songIDs = Set<String>(), chartIDs = Set<String>()
        for song in doc.songs {
            guard !song.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, songIDs.insert(song.id).inserted, !song.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoreError.invalid("楽曲IDの重複・空欄、または曲名の空欄があります。") }
            for chart in song.charts {
                guard chart.noteCount.map({ (1...1_000_000).contains($0) }) ?? true else { throw CoreError.invalid("譜面の総ノーツ数が不正です。") }
                guard !chart.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, chartIDs.insert(chart.id).inserted, !chart.difficulty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, chart.level.map({ $0 > 0 }) ?? true else { throw CoreError.invalid("譜面IDの重複・空欄、または難易度・レベルが不正です。") }
            }
        }
    }
}
