import Foundation

/// Regions use normalized coordinates with their origin at the top left.
public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public func validate() throws {
        guard [x, y, width, height].allSatisfy(\.isFinite), x >= 0, y >= 0, width > 0, height > 0, x + width <= 1.00001, y + height <= 1.00001 else { throw CoreError.invalid("プリセットの読取領域が不正です。") }
    }
}
public struct GamePreset: Codable, Equatable, Sendable, Identifiable {
    public var formatVersion: Int
    public var id: String
    public var version: Int
    public var gameId: String
    public var name: String
    public var parserId: String
    public var aspectRatio: Double
    public var aspectTolerance: Double
    public var confidenceThreshold: Double
    public var regions: [String: NormalizedRect]
    public var timing: TimingSpecification?
    public func validate() throws {
        guard formatVersion == 1, !id.isEmpty, !gameId.isEmpty, version > 0, parserId == "our-notes-v1", aspectRatio > 0, aspectTolerance >= 0, aspectTolerance <= 0.1, (0.5...1).contains(confidenceThreshold) else { throw CoreError.invalid("未対応または不正な解析プリセットです。") }
        let required = ["title", "difficulty", "score", "combo", "achievement", "timingHeader", "settingsMarker", "noteSpeed", "noteTiming", "chartPosition", "mirror"] + Judgment.allCases.flatMap { [$0.rawValue + ".total", $0.rawValue + ".fast", $0.rawValue + ".slow"] }
        guard required.allSatisfy({ regions[$0] != nil }) else { throw CoreError.invalid("解析プリセットに必要な読取領域がありません。") }
        try regions.values.forEach { try $0.validate() }; try timing?.validate()
    }
}

public struct OCRToken: Codable, Equatable, Sendable {
    public var text: String
    public var confidence: Double
    public var rect: NormalizedRect
    public init(text: String, confidence: Double = 1, rect: NormalizedRect = .init(x: 0, y: 0, width: 1, height: 1)) { self.text = text; self.confidence = confidence; self.rect = rect }
}
public struct ResultDraft: Identifiable, Sendable {
    public var id = UUID()
    public var gameID: String
    public var presetID: String
    public var presetVersion: Int
    public var title: String
    public var difficulty: String
    public var level: Int?
    public var score: Int?
    public var combo: Int?
    public var achievement: Achievement
    public var judgments: [Judgment: JudgmentCount]
    public var fingerprint: SourceFingerprint
    public var issues: [String]
    public var kind: String
    public init(gameID: String, presetID: String, presetVersion: Int, title: String, difficulty: String, level: Int?, score: Int?, combo: Int?, achievement: Achievement, judgments: [Judgment: JudgmentCount], fingerprint: SourceFingerprint, issues: [String] = [], kind: String) {
        self.gameID = gameID; self.presetID = presetID; self.presetVersion = presetVersion; self.title = title; self.difficulty = difficulty; self.level = level; self.score = score; self.combo = combo; self.achievement = achievement; self.judgments = judgments; self.fingerprint = fingerprint; self.issues = issues; self.kind = kind
    }
    public func validateForSave() throws {
        guard kind != "unsupported-assist" else { throw CoreError.invalid("アシストモードは対応対象外です。") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !difficulty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let score, (0...Int(Int32.max)).contains(score) else { throw CoreError.invalid("楽曲名・難易度・0以上のスコア（32bit整数の範囲）が必要です。") }
        guard level.map({ $0 > 0 }) ?? true, combo.map({ (0...1_000_000).contains($0) }) ?? true else { throw CoreError.invalid("レベル・コンボが不正です。") }
        for count in judgments.values {
            guard [count.total, count.fast, count.slow].compactMap({ $0 }).allSatisfy({ (0...1_000_000).contains($0) }) else { throw CoreError.invalid("判定数には0以上・100万以下の整数を入力してください。") }
            if let total = count.total, let fast = count.fast, let slow = count.slow, fast + slow > total { throw CoreError.invalid("FAST/SLOWが判定総数を超えています。") }
        }
        func hasCount(_ j: Judgment) -> Bool { guard let c = judgments[j] else { return false }; return [c.total, c.fast, c.slow].compactMap { $0 }.contains { $0 > 0 } }
        if achievement == .ap && Judgment.allCases.filter({ $0 != .perfect }).contains(where: hasCount) { throw CoreError.invalid("AP表示と判定数が矛盾しています。") }
        if achievement.isFC && [.bad, .miss].contains(where: hasCount) { throw CoreError.invalid("FC表示と判定数が矛盾しています。") }
        if Judgment.allCases.allSatisfy({ judgments[$0]?.total != nil }), let combo {
            let total = judgments.values.reduce(0) { $0 + ($1.total ?? 0) }
            if combo > total { throw CoreError.invalid("コンボが判定総数を超えています。") }
        }
    }
}

public enum OurNotesParser {
    public static func result(fields: [String: [OCRToken]], preset: GamePreset, fingerprint: SourceFingerprint, knownTitles: [String], evidence: [OCRReadEvidence] = []) -> ResultDraft {
        func text(_ key: String) -> String { (fields[key] ?? []).map(\.text).joined(separator: " ") }
        func integer(_ key: String) -> Int? {
            let value = text(key).precomposedStringWithCompatibilityMapping
            guard !value.contains("-"), !value.contains("−") else { return nil }
            let digits = value.replacingOccurrences(of: ",", with: "").filter { !$0.isWhitespace }
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }; return Int(digits)
        }
        var title = text("title").trimmingCharacters(in: .whitespacesAndNewlines)
        var issues: [String] = []
        let exact = knownTitles.filter { normalizedName($0) == normalizedName(title) }
        if let unique = Set(exact).count == 1 ? exact.first : nil { title = unique }
        else if !title.isEmpty {
            let candidates = knownTitles.map { ($0, similarity(normalizedName(title), normalizedName($0))) }.sorted { $0.1 > $1.1 }
            if let best = candidates.first, best.1 >= 0.66, candidates.count == 1 || best.1 - candidates[1].1 > 0.15 {
                title = best.0; issues.append("曲名をマスタ候補で補正しました。画像と確認してください。")
            }
        }
        let difficultyText = text("difficulty").uppercased().precomposedStringWithCompatibilityMapping
        let difficulties = ["EXPERT", "SPECIAL", "MASTER", "NORMAL", "HARD", "EASY"]
        let difficulty = difficulties.first(where: { difficultyText.contains($0) }) ?? ""
        let level = difficultyText.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.last
        let detailed = text("timingHeader").uppercased().contains("FAST") && text("timingHeader").uppercased().contains("SLOW")
        let achievementText = normalizedName(text("achievement"))
        var achievement: Achievement = achievementText.contains("ALLPERFECT") ? .ap : achievementText.contains("FULLCOMBO") ? .fc : .unknown
        var counts: [Judgment: JudgmentCount] = [:]
        for j in Judgment.allCases {
            counts[j] = detailed ? JudgmentCount(fast: integer(j.rawValue + ".fast"), slow: integer(j.rawValue + ".slow")) : JudgmentCount(total: integer(j.rawValue + ".total"))
        }
        if achievement == .unknown, [Judgment.bad, .miss].contains(where: { j in let c = counts[j]!; return [c.total, c.fast, c.slow].compactMap { $0 }.contains { $0 > 0 } }) { achievement = .none }
        if achievement == .unknown { issues.append("FC/AP表示を確認してください。") }
        let keys = ["title", "difficulty", "score", "combo"] + Judgment.allCases.flatMap { detailed ? [$0.rawValue + ".fast", $0.rawValue + ".slow"] : [$0.rawValue + ".total"] }
        for key in keys {
            let tokens = fields[key] ?? []
            if key.contains("."), text(key).contains("-") || text(key).contains("−") { issues.append("\(key)：判定数には0以上の整数が必要です。") }
            if tokens.isEmpty { issues.append("\(key)：読み取れませんでした。") }
            else if tokens.contains(where: { $0.confidence < preset.confidenceThreshold }) { issues.append("\(key)：読取信頼度が低いため確認してください。") }
            if key != "title" && key != "difficulty" && integer(key) == nil { issues.append("\(key)：整数として読めませんでした。") }
        }
        if title.isEmpty || difficulty.isEmpty || level == nil { issues.append("楽曲・難易度・レベルを確認してください。") }
        var result = ResultDraft(gameID: preset.gameId, presetID: preset.id, presetVersion: preset.version, title: title, difficulty: difficulty, level: level, score: integer("score"), combo: integer("combo"), achievement: achievement, judgments: counts, fingerprint: fingerprint, issues: issues, kind: hasAssistModeLabel(["mode", "difficulty", "achievement"].flatMap { fields[$0]?.map(\.text) ?? [] }) ? "unsupported-assist" : detailed ? "detail" : "normal")
        for field in OCRCorrectionService.sixNineAmbiguousFields(in: evidence) {
            result.issues.append("\(field.label)：6/9判定曖昧。OCR根拠と画像を照合して手動確認してください。")
        }
        do { try result.validateForSave() } catch { result.issues.append(error.localizedDescription) }
        return result
    }

    /// Explicit mode labels only; ordinary song titles containing these letters are not modes.
    public static func hasAssistModeLabel(_ labels: [String]) -> Bool {
        labels.contains { label in
            let text = normalizedName(label)
            return text == "ASSIST" || text == "アシスト" || text.contains("ASSISTMODE") || text.contains("アシストモード")
        }
    }

    public static func settings(fields: [String: [OCRToken]]) -> PlaySettings {
        func value(_ key: String) -> String { (fields[key] ?? []).map(\.text).joined().precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines) }
        func decimal(_ key: String) -> Decimal? { let text = value(key); guard text.range(of: "^[+-]?[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil else { return nil }; return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) }
        let mirror = value("mirror").uppercased()
        return PlaySettings(noteSpeed: decimal("noteSpeed"), noteTiming: decimal("noteTiming"), chartPosition: decimal("chartPosition"), mirror: mirror == "OFF" ? false : mirror == "ON" ? true : nil)
    }

    public static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs), b = Array(rhs)
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var previous = Array(0...b.count)
        for (i, character) in a.enumerated() {
            var row = [i + 1]
            for (j, other) in b.enumerated() { row.append(min(row[j] + 1, previous[j + 1] + 1, previous[j] + (character == other ? 0 : 1))) }
            previous = row
        }
        return 1 - Double(previous.last!) / Double(max(a.count, b.count))
    }
}
