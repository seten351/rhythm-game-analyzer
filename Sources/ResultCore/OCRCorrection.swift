import Foundation

/// Correction evidence is session-only. None of these types is part of AppState or Codable storage.
public enum OCRField: String, CaseIterable, Sendable {
    case title, difficulty, level, score, combo, achievement
    case perfectTotal = "PERFECT.total", perfectFast = "PERFECT.fast", perfectSlow = "PERFECT.slow"
    case greatTotal = "GREAT.total", greatFast = "GREAT.fast", greatSlow = "GREAT.slow"
    case goodTotal = "GOOD.total", goodFast = "GOOD.fast", goodSlow = "GOOD.slow"
    case badTotal = "BAD.total", badFast = "BAD.fast", badSlow = "BAD.slow"
    case missTotal = "MISS.total", missFast = "MISS.fast", missSlow = "MISS.slow"

    public var isNumeric: Bool { self != .title && self != .difficulty && self != .achievement }
    public var evidenceKey: String { self == .level ? "difficulty" : rawValue }
    public var label: String {
        switch self {
        case .title: return "曲名"
        case .difficulty: return "難易度"
        case .level: return "レベル"
        case .score: return "スコア"
        case .combo: return "コンボ"
        case .achievement: return "達成"
        default: return rawValue.replacingOccurrences(of: ".total", with: " 総数").replacingOccurrences(of: ".fast", with: " FAST").replacingOccurrences(of: ".slow", with: " SLOW")
        }
    }
    public func value(in draft: ResultDraft) -> String? {
        switch self {
        case .title: return draft.title.isEmpty ? nil : draft.title
        case .difficulty: return draft.difficulty.isEmpty ? nil : draft.difficulty
        case .level: return draft.level.map(String.init)
        case .score: return draft.score.map(String.init)
        case .combo: return draft.combo.map(String.init)
        case .achievement: return draft.achievement == .unknown ? nil : draft.achievement.rawValue
        default:
            let parts = rawValue.split(separator: ".")
            guard let judgment = Judgment(rawValue: String(parts[0])), let count = draft.judgments[judgment] else { return nil }
            return (parts[1] == "total" ? count.total : parts[1] == "fast" ? count.fast : count.slow).map(String.init)
        }
    }
}

public struct OCRReadEvidence: Equatable, Sendable {
    public var sourceID: String
    public var fieldKey: String
    public var route: String
    /// Each observation contains Vision's top three alternatives, in rank order.
    public var observations: [[OCRToken]]
    public init(sourceID: String, fieldKey: String, route: String, observations: [[OCRToken]]) {
        self.sourceID = sourceID; self.fieldKey = fieldKey; self.route = route; self.observations = observations
    }
    public var bestTokens: [OCRToken] { observations.compactMap(\.first) }
    public var variants: [[OCRToken]] {
        let best = bestTokens
        guard best.count == observations.count, !best.isEmpty else { return [] }
        var result = [best]
        // Change one observed glyph/string at a time. Never concatenate alternatives as additional digits.
        for (index, alternatives) in observations.enumerated() {
            for alternate in alternatives.dropFirst().prefix(2) {
                var variant = best; variant[index] = alternate; result.append(variant)
            }
        }
        return result
    }
}

public struct OCRCorrectionCandidate: Identifiable, Equatable, Sendable {
    public var id: String
    public var field: OCRField
    public var value: String
    public var tokens: [OCRToken]
    public var sourceID: String
    public var route: String
    public var fromCatalog: Bool
    public var confidence: Double { tokens.map(\.confidence).min() ?? 0 }
}

public struct OCRCorrectionField: Identifiable, Equatable, Sendable {
    public var id: String { field.rawValue }
    public var field: OCRField
    public var isSixNineAmbiguous: Bool { reasons.contains("6/9判定曖昧") }
    public var originalValue: String?
    public var reasons: [String]
    public var candidates: [OCRCorrectionCandidate]
    /// Every observed conflicting read, including repeated values from retries; session-only.
    public var sixNineEvidence: [OCRCorrectionCandidate] = []
}

public struct OCRCorrectionContext: Equatable, Sendable {
    public var fields: [OCRCorrectionField]
    public init(fields: [OCRCorrectionField]) { self.fields = fields }
}

public struct OCRCorrectionSelection: Equatable, Sendable {
    public var fieldID: String
    public var candidateID: String
    public init(fieldID: String, candidateID: String) { self.fieldID = fieldID; self.candidateID = candidateID }
}

public enum OCRCorrectionService {
    /// Probe actual pixels even when Vision's first pass supplies just one 6/9 reading.
    public static func shouldRetrySixNine(for field: OCRField, in evidence: [OCRReadEvidence]) -> Bool {
        guard field.isNumeric else { return false }
        return evidence.filter { $0.fieldKey == field.evidenceKey }.contains { read in
            guard let value = parsed(read.bestTokens.map(\.text).joined(separator: " "), field: field) else { return false }
            return value.contains("6") || value.contains("9")
        }
    }

    public static func context(draft: ResultDraft, evidence: [OCRReadEvidence], knownTitles: [String], confidenceThreshold: Double, excluded: Set<OCRField> = []) -> OCRCorrectionContext {
        let invalidDraft = (try? draft.validateForSave()) == nil
        var output: [OCRCorrectionField] = []
        for field in OCRField.allCases where !excluded.contains(field) {
            let reads = evidence.filter { $0.fieldKey == field.evidenceKey }
            // No read for this layout/field means no evidence, rather than an invitation to infer a value.
            guard !reads.isEmpty else { continue }
            let current = field.value(in: draft)
            var candidates: [OCRCorrectionCandidate] = []
            for read in reads {
                for variant in read.variants {
                    let text = variant.map(\.text).joined(separator: " ")
                    if let value = parsed(text, field: field) {
                        append(value, field: field, tokens: variant, read: read, catalog: false, to: &candidates)
                    }
                    if field == .title, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let normalizedText = normalizedName(text)
                        let matches: [(title: String, similarity: Double)] = Set(knownTitles).map { title in
                            (title: title, similarity: OurNotesParser.similarity(normalizedText, normalizedName(title)))
                        }
                        let eligible = matches.filter { $0.similarity >= 0.66 }
                        let ranked = eligible.sorted { lhs, rhs in
                            if lhs.similarity == rhs.similarity { return lhs.title < rhs.title }
                            return lhs.similarity > rhs.similarity
                        }
                        for match in ranked.prefix(5) { append(match.title, field: field, tokens: variant, read: read, catalog: true, to: &candidates) }
                    }
                }
            }
            let sixNine = sixNineCandidates(for: field, in: reads)
            let primary = reads.first?.bestTokens ?? []
            var reasons: [String] = []
            if !sixNine.isEmpty { reasons.append("6/9判定曖昧") }
            if current == nil { reasons.append("未読取・形式未確定") }
            if primary.contains(where: { $0.confidence < confidenceThreshold }) { reasons.append("低信頼度") }
            if candidates.count > 1 { reasons.append("複数の読取候補") }
            if field == .title, let current, normalizedName(primary.map(\.text).joined(separator: " ")) != normalizedName(current) { reasons.append("マスタ候補による曲名補正") }
            if invalidDraft { reasons.append("解析値の整合性を確認") }
            if primary.isEmpty { reasons.append("OCR根拠なし") }
            guard !reasons.isEmpty else { continue }
            // Keep original OCR candidates first; catalog values never displace every OCR value.
            if !sixNine.isEmpty {
                // Never add a swapped digit, or displace half a conflict pair at the candidate cap.
                var distinct: [OCRCorrectionCandidate] = []
                for candidate in sixNine where !distinct.contains(where: { $0.value == candidate.value }) { distinct.append(candidate) }
                candidates = distinct.count <= 5 ? distinct : []
                if distinct.count > 5 { reasons.append("6/9候補が多いため画像と照合して手入力してください") }
            } else {
                candidates = Array((candidates.filter { !$0.fromCatalog } + candidates.filter(\.fromCatalog)).prefix(5))
            }
            for index in candidates.indices { candidates[index].id = "c\(output.count)_\(index)" }
            output.append(.init(field: field, originalValue: current, reasons: reasons, candidates: candidates, sixNineEvidence: sixNine))
        }
        return .init(fields: output)
    }

    /// Competitive OCR evidence only: candidates within 0.10 of the strongest read for this source/region.
    /// The original and retry remain evidence even when a later pass returns a single value.
    public static func sixNineCandidates(for field: OCRField, in evidence: [OCRReadEvidence]) -> [OCRCorrectionCandidate] {
        guard field.isNumeric else { return [] }
        var observed: [OCRCorrectionCandidate] = []
        for read in evidence where read.fieldKey == field.evidenceKey {
            for tokens in read.variants {
                guard let rect = tokens.first?.rect, tokens.allSatisfy({ $0.rect == rect && $0.confidence.isFinite && (0...1).contains($0.confidence) }),
                      let value = parsed(tokens.map(\.text).joined(separator: " "), field: field) else { continue }
                observed.append(.init(id: "", field: field, value: value, tokens: tokens, sourceID: read.sourceID, route: read.route, fromCatalog: false))
            }
        }
        func sameRegion(_ a: OCRCorrectionCandidate, _ b: OCRCorrectionCandidate) -> Bool {
            a.sourceID == b.sourceID && a.tokens.first?.rect == b.tokens.first?.rect
        }
        func swappedOnly(_ a: String, _ b: String) -> Bool {
            guard a != b, a.count == b.count else { return false }
            return zip(a, b).allSatisfy { x, y in x == y || (x == "6" && y == "9") || (x == "9" && y == "6") }
        }
        var conflicts = Set<Int>()
        for i in observed.indices {
            let strongest = observed.filter { sameRegion(observed[i], $0) }.map(\.confidence).max() ?? 0
            guard observed[i].confidence + 0.100000001 >= strongest else { continue }
            for j in observed.indices where j > i && sameRegion(observed[i], observed[j]) {
                if observed[j].confidence + 0.100000001 >= strongest && swappedOnly(observed[i].value, observed[j].value) {
                    conflicts.insert(i); conflicts.insert(j)
                }
            }
        }
        return observed.indices.filter { conflicts.contains($0) }.map { observed[$0] }
    }

    public static func sixNineAmbiguousFields(in evidence: [OCRReadEvidence]) -> [OCRField] {
        OCRField.allCases.filter { !sixNineCandidates(for: $0, in: evidence).isEmpty }
    }

    public static func validate(_ selections: [OCRCorrectionSelection], in context: OCRCorrectionContext) throws -> [OCRCorrectionCandidate] {
        var seen = Set<String>(), result: [OCRCorrectionCandidate] = []
        for selection in selections {
            guard seen.insert(selection.fieldID).inserted,
                  let field = context.fields.first(where: { $0.id == selection.fieldID }),
                  let candidate = field.candidates.first(where: { $0.id == selection.candidateID && $0.field == field.field }),
                  parsed(candidate.value, field: field.field) == candidate.value,
                  !candidate.tokens.isEmpty else { throw CoreError.invalid("AFMの応答が許可候補と一致しません。Visionの結果を手動で確認してください。") }
            result.append(candidate)
        }
        return result
    }

    private static func append(_ value: String, field: OCRField, tokens: [OCRToken], read: OCRReadEvidence, catalog: Bool, to candidates: inout [OCRCorrectionCandidate]) {
        guard !candidates.contains(where: { $0.value == value }) else { return }
        candidates.append(.init(id: "", field: field, value: value, tokens: tokens, sourceID: read.sourceID, route: read.route, fromCatalog: catalog))
    }

    public static func parsed(_ text: String, field: OCRField) -> String? {
        let normalized = text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field {
        case .title:
            let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        case .difficulty:
            return ["EXPERT", "SPECIAL", "MASTER", "NORMAL", "HARD", "EASY"].first { normalized.uppercased().contains($0) }
        case .achievement:
            let label = normalizedName(normalized)
            if label.contains("ALLPERFECT") || normalized == "ap" { return "ap" }
            if label.contains("FULLCOMBO") || normalized == "fc" { return "fc" }
            if label == "NONE" || label == "FC/APなし" { return "none" }
            return nil
        case .level:
            // Difficulty and level share a read region. A master level is never used here.
            if !normalized.contains("-"), !normalized.contains("−"), let value = normalized.split(whereSeparator: { !$0.isNumber }).compactMap({ Int($0) }).last, value > 0 { return String(value) }
            return nil
        default:
            let digits = normalized.replacingOccurrences(of: ",", with: "").filter { !$0.isWhitespace }
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(digits), value >= 0,
                  value <= (field == .score ? Int(Int32.max) : 1_000_000) else { return nil }
            return String(value)
        }
    }
}
