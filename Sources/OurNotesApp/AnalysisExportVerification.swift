import Foundation
import CryptoKit
import ResultCore

/// Explicit development verification. Never opens or modifies the user's normal database.
@MainActor enum AnalysisExportVerification {
    static func run() async -> AppModel? {
        do {
            guard let index = CommandLine.arguments.firstIndex(of: "--verify-analysis-export") else { return nil }
            let urls = CommandLine.arguments.dropFirst(index + 1).filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
            try check(urls.count == 59, "photoの59枚を指定してください。")
            var hashes: [URL: Data] = [:], metadataImages = 0, filenameImages = 0
            for url in urls {
                let data = try Data(contentsOf: url)
                hashes[url] = Data(SHA256.hash(data: data))
                let candidates = ScreenshotDateReader.read(data: data, filename: url.lastPathComponent)
                try check(!candidates.isEmpty && candidates.allSatisfy { $0.timeZoneAssumed && $0.timeZone == "Asia/Tokyo" }, "実画像の日時・日本時間解釈")
                if candidates.contains(where: { $0.source == .metadata }) { metadataImages += 1 }
                else { filenameImages += 1 }
                if url.lastPathComponent == "IMG_0651.PNG" {
                    let f = ISO8601DateFormatter()
                    try check(candidates.allSatisfy { $0.capturedAt == f.date(from: "2026-10-01T08:04:50Z") }, "実EXIF日時")
                } else {
                    let fallback = ScreenshotDateReader.read(properties: [:], filename: url.lastPathComponent)
                    try check(candidates == fallback, "実PNGのファイル名日時")
                }
            }
            try check(metadataImages == 1 && filenameImages == 58, "1 metadata + 58 filename timestamps")
            print("Capture dates: PASS — 59 originals; 1 embedded metadata, 58 filename fallback; timezone assumption recorded.")
            fflush(stdout)
            let sampleNames: Set<String> = ["IMG_0651.PNG", "screenshot_20261001_163453_569.png", "screenshot_20261001_163523_981.png", "screenshot_20261001_163938_579.png", "screenshot_20261001_163940_795.png", "screenshot_20261001_170409_556.png", "screenshot_20261001_170411_557.png"]
            let sample = urls.filter { sampleNames.contains($0.lastPathComponent) }
            try check(sample.count == 7, "通常・詳細3組と設定画像")
            let model = AppModel(inMemory: true)
            model.state.automaticRegistrationEnabled = false // Explicitly exercise the manual confirmation path.
            try check(model.startupError == nil, "検証用起動")
            model.importImages(sample)
            while model.importing { try await Task.sleep(for: .milliseconds(20)) }
            try check(model.pending.count == 7 && model.state.plays.isEmpty, "実画像は確認待ちのみ")
            guard let settings = model.pending.first(where: { $0.settings != nil }) else { throw CoreError.invalid("設定画像のOCR失敗") }
            model.applySettings(settings.settings!, toBatch: false); try check(model.errorMessage == nil, "設定保存")
            model.discardPending(settings.id)
            while let first = model.pending.first {
                guard let other = model.pending.first(where: { $0.id != first.id && AppModel.samePlayCandidate(first, $0) }) else { throw CoreError.invalid("通常／詳細のOCR一致失敗") }
                try model.mergePending(first.id, other.id)
                let merged = model.pending.first(where: { $0.id == first.id })!
                try check(merged.screenshotDates.count == 2, "画像別日時根拠保持")
                var selection = ImportDateSelection(); selection.updateEvidence(merged.screenshotDates)
                try check(selection.playedAt != nil && selection.context.playedAtSource == .screenshot, "撮影日候補の選択")
                try model.register(merged.id, draft: merged.result!, chartID: nil, mergeID: nil, playedAt: selection.playedAt, timing: RegistrationTiming(environment: model.activeEnvironment), dateContext: selection.context)
            }
            let expected: [String: (Int, [Int], [Int], [Int])] = [
                "青春コンプレックス": (988887, [1100,0,0,0,0], [215,0,0,0,0], [567,0,0,0,0]),
                "六兆年と一夜物語": (1064865, [786,1,0,0,0], [233,1,0,0,0], [267,0,0,0,0]),
                "焚音打": (1020889, [1750,17,2,4,4], [754,15,2,4,0], [450,2,0,0,4])
            ]
            for play in model.state.plays {
                guard let e = expected[play.titleAtPlay] else { throw CoreError.invalid("曲名のOCR不一致") }
                try check(play.score == e.0 && play.screenshotDates?.count == 2 && play.dateContext?.playedAtSource == .screenshot, "スコア・画像別日時")
                for (i, judgment) in Judgment.allCases.enumerated() {
                    try check(play.judgments[judgment] == JudgmentCount(total: e.1[i], fast: e.2[i], slow: e.3[i]), "実画像判定一致")
                }
            }
            let before = model.state
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-export-verification-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let data = try model.analysisExportData()
            let file = directory.appendingPathComponent("analysis.json")
            try model.writeAnalysisExport(data, to: file, playCount: 3)
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            try check((json["songs"] as? [Any])?.count == model.state.songs.count && (json["charts"] as? [Any])?.count == model.state.charts.count && (json["plays"] as? [Any])?.count == 3, "JSON全マスター・3プレイ")
            try check((json["app"] as? [String: Any])?["version"] as? String == "0.2.0" && json["formatVersion"] as? Int == AnalysisExportService.formatVersion && json["analysisRulesVersion"] as? Int == AnalysisExportService.analysisRulesVersion, "JSON識別版")
            let text = String(decoding: data, as: UTF8.self)
            try check(!text.contains("sha256") && !text.contains("perceptualHash") && !text.contains(".png") && !text.contains("IMG_0651") && !text.contains("/Users/"), "画像・パス・指紋出力なし")
            let summary = StatisticsService.summarize(model.state.plays)
            try check(summary.judgmentNoteCount == 3664 && summary.timingNoteCount == 2504 && summary.fcRate == 2.0/3 && summary.apRate == 1.0/3, "既存統計")
            let repository = try LocalRepository(storageDirectory: directory.appendingPathComponent("db"))
            try repository.save(model.state)
            try check(try LocalRepository(storageDirectory: directory.appendingPathComponent("db")).load() == model.state, "日時根拠付きディスク再読込")
            try check(model.state == before, "出力で状態不変")
            model.importImages(sample)
            while model.importing { try await Task.sleep(for: .milliseconds(20)) }
            try check(model.duplicateCount == 6 && model.pending.count == 1 && model.state == before, "再取込の6画像重複除外・履歴不変")
            // Keep a genuine result pending so the explicit preview can exercise the import date UI.
            model.clearPending()
            if CommandLine.arguments.contains("--show-export-verification") {
                let previewURL = urls.first { $0.lastPathComponent == "screenshot_20261002_120055_382.png" }!
                model.importImages([previewURL])
                while model.importing { try await Task.sleep(for: .milliseconds(20)) }
            }
            for (url, hash) in hashes { try check(Data(SHA256.hash(data: Data(contentsOf: url))) == hash, "元画像のSHA不変") }
            print("Analysis export: PASS — 7 real OCR images, 3 merged plays/6 anonymous date records, \(model.state.songs.count) songs/\(model.state.charts.count) charts; JSON versions/nulls, historical settings, statistics, duplicate skipping, disk reload, originals unchanged.")
            fflush(stdout)
            return model
        } catch { fputs("分析出力検証エラー: \(error.localizedDescription)\n", stderr); return nil }
    }
    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CoreError.invalid(message) }
    }
}
