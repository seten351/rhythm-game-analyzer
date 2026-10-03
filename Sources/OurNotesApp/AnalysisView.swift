import SwiftUI
import Charts
import ResultCore

enum AnalysisMetric: String, CaseIterable {
    case fast = "FAST比率", slow = "SLOW比率", perfect = "PERFECT率", great = "GREAT率", good = "GOOD率", bad = "BAD率", miss = "MISS率", fc = "FC率", ap = "AP率", score = "平均スコア"
    func value(_ s: SummaryStatistics) -> Double? {
        switch self { case .fast: return s.fastRate; case .slow: return s.slowRate; case .perfect: return s.judgmentRates[.perfect]; case .great: return s.judgmentRates[.great]; case .good: return s.judgmentRates[.good]; case .bad: return s.judgmentRates[.bad]; case .miss: return s.judgmentRates[.miss]; case .fc: return s.fcRate; case .ap: return s.apRate; case .score: return s.scoreMean }
    }
}
private enum AnalysisSection: String, CaseIterable { case summary = "サマリー", timing = "タイミング調整", data = "詳細データ" }

struct AnalysisView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    var showTimingOnAppear = false
    @State private var section: AnalysisSection = .summary
    @State private var grouping: Grouping = .difficulty
    @State private var metric: AnalysisMetric = .fast
    @State private var environmentID: UUID?
    @State private var editingTiming: PlayEnvironment?
    var plays: [PlayRecord] { model.state.plays.filter { $0.gameID == model.gameID && (environmentID == nil || $0.environment?.id == environmentID) } }
    var groups: [StatisticsGroup] { StatisticsService.grouped(plays, by: grouping) }
    var summary: SummaryStatistics { StatisticsService.summarize(plays) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 24) {
                ForEach(AnalysisSection.allCases, id: \.self) { item in
                    Button { section = item } label: {
                        VStack(spacing: 12) {
                            Text(item.rawValue).font(.callout.weight(section == item ? .semibold : .regular))
                                .foregroundStyle(section == item ? palette.accent : Color.secondary)
                            Rectangle().fill(section == item ? palette.accent : Color.clear).frame(height: 2)
                        }.fixedSize(horizontal: true, vertical: false)
                    }.buttonStyle(.plain).accessibilityAddTraits(section == item ? .isSelected : [])
                }
                Spacer()
                Picker("環境", selection: $environmentID) {
                    Text(section == .timing ? "使用中の環境" : "全環境").tag(nil as UUID?)
                    ForEach(model.state.environments) { Text($0.name).tag(Optional($0.id)) }
                }.frame(maxWidth: 240).padding(.bottom, 10)
            }.padding(.horizontal, 28).padding(.top, 18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if plays.isEmpty && section != .timing {
                        Group {
                            if palette.usesBrandUI {
                                BrandEmptyState(title: "まだプレイ記録がありません", description: "スクショを取り込むと、判定の傾向と達成状況がここに表示されます。", category: .analysis)
                            } else {
                                ContentUnavailableView("まだプレイ記録がありません", systemImage: "chart.bar.xaxis", description: Text("スクショを取り込むと、判定の傾向と達成状況がここに表示されます。"))
                            }
                        }.frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        switch section {
                        case .summary: summaryContent
                        case .timing: timingContent
                        case .data: detailContent
                        }
                    }
                }.padding(28)
            }
        }
        .onAppear { if showTimingOnAppear { section = .timing } }
    }
    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 28) {
                AnalysisStat(title: "保存済みプレイ", value: "\(summary.playCount)", detail: "\(Set(plays.map(\.chartID)).count)譜面の記録")
                Divider()
                AnalysisStat(title: "FC率", value: percent(summary.fcRate), detail: "APを含む · 対象\(summary.achievementSampleCount)回")
                Divider()
                AnalysisStat(title: "AP率", value: percent(summary.apRate), detail: "対象\(summary.achievementSampleCount)回")
            }.fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 20) {
                HStack { BrandSectionHeader(title: "FAST / SLOW のバランス"); Spacer(); Text(environmentID == nil ? "全履歴" : "選択中の環境").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    balanceValue("FAST", value: summary.fastRate)
                    Spacer()
                    balanceValue("SLOW", value: summary.slowRate, alignment: .trailing)
                }
                if let fast = summary.fastRate, let slow = summary.slowRate, fast + slow > 0 {
                    GeometryReader { proxy in
                        HStack(spacing: 3) {
                            Color.blue.opacity(0.75).frame(width: max(0, proxy.size.width - 3) * fast / (fast + slow))
                            Color.pink.opacity(0.65)
                        }.clipShape(RoundedRectangle(cornerRadius: 5))
                    }.frame(height: 15).accessibilityLabel("FAST \(percent(summary.fastRate))、SLOW \(percent(summary.slowRate))")
                } else { Text("FAST/SLOWの詳細記録はまだありません。").foregroundStyle(.secondary) }
                Text("\(summary.timingSampleCount)プレイ · \(summary.timingNoteCount.formatted())件 ／ PERFECT＋GREATの詳細件数で集計")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24).background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 16) {
                analysisLink("タイミング調整", detail: "全曲横断・レベル別で確認", target: .timing)
                analysisLink("判定と集計の詳細", detail: "数値・対象件数を確認", target: .data)
            }
            if groups.count > 1 { comparisonChart }
        }
    }
    private func balanceValue(_ label: String, value: Double?, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(percent(value)).font(.system(size: 30, weight: .semibold)).monospacedDigit()
        }
    }
    private func analysisLink(_ title: String, detail: String, target: AnalysisSection) -> some View {
        Button { section = target } label: {
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.callout.weight(.medium)); Text(detail).font(.caption).foregroundStyle(.secondary) }
                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).stroke(.quaternary) }
        }.buttonStyle(.plain)
    }
    private var timingContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("固定タイミングの調整候補").font(.title3.weight(.semibold))
            Text("現在の環境・設定に一致する詳細結果を、全曲横断とプレイ時レベル別（Lv.25・26など）で確認します。")
                .font(.callout).foregroundStyle(.secondary)
            if let environment = model.state.environments.first(where: { $0.id == (environmentID ?? model.selectedEnvironmentID) }) {
                let analysis = TimingTrendService.analyze(gameID: model.gameID, environment: environment, plays: model.state.plays, charts: model.state.charts, specification: model.timingSpecification, environmentPolicy: model.timingEnvironmentPolicy)
                HStack {
                    Text("\(environment.name) · 固定値 \(environment.settings.noteTiming.map { decimalString($0) } ?? "未確定")").font(.callout.monospacedDigit())
                    Spacer()
                    Button("ゲームで変更した値を記録する…") { editingTiming = environment }
                        .buttonStyle(.bordered).disabled(model.importing)
                }
                Text("速度 \(decimalString(environment.settings.noteSpeed)) · 譜面位置 \(decimalString(environment.settings.chartPosition)) · ミラー \(environment.settings.mirror.map { $0 ? "ON" : "OFF" } ?? "不明")")
                    .font(.caption).foregroundStyle(.secondary)
                TimingTrendPanel(model: model, title: "全体の傾向", recommendation: analysis.overall)
                Text("プレイ時レベル別").font(.headline)
                Text("レベル別の候補は、そのレベル帯を中心に試す際の参考です。保存する固定値は環境ごとに1つです。")
                    .font(.caption).foregroundStyle(.secondary)
                if analysis.levels.isEmpty { Text("現在の設定に一致する詳細結果がありません。").foregroundStyle(.secondary) }
                ForEach(analysis.levels) { group in
                    DisclosureGroup {
                        TimingTrendPanel(model: model, title: "\(group.label)の根拠", recommendation: group.recommendation)
                            .padding(.top, 8)
                    } label: {
                        HStack(spacing: 16) {
                            Text(group.label).font(.callout.weight(.semibold)).frame(width: 85, alignment: .leading)
                            Text(timingBiasLabel(group.recommendation.songBias)).font(.callout.monospacedDigit()).frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(group.recommendation.songCount)曲 · \(group.recommendation.playCount)回").font(.caption).foregroundStyle(.secondary)
                            Text(group.recommendation.proposed.map { "候補 \(decimalString($0))" } ?? group.recommendation.status.label)
                                .font(.caption).foregroundStyle(group.recommendation.proposed == nil ? Color.secondary : palette.accent)
                                .frame(width: 165, alignment: .trailing)
                        }
                    }.padding(.vertical, 8)
                    Divider()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("集計対象：確認済み・同一環境・全設定一致のPERFECT＋GREAT詳細。各譜面の直近10プレイを選び、同じデータを全体とレベル別に分けます。")
                    Text("候補の条件：異なる3曲以上・詳細500件以上・曲を均等に扱った偏り10%以上・3分の2以上の曲が同方向・詳細件数で加重した偏りも同方向。同じ曲の別難易度は1曲と数えます。")
                    Text("M2 iPad Pro 11インチ固定 · スピーカー／イヤホンをまとめて解析。候補は1ステップの試行用です。表示だけでは設定や履歴を変更しません。")
                }.font(.caption).foregroundStyle(.secondary)
                .sheet(item: $editingTiming) { baseline in
                    FixedTimingEditor(model: model, environment: baseline, proposed: analysis.overall.proposed)
                }
            } else { Text("プレイ環境を選択すると、調整候補を確認できます。").foregroundStyle(.secondary) }
        }
    }
    private var comparisonChart: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("集計単位", selection: $grouping) { ForEach(Grouping.allCases, id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.segmented).frame(width: 320)
                Spacer()
                Picker("表示する指標", selection: $metric) { ForEach(AnalysisMetric.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 200)
            }
            Charts.Chart(groups) { group in
                if let value = metric.value(group.statistics) {
                    BarMark(x: .value("集計単位", group.label), y: .value(metric.rawValue, metric == .score ? value : value * 100)).foregroundStyle(palette.usesBrandUI ? Color.blue : palette.accent)
                        .annotation(position: .top) { Text(metric == .score ? number(value) : percent(value)).font(.caption.monospacedDigit()) }
                }
            }.frame(height: 220).chartYAxisLabel(metric == .score ? "スコア" : "%")
                .padding(.trailing, metric == .score ? 72 : 16).accessibilityLabel("\(grouping.label)・\(metric.rawValue)")
        }
    }
    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            comparisonChart
            Text("各判定率の内訳").font(.headline)
            Charts.Chart(groups) { group in
                ForEach(Judgment.allCases, id: \.self) { judgment in
                    if let rate = group.statistics.judgmentRates[judgment] { BarMark(x: .value("区分", group.label), y: .value("判定率", rate * 100)).foregroundStyle(by: .value("判定", judgment.rawValue)) }
                }
            }.chartForegroundStyleScale(["PERFECT": palette.usesBrandUI ? Color.blue : palette.accent, "GREAT": Color.pink, "GOOD": Color.green, "BAD": Color.orange, "MISS": Color.gray]).chartYScale(domain: 0...100).frame(height: 200)
            Text("集計表").font(.headline)
            ScrollView(.horizontal) {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 14) {
                    GridRow { Text("区分"); Text("プレイ数"); Text("平均スコア"); Text("中央値"); Text("標本SD"); Text("最低 / 最高"); Text("FAST"); Text("SLOW"); ForEach(Judgment.allCases, id: \.self) { Text($0.rawValue) }; Text("FC"); Text("AP") }.font(.caption.bold())
                    ForEach(groups) { group in
                        let s = group.statistics
                        GridRow { Text(group.label); Text("\(s.playCount)"); Text(number(s.scoreMean)); Text(number(s.scoreMedian)); Text(number(s.scoreStandardDeviation)); Text("\(s.scoreMinimum.map { $0.formatted() } ?? "—") / \(s.scoreMaximum.map { $0.formatted() } ?? "—")"); Text(percent(s.fastRate)); Text(percent(s.slowRate)); ForEach(Judgment.allCases, id: \.self) { Text(percent(s.judgmentRates[$0])) }; Text(percent(s.fcRate)); Text(percent(s.apRate)) }.font(.caption.monospacedDigit())
                    }
                }.padding(.vertical, 8)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("集計の分母").font(.headline)
                Text("判定率：全5判定が揃う\(summary.judgmentSampleCount)プレイ・\(summary.judgmentNoteCount.formatted())ノートで加重。FAST/SLOW：PERFECT＋GREATの詳細件数で加重。FC/AP：達成状態が既知のプレイが対象で、APはFCにも含めます。")
                ForEach(groups) { group in
                    let s = group.statistics
                    Text("\(group.label)：判定 \(s.judgmentSampleCount)回 / \(s.judgmentNoteCount.formatted())ノート、FAST/SLOW \(s.timingSampleCount)回 / \(s.timingNoteCount.formatted())件、達成 \(s.achievementSampleCount)回")
                }
                Text("欠測値はゼロに置き換えません。レベルはプレイ時の値です。スコアは曲・編成でも変わる参考値です。全履歴の傾向と、同一設定の調整候補は対象が異なります。")
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AnalysisStat: View {
    var title: String
    var value: String
    var detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
