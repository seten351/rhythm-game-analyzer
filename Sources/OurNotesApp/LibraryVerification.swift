import Foundation
import ResultCore

/// Disposable UI fixture. Both entry points create an in-memory repository explicitly.
@MainActor enum LibraryVerification {
    static func previewModel(artwork: SongArtworkStore? = nil) -> AppModel {
        let model = AppModel(inMemory: true, artwork: artwork)
        guard model.startupError == nil else { return model }
        var state = model.state
        let wired = PlayEnvironment(name: "iPad", device: TimingEnvironmentPolicy.fixedDeviceName, audioOutput: "有線イヤホン", settings: .init(noteSpeed: 10.5, noteTiming: 0.1, chartPosition: 0, mirror: false))
        var speakers = wired; speakers.id = UUID(); speakers.audioOutput = "スピーカー"; speakers.settings.noteTiming = 0.12
        state.environments = [wired, speakers]
        let examples: [(String, Achievement, Int)] = [
            ("夢我夢中", .none, 1_249_535), ("青春コンプレックス", .ap, 988_887),
            ("六兆年と一夜物語", .fc, 1_064_865), ("Ave Mujica", .unknown, 1_554_926), ("焚音打", .none, 1_020_889)
        ]
        let now = Date()
        for (songIndex, example) in examples.enumerated() {
            guard let song = state.songs.first(where: { $0.title == example.0 }),
                  let chart = state.charts.first(where: { $0.songID == song.id && $0.difficulty == "EXPERT" }) else { continue }
            for index in 0..<(songIndex == 3 ? 1 : 3) {
                let achievement: Achievement = index == 0 ? example.1 : .none
                let total = chart.noteCount ?? 1000
                let great = achievement == .ap ? 0 : 6
                let miss = achievement.isFC ? 0 : 2
                let judgments: [Judgment: JudgmentCount] = achievement == .unknown ? [:] : [
                    .perfect: .init(total: total - great - miss, fast: 64, slow: 43), .great: .init(total: great, fast: great, slow: 0),
                    .good: .init(total: 0, fast: 0, slow: 0), .bad: .init(total: 0, fast: 0, slow: 0), .miss: .init(total: miss, fast: 0, slow: miss)
                ]
                let date = now.addingTimeInterval(-Double(songIndex * 3600 + index * 86400))
                var play = PlayRecord(chartID: chart.id, gameID: song.gameID, titleAtPlay: song.title, difficultyAtPlay: chart.difficulty, levelAtPlay: chart.level, score: example.2 - index * 15_000, combo: achievement.isFC ? total : total / 2, achievement: achievement, judgments: judgments, importedAt: date.addingTimeInterval(60), playedAt: songIndex == 3 ? nil : date, presetID: "our-notes-results", presetVersion: 2, environment: songIndex == 3 ? nil : index == 2 ? speakers : wired, fingerprints: [])
                play.registrationMethod = index == 0 ? .automatic : .manual
                state.plays.append(play)
            }
        }
        let unknown = Song(gameID: model.gameID, masterTitle: "表示検証：レベル不明", provisional: true)
        let retired = Song(gameID: model.gameID, masterTitle: "表示検証：アーカイブ", availability: .retired)
        state.songs += [unknown, retired]
        state.charts += [Chart(songID: unknown.id, masterDifficulty: "EXPERT"), Chart(songID: retired.id, masterDifficulty: "EXPERT", masterLevel: 27)]
        do { try model.commit(state); model.selectedEnvironmentID = wired.id }
        catch { model.startupError = error.localizedDescription }
        model.notice = "楽曲一覧UI検証用の人工履歴です。通常DBは使用せず、終了時に破棄します。"
        return model
    }
}
