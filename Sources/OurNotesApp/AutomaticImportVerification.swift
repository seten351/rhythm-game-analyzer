import Foundation
import CryptoKit
import ResultCore

/// Developer-only verification: actual OCR and the production import coordinator,
/// using a disposable database. No access to the user's normal store.
@MainActor enum AutomaticImportVerification {
    static func run() async -> AppModel? {
        do {
            guard let index = CommandLine.arguments.firstIndex(of: "--verify-auto-import") else { return nil }
            let urls = CommandLine.arguments.dropFirst(index + 1).filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { throw CoreError.invalid("検証する画像のパスを指定してください。") }
            let originals = try urls.map { Data(SHA256.hash(data: try Data(contentsOf: $0))) }
            let model = AppModel(inMemory: true)
            guard model.startupError == nil else { throw CoreError.invalid(model.startupError!) }
            model.importImages(urls)
            while model.importing { try await Task.sleep(for: .milliseconds(100)) }
            let firstState = model.state, firstPending = model.pending, firstReceipts = model.importReceipts
            let firstIDs = model.lastBatchPlayIDs, firstDuplicateCount = model.duplicateCount
            let registered = model.automaticCount
            let rows: [[String: Any]] = firstState.plays.map { play in
                ["title": play.titleAtPlay, "difficulty": play.difficultyAtPlay, "level": play.levelAtPlay as Any? ?? NSNull(), "score": play.score,
                 "combo": play.combo as Any? ?? NSNull(), "achievement": play.achievement.rawValue,
                 "imageCount": play.fingerprints.count,
                 "judgments": Dictionary(uniqueKeysWithValues: Judgment.allCases.map { j in
                     let c = play.judgments[j] ?? .init()
                     return (j.rawValue, ["total": c.total as Any? ?? NSNull(), "fast": c.fast as Any? ?? NSNull(), "slow": c.slow as Any? ?? NSNull()])
                 })]
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("our-notes-auto-verification-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = try LocalRepository(storageDirectory: directory)
            try repository.save(firstState)
            guard try LocalRepository(storageDirectory: directory).load() == firstState else { throw CoreError.invalid("自動登録の保存・再読込が一致しません。") }
            let export = try model.analysisExportData()
            guard !String(decoding: export, as: UTF8.self).contains("sourcePreviews") else { throw CoreError.invalid("画像が分析出力に含まれています。") }
            fputs("一次解析完了: 自動登録\(registered)件、結果の確認待ち\(firstPending.filter { $0.result != nil }.count)件\n", stderr)
            model.clearPending()
            // Reimport registered images. Unregistered ambiguous images are not
            // duplicates and a later OCR pass may legitimately produce new evidence.
            let registeredHashes = Set(firstState.plays.flatMap { $0.fingerprints.map(\.sha256) })
            let repeatURLs = zip(urls, originals).filter { registeredHashes.contains($0.1.map { String(format: "%02x", $0) }.joined()) }.map(\.0)
            model.importImages(repeatURLs)
            while model.importing { try await Task.sleep(for: .milliseconds(100)) }
            guard model.state == firstState else { throw CoreError.invalid("同じ画像の再取込で履歴が変わりました。") }
            let repeatedSkip = model.duplicateCount
            model.pending = firstPending; model.importReceipts = firstReceipts; model.lastBatchPlayIDs = firstIDs; model.duplicateCount = firstDuplicateCount
            for (i, url) in urls.enumerated() {
                guard Data(SHA256.hash(data: try Data(contentsOf: url))) == originals[i] else { throw CoreError.invalid("元画像が変更されました。") }
            }
            let report: [String: Any] = [
                "inputImages": urls.count, "automaticPlays": registered,
                "automaticImages": firstState.plays.reduce(0) { $0 + $1.fingerprints.count },
                "reviewResults": firstPending.filter { $0.result != nil }.count,
                "settingsToReview": firstPending.filter { $0.settings != nil }.count,
                "failed": model.failedCount, "repeatSkippedImages": repeatedSkip,
                "diskReload": true, "originalsUnchanged": true,
                "pending": firstPending.map { item -> [String: Any] in
                    ["title": item.result?.title ?? "設定", "kind": item.result?.kind ?? "settings", "images": item.fingerprints.count,
                     "identityEvidence": item.assessment?.fields.filter { [.title, .difficulty, .level].contains($0.field) }.map { field in
                         ["field": field.field.rawValue, "values": field.candidates.map { ["value": $0.value, "confidence": $0.confidence] as [String: Any] }] as [String: Any]
                     } ?? [],
                     "issues": item.assessment?.issues.map { ($0.field?.rawValue ?? "result") + ": " + $0.reason } ?? [],
                     "candidates": item.assessment?.fields.filter { $0.competitiveValues.count > 1 }.map { $0.field.rawValue + ": " + $0.competitiveValues.joined(separator: ",") } ?? []]
                }, "plays": rows
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            model.notice = "検証用の一時データです。通常の保存データは変更していません。"
            return model
        } catch { fputs("自動取込検証エラー: \(error.localizedDescription)\n", stderr); return nil }
    }

    /// Reproduce duplicate checks from an explicitly supplied verification snapshot.
    /// The normal application database is never opened by this command.
    static func verifyReimport() async -> Bool {
        do {
            guard let index = CommandLine.arguments.firstIndex(of: "--verify-auto-reimport"), CommandLine.arguments.count > index + 2 else {
                throw CoreError.invalid("検証用AppState JSONと登録済み画像のパスを指定してください。")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            let state = try JSONDecoder().decode(AppState.self, from: data)
            let hashes = Set(state.plays.flatMap { $0.fingerprints.map(\.sha256) })
            let urls = try CommandLine.arguments.dropFirst(index + 2).map { URL(fileURLWithPath: $0) }.filter { url in
                let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                return hashes.contains(hash)
            }
            guard !urls.isEmpty else { throw CoreError.invalid("登録済み画像がありません。") }
            let model = AppModel(inMemory: true, loadBundledCatalog: false)
            try model.commit(state)
            model.importImages(urls)
            while model.importing { try await Task.sleep(for: .milliseconds(100)) }
            guard model.state == state, model.duplicateCount == urls.count, model.pending.isEmpty, model.failedCount == 0 else {
                throw CoreError.invalid("再取込で履歴または確認待ちが変わりました。")
            }
            print("重複再取込: \(urls.count)画像をスキップ、\(state.plays.count)プレイの全保存値を保持")
            return true
        } catch { fputs("重複検証エラー: \(error.localizedDescription)\n", stderr); return false }
    }
}
