import SwiftUI
import ResultCore

struct ImportView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    @State private var selected: UUID?
    @State private var dropTargeted = false
    @State private var editing: PlayRecord?
    @State private var deleting: PlayRecord?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("記録する環境", selection: $model.selectedEnvironmentID) {
                    Text("環境不明").tag(nil as UUID?)
                    ForEach(model.state.environments) { Text($0.name).tag(Optional($0.id)) }
                }.frame(maxWidth: 320).disabled(model.importing)
                Spacer()
                if model.importing { Button("中止") { model.cancelImport() } }
                Button("画像を追加…") { model.chooseImages() }.buttonStyle(.borderedProminent).disabled(model.importing || !model.pending.isEmpty)
            }
            HStack(spacing: 12) {
                Label(model.automaticRegistrationEnabled ? "高信頼の結果を自動登録" : "すべて確認して登録", systemImage: model.automaticRegistrationEnabled ? "checkmark.shield" : "person.crop.rectangle.badge.checkmark")
                if let environment = model.activeEnvironment { Text("固定タイミング \(environment.settings.noteTiming.map { decimalString($0) } ?? "不明")を使用") }
            }.font(.caption).foregroundStyle(.secondary)
            if model.importing {
                ProgressView(value: Double(model.processed), total: Double(max(1, model.importCount))) {
                    Text("画像を読み取り中 · \(model.processed) / \(model.importCount)枚")
                }
                Text("全画像を解析後、通常・詳細の照合と登録を行います。").font(.caption).foregroundStyle(.secondary)
            }
            if model.importCount > 0 && !model.importing { batchSummary }
            if !model.notice.isEmpty { Text(model.notice).font(.caption).foregroundStyle(.secondary) }
            if model.pending.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !model.importReceipts.isEmpty { receipts }
                        dropArea.frame(minHeight: model.importReceipts.isEmpty ? 330 : 140)
                    }
                }
            } else {
                if !model.importReceipts.isEmpty {
                    DisclosureGroup("今回の登録・スキップ結果（\(model.importReceipts.count)件）") {
                        ScrollView { receipts }.frame(maxHeight: 220)
                    }
                }
                HStack {
                    Text("確認が必要な結果だけ表示しています").font(.callout.weight(.medium))
                    Spacer()
                    Button("残りの確認を終了…") { model.clearPending(); selected = nil }.disabled(model.importing)
                }
                HStack(spacing: 0) {
                    List(model.pending, selection: $selected) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.result?.title ?? (item.settings != nil ? "プレイ設定" : "解析失敗")).font(.callout.weight(.medium))
                            if let result = item.result { Text("\(result.difficulty) · \(result.score.map { $0.formatted() } ?? "スコア不明")").font(.caption).foregroundStyle(.secondary) }
                            Text(item.error != nil ? "保存を再試行してください" : item.assessment.map { assessment in
                                if assessment.issues.contains(where: { $0.field == nil }) { return "内容を確認" }
                                return "\(Set(assessment.issues.compactMap(\.field)).count)項目を確認"
                            } ?? "設定を確認")
                                .font(.caption).foregroundStyle(.orange)
                        }.padding(.vertical, 6).tag(item.id)
                    }.scrollContentBackground(.hidden).background(palette.surface).frame(width: 215)
                    Divider()
                    if let item = model.pending.first(where: { $0.id == selected }) ?? model.pending.first {
                        ImportReviewView(model: model, item: item).id(item.id)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(24)
        .sheet(item: $editing) { play in PlayEditor(model: model, play: play) }
        .confirmationDialog("このプレイ記録を削除しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("プレイ記録を削除", role: .destructive) { if let play = deleting { model.deletePlay(play.id) }; deleting = nil }
            Button("取消", role: .cancel) { deleting = nil }
        }
    }
    private var batchSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { BrandSectionHeader(title: "今回の取込結果"); Spacer(); Text("\(model.processed) / \(model.importCount)枚を解析").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 24) {
                AnalysisStat(title: "自動登録", value: "\(model.automaticCount)", detail: "プレイ")
                AnalysisStat(title: "要確認", value: "\(model.pending.filter { $0.error == nil }.count)", detail: "結果")
                AnalysisStat(title: "重複スキップ", value: "\(model.duplicateCount)", detail: "画像")
                AnalysisStat(title: "登録失敗", value: "\(model.failedCount)", detail: "結果")
            }
            if model.pending.isEmpty && model.failedCount == 0 { Label("取込が完了しました", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(palette.accent) }
        }.padding(18).background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private var dropArea: some View {
        VStack(spacing: 12) {
            if palette.usesBrandUI && model.importReceipts.isEmpty {
                BrandEmptyState(title: "スクショをここへドロップ", description: "PNG / JPEG / HEIC · 一度に100枚まで", category: .imports)
            } else {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 30)).foregroundStyle(palette.accent)
                Text("スクショをここへドロップ").font(.headline)
                Text("PNG / JPEG / HEIC · 一度に100枚まで").font(.caption).foregroundStyle(.secondary)
            }
            if model.importReceipts.isEmpty { Text("問題のない結果は、そのまま登録されます。").font(.callout).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
            .background(dropTargeted ? palette.accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [5])) }
            .dropDestination(for: URL.self) { urls, _ in model.importImages(urls); return true } isTargeted: { dropTargeted = $0 }
    }
    private var receipts: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.importReceipts) { receipt in
                let play = model.state.plays.first { $0.id == receipt.playID }
                HStack(spacing: 14) {
                    Image(systemName: receipt.status == .failed ? "exclamationmark.triangle" : receipt.status == .duplicate ? "doc.on.doc" : "checkmark.circle.fill")
                        .foregroundStyle(receipt.status == .failed ? Color.orange : palette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(receipt.title).font(.callout.weight(.medium)); Text(receipt.status.rawValue).font(.caption).foregroundStyle(.secondary) }
                        if let play { Text("\(play.difficultyAtPlay) · \(play.score.formatted()) · \(play.achievement.label) · \(playDateLabel(play))").font(.caption).foregroundStyle(.secondary) }
                        Text(receipt.playID != nil && play == nil ? "履歴から削除済みです。" : receipt.message).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let play {
                        Button("確認・編集") { editing = play }
                        Button { deleting = play } label: { Image(systemName: "trash") }.help("このプレイ記録を削除")
                    }
                }.padding(.vertical, 12)
                Divider()
            }
        }
    }
}

struct ImportReviewView: View {
    @Bindable var model: AppModel
    var item: PendingImport
    @State private var showAll = false
    var body: some View {
        if !showAll, let assessment = item.assessment, !assessment.issues.isEmpty,
           assessment.level == .medium, assessment.issues.allSatisfy({ $0.field != nil }), assessment.duplicateIDs.isEmpty {
            FocusedImportReview(model: model, item: item, assessment: assessment, showAll: $showAll)
        } else {
            PendingDetailView(model: model, itemID: item.id)
        }
    }
}

struct FocusedImportReview: View {
    @Bindable var model: AppModel
    var item: PendingImport
    var assessment: RegistrationAssessment
    @Binding var showAll: Bool
    @State private var values: [OCRField: String] = [:]
    @State private var chartID: UUID?
    var fields: [OCRField] { OCRField.allCases.filter { field in assessment.issues.contains { $0.field == field } } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Text("この\(fields.count)項目だけ確認してください").font(.headline); Spacer(); Button("全項目を編集") { showAll = true } }
                    if let image = item.image { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 280).clipShape(RoundedRectangle(cornerRadius: 9)) }
                    if item.sourcePreviews.count > 1 {
                        DisclosureGroup("統合した画像") { ForEach(item.fingerprints, id: \.sha256) { fingerprint in if let image = item.sourcePreviews[fingerprint.sha256] { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 280) } } }
                    }
                    ForEach(fields, id: \.self) { field in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(field.label).font(.headline)
                            ForEach(assessment.issues.filter { $0.field == field }) { issue in Text(issue.reason).font(.caption).foregroundStyle(.secondary) }
                            if field == .title && !assessment.chartCandidates.isEmpty {
                                Picker("登録する譜面", selection: $chartID) {
                                    Text("候補を選択").tag(nil as UUID?)
                                    ForEach(assessment.chartCandidates) { candidate in Text("\(candidate.title) · \(candidate.chart.difficulty) Lv.\(candidate.chart.level.map(String.init) ?? "?")").tag(Optional(candidate.id)) }
                                }
                            } else if field == .achievement {
                                Picker("達成", selection: binding(field)) { ForEach(Achievement.allCases, id: \.self) { Text($0.label).tag($0.rawValue) } }
                            } else {
                                TextField("確認した値", text: binding(field)).textFieldStyle(.roundedBorder)
                                let candidates = Array(Set(assessment.issues.filter { $0.field == field }.flatMap(\.candidates))).sorted()
                                if !candidates.isEmpty { HStack { Text("候補").font(.caption).foregroundStyle(.secondary); ForEach(candidates, id: \.self) { value in Button(value) { set(value, for: field) } } } }
                            }
                        }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                    }
                    DisclosureGroup("確定済みの内容") {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("\(assessment.draft.title) · \(assessment.draft.difficulty)")
                            Text("スコア \(assessment.draft.score.map { $0.formatted() } ?? "—") · \(assessment.draft.achievement.label)")
                            ForEach(Judgment.allCases, id: \.self) { j in
                                let c = assessment.draft.judgments[j] ?? .init()
                                Text("\(j.rawValue) \(c.total.map(String.init) ?? "—") · FAST \(c.fast.map(String.init) ?? "—") / SLOW \(c.slow.map(String.init) ?? "—")").font(.caption.monospacedDigit())
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                }.padding(20)
            }
            Divider()
            HStack { Button("この画像を破棄") { model.discardPending(item.id) }; Spacer(); Button("確認した項目で登録") { model.perform {
                var confirmed = values
                if let chartID, fields.contains(.title), let candidate = assessment.chartCandidates.first(where: { $0.id == chartID }) {
                    confirmed[.title] = candidate.title; confirmed[.difficulty] = candidate.chart.difficulty
                    if let level = candidate.chart.level { confirmed[.level] = String(level) }
                }
                try model.registerReviewed(item.id, values: confirmed, chartID: chartID)
            } }.buttonStyle(.borderedProminent) }.padding(16)
        }.disabled(model.importing).onAppear {
            chartID = assessment.chartID
            for field in fields { values[field] = field.value(in: assessment.draft) ?? (field == .achievement ? "unknown" : "") }
        }
    }
    private func binding(_ field: OCRField) -> Binding<String> { Binding(get: { values[field] ?? "" }, set: { set($0, for: field) }) }
    private func set(_ value: String, for field: OCRField) {
        values[field] = value
        if [.title, .difficulty, .level].contains(field) { chartID = nil }
    }
}

struct PendingDetailView: View {
    @Bindable var model: AppModel
    var itemID: UUID
    @State private var draft: ResultDraft?
    @State private var score = ""
    @State private var combo = ""
    @State private var level = ""
    @State private var values: [String: String] = [:]
    @State private var selection = ImportEditorSelection()
    @State private var dateSelection = ImportDateSelection()
    @State private var applyBatch = false
    @State private var correctionEditor = ImportCorrectionEditor()
    @State private var timing = RegistrationTiming(environment: nil)
    var item: PendingImport? { model.pending.first { $0.id == itemID } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let image = item?.image { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 330).clipShape(RoundedRectangle(cornerRadius: 12)) }
                if let item, item.sourcePreviews.count > 1 {
                    DisclosureGroup("統合した各画像を確認") {
                        ForEach(item.fingerprints, id: \.sha256) { source in
                            if let image = item.sourcePreviews[source.sha256] {
                                Text(source.layout == "detail" ? "詳細リザルト" : "通常リザルト").font(.caption)
                                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 330)
                            }
                        }
                    }
                }
                if let error = item?.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if let settings = item?.settings {
                    Text("設定の確認").font(.title2.bold())
                    ForEach(ScreenshotDateChoice.choices(in: item?.screenshotDates ?? [])) { choice in
                        Text("撮影日時：\(screenshotDateLabel(choice))").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("速度 \(decimalString(settings.noteSpeed)) / ノーツタイミング \(decimalString(settings.noteTiming)) / 譜面位置 \(decimalString(settings.chartPosition)) / ミラー \(settings.mirror == true ? "ON" : "OFF")")
                    Toggle("今回登録したプレイにも適用（確認済みの同一設定の場合）", isOn: $applyBatch)
                    Button("選択中の環境へ設定を保存") {
                        model.applySettings(settings, toBatch: applyBatch)
                        if model.errorMessage == nil { model.discardPending(itemID) }
                    }.buttonStyle(.borderedProminent)
                }
                if draft != nil {
                    Text("解析結果を確認").font(.title2.bold())
                    if let draft, !draft.issues.isEmpty { Text(draft.issues.joined(separator: "\n")).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow { Text("曲名"); TextField("楽曲名", text: Binding(get: { draft?.title ?? "" }, set: { draft?.title = $0; fieldChanged(.title) })) }
                        GridRow { Text("難易度"); TextField("EXPERT", text: Binding(get: { draft?.difficulty ?? "" }, set: { draft?.difficulty = $0; fieldChanged(.difficulty) })) }
                        GridRow { Text("レベル"); TextField("不明は空欄", text: Binding(get: { level }, set: { level = $0; fieldChanged(.level) })) }
                        GridRow { Text("スコア"); TextField("今回のスコア", text: Binding(get: { score }, set: { score = $0; fieldChanged(.score) })) }
                        GridRow { Text("コンボ"); TextField("不明は空欄", text: Binding(get: { combo }, set: { combo = $0; fieldChanged(.combo) })) }
                        GridRow { Text("達成"); Picker("達成", selection: Binding(get: { draft?.achievement ?? .unknown }, set: { draft?.achievement = $0; fieldChanged(.achievement) })) { ForEach(Achievement.allCases, id: \.self) { Text($0.label).tag($0) } }.labelsHidden() }
                    }.textFieldStyle(.roundedBorder)
                    JudgmentEditor(values: $values) { key in if let field = OCRField(rawValue: key) { fieldChanged(field) } }
                    Text("空欄は不明です。表示されていない総数をFAST/SLOWから補完しません。").font(.caption).foregroundStyle(.secondary)
                    OCRCorrectionPanel(model: model, itemID: itemID, editor: correctionEditor, adopt: adopt)
                    Button("修正内容を確認待ちに反映") { saveEditsToPending() }
                    if let draft {
                        let matching = ResultService.matchingCharts(for: draft, in: model.state)
                        Picker("登録先の譜面", selection: $selection.chartID) {
                            Text("名前と難易度で正規マスターに照合").tag(nil as UUID?)
                            ForEach(model.state.activeCharts(gameID: draft.gameID)) { chart in Text("\(model.state.song(for: chart)?.title ?? "") · \(chart.difficulty) Lv.\(chart.level.map(String.init) ?? "?")").tag(Optional(chart.id)) }
                        }
                        if matching.isEmpty { Text("正規マスターに一致しません。曲名・難易度を修正するか、登録先を選択してください。").foregroundStyle(.orange) }
                        if matching.count > 1 { Text("同名候補が複数あります。登録先を指定してください。").foregroundStyle(.orange) }
                        let candidateIDs = Set(ResultService.candidates(for: draft, in: model.state).map(\.id) + (item?.assessment?.duplicateIDs ?? []))
                        let candidates = model.state.plays.filter { candidateIDs.contains($0.id) }
                        if !candidates.isEmpty {
                            Picker("既存の同一プレイ候補", selection: $selection.mergeID) {
                                Text("別プレイとして新規登録").tag(nil as UUID?)
                                ForEach(candidates) { play in Text("\(playDateLabel(play)) · \(play.score)").tag(Optional(play.id)) }
                            }
                            Text("同じスコアでも別プレイの可能性があります。画像を確認して統合してください。").font(.caption).foregroundStyle(.secondary)
                        }
                        let pairings = model.pending.filter { other in other.id != itemID && item.map { current in AppModel.samePlayCandidate(current, other) } == true }
                        ForEach(pairings) { other in Button("同じプレイの画像と統合：\(other.name)") {
                            model.perform { let corrected = try correctedDraft(); try model.mergePending(itemID, other.id, corrected: corrected, editedFields: correctionEditor.editedFields); reload() }
                        } }
                    }
                    if let mergeID = selection.mergeID, let existing = model.state.plays.first(where: { $0.id == mergeID }) {
                        Text("既存プレイの日時とノーツタイミング \(existing.environment?.settings.noteTiming.map { decimalString($0) } ?? "不明") を保持し、追加画像の撮影日時根拠を追記します。過去の日時・設定は履歴の編集で修正できます。")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(ScreenshotDateChoice.choices(in: item?.screenshotDates ?? [])) { choice in
                            Text("追加画像：\(screenshotDateLabel(choice))").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        ScreenshotDatePanel(selection: $dateSelection, evidence: item?.screenshotDates ?? [])
                        RegistrationTimingPanel(confirmation: $timing)
                    }
                    Button(selection.mergeID == nil ? "確認して登録" : "確認して既存プレイへ統合") {
                        model.perform { let corrected = try correctedDraft(); try model.register(itemID, draft: corrected, chartID: selection.chartID, mergeID: selection.mergeID, playedAt: dateSelection.playedAt, timing: timing, dateContext: dateSelection.context) }
                    }.buttonStyle(.borderedProminent).disabled(model.importing)
                }
                Button("この画像を破棄") { model.discardPending(itemID) }.disabled(model.importing)
            }.padding(20)
        }.disabled(model.importing).onAppear { reload() }
        .onChange(of: model.activeEnvironment) { _, current in timing = RegistrationTiming(environment: current) }
        .onDisappear { model.correction.invalidate(itemID: itemID) }
    }
    func reload() {
        model.correction.invalidate(itemID: itemID)
        correctionEditor.revision &+= 1; correctionEditor.editedFields = item?.editedFields ?? []
        draft = item?.result
        score = draft?.score.map(String.init) ?? ""; combo = draft?.combo.map(String.init) ?? ""; level = draft?.level.map(String.init) ?? ""
        values = judgmentStrings(draft?.judgments ?? [:])
        dateSelection.updateEvidence(item?.screenshotDates ?? [])
        if timing.baseline != model.activeEnvironment { timing = RegistrationTiming(environment: model.activeEnvironment) }
    }
    func correctedDraft() throws -> ResultDraft {
        guard var draft else { throw CoreError.invalid("解析結果がありません。") }
        draft.score = try optionalInteger(score); draft.combo = try optionalInteger(combo); draft.level = try optionalInteger(level); draft.judgments = try judgmentValues(values)
        try draft.validateForSave(); return draft
    }
    func saveEditsToPending() {
        model.perform { try model.updatePending(itemID, draft: correctedDraft(), editedFields: correctionEditor.editedFields) }
    }
    func fieldChanged(_ field: OCRField) {
        correctionEditor.changed(field); model.correction.invalidate(itemID: itemID)
        if field == .title || field == .difficulty { selection.identityChanged() }
        if field == .score || field == .combo { selection.valuesChanged() }
    }
    func adopt(_ candidate: OCRCorrectionCandidate) {
        guard model.correction.targetID == itemID, model.correction.editorRevision == correctionEditor.revision,
              !correctionEditor.editedFields.contains(candidate.field),
              model.correction.consume(candidate, itemID: itemID, revision: correctionEditor.revision) else { return }
        switch candidate.field {
        case .title: draft?.title = candidate.value
        case .difficulty: draft?.difficulty = candidate.value
        case .level: level = candidate.value
        case .score: score = candidate.value
        case .combo: combo = candidate.value
        case .achievement: if let achievement = Achievement(rawValue: candidate.value) { draft?.achievement = achievement }
        default: values[candidate.field.rawValue] = candidate.value
        }
        correctionEditor.adopting(candidate, selection: &selection)
    }
}

struct ImportEditorSelection: Equatable {
    var chartID: UUID?
    var mergeID: UUID?
    mutating func identityChanged() { chartID = nil; mergeID = nil }
    mutating func valuesChanged() { mergeID = nil }
}

struct JudgmentEditor: View {
    @Binding var values: [String: String]
    var onEdit: ((String) -> Void)? = nil
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow { Text("判定"); Text("総数"); Text("FAST").foregroundStyle(.blue); Text("SLOW").foregroundStyle(.pink) }
            ForEach(Judgment.allCases, id: \.self) { j in GridRow {
                Text(j.rawValue).font(.caption.bold())
                ForEach(["total", "fast", "slow"], id: \.self) { type in
                    TextField("—", text: Binding(get: { values[j.rawValue + "." + type] ?? "" }, set: { values[j.rawValue + "." + type] = $0; onEdit?(j.rawValue + "." + type) })).frame(maxWidth: 100).textFieldStyle(.roundedBorder)
                }
            } }
        }
    }
}
func optionalInteger(_ text: String) throws -> Int? {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if clean.isEmpty { return nil }; guard let value = Int(clean), value >= 0 else { throw CoreError.invalid("数値には0以上の整数を入力してください。") }; return value
}
func judgmentStrings(_ counts: [Judgment: JudgmentCount]) -> [String: String] {
    var result: [String: String] = [:]
    for j in Judgment.allCases { result[j.rawValue + ".total"] = counts[j]?.total.map(String.init) ?? ""; result[j.rawValue + ".fast"] = counts[j]?.fast.map(String.init) ?? ""; result[j.rawValue + ".slow"] = counts[j]?.slow.map(String.init) ?? "" }
    return result
}
func judgmentValues(_ values: [String: String]) throws -> [Judgment: JudgmentCount] {
    try Dictionary(uniqueKeysWithValues: Judgment.allCases.map { j in (j, try JudgmentCount(total: optionalInteger(values[j.rawValue + ".total"] ?? ""), fast: optionalInteger(values[j.rawValue + ".fast"] ?? ""), slow: optionalInteger(values[j.rawValue + ".slow"] ?? ""))) })
}
