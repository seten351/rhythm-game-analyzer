import Foundation
import XCTest
@testable import ResultCore

final class OurNotesPolicyTests: XCTestCase {
    private let rect = NormalizedRect(x: 0.6, y: 0.5, width: 0.1, height: 0.05)
    private func draft(_ achievement: Achievement = .unknown, _ judgments: [Judgment: JudgmentCount] = [:]) -> ResultDraft {
        .init(gameID: "our-notes", presetID: "preset", presetVersion: 1, title: "Song", difficulty: "EXPERT", level: 26, score: 900_000, combo: nil, achievement: achievement, judgments: judgments, fingerprint: .init(sha256: "sha", layout: "normal"), kind: "normal")
    }
    private func evidence(_ field: OCRField = .greatTotal, _ values: [(String, Double)] = [("6", 0.98), ("9", 0.94)], source: String = "sha", route: String = "region", rect: NormalizedRect? = nil) -> OCRReadEvidence {
        .init(sourceID: source, fieldKey: field.evidenceKey, route: route, observations: [values.map { .init(text: $0.0, confidence: $0.1, rect: rect ?? self.rect) }])
    }
    private func fields(_ achievement: String = "FULL COMBO", detailed: Bool = false) -> [String: [OCRToken]] {
        var output: [String: [OCRToken]] = ["title": [.init(text: "Song")], "difficulty": [.init(text: "EXPERT 26")], "score": [.init(text: "900000")], "combo": [.init(text: "100")], "achievement": [.init(text: achievement)], "timingHeader": [.init(text: detailed ? "FAST SLOW" : "NORMAL")]]
        for j in Judgment.allCases {
            if detailed {
                output[j.rawValue + ".fast"] = [.init(text: j == .perfect ? "60" : j == .good ? "2" : "0")]
                output[j.rawValue + ".slow"] = [.init(text: j == .perfect ? "40" : "0")]
            } else { output[j.rawValue + ".total"] = [.init(text: j == .perfect ? "100" : j == .good ? "2" : "0")] }
        }
        return output
    }
    private func parse(_ fields: [String: [OCRToken]], evidence: [OCRReadEvidence] = []) -> ResultDraft {
        let preset = GamePreset(formatVersion: 1, id: "preset", version: 1, gameId: "our-notes", name: "test", parserId: "our-notes-v1", aspectRatio: 1.4, aspectTolerance: 0.01, confidenceThreshold: 0.8, regions: [:])
        return OurNotesParser.result(fields: fields, preset: preset, fingerprint: .init(sha256: "sha", layout: "normal"), knownTitles: [], evidence: evidence)
    }
    func testFCAllowsGOODAndGREATInTotalsAndTimingDetails() throws {
        for count in [JudgmentCount(total: 2), .init(fast: 2, slow: 1), .init(total: 3, fast: 2, slow: 1)] {
            XCTAssertNoThrow(try draft(.fc, [.great: count, .good: count, .bad: .init(total: 0), .miss: .init(total: 0)]).validateForSave())
        }
        for detailed in [false, true] {
            let result = parse(fields(detailed: detailed))
            XCTAssertEqual(result.achievement, .fc)
            XCTAssertTrue(result.issues.isEmpty)
        }
    }
    func testFCRejectsBADAndMISSForAnyKnownPositiveCount() {
        for j in [Judgment.bad, .miss] {
            for count in [JudgmentCount(total: 1), .init(fast: 1), .init(slow: 1)] {
                XCTAssertThrowsError(try draft(.fc, [j: count]).validateForSave())
            }
        }
    }
    func testAPRejectsEachNonPerfectJudgmentAndPreservesMissingCounts() throws {
        for j in [Judgment.great, .good, .bad, .miss] {
            for count in [JudgmentCount(total: 1), .init(fast: 1), .init(slow: 1)] {
                XCTAssertThrowsError(try draft(.ap, [j: count]).validateForSave())
            }
        }
        let zeros = Dictionary(uniqueKeysWithValues: Judgment.allCases.map { ($0, JudgmentCount(total: $0 == .perfect ? 100 : 0, fast: 0, slow: 0)) })
        XCTAssertNoThrow(try draft(.ap, zeros).validateForSave())
        let missing = draft(.ap, [.good: .init()])
        XCTAssertNoThrow(try missing.validateForSave())
        XCTAssertNil(missing.judgments[.good]?.total)
    }
    func testGOODWithoutAchievementLabelDoesNotInferNonFC() {
        for detailed in [false, true] {
            let result = parse(fields("", detailed: detailed))
            XCTAssertEqual(result.achievement, .unknown)
            XCTAssertTrue(result.issues.contains { $0.contains("FC/AP表示") })
        }
    }
    func testAssistLabelsRejectSaveAndOrdinaryTitleDoesNotBecomeMode() {
        for label in ["ASSIST", "ASSIST MODE", "アシスト", "アシストモード"] {
            var input = fields(); input["mode"] = [.init(text: label)]
            let result = parse(input)
            XCTAssertEqual(result.kind, "unsupported-assist")
            XCTAssertThrowsError(try ResultService.save(result, to: AppState(), environment: nil))
            XCTAssertTrue(result.issues.contains { $0.contains("アシストモードは対応対象外") })
        }
        var ordinary = fields(); ordinary["title"] = [.init(text: "Assist Song")]
        XCTAssertEqual(parse(ordinary).kind, "normal")
    }
    func testHighConfidenceSixNineConflictBlocksCleanParserResult() throws {
        var input = fields(); input["GREAT.total"] = [.init(text: "6", confidence: 0.98)]
        let reads = [evidence()]
        let result = parse(input, evidence: reads)
        XCTAssertEqual(result.judgments[.great]?.total, 6) // Provisional Vision result; never silently rewritten.
        XCTAssertTrue(result.issues.contains { $0.contains("GREAT 総数：6/9判定曖昧") })
        let context = OCRCorrectionService.context(draft: result, evidence: reads, knownTitles: [], confidenceThreshold: 0.8)
        let field = try XCTUnwrap(context.fields.first { $0.field == .greatTotal })
        XCTAssertTrue(field.isSixNineAmbiguous)
        XCTAssertEqual(Set(field.candidates.map(\.value)), ["6", "9"])
    }
    func testConflictCanBeMultiDigitNormalizedOrAcrossRetryButNotAnotherRegionOrImage() {
        for values in [[("196", 0.98), ("169", 0.94)], [("１,６９６", 0.98), ("１,６９９", 0.94)]] {
            XCTAssertEqual(OCRCorrectionService.sixNineAmbiguousFields(in: [evidence(.score, values)]), [.score])
        }
        let original = evidence(.greatTotal, [("6", 0.98)])
        let retry = evidence(.greatTotal, [("9", 0.96)], route: "inverted-padded")
        XCTAssertEqual(OCRCorrectionService.sixNineAmbiguousFields(in: [original, retry]), [.greatTotal])
        XCTAssertTrue(OCRCorrectionService.sixNineAmbiguousFields(in: [original, evidence(.greatTotal, [("9", 0.96)], source: "another-image")]).isEmpty)
        XCTAssertTrue(OCRCorrectionService.sixNineAmbiguousFields(in: [original, evidence(.greatTotal, [("9", 0.96)], rect: .init(x: 0.7, y: 0.5, width: 0.1, height: 0.05))]).isEmpty)
        XCTAssertTrue(OCRCorrectionService.sixNineAmbiguousFields(in: [original, evidence(.goodTotal, [("9", 0.96)])]).isEmpty)
    }
    func testWeakOrNonSixNineAlternativesAndSingleReadDoNotBecomeSixNineConflicts() {
        for values in [[("6", 0.98), ("9", 0.6)], [("6", 0.98)], [("6", 0.98), ("8", 0.97)], [("16", 0.98), ("9", 0.97)], [("-6", 0.98), ("-9", 0.97)], [("6x", 0.98), ("9x", 0.97)]] {
            XCTAssertTrue(OCRCorrectionService.sixNineAmbiguousFields(in: [evidence(.score, values)]).isEmpty)
        }
        XCTAssertTrue(OCRCorrectionService.sixNineAmbiguousFields(in: [evidence(.title, [("Song6", 0.98), ("Song9", 0.97)])]).isEmpty)
        XCTAssertEqual(OCRCorrectionService.sixNineAmbiguousFields(in: [evidence(.level, [("EXPERT 26", 0.98), ("EXPERT 29", 0.94)])]), [.level])
    }
    func testOtherCountsAndTotalsNeverGenerateOrEliminateSixNineCandidates() throws {
        let reads = [evidence()]
        // FAST/SLOW sum favors 6; this cannot be used to eliminate the actual OCR candidate 9.
        let result = draft(.fc, [.great: .init(total: 6, fast: 3, slow: 3)])
        let context = OCRCorrectionService.context(draft: result, evidence: reads, knownTitles: [], confidenceThreshold: 0.8)
        XCTAssertEqual(Set(try XCTUnwrap(context.fields.first?.candidates).map(\.value)), ["6", "9"])
        XCTAssertTrue(OCRCorrectionService.sixNineCandidates(for: .greatTotal, in: []).isEmpty)
    }
    func testCandidateCapNeverDropsOnlyHalfOfAmbiguousPair() throws {
        let reads = [evidence(.score, [("1", 0.99), ("2", 0.99), ("3", 0.99)]), evidence(.score, [("4", 0.99), ("5", 0.99)]), evidence(.score)]
        let context = OCRCorrectionService.context(draft: draft(), evidence: reads, knownTitles: [], confidenceThreshold: 0.8)
        XCTAssertEqual(Set(try XCTUnwrap(context.fields.first?.candidates).map(\.value)), ["6", "9"])
        let overflow = ["16", "26", "36"].flatMap { value in [evidence(.score, [(value, 0.99), (value.replacingOccurrences(of: "6", with: "9"), 0.97)])] }
        let overflowContext = OCRCorrectionService.context(draft: draft(), evidence: overflow, knownTitles: [], confidenceThreshold: 0.8)
        XCTAssertTrue(overflowContext.fields.first?.isSixNineAmbiguous == true)
        XCTAssertTrue(overflowContext.fields.first?.candidates.isEmpty == true)
    }
    func testOriginalAmbiguitySurvivesSingleValueRetryAndManualExclusion() {
        let reads = [evidence(), evidence(.greatTotal, [("6", 1)], route: "inverted-padded")]
        XCTAssertEqual(OCRCorrectionService.sixNineAmbiguousFields(in: reads), [.greatTotal])
        let eligible = OCRCorrectionService.context(draft: draft(), evidence: reads, knownTitles: [], confidenceThreshold: 0.8)
        XCTAssertEqual(eligible.fields.first?.sixNineEvidence.count, 3)
        XCTAssertTrue(eligible.fields.first?.sixNineEvidence.contains { $0.value == "6" && $0.route == "inverted-padded" } == true)
        let context = OCRCorrectionService.context(draft: draft(), evidence: reads, knownTitles: [], confidenceThreshold: 0.8, excluded: [.greatTotal])
        XCTAssertTrue(context.fields.isEmpty)
    }

    func testSingleSixNineReadTriggersPixelRetryWithoutInventingOtherCandidate() {
        for field in [OCRField.score, .combo, .missTotal, .missSlow, .level] {
            let read = evidence(field, [(field == .level ? "EXPERT 26" : "196", 0.99)])
            XCTAssertTrue(OCRCorrectionService.shouldRetrySixNine(for: field, in: [read]))
            XCTAssertTrue(OCRCorrectionService.sixNineCandidates(for: field, in: [read]).isEmpty)
        }
        for value in ["123", "-6", "9x", ""] {
            XCTAssertFalse(OCRCorrectionService.shouldRetrySixNine(for: .score, in: [evidence(.score, [(value, 0.99)])]))
        }
        XCTAssertFalse(OCRCorrectionService.shouldRetrySixNine(for: .title, in: [evidence(.title, [("Song6", 0.99)])]))
    }
}
