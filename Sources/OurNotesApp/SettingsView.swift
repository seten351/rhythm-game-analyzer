import SwiftUI
import ResultCore

struct SettingsView: View {
    @Environment(\.appPalette) private var palette
    @Bindable var model: AppModel
    @State private var editing: PlayEnvironment?
    @State private var timingEditing: PlayEnvironment?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AppearanceSettings()
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    BrandSectionHeader(title: "スクショ取込", font: .title2.weight(.semibold))
                    Toggle("高信頼結果を自動登録する", isOn: Binding(get: { model.automaticRegistrationEnabled }, set: { value in model.perform { try model.setAutomaticRegistration(value) } }))
                        .disabled(model.importing)
                    Text("曲・譜面が一意に決まり、読取候補と判定数に矛盾がない結果を登録します。曖昧な項目と重複候補だけ確認を求めます。登録後は「今回の取込結果」から確認・編集できます。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                HStack { BrandSectionHeader(title: "プレイ環境", font: .title2.bold()); Spacer(); Button("環境を追加") { editing = PlayEnvironment(name: "新しい環境", device: TimingEnvironmentPolicy.fixedDeviceName) } }
                Text("端末はM2 iPad Pro 11インチに固定。音声出力は記録用で、スピーカー／イヤホンの結果をまとめて解析します。遅延の推定・補正は行いません。")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(model.state.environments) { environment in
                    HStack {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(environment.name).font(.headline)
                            Text("\(TimingEnvironmentPolicy.fixedDeviceName) / \(environment.audioOutput.isEmpty ? "音声出力は未記録" : environment.audioOutput)").font(.caption).foregroundStyle(.secondary)
                            Text("速度 \(decimalString(environment.settings.noteSpeed)) · ノーツタイミング \(decimalString(environment.settings.noteTiming)) · 譜面位置 \(decimalString(environment.settings.chartPosition)) · ミラー \(environment.settings.mirror.map { $0 ? "ON" : "OFF" } ?? "不明")").font(.caption.monospacedDigit())
                        }; Spacer(); Button("取込に使用") { model.selectedEnvironmentID = environment.id }
                        Button(environment.settings.noteTiming == nil ? "タイミングを確定…" : "固定タイミングを変更…") { timingEditing = environment }.disabled(model.importing)
                        Button("編集") { editing = environment }
                    }.padding(18).background(palette.surface, in: RoundedRectangle(cornerRadius: 12)).overlay { RoundedRectangle(cornerRadius: 12).stroke(palette.border) }
                }
                Text("現在設定の変更は過去プレイへ反映しません。過去の設定を修正する場合は履歴の編集から明示的に適用します。").font(.caption).foregroundStyle(.secondary)
                Text("自動登録には取込開始時の環境・固定タイミングを引き継ぎます。未確定の値は不明のまま保存します。ゲームで設定を変更したときは、次の取込前にここで記録してください。")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                BrandSectionHeader(title: "解析プリセット", font: .title2.bold())
                if let preset = model.preset {
                    Text("\(preset.name) · v\(preset.version)").font(.headline)
                    if let timing = model.timingSpecification {
                        Text("\(timing.unit) · \(decimalString(timing.step))刻み · \(decimalString(timing.minimum))〜\(decimalString(timing.maximum))。SLOW優勢は\(timing.slowCorrectionDirection == 1 ? "増加" : "減少")、FAST優勢は逆方向を提案します。個別譜面は偏りを表示し、調整候補は傾向分析の全体・プレイ時レベル別で確認できます。")
                            .foregroundStyle(.secondary)
                    } else { Text("調整仕様が未確認のため数値候補は保留します。").foregroundStyle(.secondary) }
                }
                Button("更新プリセットを選択…") { model.choosePreset() }.disabled(model.importing || !model.pending.isEmpty)
                Text("取込スクショは保存せず、ローカルDBには解析値と指紋のみ保存します。楽曲画像の表示用コピーはMac内に保存します。").foregroundStyle(.secondary)
                Text(model.storePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(24)
        }.sheet(item: $editing) { environment in EnvironmentEditor(model: model, environment: environment) }
        .sheet(item: $timingEditing) { environment in FixedTimingEditor(model: model, environment: environment) }
    }
}

struct EnvironmentEditor: View {
    @Bindable var model: AppModel
    @State var environment: PlayEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var speed = ""
    @State private var baseline: PlayEnvironment?
    @State private var position = ""
    @State private var mirror = "不明"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("プレイ環境を編集").font(.title2.bold())
            Form {
                TextField("環境名", text: $environment.name)
                LabeledContent("端末", value: TimingEnvironmentPolicy.fixedDeviceName)
                Picker("音声出力（記録用）", selection: $environment.audioOutput) {
                    Text("未記録").tag("")
                    Text("スピーカー").tag("スピーカー")
                    Text("イヤホン").tag("イヤホン")
                    if !["", "スピーカー", "イヤホン"].contains(environment.audioOutput) {
                        Text(environment.audioOutput + "（既存の記録）").tag(environment.audioOutput)
                    }
                }
                TextField("プレイ条件メモ（任意）", text: $environment.conditions)
                TextField("ノーツ速度", text: $speed)
                Text("固定ノーツタイミング：\(environment.settings.noteTiming.map { decimalString($0) } ?? "未確定")。変更は環境一覧のタイミング専用ボタンから行います。")
                TextField("譜面位置", text: $position)
                Picker("ミラー", selection: $mirror) { Text("不明").tag("不明"); Text("OFF").tag("OFF"); Text("ON").tag("ON") }
            }
            Text("不明な数値は空欄にします。ノーツタイミングと譜面位置は別々の設定です。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("取消") { dismiss() }; Spacer(); Button("保存") { model.perform {
                func parse(_ text: String) throws -> Decimal? { let clean = text.trimmingCharacters(in: .whitespacesAndNewlines); if clean.isEmpty { return nil }; guard clean.range(of: "^[+-]?[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil, let value = Decimal(string: clean, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { throw CoreError.invalid("設定値は数値で入力してください。") }; return value }
                guard !environment.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoreError.invalid("環境名が必要です。") }
                environment.settings = try PlaySettings(noteSpeed: parse(speed), noteTiming: environment.settings.noteTiming, chartPosition: parse(position), mirror: mirror == "不明" ? nil : mirror == "ON")
                try model.saveEnvironment(environment, expected: baseline); dismiss()
            } }.buttonStyle(.borderedProminent) }
        }.padding(28).frame(width: 550).textFieldStyle(.roundedBorder).onAppear { baseline = environment; speed = decimalString(environment.settings.noteSpeed); position = decimalString(environment.settings.chartPosition); mirror = environment.settings.mirror.map { $0 ? "ON" : "OFF" } ?? "不明" }
    }
}
