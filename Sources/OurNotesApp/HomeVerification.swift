import Foundation
import ResultCore

@MainActor enum HomeVerification {
    static func previewModel(empty: Bool = false) -> AppModel {
        if empty { return AppModel(inMemory: true) }
        let model = LibraryVerification.previewModel()
        guard model.startupError == nil else { return model }
        var state = model.state
        let featuredTitles = Set(["夢我夢中", "青春コンプレックス", "六兆年と一夜物語"])
        let latest = Dictionary(grouping: state.plays, by: \.chartID).compactMapValues { $0.max { $0.importedAt < $1.importedAt }?.id }
        let imported = Date()
        for index in state.plays.indices {
            let play = state.plays[index]
            if play.achievement == .unknown { state.plays[index].combo = nil }
            guard featuredTitles.contains(play.titleAtPlay) else { continue }
            if latest[play.chartID] == play.id {
                state.plays[index].importedAt = imported
                if play.titleAtPlay == "夢我夢中" { state.plays[index].combo = 850 }
                model.lastBatchPlayIDs.append(play.id)
                model.importReceipts.append(.init(title: play.titleAtPlay, status: .automatic, playID: play.id, message: "成果ホーム検証用の人工記録です。", imageCount: 2))
            } else { state.plays[index].combo = 600 }
        }
        do { try model.commit(state) } catch { model.startupError = error.localizedDescription }
        model.importCount = 6; model.processed = 6
        model.notice = "成果ホーム検証用の人工記録です。通常DBは使用していません。"
        return model
    }
}
