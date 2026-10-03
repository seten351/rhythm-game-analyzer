import SwiftUI
import Charts
import ResultCore

struct ChartDetailView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var row: LibraryChartRow
    @Binding var tab: LibraryDetailTab
    var onShowTimingAnalysis: () -> Void
    @State private var editing: PlayRecord?
    @State private var deleting: PlayRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(row.song.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    HStack(spacing: 10) {
                        Text("\(row.chart.difficulty) · Lv.\(row.chart.level.map(String.init) ?? "—")").font(.caption).foregroundStyle(.secondary)
                        LibraryAchievementLabel(row: row)
                    }
                }
                Picker("譜面の詳細", selection: $tab) {
                    Text("概要").tag(LibraryDetailTab.overview)
                    Text("履歴 \(row.plays.count)").tag(LibraryDetailTab.history)
                }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("library.detailTab")
                if row.plays.isEmpty {
                    if palette.usesBrandUI {
                        BrandEmptyState(title: "まだプレイ記録がありません。", description: "スクショを取り込むと、ここに結果が表示されます。", category: .history, alignment: .leading, titleFont: .callout)
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("まだプレイ記録がありません。").font(.callout)
                            Text("スクショを取り込むと、ここに結果が表示されます。").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 10)
                    }
                } else if tab == .overview {
                    overview
                } else {
                    history
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editing) { play in PlayEditor(model: model, play: play) }
        .confirmationDialog("このプレイ記録を削除しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("プレイ記録を削除", role: .destructive) {
                if let play = deleting { model.deletePlay(play.id) }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            if let play = deleting { Text("\(row.song.title) · \(play.score.formatted())\n\(playDateLabel(play))") }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let best = row.bestPlay {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("最高スコア")
                        Spacer()
                        Text("全環境・全設定")
                    }.font(.caption).foregroundStyle(.secondary)
                    Text(best.score.formatted()).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(libraryEnvironmentLabel(best)).font(.caption).foregroundStyle(.secondary)
                    Text("タイミング \(best.environment?.settings.noteTiming.map { decimalString($0) } ?? "不明")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let latest = row.latestPlay {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("プレイ回数").font(.caption).foregroundStyle(.secondary)
                        Text("\(row.plays.count) 回").font(.headline).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(latest.playedAt == nil ? "最終記録（登録日）" : "最終記録（プレイ日）").font(.caption).foregroundStyle(.secondary)
                        Text(latest.orderDate.formatted(date: .numeric, time: .omitted)).font(.callout.weight(.medium)).monospacedDigit()
                    }.help(playDateLabel(latest))
                }.padding(.vertical, 13)
                    .overlay(alignment: .top) { Divider() }
                    .overlay(alignment: .bottom) { Divider() }
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        BrandSectionHeader(title: "最新の判定")
                        Spacer()
                        Text(latest.achievement.label).font(.caption).foregroundStyle(.secondary)
                    }
                    judgmentGrid(latest, detailed: false)
                    Divider()
                    HStack {
                        Text("FAST \(latest.timingCounts.map { $0.fast.formatted() } ?? "—")").foregroundStyle(.blue)
                        Spacer()
                        Text("SLOW \(latest.timingCounts.map { $0.slow.formatted() } ?? "—")").foregroundStyle(.pink)
                    }.font(.callout.monospacedDigit())
                    Text("PERFECT＋GREAT").font(.caption2).foregroundStyle(.secondary)
                    Text(playDateLabel(latest)).font(.caption2).foregroundStyle(.secondary)
                }
                Button("傾向分析でタイミングを確認", action: onShowTimingAnalysis).buttonStyle(.bordered)
                DisclosureGroup("この譜面の推移") { trends.padding(.top, 12) }
                    .font(.callout)
            }
        }
    }

    private var history: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(row.plays) { play in
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(play.score.formatted()).font(.title3.weight(.medium)).monospacedDigit()
                        Spacer(minLength: 4)
                        Text(play.achievement.label).font(.caption).foregroundStyle(play.achievement.isAP ? palette.ap : play.achievement.isFC ? palette.fc : .secondary)
                    }
                    Text(playDateLabel(play)).font(.caption).foregroundStyle(.secondary)
                    Text(libraryEnvironmentLabel(play)).font(.caption2).foregroundStyle(.secondary)
                    Text("タイミング \(play.environment?.settings.noteTiming.map { decimalString($0) } ?? "不明") · プリセット v\(play.presetVersion)")
                        .font(.caption2).foregroundStyle(.secondary)
                    DisclosureGroup("判定の詳細") {
                        judgmentGrid(play, detailed: true).padding(.top, 8)
                        HStack { Text("最大コンボ"); Spacer(); Text(play.combo.map { $0.formatted() } ?? "—").monospacedDigit() }
                            .font(.caption).padding(.top, 5)
                    }.font(.caption)
                    HStack {
                        if play.registrationMethod == .automatic { Label("自動登録", systemImage: "checkmark.shield").font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        Button("編集") { editing = play }.buttonStyle(.bordered).controlSize(.small)
                        Button { deleting = play } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .accessibilityLabel("このプレイ記録を削除").help("このプレイ記録を削除")
                    }
                }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).stroke(.quaternary) }
            }
        }
    }

    private func judgmentGrid(_ play: PlayRecord, detailed: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            if detailed {
                GridRow { Text("判定"); Text("合計"); Text("FAST"); Text("SLOW") }.foregroundStyle(.secondary)
            }
            ForEach(Judgment.allCases, id: \.self) { judgment in
                let counts = play.judgments[judgment] ?? .init()
                GridRow {
                    Text(judgment.rawValue).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    Text(counts.total.map { $0.formatted() } ?? "—").gridColumnAlignment(.trailing)
                    if detailed {
                        Text(counts.fast.map { $0.formatted() } ?? "—").gridColumnAlignment(.trailing)
                        Text(counts.slow.map { $0.formatted() } ?? "—").gridColumnAlignment(.trailing)
                    }
                }
            }
        }.font(.caption.monospacedDigit())
    }

    private var trends: some View {
        let plays = Array(row.plays.reversed())
        let timed = plays.filter { ($0.timingCounts.map { $0.fast + $0.slow } ?? 0) > 0 }
        let statistics = StatisticsService.summarize(plays.filter(\.confirmed))
        let tickDates = Array(Set([plays.first?.orderDate, plays.isEmpty ? nil : plays[plays.count / 2].orderDate, plays.last?.orderDate].compactMap { $0 })).sorted()
        let sameDay = tickDates.first.flatMap { first in tickDates.last.map { Calendar.current.isDate(first, inSameDayAs: $0) } } ?? true
        let dateFormat: Date.FormatStyle = sameDay ? .dateTime.hour().minute() : .dateTime.month(.twoDigits).day(.twoDigits)
        return VStack(alignment: .leading, spacing: 16) {
            Text("スコア履歴").font(.caption.weight(.medium))
            Charts.Chart(plays) { play in
                LineMark(x: .value("日時", play.orderDate), y: .value("スコア", play.score))
                PointMark(x: .value("日時", play.orderDate), y: .value("スコア", play.score))
            }.frame(height: 140).chartYScale(domain: .automatic(includesZero: false))
                .chartXScale(range: .plotDimension(padding: 8))
                .chartXAxis {
                    AxisMarks(values: tickDates) { value in
                        AxisGridLine(); AxisTick()
                        AxisValueLabel(format: dateFormat, anchor: value.index == 0 ? .topLeading : value.index == tickDates.count - 1 ? .topTrailing : .top)
                    }
                }
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                .accessibilityLabel("個別譜面のスコア履歴")
            if !timed.isEmpty {
                Text("FAST / SLOW（PERFECT＋GREAT）").font(.caption.weight(.medium))
                Charts.Chart(Array(timed.enumerated()), id: \.element.id) { index, play in
                    if let counts = play.timingCounts {
                        BarMark(x: .value("記録順", "\(index + 1)"), y: .value("割合", Double(counts.fast) / Double(counts.fast + counts.slow))).foregroundStyle(by: .value("方向", "FAST"))
                        BarMark(x: .value("記録順", "\(index + 1)"), y: .value("割合", Double(counts.slow) / Double(counts.fast + counts.slow))).foregroundStyle(by: .value("方向", "SLOW"))
                    }
                }.frame(height: 130).chartForegroundStyleScale(["FAST": Color.blue, "SLOW": Color.pink]).chartYScale(domain: 0...1)
                    .chartYAxis { AxisMarks(values: [0.0, 0.5, 1.0]) { _ in AxisGridLine(); AxisValueLabel(format: FloatingPointFormatStyle<Double>.Percent()) } }
                    .accessibilityLabel("詳細データのあるプレイのFASTとSLOW、古い記録から順に表示")
                Text("詳細のある記録を古い順に表示").font(.caption2).foregroundStyle(.secondary)
            }
            Text(timingBiasLabel(statistics.timingBias)).font(.callout.weight(.medium)).monospacedDigit()
            Text("確認済みの全履歴：\(statistics.timingSampleCount)プレイ / \(statistics.timingNoteCount.formatted())件")
                .font(.caption).foregroundStyle(.secondary)
            Text("異なる環境・設定の記録を含みます。日時未指定の結果は登録日時で表示しています。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

func libraryEnvironmentLabel(_ play: PlayRecord) -> String {
    guard let environment = play.environment else { return "環境不明" }
    let parts = [environment.name, environment.audioOutput].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    return parts.isEmpty ? "環境不明" : parts.joined(separator: " · ")
}
