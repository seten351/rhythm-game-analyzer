import SwiftUI
import ResultCore

struct LibraryView: View {
    @Environment(\.appPalette) private var palette
    @BrandReduceMotion private var reduceMotion
    @Namespace private var achievementSelection
    @Bindable var model: AppModel
    @Binding var browser: LibraryBrowserState
    var onShowTimingAnalysis: () -> Void = {}

    var body: some View {
        let allRows = LibraryPresentation.rows(in: model.state, gameID: model.gameID)
        let scoped = LibraryPresentation.scopedRows(allRows, browser: browser)
        let visible = LibraryPresentation.visibleRows(scoped, browser: browser)
        VStack(alignment: .leading, spacing: 16) {
            summary(allRows)
            filters(allRows)
            achievementFilters(scoped, visibleCount: visible.count)
            if allRows.isEmpty {
                Group {
                    if palette.usesBrandUI {
                        BrandEmptyState(title: "楽曲マスターがありません", description: "アプリを再起動すると同梱の全曲マスターを自動適用します。", category: .library)
                    } else {
                        ContentUnavailableView("楽曲マスターがありません", systemImage: "music.note.list", description: Text("アプリを再起動すると同梱の全曲マスターを自動適用します。"))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        if visible.isEmpty {
                            Group {
                                if palette.usesBrandUI {
                                    VStack(spacing: 12) {
                                        BrandEmptyState(title: "条件に合う譜面がありません", category: .library)
                                        Button("絞り込みを解除") { browser.resetFilters() }
                                    }
                                } else {
                                    ContentUnavailableView {
                                        Label("条件に合う譜面がありません", systemImage: "line.3.horizontal.decrease.circle")
                                    } actions: {
                                        Button("絞り込みを解除") { browser.resetFilters() }
                                    }
                                }
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            chartTable(visible)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("最高スコアは全環境・全設定の記録から集計。FCにはAPを含みます。")
                            if browser.filter == .notFC || browser.filter == .notAP {
                                Text("未FC・未APには、未プレイと達成不明を含みます。")
                            }
                            if browser.includeArchived { Text("アーカイブ済みの楽曲・譜面も表示中") }
                        }.font(.caption2).foregroundStyle(.secondary).padding(12)
                    }.frame(minWidth: 490, maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    Group {
                        if let row = visible.first(where: { $0.id == browser.selectedID }) {
                            ChartDetailView(model: model, row: row, tab: $browser.detailTab, onShowTimingAnalysis: onShowTimingAnalysis)
                                .id(row.id)
                        } else {
                            Group {
                                if palette.usesBrandUI {
                                    BrandEmptyState(title: "譜面を選択", description: "達成状況とプレイ履歴を表示します。", category: .history)
                                } else {
                                    ContentUnavailableView("譜面を選択", systemImage: "music.note", description: Text("達成状況とプレイ履歴を表示します。"))
                                }
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }.frame(width: 330).frame(maxHeight: .infinity)
                        .background(palette.surface)
                }
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(.quaternary) }
            }
        }.padding(24)
            .onAppear {
                browser.retainVisibleSelection(in: visible)
                if browser.selectedID == nil { browser.selectedID = visible.first?.id }
            }
            .onChange(of: visible.map(\.id)) { _, _ in browser.retainVisibleSelection(in: visible) }
    }

    private func summary(_ rows: [LibraryChartRow]) -> some View {
        let active = rows.filter { !$0.isArchived }
        return HStack(spacing: 20) {
            Text("現行 \(Set(active.map { $0.song.id }).count)曲 · \(active.count)譜面")
            Text("未プレイ \(active.filter { $0.plays.isEmpty }.count)")
            Text("FC達成 \(active.filter(\.hasFC).count)")
            Text("AP達成 \(active.filter(\.hasAP).count)")
            Spacer(minLength: 4)
            Label("譜面で比較", systemImage: "tablecells").foregroundStyle(palette.accent)
            Menu {
                Toggle("アーカイブを含む", isOn: $browser.includeArchived)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().help("一覧の表示設定")
                .accessibilityLabel("一覧の表示設定")
        }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }

    private func filters(_ rows: [LibraryChartRow]) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("曲名・別名").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("楽曲を検索", text: $browser.search).textFieldStyle(.plain)
                        .accessibilityIdentifier("library.search")
                    if !browser.search.isEmpty {
                        Button { browser.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("検索を消去").accessibilityLabel("検索を消去")
                    }
                }.padding(.horizontal, 9).padding(.vertical, 6)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
            }.frame(minWidth: 170, maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 5) {
                Text("難易度").font(.caption).foregroundStyle(.secondary)
                Picker("難易度", selection: $browser.difficulty) {
                    Text("すべて").tag(nil as String?)
                    ForEach(Array(Set(rows.map { $0.chart.difficulty })).sorted(by: LibraryPresentation.difficultyPrecedes), id: \.self) { value in
                        Text(value).tag(Optional(value))
                    }
                }.labelsHidden().accessibilityIdentifier("library.difficulty")
            }.frame(width: 125)
            VStack(alignment: .leading, spacing: 5) {
                Text("レベル").font(.caption).foregroundStyle(.secondary)
                Picker("レベル", selection: $browser.level) {
                    Text("すべて").tag(nil as Int?)
                    ForEach(Array(Set(rows.compactMap { $0.chart.level })).sorted(), id: \.self) { value in Text("Lv.\(value)").tag(Optional(value)) }
                }.labelsHidden().accessibilityIdentifier("library.level")
            }.frame(width: 90)
            VStack(alignment: .leading, spacing: 5) {
                Text("並び順").font(.caption).foregroundStyle(.secondary)
                Picker("並び順", selection: $browser.sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { value in Text(value.rawValue).tag(value) }
                }.labelsHidden().accessibilityIdentifier("library.sort")
            }.frame(width: 145)
        }
    }

    private func achievementFilters(_ scoped: [LibraryChartRow], visibleCount: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(LibraryFilter.allCases, id: \.self) { value in
                Button { browser.filter = value } label: {
                    HStack(spacing: 6) {
                        Text(value.rawValue).fontWeight(browser.filter == value ? .semibold : .regular)
                        Text("\(scoped.filter(value.includes).count)").monospacedDigit().opacity(0.8)
                    }.font(.caption).padding(.horizontal, 9).padding(.vertical, 6)
                        .foregroundStyle(browser.filter == value ? palette.accent : Color.secondary)
                        .background {
                            if palette.usesBrandUI {
                                ZStack {
                                    if browser.filter == value {
                                        RoundedRectangle(cornerRadius: 6).fill(palette.brand.selection)
                                            .matchedGeometryEffect(id: "achievement", in: achievementSelection)
                                    }
                                }
                                .animation(BrandMotion.selection(reduceMotion: reduceMotion), value: browser.filter)
                            } else {
                                RoundedRectangle(cornerRadius: 6).fill(browser.filter == value ? palette.accent.opacity(0.12) : .clear)
                            }
                        }
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(browser.filter == value ? .isSelected : [])
            }
            Spacer(minLength: 4)
            Text("\(visibleCount) 譜面").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func chartTable(_ rows: [LibraryChartRow]) -> some View {
        GeometryReader { geometry in
          if palette.usesBrandUI {
            BrandLibraryTable(rows: rows, selectedID: $browser.selectedID, palette: palette, width: geometry.size.width, artwork: model.artwork)
          } else {
          Table(rows, selection: $browser.selectedID) {
            TableColumn("曲名 / 難易度") { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.song.title).font(.callout.weight(.medium)).lineLimit(1).help(row.song.title)
                    HStack(spacing: 7) {
                        Text(row.chart.difficulty)
                        if row.song.provisional { Text("マスタ未照合").foregroundStyle(.orange) }
                        if row.isArchived { Text("アーカイブ") }
                    }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.vertical, 7)
            // Include native cell insets and scrollbar space when fitting the title column.
            }.width(max(130, geometry.size.width - 370))
            TableColumn("Lv.") { row in Text(row.chart.level.map(String.init) ?? "—").monospacedDigit() }.width(34)
            TableColumn("達成") { row in LibraryAchievementLabel(row: row, selected: browser.selectedID == row.id) }.width(80)
            TableColumn("最高スコア") { row in
                Text(row.bestPlay?.score.formatted() ?? "—").monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }.width(94)
            TableColumn("回数") { row in
                Text(row.plays.count.formatted()).monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }.width(34)
          }.tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden).background(palette.surface)
            .accessibilityIdentifier("library.table")
          }
        }
    }
}

struct LibraryAchievementLabel: View {
    @Environment(\.appPalette) private var palette
    var row: LibraryChartRow
    var selected = false
    var body: some View {
        if selected && !palette.usesBrandUI {
            Text(row.achievementLabel).font(.caption.weight(row.hasFC ? .semibold : .regular))
        } else {
            Text(row.achievementLabel).font(.caption.weight(row.hasFC ? .semibold : .regular))
                .foregroundStyle(row.hasAP ? palette.ap : row.hasFC ? palette.fc : Color.secondary)
                .padding(.horizontal, row.hasAP ? 5 : 0).padding(.vertical, 2)
                .background(row.hasAP ? palette.ap.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

struct PlayEditor: View {
    @Bindable var model: AppModel
    @State var play: PlayRecord
    @Environment(\.dismiss) private var dismiss
    @State private var score = ""
    @State private var combo = ""
    @State private var level = ""
    @State private var values: [String: String] = [:]
    @State private var hasDate = false
    @State private var date = Date()
    @State private var environmentID: UUID?
    @State private var replaceEnvironment = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("プレイ履歴を編集").font(.title2.bold())
                TextField("プレイ時の曲名", text: $play.titleAtPlay)
                TextField("プレイ時の難易度", text: $play.difficultyAtPlay)
                HStack { TextField("スコア", text: $score); TextField("コンボ", text: $combo); TextField("プレイ時レベル", text: $level) }
                Picker("達成", selection: $play.achievement) { ForEach(Achievement.allCases, id: \.self) { Text($0.label).tag($0) } }
                JudgmentEditor(values: $values)
                Toggle("プレイ日時を指定", isOn: $hasDate)
                if hasDate { DatePicker("日時", selection: Binding(get: { date }, set: { value in
                    date = value
                    var context = play.dateContext ?? PlayDateContext(); context.playedAtSource = .manual; play.dateContext = context
                })) }
                ForEach(ScreenshotDateChoice.choices(in: play.screenshotDates ?? [])) { choice in
                    HStack {
                        Text(screenshotDateLabel(choice)).font(.caption)
                        Spacer()
                        Button("この撮影日時を使用") {
                            date = choice.candidate.capturedAt; hasDate = true
                            play.dateContext = PlayDateContext(selectedScreenshotDate: choice.reference, playedAtSource: .screenshot)
                        }
                    }
                }
                Text("撮影日時はプレイ日時の候補です。各画像の根拠を保持し、手入力でも修正できます。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("環境スナップショットを更新する", isOn: $replaceEnvironment)
                if replaceEnvironment { Picker("使用した環境", selection: $environmentID) { Text("環境不明").tag(nil as UUID?); ForEach(model.state.environments) { Text($0.name).tag(Optional($0.id)) } }; Text("選択した環境の現在設定を、このプレイに明示的に適用します。").font(.caption).foregroundStyle(.secondary) }
                HStack { Button("取消") { dismiss() }; Spacer(); Button("保存") { model.perform {
                    guard let parsedScore = try optionalInteger(score) else { throw CoreError.invalid("スコアが必要です。") }
                    play.score = parsedScore; play.combo = try optionalInteger(combo); play.levelAtPlay = try optionalInteger(level); play.judgments = try judgmentValues(values)
                    let nextDate = hasDate ? date : nil
                    if nextDate != play.playedAt {
                        var context = play.dateContext ?? PlayDateContext()
                        if nextDate == nil { context.playedAtSource = nil }
                        else if !(context.playedAtSource == .screenshot && play.selectedScreenshotDate?.capturedAt == nextDate) { context.playedAtSource = .manual }
                        play.dateContext = context
                    }
                    play.playedAt = nextDate
                    if replaceEnvironment { play.environment = model.state.environments.first { $0.id == environmentID } }
                    try model.commit(ResultService.update(play, in: model.state)); dismiss()
                } }.buttonStyle(.borderedProminent) }
            }.padding(26)
        }.frame(width: 650, height: 720).textFieldStyle(.roundedBorder).onAppear {
            score = String(play.score); combo = play.combo.map(String.init) ?? ""; level = play.levelAtPlay.map(String.init) ?? ""; values = judgmentStrings(play.judgments); hasDate = play.playedAt != nil; date = play.playedAt ?? Date(); environmentID = play.environment?.id
        }
    }
}
