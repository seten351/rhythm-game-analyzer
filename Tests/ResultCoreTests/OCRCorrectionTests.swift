import Foundation
import XCTest
@testable import ResultCore

final class OCRCorrectionTests: XCTestCase {
    private func draft(
        title: String = "Song",
        difficulty: String = "MASTER",
        level: Int? = 30,
        score: Int? = 900_000,
        combo: Int? = 500,
        achievement: Achievement = .unknown,
        judgments: [Judgment: JudgmentCount] = [:]
    ) -> ResultDraft {
        ResultDraft(gameID: "our-notes", presetID: "preset", presetVersion: 1,
                    title: title, difficulty: difficulty, level: level, score: score, combo: combo,
                    achievement: achievement, judgments: judgments,
                    fingerprint: .init(sha256: "sha", layout: "result"), kind: "normal")
    }

    private func read(_ field: OCRField, _ text: String, confidence: Double = 0.2,
                      source: String = "image-A", route: String = "preset-region",
                      rect: NormalizedRect = .init(x: 0.1, y: 0.2, width: 0.3, height: 0.1)) -> OCRReadEvidence {
        .init(sourceID: source, fieldKey: field.evidenceKey, route: route,
              observations: [[OCRToken(text: text, confidence: confidence, rect: rect)]])
    }

    private func field(_ field: OCRField, evidence: [OCRReadEvidence], draft: ResultDraft? = nil,
                       knownTitles: [String] = [], excluded: Set<OCRField> = []) -> OCRCorrectionField? {
        OCRCorrectionService.context(draft: draft ?? self.draft(), evidence: evidence,
                                     knownTitles: knownTitles, confidenceThreshold: 0.8,
                                     excluded: excluded).fields.first { $0.field == field }
    }

    func testCandidatesKeepFieldLocalSourceRouteAndOCRRectangle() throws {
        let rect = NormalizedRect(x: 0.12, y: 0.23, width: 0.34, height: 0.08)
        let result = try XCTUnwrap(field(.score, evidence: [read(.score, "900,001", source: "screen-2", route: "score-retry", rect: rect)]))

        XCTAssertEqual(result.originalValue, "900000")
        XCTAssertEqual(result.candidates.map(\.value), ["900001"])
        XCTAssertEqual(result.candidates.first?.field, .score)
        XCTAssertEqual(result.candidates.first?.sourceID, "screen-2")
        XCTAssertEqual(result.candidates.first?.route, "score-retry")
        XCTAssertEqual(result.candidates.first?.tokens.first?.rect, rect)
    }

    func testStrictNumericCandidatesRejectMalformedNegativeAndOverflowValues() {
        for text in ["12x", "-1", "2147483648"] {
            let item = field(.score, evidence: [read(.score, text)])
            XCTAssertFalse(item?.candidates.contains(where: { $0.value == text }) ?? false, "accepted \(text)")
        }
        for text in ["-1", "1000001", "999999999999999999999999"] {
            let item = field(.combo, evidence: [read(.combo, text)])
            XCTAssertFalse(item?.candidates.contains(where: { $0.value == text }) ?? false, "accepted \(text)")
        }
    }

    func testZeroIsARealCandidateAndMissingIsNotConvertedToZero() throws {
        var value = draft(score: nil)
        value.score = nil
        let zero = try XCTUnwrap(field(.score, evidence: [read(.score, "0")], draft: value))
        XCTAssertNil(zero.originalValue)
        XCTAssertEqual(zero.candidates.map(\.value), ["0"])

        let noEvidence = OCRCorrectionService.context(draft: value, evidence: [], knownTitles: [], confidenceThreshold: 0.8)
        XCTAssertFalse(noEvidence.fields.contains { $0.field == .score })
    }

    func testNoInferenceFromCatalogTimingDetailsOrJudgmentAchievement() {
        let catalogOnly = OCRCorrectionService.context(draft: draft(level: nil), evidence: [],
                                                       knownTitles: ["Song"], confidenceThreshold: 0.8)
        XCTAssertFalse(catalogOnly.fields.contains { $0.field == .level })

        let fastSlowOnly = [
            read(.perfectFast, "12"), read(.perfectSlow, "8"),
            read(.greatFast, "0"), read(.greatSlow, "0")
        ]
        let detailContext = OCRCorrectionService.context(draft: draft(judgments: [:]), evidence: fastSlowOnly,
                                                         knownTitles: [], confidenceThreshold: 0.8)
        XCTAssertFalse(detailContext.fields.contains { $0.field == .perfectTotal })
        XCTAssertFalse(detailContext.fields.contains { $0.field == .achievement })

        let judgmentsOnly = OCRCorrectionService.context(draft: draft(achievement: .unknown),
                                                         evidence: [read(.perfectTotal, "100"), read(.greatTotal, "0")],
                                                         knownTitles: [], confidenceThreshold: 0.8)
        XCTAssertFalse(judgmentsOnly.fields.contains { $0.field == .achievement })
    }

    func testTitleCandidatesUseMasterThresholdAndCapDistinctValuesAtFive() throws {
        let titles = ["Alpha Song", "Alpha Song 2", "Alpha Song 3", "Alpha Song 4", "Alpha Song 5", "Alpha Song 6"]
        let item = try XCTUnwrap(field(.title, evidence: [read(.title, "Alpha Song")], knownTitles: titles))
        XCTAssertLessThanOrEqual(item.candidates.count, 5)
        XCTAssertEqual(Set(item.candidates.map(\.value)).count, item.candidates.count)
        XCTAssertTrue(item.candidates.contains { $0.value == "Alpha Song" && !$0.fromCatalog })
        XCTAssertTrue(item.candidates.filter(\.fromCatalog).allSatisfy { titles.contains($0.value) })

        let weakMatch = field(.title, evidence: [read(.title, "ZZZZZZZ")], knownTitles: ["Completely Different Song"])
        XCTAssertFalse(weakMatch?.candidates.contains(where: \.fromCatalog) ?? false)
    }

    func testManualFieldsAreExcludedFromCorrectionContext() {
        let context = OCRCorrectionService.context(draft: draft(),
                                                   evidence: [read(.score, "900001"), read(.combo, "501")],
                                                   knownTitles: [], confidenceThreshold: 0.8,
                                                   excluded: [.score])
        XCTAssertFalse(context.fields.contains { $0.field == .score })
        XCTAssertTrue(context.fields.contains { $0.field == .combo })
    }

    func testValidationRejectsWholeResponseForUnknownMismatchedOrDuplicateIDs() throws {
        let context = OCRCorrectionService.context(draft: draft(),
                                                   evidence: [read(.score, "900001"), read(.combo, "501")],
                                                   knownTitles: [], confidenceThreshold: 0.8)
        let score = try XCTUnwrap(context.fields.first { $0.field == .score }?.candidates.first)
        let combo = try XCTUnwrap(context.fields.first { $0.field == .combo }?.candidates.first)
        let invalidResponses = [
            [OCRCorrectionSelection(fieldID: "unknown", candidateID: score.id)],
            [OCRCorrectionSelection(fieldID: "score", candidateID: combo.id)],
            [OCRCorrectionSelection(fieldID: "score", candidateID: score.id),
             OCRCorrectionSelection(fieldID: "score", candidateID: score.id)]
        ]
        for response in invalidResponses {
            XCTAssertThrowsError(try OCRCorrectionService.validate(response, in: context))
        }
    }

    func testEmptySelectionIsValidAndDoesNotInventCandidates() throws {
        let context = OCRCorrectionService.context(draft: draft(), evidence: [read(.score, "900001")],
                                                   knownTitles: [], confidenceThreshold: 0.8)
        XCTAssertTrue(try OCRCorrectionService.validate([], in: context).isEmpty)
    }
}
