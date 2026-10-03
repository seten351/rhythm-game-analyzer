import AppKit
import Foundation
import UniformTypeIdentifiers
import ResultCore

/// Bundle metadata is authoritative in the app; the resource provides the same version for SwiftPM runs.
enum AppVersion {
    static func current() throws -> AnalysisExportAppInfo {
        if Bundle.main.bundleIdentifier == "jp.local.ournotes.analyzer",
           let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            return .init(version: version, build: build)
        }
        let url = Bundle.module.resourceURL!.appendingPathComponent("Resources/app-version.json")
        return try JSONDecoder().decode(AnalysisExportAppInfo.self, from: Data(contentsOf: url))
    }
}

extension AppModel {
    func analysisExportData(exportedAt: Date = Date()) throws -> Data {
        guard startupError == nil else { throw CoreError.invalid("起動エラーを解決してから出力してください。") }
        guard !importing else { throw CoreError.invalid("解析完了後に出力してください。") }
        let document = try AnalysisExportService.document(state: state, gameID: gameID,
            app: AppVersion.current(), exportedAt: exportedAt,
            timingSpecification: timingSpecification, timingEnvironmentPolicy: timingEnvironmentPolicy)
        return try AnalysisExportService.encode(document)
    }
    func writeAnalysisExport(_ data: Data, to url: URL, playCount: Int) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "json" else { throw CoreError.invalid("ローカルのJSON保存先を選択してください。") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try data.write(to: url, options: .atomic)
        notice = "分析用JSONを出力しました（\(playCount)プレイ）。"
    }
    func chooseAnalysisExport() {
        perform {
            let now = Date()
            let data = try analysisExportData(exportedAt: now)
            let count = state.plays.filter { $0.gameID == gameID && $0.confirmed }.count
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true; panel.isExtensionHidden = false
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Tokyo"); formatter.dateFormat = "yyyyMMdd-HHmmss"
            panel.nameFieldStringValue = "our-notes-analysis-\(formatter.string(from: now)).json"
            panel.message = "表示中の絞り込みに関係なく、全マスターと保存済みの確定履歴を出力します。"
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
                throw CoreError.invalid("保存パネルを表示するウィンドウが見つかりません。")
            }
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                self?.perform { try self?.writeAnalysisExport(data, to: url, playCount: count) }
            }
        }
    }
}
