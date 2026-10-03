import Foundation

public struct SummaryStatistics: Sendable {
    public var playCount: Int
    public var scoreMean: Double?
    public var scoreMedian: Double?
    public var scoreStandardDeviation: Double?
    public var scoreMinimum: Int?
    public var scoreMaximum: Int?
    public var achievementSampleCount: Int
    public var fcRate: Double?
    public var apRate: Double?
    public var judgmentSampleCount: Int
    public var judgmentNoteCount: Int
    public var judgmentRates: [Judgment: Double]
    public var timingSampleCount: Int
    public var timingNoteCount: Int
    public var fastRate: Double?
    public var slowRate: Double?
    public var timingBias: Double?
}

public struct StatisticsGroup: Identifiable, Sendable {
    public var id: String
    public var label: String
    public var statistics: SummaryStatistics
}
public enum Grouping: String, CaseIterable, Sendable {
    case difficulty, level
    public var label: String { self == .difficulty ? "難易度別" : "プレイ時レベル別" }
}

public enum StatisticsService {
    public static func summarize(_ plays: [PlayRecord]) -> SummaryStatistics {
        let scores = plays.map { Double($0.score) }.sorted()
        let mean = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
        let median: Double? = scores.isEmpty ? nil : (scores[(scores.count - 1) / 2] + scores[scores.count / 2]) / 2
        let std: Double? = scores.count > 1 ? sqrt(scores.reduce(0) { $0 + pow($1 - mean!, 2) } / Double(scores.count - 1)) : nil
        let achieved = plays.filter { $0.achievement != .unknown }
        let knownJudgments = plays.filter { p in Judgment.allCases.allSatisfy { p.judgments[$0]?.total != nil } }
        let totals = Dictionary(uniqueKeysWithValues: Judgment.allCases.map { j in (j, knownJudgments.reduce(0) { $0 + ($1.judgments[j]?.total ?? 0) }) })
        let notes = totals.values.reduce(0, +)
        let timing = plays.compactMap(\.timingCounts).filter { $0.fast + $0.slow > 0 }
        let fast = timing.reduce(0) { $0 + $1.fast }, slow = timing.reduce(0) { $0 + $1.slow }, timingNotes = fast + slow
        return SummaryStatistics(
            playCount: plays.count, scoreMean: mean, scoreMedian: median, scoreStandardDeviation: std,
            scoreMinimum: plays.map(\.score).min(), scoreMaximum: plays.map(\.score).max(),
            achievementSampleCount: achieved.count,
            fcRate: achieved.isEmpty ? nil : Double(achieved.filter { $0.achievement.isFC }.count) / Double(achieved.count),
            apRate: achieved.isEmpty ? nil : Double(achieved.filter { $0.achievement.isAP }.count) / Double(achieved.count),
            judgmentSampleCount: knownJudgments.count, judgmentNoteCount: notes,
            judgmentRates: notes > 0 ? totals.mapValues { Double($0) / Double(notes) } : [:],
            timingSampleCount: timing.count, timingNoteCount: timingNotes,
            fastRate: timingNotes > 0 ? Double(fast) / Double(timingNotes) : nil,
            slowRate: timingNotes > 0 ? Double(slow) / Double(timingNotes) : nil,
            timingBias: timingNotes > 0 ? Double(slow - fast) / Double(timingNotes) : nil)
    }

    public static func grouped(_ plays: [PlayRecord], by grouping: Grouping) -> [StatisticsGroup] {
        let groups = Dictionary(grouping: plays) { p in grouping == .difficulty ? p.difficultyAtPlay : p.levelAtPlay.map(String.init) ?? "不明" }
        return groups.map { key, rows in StatisticsGroup(id: key, label: grouping == .level && key != "不明" ? "Lv.\(key)" : key, statistics: summarize(rows)) }.sorted { a, b in
            if grouping == .level { return (Int(a.id) ?? Int.max) < (Int(b.id) ?? Int.max) }
            let order = ["EASY", "NORMAL", "HARD", "EXPERT", "SPECIAL", "MASTER"]
            let ai = order.firstIndex(of: a.id.uppercased()) ?? Int.max, bi = order.firstIndex(of: b.id.uppercased()) ?? Int.max
            return ai == bi ? a.id < b.id : ai < bi
        }
    }
}

public struct LibraryProgress: Sendable {
    public var charts: Int
    public var played: Int
    public var fc: Int
    public var ap: Int
    public var unplayed: Int { charts - played }
    public var notFC: Int { charts - fc }
    public var notAP: Int { charts - ap }
    public static func calculate(charts: [Chart], plays: [PlayRecord]) -> LibraryProgress {
        let groups = Dictionary(grouping: plays, by: \.chartID)
        return LibraryProgress(charts: charts.count, played: charts.filter { !(groups[$0.id] ?? []).isEmpty }.count, fc: charts.filter { (groups[$0.id] ?? []).contains { $0.achievement.isFC } }.count, ap: charts.filter { (groups[$0.id] ?? []).contains { $0.achievement.isAP } }.count)
    }
}

public struct TimingSpecification: Codable, Equatable, Sendable {
    public var parameter: String
    public var unit: String
    public var step: Decimal
    public var minimum: Decimal
    public var maximum: Decimal
    /// +1 means increase the value when SLOW dominates, -1 means decrease.
    public var slowCorrectionDirection: Int
    public init(parameter: String = "ノーツタイミング", unit: String, step: Decimal, minimum: Decimal, maximum: Decimal, slowCorrectionDirection: Int) {
        self.parameter = parameter; self.unit = unit; self.step = step; self.minimum = minimum; self.maximum = maximum; self.slowCorrectionDirection = slowCorrectionDirection
    }
    public func validate() throws {
        guard parameter == "ノーツタイミング", !unit.isEmpty, step > 0, minimum < maximum, step <= maximum - minimum, slowCorrectionDirection == 1 || slowCorrectionDirection == -1 else { throw CoreError.invalid("タイミング仕様の対象・単位・刻み・範囲・増減方向を確認してください。") }
    }
    public func validateValue(_ value: Decimal) throws {
        try validate()
        guard !value.isNaN, value >= minimum && value <= maximum else { throw CoreError.invalid("ノーツタイミングが確認済みの許容範囲外です。") }
        var steps = (value - minimum) / step
        var integral = Decimal()
        NSDecimalRound(&integral, &steps, 0, .plain)
        guard steps == integral else { throw CoreError.invalid("ノーツタイミングは\(decimalString(step))刻みで入力してください。") }
    }
}
public struct TimingRecommendation: Sendable {
    public var current: Decimal?
    public var proposed: Decimal?
    public var playCount: Int
    public var noteCount: Int
    public var bias: Double?
    public var reason: String
}
public enum TimingEnvironmentPolicy: Equatable, Sendable {
    case strict, ourNotesFixedDevice
    public static let fixedDeviceName = "M2 iPad Pro 11インチ"
    public static func isFixedDevice(_ device: String) -> Bool {
        let name = normalizedName(device)
        // Legacy blank snapshots belong to the user's confirmed fixed device.
        return name.isEmpty || [fixedDeviceName, "M2 iPad Pro 11", "iPad Pro 11インチ (M2)", "iPad Pro 11 (M2)"].contains { normalizedName($0) == name }
    }
}
public enum TimingService {
    /// Legacy chart-specific calculation. Current app candidates use TimingTrendService.
    public static func recommend(chartID: UUID, environment: PlayEnvironment, plays: [PlayRecord], specification: TimingSpecification?, environmentPolicy: TimingEnvironmentPolicy = .strict) -> TimingRecommendation {
        let eligible = plays.filter { p in
            guard p.chartID == chartID, p.confirmed, let snapshot = p.environment, snapshot.id == environment.id, snapshot.settings == environment.settings, let counts = p.timingCounts else { return false }
            switch environmentPolicy {
            case .strict:
                guard snapshot.device == environment.device, snapshot.audioOutput == environment.audioOutput, snapshot.conditions == environment.conditions else { return false }
            case .ourNotesFixedDevice:
                guard p.gameID == "our-notes", TimingEnvironmentPolicy.isFixedDevice(snapshot.device) else { return false }
            }
            return counts.fast + counts.slow > 0
        }.sorted { $0.orderDate > $1.orderDate }
        let recent = Array(eligible.prefix(10))
        func hold(_ reason: String, rows: [PlayRecord]? = nil) -> TimingRecommendation {
            let rows = rows ?? recent
            let s = StatisticsService.summarize(rows)
            return TimingRecommendation(current: environment.settings.noteTiming, proposed: nil, playCount: rows.count, noteCount: s.timingNoteCount, bias: s.timingBias, reason: reason)
        }
        guard let specification else { return hold("プリセットの単位・刻み・範囲・増減方向が未確認です。数値候補は保留し、同じ設定で集めた傾向を表示します。") }
        guard (try? specification.validate()) != nil else { return hold("タイミング仕様が不正です。") }
        if case .strict = environmentPolicy, !environment.isSpecified { return hold("端末・音声出力・プレイ条件・現在の設定値を入力してください。") }
        guard environment.settings.isComplete, let current = environment.settings.noteTiming else { return hold("ノーツ速度・ノーツタイミング・譜面位置・ミラーの現在値を確認してください。設定スクショからも保存できます。") }
        guard current >= specification.minimum && current <= specification.maximum else { return hold("現在値がプリセットの許容範囲外です。") }
        guard (try? specification.validateValue(current)) != nil else { return hold("現在値が確認済みの変更刻みに合いません。ゲームの設定値を確認してください。") }
        guard recent.count >= 3 else { return hold("同一譜面・同一環境・同一設定の詳細結果が3プレイ以上必要です。", rows: recent) }
        let stats = StatisticsService.summarize(recent)
        guard stats.timingNoteCount >= 500, let bias = stats.timingBias else { return hold("FAST/SLOWの合計が500件以上必要です。", rows: recent) }
        guard abs(bias) >= 0.1 else { return hold("偏りが10%未満です。現在の設定を維持して再計測してください。", rows: recent) }
        let sameDirection = recent.filter { p in let c = p.timingCounts!; return bias > 0 ? c.slow > c.fast : c.fast > c.slow }.count
        guard sameDirection * 3 >= recent.count * 2 else { return hold("プレイ間で偏りの方向が揃っていません。", rows: recent) }
        let direction = bias > 0 ? specification.slowCorrectionDirection : -specification.slowCorrectionDirection
        let proposed = current + specification.step * Decimal(direction)
        guard proposed >= specification.minimum && proposed <= specification.maximum else { return hold("1ステップの変更が許容範囲を超えます。", rows: recent) }
        return TimingRecommendation(current: current, proposed: proposed, playCount: recent.count, noteCount: stats.timingNoteCount, bias: bias, reason: "\(bias > 0 ? "SLOW" : "FAST")側の偏りがあり、\(sameDirection)/\(recent.count)プレイで方向が一致しています。譜面位置などを固定して1ステップ変更し、再計測してください。")
    }
}
