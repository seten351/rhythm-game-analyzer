import Foundation
import ResultCore

enum HomeAchievementKind: Int {
    case firstAP, firstFC, comboImproved
    var title: String { switch self { case .firstAP: return "初 AP"; case .firstFC: return "初 FC"; case .comboImproved: return "最大コンボ更新" } }
    var symbol: String { switch self { case .firstAP: return "sparkles"; case .firstFC: return "flag.fill"; case .comboImproved: return "arrow.up.right" } }
}

struct HomeRecord: Identifiable {
    let play: PlayRecord
    let song: Song
    let chart: ResultCore.Chart
    var id: UUID { play.id }
    var perfectRate: Double? {
        let counts = Judgment.allCases.compactMap { play.judgments[$0]?.total }
        guard counts.count == Judgment.allCases.count, counts.allSatisfy({ $0 >= 0 }), counts.reduce(0, +) > 0,
              let perfect = play.judgments[.perfect]?.total else { return nil }
        return Double(perfect) / Double(counts.reduce(0, +))
    }
    var chartLabel: String { "\(chart.difficulty) · Lv.\(chart.level.map(String.init) ?? "—")" }
}

struct HomeAchievement: Identifiable {
    let record: HomeRecord
    let kind: HomeAchievementKind
    let previousCombo: Int?
    var id: UUID { record.chart.id }
    var comboIncrease: Int? {
        guard let old = previousCombo, let new = record.play.combo, new > old else { return nil }
        return new - old
    }
}

struct HomeSnapshot {
    let achievements: [HomeAchievement]
    let recentRecords: [HomeRecord]
    let focusCount: Int
    let hasBatch: Bool
    let totalPlays: Int
    let chartCount: Int
    let playedChartCount: Int
    let fcCount: Int
    let apCount: Int
}

enum HomePresentation {
    /// nil means a reopened app: use the latest 20 registered plays. An empty batch
    /// means this import saved nothing; never present older results as new successes.
    static func snapshot(state: AppState, gameID: String, batchPlayIDs: [UUID]? = nil) -> HomeSnapshot {
        let songs = Dictionary(uniqueKeysWithValues: state.songs.filter { $0.gameID == gameID }.map { ($0.id, $0) })
        let charts = Dictionary(uniqueKeysWithValues: state.charts.filter { songs[$0.songID] != nil }.map { ($0.id, $0) })
        let records = state.plays.compactMap { play -> HomeRecord? in
            guard play.confirmed, play.gameID == gameID, let chart = charts[play.chartID], let song = songs[chart.songID] else { return nil }
            return HomeRecord(play: play, song: song, chart: chart)
        }.sorted(by: registeredLater)
        let focusIDs = Set(batchPlayIDs ?? records.prefix(20).map(\.id))
        let focus = records.filter { focusIDs.contains($0.id) }
        let groups = Dictionary(grouping: records, by: { $0.chart.id })
        var achievements: [HomeAchievement] = []
        for (chartID, incoming) in Dictionary(grouping: focus, by: { $0.chart.id }) {
            guard let chart = charts[chartID], chart.availability == .active, songs[chart.songID]?.availability == .active else { continue }
            // Registration order is explicit: importing an old screenshot is not
            // evidence of a new real-world achievement today. Equal timestamps do
            // not imply a performance sequence, so compare the group as a whole.
            let candidates = incoming.compactMap { record -> HomeAchievement? in
                let previous = (groups[chartID] ?? []).filter {
                    $0.id != record.id && ($0.play.importedAt < record.play.importedAt ||
                        ($0.play.importedAt == record.play.importedAt && !focusIDs.contains($0.id)))
                }
                let previousCombo = previous.compactMap { $0.play.combo }.max()
                let kind: HomeAchievementKind
                if record.play.achievement.isAP && !previous.contains(where: { $0.play.achievement.isAP }) { kind = .firstAP }
                else if record.play.achievement.isFC && !previous.contains(where: { $0.play.achievement.isFC }) { kind = .firstFC }
                else if let previousCombo, let combo = record.play.combo, combo > previousCombo { kind = .comboImproved }
                else { return nil }
                return .init(record: record, kind: kind, previousCombo: previousCombo)
            }.sorted { a, b in
                if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
                if a.kind == .comboImproved && a.record.play.combo != b.record.play.combo { return (a.record.play.combo ?? 0) > (b.record.play.combo ?? 0) }
                return registeredLater(a.record, b.record)
            }
            if let chosen = candidates.first { achievements.append(chosen) }
        }
        achievements.sort { a, b in
            a.kind == b.kind ? registeredLater(a.record, b.record) : a.kind.rawValue < b.kind.rawValue
        }
        let active = Set(state.activeCharts(gameID: gameID).map(\.id))
        let activeRecords = records.filter { active.contains($0.chart.id) }
        return HomeSnapshot(achievements: achievements, recentRecords: Array(records.prefix(6)), focusCount: focus.count,
                            hasBatch: batchPlayIDs != nil, totalPlays: records.count, chartCount: active.count,
                            playedChartCount: Set(activeRecords.map { $0.chart.id }).count,
                            fcCount: Set(activeRecords.filter { $0.play.achievement.isFC }.map { $0.chart.id }).count,
                            apCount: Set(activeRecords.filter { $0.play.achievement.isAP }.map { $0.chart.id }).count)
    }

    private static func registeredLater(_ a: HomeRecord, _ b: HomeRecord) -> Bool {
        a.play.importedAt == b.play.importedAt ? a.id.uuidString < b.id.uuidString : a.play.importedAt > b.play.importedAt
    }
}
