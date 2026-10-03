import Foundation

public enum TimingTrendStatus: String, Sendable {
    case candidate, maintain, insufficientData, mixedDirections, unavailable, unknownLevel, limit
    public var label: String {
        switch self {
        case .candidate: return "1ステップを試す候補"
        case .maintain: return "現在値を維持"
        case .insufficientData: return "データ不足で保留"
        case .mixedDirections: return "傾向が分かれるため保留"
        case .unavailable: return "設定・仕様の確認が必要"
        case .unknownLevel: return "レベル不明のため保留"
        case .limit: return "許容範囲のため保留"
        }
    }
}

public struct TimingSongEvidence: Identifiable, Sendable {
    public var songID: UUID
    public var statistics: SummaryStatistics
    public var id: UUID { songID }
}

public struct TimingTrendRecommendation: Sendable {
    public var current: Decimal?
    public var proposed: Decimal?
    public var status: TimingTrendStatus
    public var statistics: SummaryStatistics
    /// Average of per-song biases, with equal weight for each distinct song.
    public var songBias: Double?
    public var matchingSongCount: Int
    public var songs: [TimingSongEvidence]
    public var reason: String
    public var songCount: Int { songs.count }
    public var playCount: Int { statistics.timingSampleCount }
    public var noteCount: Int { statistics.timingNoteCount }
    public var bias: Double? { statistics.timingBias }
}

public struct TimingLevelTrend: Identifiable, Sendable {
    public var level: Int?
    public var recommendation: TimingTrendRecommendation
    public var id: String { level.map(String.init) ?? "unknown" }
    public var label: String { level.map { "Lv.\($0)" } ?? "レベル不明" }
}

public struct TimingTrendAnalysis: Sendable {
    public var overall: TimingTrendRecommendation
    public var levels: [TimingLevelTrend]
}

/// Cross-song candidates for one environment's current settings. Does not mutate history.
public enum TimingTrendService {
    public static let maximumRecentPlaysPerChart = 10
    public static let minimumSongs = 3
    public static let minimumDetailCount = 500
    public static let minimumAbsoluteBias = 0.1
    public static let directionAgreementNumerator = 2
    public static let directionAgreementDenominator = 3

    public static func analyze(gameID: String, environment: PlayEnvironment, plays: [PlayRecord], charts: [Chart], specification: TimingSpecification?, environmentPolicy: TimingEnvironmentPolicy = .strict) -> TimingTrendAnalysis {
        let songIDs = Dictionary(charts.map { ($0.id, $0.songID) }, uniquingKeysWith: { first, _ in first })
        let eligible: [PlayRecord] = plays.filter { play in
            guard play.gameID == gameID, play.confirmed, songIDs[play.chartID] != nil,
                  let snapshot = play.environment, snapshot.id == environment.id,
                  snapshot.settings == environment.settings, let counts = play.timingCounts,
                  counts.fast >= 0, counts.slow >= 0, counts.fast + counts.slow > 0 else { return false }
            switch environmentPolicy {
            case .strict:
                return snapshot.device == environment.device && snapshot.audioOutput == environment.audioOutput && snapshot.conditions == environment.conditions
            case .ourNotesFixedDevice:
                return gameID == "our-notes" && TimingEnvironmentPolicy.isFixedDevice(snapshot.device)
            }
        }
        // Select once, then split the same sample by historical level. UUID resolves date ties only.
        var recent: [PlayRecord] = []
        let chartGroups = Dictionary(grouping: eligible, by: \.chartID)
        for rows in chartGroups.values {
            let ordered = rows.sorted { a, b in
                if a.orderDate == b.orderDate { return a.id.uuidString < b.id.uuidString }
                return a.orderDate > b.orderDate
            }
            recent.append(contentsOf: ordered.prefix(maximumRecentPlaysPerChart))
        }
        func evaluate(_ rows: [PlayRecord]) -> TimingTrendRecommendation {
            let statistics = StatisticsService.summarize(rows)
            let songs = Dictionary(grouping: rows, by: { songIDs[$0.chartID]! }).map { id, songRows in
                TimingSongEvidence(songID: id, statistics: StatisticsService.summarize(songRows))
            }.sorted { $0.songID.uuidString < $1.songID.uuidString }
            let songBias = songs.isEmpty ? nil : songs.reduce(0.0) { $0 + ($1.statistics.timingBias ?? 0) } / Double(songs.count)
            let matching = songs.filter { sameDirection($0.statistics.timingBias, songBias) }.count
            var result = TimingTrendRecommendation(current: environment.settings.noteTiming, proposed: nil, status: .unavailable, statistics: statistics, songBias: songBias, matchingSongCount: matching, songs: songs, reason: "")
            func hold(_ status: TimingTrendStatus, _ reason: String) -> TimingTrendRecommendation {
                result.status = status; result.reason = reason
                return result
            }
            guard let specification else { return hold(.unavailable, "単位・刻み・範囲・増減方向を確認してください。偏りは表示しますが、数値候補は保留します。") }
            guard (try? specification.validate()) != nil else { return hold(.unavailable, "タイミング仕様が不正です。") }
            if case .strict = environmentPolicy, !environment.isSpecified {
                return hold(.unavailable, "端末・音声出力・プレイ条件を確認してください。")
            }
            if case .ourNotesFixedDevice = environmentPolicy, !TimingEnvironmentPolicy.isFixedDevice(environment.device) {
                return hold(.unavailable, "現在の環境が固定端末と一致しません。")
            }
            guard environment.settings.isComplete, let current = environment.settings.noteTiming else {
                return hold(.unavailable, "ノーツ速度・ノーツタイミング・譜面位置・ミラーの現在値を確認してください。")
            }
            guard (try? specification.validateValue(current)) != nil else { return hold(.unavailable, "現在値が確認済みの範囲・変更刻みに合いません。") }
            guard songs.count >= minimumSongs else { return hold(.insufficientData, "同一環境・現在の設定で、異なる\(minimumSongs)曲以上の詳細結果が必要です。同じ曲の反復や別難易度は曲数を増やしません。") }
            guard statistics.timingNoteCount >= minimumDetailCount, let songBias, let bias = statistics.timingBias else {
                return hold(.insufficientData, "PERFECT＋GREATのFAST/SLOW詳細が計\(minimumDetailCount)件以上必要です。")
            }
            guard abs(songBias) >= minimumAbsoluteBias else { return hold(.maintain, "曲を均等に扱った偏りが10%未満です。現在値を維持して再計測してください。") }
            guard sameDirection(songBias, bias) else { return hold(.mixedDirections, "曲を均等に扱った偏りと、詳細件数で加重した偏りの方向が一致しません。") }
            guard matching * directionAgreementDenominator >= songs.count * directionAgreementNumerator else {
                return hold(.mixedDirections, "同方向の曲が3分の2未満です。曲によって偏りの方向が分かれています。")
            }
            let direction = songBias > 0 ? specification.slowCorrectionDirection : -specification.slowCorrectionDirection
            let proposed = current + specification.step * Decimal(direction)
            guard (try? specification.validateValue(proposed)) != nil else { return hold(.limit, "1ステップの変更が確認済みの許容範囲を超えます。") }
            result.proposed = proposed
            result.status = .candidate
            result.reason = "\(songBias > 0 ? "SLOW" : "FAST")寄りで、\(matching)/\(songs.count)曲が同方向です。他の設定を固定して1ステップだけ試し、変更後の結果で再確認してください。"
            return result
        }
        var overall = evaluate(recent)
        let levelGroups = Dictionary(grouping: recent, by: \.levelAtPlay)
        let unsortedLevels: [TimingLevelTrend] = levelGroups.map { level, rows in
            var result = evaluate(rows)
            if level == nil {
                result.proposed = nil; result.status = .unknownLevel
                result.reason = "プレイ時レベルが不明です。全体には含めますが、レベル別の数値候補は出しません。"
            }
            return TimingLevelTrend(level: level, recommendation: result)
        }
        let levels: [TimingLevelTrend] = unsortedLevels.sorted {
            switch ($0.level, $1.level) {
            case let (a?, b?): return a < b
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return false
            }
        }
        let supported = levels.filter { $0.recommendation.status == .candidate }
        let oppositeLevels = supported.contains { a in supported.contains { b in
            !sameDirection(a.recommendation.songBias, b.recommendation.songBias)
        } }
        let oppositeOverall = overall.status == .candidate && supported.contains {
            !sameDirection($0.recommendation.songBias, overall.songBias)
        }
        if oppositeLevels || oppositeOverall {
            overall.proposed = nil; overall.status = .mixedDirections
            overall.reason = "十分なデータがあるレベル帯で偏りの方向が分かれています（\(supported.map(\.label).joined(separator: "・"))）。全体の固定値変更は保留し、レベル別の根拠を確認してください。"
        }
        return TimingTrendAnalysis(overall: overall, levels: levels)
    }

    private static func sameDirection(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b else { return false }
        return (a > 0 && b > 0) || (a < 0 && b < 0)
    }
}
