import Foundation
import AppKit
import ResultCore

/// Explicit developer smoke check. Synthetic OCR only; never opens the normal repository.
@MainActor enum AFMVerification {
    private static var sixNineFixture: Bool { CommandLine.arguments.contains("--six-nine-fixture") }
    static func previewModel() -> AppModel {
        let model = AppModel(inMemory: true, loadBundledCatalog: false)
        let image = NSImage(size: NSSize(width: 800, height: 400))
        image.lockFocus()
        NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 800, height: 400)).fill()
        let text = sixNineFixture ? "人工データ：6/9確認用\nSCORE 6" : "人工データ：AFM確認用\nSCORE 100"
        (text as NSString).draw(in: NSRect(x: 40, y: 120, width: 720, height: 240), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let rect = ResultCore.NormalizedRect(x: 0.05, y: 0.10, width: 0.90, height: 0.60)
        let fingerprint = SourceFingerprint(sha256: "synthetic-preview", layout: "normal")
        let draft = ResultDraft(gameID: "our-notes", presetID: "verification", presetVersion: 1, title: "AFM確認用", difficulty: "EXPERT", level: 25, score: sixNineFixture ? 6 : 100, combo: 10, achievement: .unknown, judgments: [:], fingerprint: fingerprint, issues: ["人工データのOCR候補です。実画像の精度検証には使用しません。"], kind: "normal")
        let evidence = fixtureEvidence(sourceID: fingerprint.sha256, rect: rect)
        model.pending = [PendingImport(name: "人工データ（保存しません）", result: draft, image: image, fingerprints: [fingerprint], evidence: [evidence], sourcePreviews: [fingerprint.sha256: image])]
        model.notice = "AFM UI検証用の人工データです。通常DBを使用せず、終了時に破棄します。"
        return model
    }

    static func run() async -> Bool {
        let provider = FoundationOCRCorrectionProvider(diagnostic: { print($0) })
        if let reason = provider.availability.reason {
            print("AFM on-device: UNAVAILABLE — \(reason)")
            return true
        }
        let draft = ResultDraft(gameID: "our-notes", presetID: "verification", presetVersion: 1, title: "検証", difficulty: "EXPERT", level: 25, score: sixNineFixture ? 6 : 100, combo: nil, achievement: .unknown, judgments: [:], fingerprint: .init(sha256: "synthetic", layout: "normal"), kind: "normal")
        let evidence = fixtureEvidence(sourceID: "synthetic", rect: .init(x: 0, y: 0, width: 1, height: 1))
        let context = OCRCorrectionService.context(draft: draft, evidence: [evidence], knownTitles: [], confidenceThreshold: 0.8)
        let controller = OCRCorrectionController(provider: provider)
        controller.start(itemID: UUID(), revision: 0, context: context)
        let clock = ContinuousClock(), limit = clock.now.advanced(by: .seconds(35))
        while controller.isRunning && clock.now < limit { try? await Task.sleep(for: .milliseconds(100)) }
        if controller.isRunning || !controller.succeeded {
            let message = controller.message
            controller.cancel(); print("AFM on-device: FAILED — \(message)"); return false
        }
        print("AFM on-device candidate-ID check: PASS (synthetic \(sixNineFixture ? "6/9" : "100/101") evidence, \(controller.suggestions.count) suggestions; no values saved)")
        controller.invalidate()
        return true
    }

    private static func fixtureEvidence(sourceID: String, rect: ResultCore.NormalizedRect) -> OCRReadEvidence {
        .init(sourceID: sourceID, fieldKey: "score", route: "verification", observations: [[
            .init(text: sixNineFixture ? "6" : "100", confidence: sixNineFixture ? 0.98 : 0.2, rect: rect),
            .init(text: sixNineFixture ? "9" : "101", confidence: sixNineFixture ? 0.94 : 0.15, rect: rect)
        ]])
    }
}
