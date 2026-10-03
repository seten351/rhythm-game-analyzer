import Foundation
import ResultCore

enum LibraryFilter: String, CaseIterable {
    case all = "すべて", unplayed = "未プレイ", notFC = "未FC", notAP = "未AP", fc = "FC", ap = "AP"

    func includes(_ row: LibraryChartRow) -> Bool {
        switch self {
        case .all: return true
        case .unplayed: return row.plays.isEmpty
        case .notFC: return !row.hasFC
        case .notAP: return !row.hasAP
        case .fc: return row.hasFC
        case .ap: return row.hasAP
        }
    }
}

enum LibrarySort: String, CaseIterable {
    case recent = "新しい記録順", title = "曲名順", level = "Lv.が高い順"
}

enum LibraryDetailTab: String, CaseIterable {
    case overview = "概要", history = "履歴"
}

/// Presentation state belongs to the window, so navigating to analysis keeps the selection.
struct LibraryBrowserState {
    var search = ""
    var filter: LibraryFilter = .all
    var difficulty: String?
    var level: Int?
    var includeArchived = false
    var sort: LibrarySort = .recent
    var selectedID: UUID?
    var detailTab: LibraryDetailTab = .overview

    mutating func retainVisibleSelection(in rows: [LibraryChartRow]) {
        if let selectedID, !rows.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }

    mutating func resetFilters() {
        search = ""; filter = .all; difficulty = nil; level = nil; includeArchived = false
    }
}

struct LibraryChartRow: Identifiable {
    let song: Song
    let chart: ResultCore.Chart
    /// Newest first. Date ties are resolved by ID so selection and sorting stay stable.
    let plays: [PlayRecord]
    var id: UUID { chart.id }
    var isArchived: Bool { song.availability == .retired || chart.availability == .retired }
    var hasFC: Bool { plays.contains { $0.achievement.isFC } }
    var hasAP: Bool { plays.contains { $0.achievement.isAP } }
    var latestPlay: PlayRecord? { plays.first }
    var bestPlay: PlayRecord? {
        // Keep the newest record when scores tie, including its actual environment snapshot.
        plays.reduce(nil as PlayRecord?) { best, play in
            guard let best else { return play }
            return play.score > best.score ? play : best
        }
    }
    var achievement: Achievement {
        if hasAP { return .ap }
        if hasFC { return .fc }
        return plays.contains { $0.achievement == .none } ? .none : .unknown
    }
    var achievementLabel: String {
        if plays.isEmpty { return "未プレイ" }
        // Unknown results are not evidence of failure to achieve FC.
        if !hasFC && plays.contains(where: { $0.achievement == .unknown }) { return "達成不明" }
        return achievement == .none ? "FC記録なし" : achievement.label
    }
}

enum LibraryPresentation {
    static func rows(in state: AppState, gameID: String) -> [LibraryChartRow] {
        let songs = Dictionary(uniqueKeysWithValues: state.songs.filter { $0.gameID == gameID }.map { ($0.id, $0) })
        let plays = Dictionary(grouping: state.plays.filter { $0.gameID == gameID }, by: \.chartID)
        return state.charts.compactMap { chart in
            guard let song = songs[chart.songID] else { return nil }
            let history = (plays[chart.id] ?? []).sorted {
                $0.orderDate == $1.orderDate ? $0.id.uuidString < $1.id.uuidString : $0.orderDate > $1.orderDate
            }
            return LibraryChartRow(song: song, chart: chart, plays: history)
        }
    }

    /// Search/difficulty/level/archive scope, before the achievement filter is applied.
    static func scopedRows(_ rows: [LibraryChartRow], browser: LibraryBrowserState) -> [LibraryChartRow] {
        let query = normalizedName(browser.search)
        return rows.filter { row in
            (browser.includeArchived || !row.isArchived)
                && (browser.difficulty == nil || row.chart.difficulty == browser.difficulty)
                && (browser.level == nil || row.chart.level == browser.level)
                && (query.isEmpty || row.song.allNames.contains { normalizedName($0).contains(query) })
        }
    }

    static func visibleRows(_ scopedRows: [LibraryChartRow], browser: LibraryBrowserState) -> [LibraryChartRow] {
        scopedRows.filter(browser.filter.includes).sorted { a, b in
            switch browser.sort {
            case .recent:
                let ad = a.latestPlay?.orderDate ?? .distantPast, bd = b.latestPlay?.orderDate ?? .distantPast
                if ad != bd { return ad > bd }
            case .level:
                // Missing levels belong after known values, rather than becoming level zero.
                if a.chart.level != b.chart.level { return (a.chart.level ?? Int.min) > (b.chart.level ?? Int.min) }
            case .title: break
            }
            let titleOrder = a.song.title.localizedStandardCompare(b.song.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            if a.chart.difficulty != b.chart.difficulty { return difficultyPrecedes(a.chart.difficulty, b.chart.difficulty) }
            return a.id.uuidString < b.id.uuidString
        }
    }

    static func difficultyPrecedes(_ a: String, _ b: String) -> Bool {
        let order = ["EASY", "NORMAL", "HARD", "EXPERT", "SPECIAL", "MASTER"]
        let ai = order.firstIndex(of: a.uppercased()) ?? Int.max, bi = order.firstIndex(of: b.uppercased()) ?? Int.max
        return ai == bi ? a.localizedStandardCompare(b) == .orderedAscending : ai < bi
    }
}
