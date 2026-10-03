import SwiftUI
import ResultCore

struct CatalogView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label("楽曲マスターは自動で登録されます", systemImage: "checkmark.circle.fill").font(.title2.bold()).foregroundStyle(palette.accent)
                Text("攻略サイト・Wikiで照合した全曲データを使用します。楽曲の手動登録やマスターファイルの選択は不要です。")
                let charts = model.state.activeCharts(gameID: model.gameID)
                HStack {
                    MetricCard(title: "収録曲", value: "\(Set(charts.map(\.songID)).count)")
                    MetricCard(title: "収録譜面", value: "\(charts.count)", detail: "EASY・NORMAL・HARD・EXPERT")
                }
                ForEach(model.state.catalogs.filter { $0.gameID == model.gameID }, id: \.sourceID) { catalog in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Web照合済みマスター · 改訂 \(catalog.revision)").font(.headline)
                        Text("データ更新日時: \(catalog.generatedAt)").font(.caption).foregroundStyle(.secondary)
                        Text("アプリへの適用: \(catalog.importedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("確認元").font(.title2.bold())
                Link("Gamerch 楽曲一覧", destination: URL(string: "https://gamerch.com/bang-dream-on/993622")!)
                Link("AppMedia 楽曲一覧", destination: URL(string: "https://appmedia.jp/bang-dream-on/80416189")!)
                Link("アワーノーツ データベースWiki 楽曲一覧", destination: URL(string: "https://wikiwiki.jp/on_database/楽曲一覧")!)
                Text("アプリに同梱された確認日時点のデータです。新しいマスターはアプリ更新後の起動時に適用されます。").foregroundStyle(.secondary)
                Text("既存データの扱い").font(.title2.bold())
                Text("楽曲名・別名・難易度・レベルはWebの正規データに統一します。過去の手修正は引き継ぎません。プレイ履歴とプレイ時点の値は保持し、正規マスターに対応しない履歴はアーカイブで確認できます。")
            }.padding(24)
        }
    }
}
