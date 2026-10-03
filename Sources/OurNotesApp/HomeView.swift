import SwiftUI
import ResultCore

struct HomeView: View {
    @Bindable var model: AppModel
    @Environment(\.appPalette) private var palette
    var onImport: () -> Void
    var onShowLibrary: () -> Void
    var onShowChart: (HomeRecord) -> Void
    @State private var inspecting: HomeRecord?

    var body: some View {
        let snapshot = HomePresentation.snapshot(state: model.state, gameID: model.gameID,
                                                  batchPlayIDs: model.importCount > 0 ? model.lastBatchPlayIDs : nil)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if model.importing {
                    ProgressView(value: Double(model.processed), total: Double(max(1, model.importCount))) {
                        Text("スクショを解析中 · \(model.processed) / \(model.importCount)枚")
                    }
                    Text("解析と照合が終わると、登録された成果がここに反映されます。").font(.caption).foregroundStyle(.secondary)
                }
                if !model.pending.isEmpty || model.failedCount > 0 { attention }
                if snapshot.totalPlays == 0 {
                    emptyState
                } else {
                    if !model.importing { achievements(snapshot) }
                    totals(snapshot)
                    recent(snapshot.recentRecords)
                    Text("初AP・初FC・コンボ更新は保存された確定履歴の範囲で判定します。異なる環境・設定の記録も含みます。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("home.content")
        .sheet(item: $inspecting) { record in
            HomeRecordDetail(record: record) { inspecting = nil; onShowChart(record) }
                .presentationBackground(palette.background)
        }
    }

    private var attention: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.pending.isEmpty ? "取込結果を確認してください" : "\(model.pending.count)件の確認待ちがあります").font(.callout.weight(.medium))
                if model.failedCount > 0 { Text("登録できなかった結果：\(model.failedCount)件").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button("取込結果を確認", action: onImport).disabled(model.importing)
        }.padding(15).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            if palette.usesBrandUI {
                BrandEmptyState(title: "最初の記録を、スクショから。", description: "初FC・初AP・最大コンボの更新が、ここに集まります。", category: .ourNotes, titleFont: .title2.weight(.semibold))
            } else {
                Image(systemName: "photo.badge.plus").font(.system(size: 34)).foregroundStyle(palette.accent)
                Text("最初の記録を、スクショから。").font(.title2.weight(.semibold))
                Text("初FC・初AP・最大コンボの更新が、ここに集まります。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button(model.pending.isEmpty ? "スクショを追加" : "取込結果を確認", action: onImport)
                .buttonStyle(.borderedProminent).disabled(model.importing)
            Text("曖昧な項目があるときだけ確認します。").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 340)
    }

    private func achievements(_ snapshot: HomeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                if palette.usesBrandUI {
                    BrandSectionHeader(title: snapshot.hasBatch ? "今回の取込" : "最近の成果", category: .achievement,
                                       role: snapshot.achievements.isEmpty ? .section : .signature)
                        .foregroundStyle(Color.primary)
                } else { Label(snapshot.hasBatch ? "今回の取込" : "最近の成果", systemImage: "checkmark.seal") }
                Spacer()
                if snapshot.hasBatch {
                    Button("取込結果", action: onImport).buttonStyle(.borderless)
                } else { Text("最近登録した\(snapshot.focusCount)プレイから") }
            }.font(.caption).foregroundStyle(.secondary)
            if !snapshot.achievements.isEmpty {
                Text("\(snapshot.achievements.count)譜面に新しい成果。").font(.title.weight(.semibold))
                if snapshot.hasBatch { Text("\(snapshot.focusCount)プレイを登録しました").font(.callout).foregroundStyle(.secondary) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 13), count: min(3, snapshot.achievements.count)), spacing: 13) {
                    ForEach(snapshot.achievements.prefix(3)) { achievement in
                        achievementCard(achievement)
                    }
                }
                if snapshot.achievements.count > 3 {
                    DisclosureGroup("ほか\(snapshot.achievements.count - 3)譜面の成果") {
                        ForEach(snapshot.achievements.dropFirst(3)) { achievement in
                            Button { inspecting = achievement.record } label: {
                                HStack {
                                    Text(achievement.record.song.title)
                                    Text(achievement.record.chart.difficulty).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(achievement.kind.title).foregroundStyle(palette.usesBrandUI ? palette.achievementColor(achievement.kind) : palette.accent)
                                }.font(.callout).padding(.vertical, 6)
                            }.buttonStyle(.plain)
                        }
                    }.font(.caption)
                }
            } else {
                Text(snapshot.hasBatch ? (snapshot.focusCount == 0 ? "新しい登録はありません" : "\(snapshot.focusCount)プレイを登録しました") : "プレイの記録が積み重なっています")
                    .font(.title2.weight(.semibold))
                Text(snapshot.hasBatch && snapshot.focusCount == 0 ? "重複スキップや確認待ちの内容は、取込結果から確認できます。" : "初AP・初FC・最大コンボが更新されると、ここに表示します。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack(alignment: .topTrailing) {
                    if palette.usesBrandUI { palette.surface }
                    else { LinearGradient(colors: [palette.surface, palette.glow], startPoint: .topLeading, endPoint: .bottomTrailing) }
                    if palette.usesLogoMotif {
                        LogoRibbons(palette: palette).frame(width: 290, height: 130).opacity(palette.isDark ? 0.26 : 0.20)
                            .padding(.trailing, 12).padding(.top, 8)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(palette.border) }
    }

    private func achievementCard(_ achievement: HomeAchievement) -> some View {
        let record = achievement.record
        let accent = palette.achievementColor(achievement.kind)
        return Button { inspecting = record } label: {
            VStack(alignment: .leading, spacing: 10) {
                if palette.usesBrandUI {
                    HStack {
                        BrandNoteLines(colors: palette.brand, role: .achievement(achievement.kind))
                        BrandScriptLabel(category: .newRecord)
                        Spacer(minLength: 0)
                        Text(achievement.kind == .firstAP ? "AP" : achievement.kind == .firstFC ? "FC" : "COMBO")
                            .font(.caption2.weight(.semibold)).foregroundStyle(accent)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                Label(achievement.kind.title, systemImage: achievement.kind.symbol)
                    .font(.caption.weight(.semibold)).foregroundStyle(accent)
                Text(record.song.title).font(.headline).lineLimit(2).frame(height: 40, alignment: .topLeading).help(record.song.title)
                Text(record.chartLabel).font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("最大コンボ").font(.caption).foregroundStyle(.secondary)
                    Text(record.play.combo.map { $0.formatted() } ?? "—").font(.system(size: 29, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                HStack {
                    if let increase = achievement.comboIncrease { Text("前の記録から +\(increase.formatted())") }
                    else { Text("PERFECT \(percent(record.perfectRate))") }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                }.font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(palette.raised, in: RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .top) {
                    if palette.usesLogoMotif {
                        Rectangle().fill(LinearGradient(colors: palette.ribbonColors, startPoint: .leading, endPoint: .trailing)).frame(height: 3)
                            .padding(.horizontal, 8)
                    }
                }
                .overlay { RoundedRectangle(cornerRadius: 9).stroke(palette.border) }
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityIdentifier("home.achievement.\(achievement.kind.rawValue)")
    }

    private func totals(_ snapshot: HomeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { BrandSectionHeader(title: "これまでの達成", category: .history); Spacer(); Button("譜面で比較", action: onShowLibrary).buttonStyle(.borderless) }
            HStack(spacing: 20) {
                HomeTotal(title: "記録した譜面", value: snapshot.playedChartCount, detail: "/ \(snapshot.chartCount)譜面")
                Divider()
                HomeTotal(title: "FC達成", value: snapshot.fcCount, detail: "譜面 · APを含む")
                Divider()
                HomeTotal(title: "AP達成", value: snapshot.apCount, detail: "譜面")
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 15)
                .overlay(alignment: .top) { Divider() }.overlay(alignment: .bottom) { Divider() }
            Text("現行マスターの譜面を集計しています。").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func recent(_ records: [HomeRecord]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text("最近登録したプレイ").font(.headline); Spacer(); Text("登録が新しい順").font(.caption).foregroundStyle(.secondary) }
            ForEach(records) { record in
                Button { inspecting = record } label: {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(record.song.title).font(.callout.weight(.medium)); Text(record.play.achievement.label).font(.caption).foregroundStyle(record.play.achievement.isAP ? palette.ap : (record.play.achievement.isFC ? palette.fc : Color.secondary)) }
                            Text("\(record.chartLabel) · \(record.play.importedAt.formatted(date: .abbreviated, time: .shortened)) 登録")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("最大コンボ \(record.play.combo.map { $0.formatted() } ?? "—")").font(.callout.monospacedDigit())
                            Text("PERFECT \(percent(record.perfectRate))").font(.caption).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 11).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if record.id != records.last?.id { Divider() }
            }
        }
    }
}

private struct HomeTotal: View {
    let title: String
    let value: Int
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(value.formatted()).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HomeRecordDetail: View {
    let record: HomeRecord
    let onShowChart: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if palette.usesBrandUI { BrandSectionHeader(title: "プレイ詳細", category: .history, font: .caption.weight(.medium)) }
            HStack { Text(record.song.title).font(.title2.weight(.semibold)); Spacer(); Button("閉じる") { dismiss() } }
            Text("\(record.chartLabel) · \(record.play.achievement.label)").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("最大コンボ").font(.caption).foregroundStyle(.secondary)
                    Text(record.play.combo.map { $0.formatted() } ?? "—").font(.title.monospacedDigit())
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) { Text("PERFECT率").font(.caption).foregroundStyle(.secondary); Text(percent(record.perfectRate)).font(.title2.monospacedDigit()) }
            }
            Grid(alignment: .leading, horizontalSpacing: 25, verticalSpacing: 9) {
                GridRow { Text("判定"); Text("合計"); Text("FAST"); Text("SLOW") }.foregroundStyle(.secondary)
                ForEach(Judgment.allCases, id: \.self) { judgment in
                    let count = record.play.judgments[judgment] ?? .init()
                    GridRow {
                        Text(judgment.rawValue).frame(maxWidth: .infinity, alignment: .leading)
                        Text(count.total.map { $0.formatted() } ?? "—").gridColumnAlignment(.trailing)
                        Text(count.fast.map { $0.formatted() } ?? "—").gridColumnAlignment(.trailing)
                        Text(count.slow.map { $0.formatted() } ?? "—").gridColumnAlignment(.trailing)
                    }
                }
            }.font(.callout.monospacedDigit())
            Divider()
            Text("プレイ日時：\(record.play.playedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "不明")").font(.caption)
            Text("登録日時：\(record.play.importedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
            Text(libraryEnvironmentLabel(record.play)).font(.caption).foregroundStyle(.secondary)
            HStack { Text("PERFECT率は全5判定の合計を分母に計算").font(.caption2).foregroundStyle(.secondary); Spacer(); Button("譜面の履歴を開く", action: onShowChart).buttonStyle(.borderedProminent) }
        }.padding(28).frame(width: 540)
    }
}
