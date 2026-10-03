import Foundation
import CryptoKit
import ResultCore

/// Explicit developer verification. Uses only supplied images and disposable local storage.
@MainActor enum WorkflowVerification {
    static func run() async -> AppModel? {
        do {
            guard let index = CommandLine.arguments.firstIndex(of: "--verify-workflow") else { return nil }
            let paths = CommandLine.arguments.dropFirst(index + 1).filter { !$0.hasPrefix("--") }
            try check(paths.count == 7, "提供された7枚を指定してください。")
            let model = AppModel(inMemory: true)
            model.state.automaticRegistrationEnabled = false // Legacy verification covers explicit manual confirmation.
            try check(model.startupError == nil, "起動失敗")
            try check(model.state.catalogs.contains { $0.sourceID == OurNotesCatalog.sourceID && $0.isComplete }, "全曲マスターの自動適用")
            let urls = paths.map { URL(fileURLWithPath: $0) }
            model.importImages(urls)
            while model.importing { try await Task.sleep(nanoseconds: 20_000_000) }
            try check(model.pending.count == 7 && model.state.plays.isEmpty, "7画像を確認待ちにし、画像ペアを自動で二重登録しない")
            if CommandLine.arguments.contains("--verify-workflow-afm") {
                if let reason = model.correction.availability.reason {
                    print("Real-image AFM: UNAVAILABLE — \(reason)")
                } else {
                    let stateBefore = model.state, pendingBefore = model.pending.compactMap(\.result).map { draft in OCRField.allCases.map { $0.value(in: draft) } }
                    var checked = 0, suggestions = 0
                    for item in model.pending where item.result != nil {
                        let context = model.correctionContext(item.id)
                        guard context.fields.contains(where: { !$0.candidates.isEmpty }) else { continue }
                        model.requestCorrections(item.id, editorRevision: 0)
                        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(35))
                        while model.correction.isRunning && clock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
                        try check(!model.correction.isRunning && model.correction.succeeded, "実画像AFM候補ID選択: " + model.correction.message)
                        suggestions += model.correction.suggestions.count; checked += 1
                        model.correction.invalidate()
                    }
                    try check(checked > 0 && model.state == stateBefore && (model.pending.compactMap(\.result).map { draft in OCRField.allCases.map { $0.value(in: draft) } }) == pendingBefore, "AFMが解析値・登録データを変更しない")
                    print("Real-image AFM: PASS — \(checked) OCR contexts, \(suggestions) validated candidate IDs; drafts and storage unchanged.")
                    fflush(stdout)
                }
            }
            guard let settingsItem = model.pending.first(where: { $0.settings != nil }), let settings = settingsItem.settings else { throw CoreError.invalid("設定画像を検出できません。") }
            try check(settings == PlaySettings(noteSpeed: Decimal(string: "10.50"), noteTiming: Decimal(string: "0.10"), chartPosition: 0, mirror: false), "設定値の読取")
            model.applySettings(settings, toBatch: false)
            try check(model.errorMessage == nil, "設定保存")
            model.pending.removeAll { $0.id == settingsItem.id }
            while let first = model.pending.first {
                guard let second = model.pending.first(where: { $0.id != first.id && AppModel.samePlayCandidate(first, $0) }) else { throw CoreError.invalid("通常・詳細の組合せが見つかりません。") }
                try model.mergePending(first.id, second.id)
                try check(model.errorMessage == nil, "画像ペアの統合")
                guard let merged = model.pending.first(where: { $0.id == first.id }), let draft = merged.result else { throw CoreError.invalid("統合結果がありません。") }
                try model.register(merged.id, draft: draft, chartID: nil, mergeID: nil, playedAt: nil, timing: RegistrationTiming(environment: model.activeEnvironment))
            }
            let plays = model.state.plays
            try check(plays.count == 3 && plays.allSatisfy { $0.fingerprints.count == 2 }, "3プレイ・6画像指紋")
            let expected: [String: (Int, Int, Achievement, [Int], [Int], [Int])] = [
                "青春コンプレックス": (988887, 1100, .ap, [1100,0,0,0,0], [215,0,0,0,0], [567,0,0,0,0]),
                "六兆年と一夜物語": (1064865, 787, .fc, [786,1,0,0,0], [233,1,0,0,0], [267,0,0,0,0]),
                "焚音打": (1020889, 579, .none, [1750,17,2,4,4], [754,15,2,4,0], [450,2,0,0,4])
            ]
            for play in plays {
                guard let e = expected[play.titleAtPlay] else { throw CoreError.invalid("期待しない曲名です。") }
                try check(play.score == e.0 && play.combo == e.1 && play.achievement == e.2, "スコア・コンボ・達成状態")
                for (i, judgment) in Judgment.allCases.enumerated() {
                    try check(play.judgments[judgment] == JudgmentCount(total: e.3[i], fast: e.4[i], slow: e.5[i]), "全判定・FAST/SLOWの一致")
                }
            }
            let summary = StatisticsService.summarize(plays)
            try check(summary.judgmentNoteCount == 3664 && summary.timingNoteCount == 2504 && abs((summary.fastRate ?? 0) - 1218.0 / 2504) < 0.000001, "加重集計")
            try check(summary.fcRate == 2.0/3 && summary.apRate == 1.0/3 && StatisticsService.grouped(plays, by: .level).count == 3, "FC/AP率・レベル別集計")
            model.importImages(urls)
            while model.importing { try await Task.sleep(nanoseconds: 20_000_000) }
            try check(model.state.plays.count == 3 && model.pending.count == 1 && model.pending[0].settings != nil, "6結果画像の再取込重複除外")
            model.clearPending()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ournotes-storage-verification-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let repository = try LocalRepository(storageDirectory: directory)
                try repository.save(model.state)
                let reopened = try LocalRepository(storageDirectory: directory)
                try check(try reopened.load() == model.state, "ディスク保存と再読込")
                let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                try check(contents.allSatisfy { !$0.pathExtension.lowercased().contains("png") && !["jpg","jpeg","heic"].contains($0.pathExtension.lowercased()) }, "保存先に画像がない")
            }
            print("Workflow: PASS — 7 images, 3 merged plays, 6 duplicate results skipped, statistics and disk reload verified; no images persisted.")
            fflush(stdout)
            return model
        } catch {
            fputs("ワークフロー検証エラー: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }
    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CoreError.invalid(message) }
    }
}
