import Foundation
import ResultCore

/// Explicit UI fixture. Synthetic history in memory; never opens the normal repository.
@MainActor enum TimingVerification {
    static func previewModel() -> AppModel {
        let model = AppModel(inMemory: true, loadBundledCatalog: false)
        let environment = PlayEnvironment(name: "一致する傾向（人工データ）", settings: .init(noteSpeed: Decimal(string: "10.50"), noteTiming: Decimal(string: "0.10"), chartPosition: 0, mirror: false))
        var conflicting = environment; conflicting.id = UUID(); conflicting.name = "レベル間で反対（人工データ）"
        var state = AppState(); state.environments = [environment, conflicting]
        for songIndex in 0..<8 {
            let song = Song(gameID: "our-notes", masterTitle: "人工曲\(songIndex + 1)：タイミング確認用")
            let level: Int? = songIndex < 3 ? 25 : songIndex < 6 ? 26 : songIndex == 6 ? 28 : nil
            let chart = Chart(songID: song.id, masterDifficulty: "EXPERT", masterLevel: level)
            state.songs.append(song); state.charts.append(chart)
            for current in state.environments {
                if current.id == conflicting.id && songIndex >= 6 { continue }
                for index in 0..<(songIndex < 6 ? 3 : 2) {
                    var snapshot = current
                    snapshot.audioOutput = ["", "スピーカー", "イヤホン"][index]
                    let fastDominates = current.id == conflicting.id ? songIndex < 3 : songIndex == 6
                    state.plays.append(PlayRecord(chartID: chart.id, gameID: song.gameID, titleAtPlay: song.title, difficultyAtPlay: chart.difficulty, levelAtPlay: level, score: 900_000 + index, achievement: .unknown, judgments: [.perfect: .init(fast: fastDominates ? 150 : 50, slow: fastDominates ? 50 : 150), .great: .init(fast: 0, slow: 0)], importedAt: Date().addingTimeInterval(Double(index - 3) * 60), presetID: "verification", presetVersion: 2, environment: snapshot, fingerprints: [.init(sha256: "synthetic-timing-\(current.id)-\(songIndex)-\(index)", layout: "detail")]))
                }
            }
        }
        do { try model.commit(state); model.selectedEnvironmentID = environment.id }
        catch { model.startupError = error.localizedDescription }
        model.notice = "タイミングUI検証用の人工履歴です。通常DBは使用せず、終了時に破棄します。"
        return model
    }
}
