import Foundation

// All recognition evidence is transient. Only the resolved PlayRecord is persisted.
public struct RecognizedValue: Equatable, Sendable {
    public var value: String
    public var confidence: Double
    public var sourceID: String
    public var region: NormalizedRect
    public var route: String
}

public struct RecognizedField: Identifiable, Sendable {
    public var id: String { field.rawValue }
    public var field: OCRField
    public var value: String?
    public var candidates: [RecognizedValue]
    public var confidence: Double { candidates.filter { $0.value == value }.map(\.confidence).max() ?? 0 }
    /// Vision commonly reports 0.3 even for correctly recognized Japanese titles.
    /// These readings need a catalog constraint; confidence alone cannot settle them.
    public var plausibleValues: [String] {
        values(minimum: 0.2)
    }
    public var competitiveValues: [String] {
        values(minimum: field == .title ? 0.2 : 0.5)
    }
    private func values(minimum: Double) -> [String] {
        let strongest = candidates.map(\.confidence).max() ?? 0
        return Array(Set(candidates.filter { $0.confidence >= minimum && $0.confidence + 0.100000001 >= strongest }.map(\.value))).sorted()
    }
}

public enum RecognitionEvidence {
    public static func fields(draft: ResultDraft, evidence: [OCRReadEvidence]) -> [RecognizedField] {
        OCRField.allCases.map { field in
            var candidates: [RecognizedValue] = []
            for read in evidence where read.fieldKey == field.evidenceKey {
                for tokens in read.variants {
                    guard !tokens.isEmpty, tokens.allSatisfy({ $0.confidence.isFinite && (0...1).contains($0.confidence) }),
                          let value = OCRCorrectionService.parsed(tokens.map(\.text).joined(separator: " "), field: field) else { continue }
                    candidates.append(.init(value: value, confidence: tokens.map(\.confidence).min() ?? 0,
                                            sourceID: read.sourceID, region: tokens[0].rect, route: read.route))
                }
            }
            return .init(field: field, value: field.value(in: draft), candidates: candidates)
        }
    }

    public static func apply(_ value: String, field: OCRField, to draft: inout ResultDraft) {
        switch field {
        case .title: draft.title = value
        case .difficulty: draft.difficulty = value
        case .level: draft.level = Int(value)
        case .score: draft.score = Int(value)
        case .combo: draft.combo = Int(value)
        case .achievement: draft.achievement = Achievement(rawValue: value) ?? .unknown
        default:
            let parts = field.rawValue.split(separator: ".")
            guard let judgment = Judgment(rawValue: String(parts[0])) else { return }
            var count = draft.judgments[judgment] ?? .init()
            if parts[1] == "total" { count.total = Int(value) }
            else if parts[1] == "fast" { count.fast = Int(value) }
            else { count.slow = Int(value) }
            draft.judgments[judgment] = count
        }
    }
}

public struct AutomaticChartCandidate: Identifiable, Sendable {
    public var id: UUID { chart.id }
    public var chart: Chart
    public var title: String
    public var similarity: Double
    public var exact: Bool
}

public enum AutomaticChartMatcher {
    /// Punctuation can be omitted by OCR. Confusable glyphs get a reduced edit cost,
    /// never an unconditional replacement that would merge distinct master entries.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
            .precomposedStringWithCompatibilityMapping.uppercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "ー" || $0 == "?" }
    }
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(normalized(lhs)), b = Array(normalized(rhs))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let confusables = [Set("IL1"), Set("O0"), Set("シツ"), Set("ソン"), Set("ロ口"), Set("工エ"), Set("カ力"), Set("ー一−-"), Set("タ夕")]
        var previous = (0...b.count).map(Double.init)
        for (i, x) in a.enumerated() {
            var row = [Double(i + 1)]
            for (j, y) in b.enumerated() {
                let cost: Double = x == y ? 0 : x == "?" || y == "?" ? 0.4 : confusables.contains(where: { $0.contains(x) && $0.contains(y) }) ? 0.25 : 1
                row.append(min(row[j] + 1, previous[j + 1] + 1, previous[j] + cost))
            }
            previous = row
        }
        return 1 - previous[b.count] / Double(max(a.count, b.count))
    }
    public static func candidates(title: String, difficulty: String, level: Int?, gameID: String, state: AppState) -> [AutomaticChartCandidate] {
        guard normalized(title).filter({ $0 != "?" }).count >= 2, !difficulty.isEmpty else { return [] }
        let allowed = ResultService.canonicalChartIDs(gameID: gameID, in: state)
        let charts = state.activeCharts(gameID: gameID).filter { (allowed?.contains($0.id) ?? true) && normalizedName($0.difficulty) == normalizedName(difficulty) }
        let all = charts.compactMap { chart -> AutomaticChartCandidate? in
            guard let song = state.song(for: chart), !song.provisional else { return nil }
            let exact = song.allNames.contains { normalizedName($0) == normalizedName(title) || normalized($0) == normalized(title) }
            let score = song.allNames.map { similarity(title, $0) }.max() ?? 0
            guard exact || score >= 0.78 else { return nil }
            return .init(chart: chart, title: song.title, similarity: exact ? 1 : score, exact: exact)
        }
        // A contradictory level must not redirect an exact title to a different song.
        let pool = all.contains(where: \.exact) ? all.filter(\.exact) : all
        return pool.filter { level == nil || $0.chart.level == nil || $0.chart.level == level }.sorted {
            $0.similarity == $1.similarity ? $0.id.uuidString < $1.id.uuidString : $0.similarity > $1.similarity
        }
    }
    public static func unique(_ candidates: [AutomaticChartCandidate]) -> AutomaticChartCandidate? {
        guard let first = candidates.first else { return nil }
        if candidates.count == 1 { return first }
        guard !candidates[1].exact, first.similarity >= 0.9, first.similarity - candidates[1].similarity >= 0.15 else { return nil }
        return first
    }
}

public struct RegistrationIssue: Identifiable, Equatable, Sendable {
    public var id: String { (field?.rawValue ?? "result") + reason }
    public var field: OCRField?
    public var reason: String
    public var candidates: [String]
    public init(field: OCRField? = nil, reason: String, candidates: [String] = []) { self.field = field; self.reason = reason; self.candidates = candidates }
}

public enum ResultIntegrity {
    public static func issues(_ draft: ResultDraft, chart: Chart?) -> [RegistrationIssue] {
        var result: [RegistrationIssue] = []
        if !["normal", "detail", "merged"].contains(draft.kind) { result.append(.init(reason: "対応する通常リザルト画面として確定できません。")) }
        if draft.score.map({ !(0...99_999_999).contains($0) }) ?? true { result.append(.init(field: .score, reason: "スコアが未取得、または通常の表示範囲を超えています。")) }
        if let level = draft.level, let expected = chart?.level, level != expected { result.append(.init(field: .level, reason: "レベルが正規マスター（Lv.\(expected)）と一致しません。")) }
        var total = 0, allTotals = true
        for judgment in Judgment.allCases {
            let c = draft.judgments[judgment] ?? .init()
            if let n = c.total { total += max(0, min(n, 1_000_000)) } else { allTotals = false }
            for (suffix, value) in [("total", c.total), ("fast", c.fast), ("slow", c.slow)] {
                if let value, !(0...1_000_000).contains(value) { result.append(.init(field: OCRField(rawValue: judgment.rawValue + "." + suffix), reason: "判定数の範囲が不正です。")) }
            }
            let timingCount = max(0, min(c.fast ?? 0, 1_000_000)) + max(0, min(c.slow ?? 0, 1_000_000))
            if let n = c.total, timingCount > n {
                result.append(.init(field: OCRField(rawValue: judgment.rawValue + ".total"), reason: "\(judgment.rawValue)のFAST＋SLOWが総数を超えています。"))
            }
            // With both views available, a difference outside PERFECT needs review.
            // This is a conservative registration gate, not a rule for filling totals.
            if draft.gameID == OurNotesCatalog.gameID, judgment != .perfect,
               let n = c.total, c.fast != nil, c.slow != nil, timingCount != n {
                for suffix in ["total", "fast", "slow"] {
                    result.append(.init(field: OCRField(rawValue: judgment.rawValue + "." + suffix), reason: "\(judgment.rawValue)の通常表示（\(n)）とFAST＋SLOW（\(timingCount)）が異なります。両画像のこの行を確認してください。"))
                }
            }
            if (draft.achievement == .ap && judgment != .perfect) || (draft.achievement.isFC && [.bad, .miss].contains(judgment)) {
                if [c.total, c.fast, c.slow].compactMap({ $0 }).contains(where: { $0 > 0 }) {
                    result.append(.init(field: .achievement, reason: "\(draft.achievement.label)表示と\(judgment.rawValue)の件数が矛盾しています。"))
                }
            }
        }
        if allTotals {
            if total == 0 { result.append(.init(reason: "判定合計が0件です。結果画面を確認してください。")) }
            if let expected = chart?.noteCount, total != expected { result.append(.init(reason: "判定合計\(total)がマスターの総ノーツ数\(expected)と一致しません。")) }
            if let combo = draft.combo, combo > total || (draft.achievement.isFC && combo != total) { result.append(.init(field: .combo, reason: "コンボ数が判定合計・達成表示と一致しません。")) }
        } else if let expected = chart?.noteCount {
            let observed = draft.judgments.values.reduce(0) { $0 + max(0, min($1.fast ?? 0, 1_000_000)) + max(0, min($1.slow ?? 0, 1_000_000)) }
            if observed > expected { result.append(.init(reason: "FAST＋SLOWの合計がマスターの総ノーツ数を超えています。")) }
        }
        if let combo = draft.combo, !(0...1_000_000).contains(combo) || (chart?.noteCount.map { combo > $0 } ?? false) { result.append(.init(field: .combo, reason: "コンボ数の範囲が不正です。")) }
        if draft.achievement.isFC, let combo = draft.combo, let expected = chart?.noteCount, combo != expected {
            result.append(.init(field: .combo, reason: "FC/APのコンボ数がマスターの総ノーツ数\(expected)と一致しません。"))
        }
        return result
    }
}

public struct AutomaticDateSelection: Sendable {
    public var playedAt: Date?
    public var context: PlayDateContext
    public static func resolve(_ evidence: [ScreenshotDateEvidence], now: Date = Date()) -> Self {
        let empty = Self(playedAt: nil, context: .init())
        guard !evidence.contains(where: \.hasConflict) else { return empty }
        let choices = ScreenshotDateChoice.choices(in: evidence).filter { $0.candidate.capturedAt >= Date(timeIntervalSince1970: 946684800) && $0.candidate.capturedAt <= now.addingTimeInterval(300) }
        guard let earliest = choices.first, let latest = choices.last, latest.candidate.capturedAt.timeIntervalSince(earliest.candidate.capturedAt) <= 60 else { return empty }
        let chosen = choices.first(where: { $0.imageKind == .normal }) ?? earliest
        return Self(playedAt: chosen.candidate.capturedAt, context: .init(selectedScreenshotDate: chosen.reference, playedAtSource: .screenshot))
    }
}

public enum RegistrationConfidenceLevel: String, Sendable { case high = "高信頼", medium = "項目確認", low = "全体確認" }
public struct RegistrationCheck: Sendable { public var label: String; public var passed: Bool; public var weight: Int }
public struct RegistrationAssessment: Sendable {
    public var draft: ResultDraft
    public var chartID: UUID?
    public var fields: [RecognizedField]
    public var chartCandidates: [AutomaticChartCandidate]
    public var issues: [RegistrationIssue]
    public var duplicateIDs: [UUID]
    public var checks: [RegistrationCheck]
    /// Evidence coverage index, not an estimated probability of correctness.
    public var confidenceScore: Int { checks.filter(\.passed).reduce(0) { $0 + $1.weight } }
    public var canAutomaticallyRegister: Bool { chartID != nil && issues.isEmpty && duplicateIDs.isEmpty }
    public var level: RegistrationConfidenceLevel {
        if canAutomaticallyRegister { return .high }
        return (chartID != nil || !chartCandidates.isEmpty) && draft.score != nil && issues.count <= 4 ? .medium : .low
    }
}

public enum AutomaticDuplicateDetection {
    public static func candidates(_ draft: ResultDraft, chartID: UUID, playedAt: Date?, state: AppState) -> [UUID] {
        state.plays.filter { play in
            guard play.chartID == chartID, play.gameID == draft.gameID else { return false }
            if play.fingerprints.contains(where: { $0.sha256 == draft.fingerprint.sha256 }) { return true }
            // Two trustworthy, well-separated capture dates can represent identical repeated plays.
            if let a = play.playedAt, let b = playedAt, abs(a.timeIntervalSince(b)) > 90 { return false }
            guard play.score == draft.score else { return false }
            var equal = 0
            for j in Judgment.allCases {
                let a = play.judgments[j] ?? .init(), b = draft.judgments[j] ?? .init()
                for (x, y) in [(a.total, b.total), (a.fast, b.fast), (a.slow, b.slow)] { if let x, let y, x == y { equal += 1 } }
            }
            return (draft.combo != nil && play.combo == draft.combo) || equal >= 3
        }.map(\.id)
    }
}

public enum AutomaticRegistrationService {
    public static func assess(_ input: ResultDraft, evidence: [OCRReadEvidence], state: AppState,
                              screenshotDates: [ScreenshotDateEvidence] = [], threshold: Double = 0.9,
                              confirmedFields: Set<OCRField> = [], selectedChartID: UUID? = nil) -> RegistrationAssessment {
        var draft = input
        let fields = RecognitionEvidence.fields(draft: draft, evidence: evidence)
        func read(_ field: OCRField) -> RecognizedField { fields.first { $0.field == field }! }
        var issues: [RegistrationIssue] = []
        var resolvedByMaster = Set<OCRField>()
        let requiredJudgments = Judgment.allCases.flatMap { judgment -> [OCRField] in
            let suffixes = draft.kind == "detail" ? ["fast", "slow"] : draft.kind == "merged" ? ["total", "fast", "slow"] : ["total"]
            return suffixes.compactMap { OCRField(rawValue: judgment.rawValue + "." + $0) }
        }
        let numericFields = [OCRField.score, .combo] + requiredJudgments
        for field in numericFields + [.difficulty, .level] where !confirmedFields.contains(field) {
            if read(field).competitiveValues.count == 1, let value = read(field).competitiveValues.first { RecognitionEvidence.apply(value, field: field, to: &draft) }
        }
        // Use original recognized titles, not the parser's provisional fuzzy substitution.
        let titles = confirmedFields.contains(.title) ? [draft.title] : read(.title).competitiveValues
        let readDifficulties = confirmedFields.contains(.difficulty) ? [draft.difficulty] : read(.difficulty).plausibleValues
        let readLevels = confirmedFields.contains(.level) ? draft.level.map { [String($0)] } ?? [] : read(.level).plausibleValues
        let difficulties = readDifficulties.isEmpty ? [draft.difficulty] : readDifficulties
        let levels: [Int?] = readLevels.isEmpty ? [draft.level] : readLevels.compactMap(Int.init).map(Optional.some)
        var matches: [AutomaticChartCandidate] = []
        for title in titles {
            for difficulty in difficulties {
                for level in levels {
                    for match in AutomaticChartMatcher.candidates(title: title, difficulty: difficulty, level: level, gameID: draft.gameID, state: state) {
                        if let index = matches.firstIndex(where: { $0.id == match.id }) {
                            if match.similarity > matches[index].similarity { matches[index] = match }
                        } else { matches.append(match) }
                    }
                }
            }
        }
        matches.sort { $0.similarity == $1.similarity ? $0.id.uuidString < $1.id.uuidString : $0.similarity > $1.similarity }
        var match = AutomaticChartMatcher.unique(matches)
        if let selectedChartID, let chart = state.activeCharts(gameID: draft.gameID).first(where: { $0.id == selectedChartID }),
           ResultService.canonicalChartIDs(gameID: draft.gameID, in: state)?.contains(chart.id) ?? true, let song = state.song(for: chart) {
            match = .init(chart: chart, title: song.title, similarity: 1, exact: true)
        }
        if let match {
            if confirmedFields.contains(.difficulty), normalizedName(draft.difficulty) != normalizedName(match.chart.difficulty) {
                issues.append(.init(field: .difficulty, reason: "確認した難易度と選択中の譜面が異なります。登録先を選び直してください。"))
            }
            draft.title = match.title; draft.difficulty = match.chart.difficulty
            if matches.count == 1, readDifficulties.contains(match.chart.difficulty),
               let level = match.chart.level, readLevels.contains(String(level)) {
                draft.level = level
                resolvedByMaster.formUnion([.difficulty, .level])
            }
            if draft.level == nil { draft.level = match.chart.level; resolvedByMaster.insert(.level) }
        } else {
            issues.append(.init(field: .title, reason: matches.isEmpty ? "楽曲・難易度・Lvを正規マスターに照合できません。" : "楽曲の候補が複数あります。", candidates: matches.map(\.title)))
        }
        // Only values actually seen by OCR may be considered. Exhaust every combination;
        // a catalog total can prove uniqueness, but never synthesize a missing digit/zero.
        if let noteCount = match?.chart.noteCount, draft.kind != "detail" {
            let totalFields = Judgment.allCases.compactMap { OCRField(rawValue: $0.rawValue + ".total") }
            let options = totalFields.map { field in confirmedFields.contains(field) ? field.value(in: draft).map { [$0] } ?? [] : read(field).plausibleValues }
            if options.allSatisfy({ !$0.isEmpty }), options.reduce(1, { min(513, $0 * $1.count) }) <= 512 {
                var solutions: [[String]] = []
                func search(_ index: Int, _ sum: Int, _ values: [String]) {
                    if index == options.count { if sum == noteCount { solutions.append(values) }; return }
                    for value in options[index] { if let n = Int(value), sum + n <= noteCount { search(index + 1, sum + n, values + [value]) } }
                }
                search(0, 0, [])
                if solutions.count == 1 {
                    for (index, field) in totalFields.enumerated() { RecognitionEvidence.apply(solutions[0][index], field: field, to: &draft); resolvedByMaster.insert(field) }
                }
            }
        }
        for field in numericFields + [.difficulty, .level] {
            guard !confirmedFields.contains(field), !resolvedByMaster.contains(field) else { continue }
            let r = read(field), values = r.competitiveValues
            if values.count != 1 || field.value(in: draft) == nil {
                issues.append(.init(field: field, reason: values.isEmpty ? "読み取れる値がありません。" : "複数のOCR候補があり、一意に確定できません。", candidates: values))
            } else {
                let supporting = r.candidates.filter { $0.value == values[0] }
                let confidence = supporting.map(\.confidence).max() ?? 0
                let sources = Set(supporting.filter { $0.confidence >= 0.75 }.map(\.sourceID))
                if confidence < threshold && sources.count < 2 { issues.append(.init(field: field, reason: "読取信頼度が低く、独立した根拠で確認できません。", candidates: values)) }
                if values[0].contains(where: { $0 == "6" || $0 == "9" }),
                   supporting.allSatisfy({ $0.route == "inverted-padded" }) {
                    issues.append(.init(field: field, reason: "6/9を画像変換後だけで認識しました。元画像との照合が必要です。", candidates: values))
                }
            }
        }
        if !confirmedFields.contains(.achievement) {
            let achievement = read(.achievement)
            if achievement.competitiveValues.count == 1, let value = achievement.competitiveValues.first,
               achievement.candidates.filter({ $0.value == value }).map(\.confidence).max() ?? 0 >= threshold {
                RecognitionEvidence.apply(value, field: .achievement, to: &draft)
            } else if achievement.competitiveValues.count > 1 || draft.achievement == .fc || draft.achievement == .ap {
                issues.append(.init(field: .achievement, reason: "FC/AP表示を確定できません。", candidates: achievement.competitiveValues))
            }
            if draft.achievement == .unknown || draft.achievement == .none {
                let hasBreak = [Judgment.bad, .miss].contains { j in
                    let c = draft.judgments[j] ?? .init()
                    return [c.total, c.fast, c.slow].compactMap { $0 }.contains { $0 > 0 }
                }
                if hasBreak { draft.achievement = .none }
                else { issues.append(.init(field: .achievement, reason: "FC/APの表示が読み取れません。", candidates: ["none", "fc", "ap"])) }
            }
        }
        let integrity = ResultIntegrity.issues(draft, chart: match?.chart)
        let unresolvedFields = Set(issues.compactMap(\.field))
        for issue in integrity {
            let related = integrity.filter { $0.reason == issue.reason }.compactMap(\.field)
            // If one member of a conflicting row is already unreadable/ambiguous,
            // ask about that member first. Revalidate the whole row after correction.
            if related.contains(where: { unresolvedFields.contains($0) }),
               let field = issue.field, !unresolvedFields.contains(field) { continue }
            issues.append(issue)
        }
        let date = AutomaticDateSelection.resolve(screenshotDates)
        let duplicateIDs = match.map { AutomaticDuplicateDetection.candidates(draft, chartID: $0.id, playedAt: date.playedAt, state: state) } ?? []
        if !duplicateIDs.isEmpty { issues.append(.init(reason: "既に登録済みの可能性があります。既存プレイへの統合か、別プレイかを確認してください。")) }
        var uniqueIssues: [RegistrationIssue] = []
        for issue in issues where !uniqueIssues.contains(where: { $0.id == issue.id }) { uniqueIssues.append(issue) }
        let checks: [RegistrationCheck] = [
            .init(label: "正規マスター照合", passed: match != nil, weight: 25),
            .init(label: "難易度・レベル", passed: !issues.contains { $0.field == .difficulty || $0.field == .level }, weight: 15),
            .init(label: "スコア・コンボ", passed: !issues.contains { $0.field == .score || $0.field == .combo }, weight: 15),
            .init(label: "判定数・FAST/SLOW", passed: !issues.contains { $0.field?.rawValue.contains(".") == true } && ResultIntegrity.issues(draft, chart: match?.chart).isEmpty, weight: 20),
            .init(label: "FC/AP", passed: !issues.contains { $0.field == .achievement }, weight: 10),
            .init(label: "総ノーツ数", passed: match?.chart.noteCount != nil && Judgment.allCases.allSatisfy { draft.judgments[$0]?.total != nil } && ResultIntegrity.issues(draft, chart: match?.chart).isEmpty, weight: 5),
            .init(label: "日時", passed: date.playedAt != nil, weight: 5), .init(label: "重複なし", passed: duplicateIDs.isEmpty, weight: 5)
        ]
        draft.issues = uniqueIssues.map { ($0.field.map { $0.label + "：" } ?? "") + $0.reason }
        return .init(draft: draft, chartID: match?.id, fields: fields, chartCandidates: matches, issues: uniqueIssues, duplicateIDs: duplicateIDs, checks: checks)
    }
}
