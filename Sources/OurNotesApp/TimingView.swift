import SwiftUI
import ResultCore

enum RegistrationTimingChoice: String, CaseIterable {
    case unchanged = "変更していない", changed = "変更した", unknown = "今回の値は不明"
}

/// Transient confirmation. The existing environment and play snapshots remain the storage format.
struct RegistrationTiming: Equatable {
    var baseline: PlayEnvironment?
    var choice: RegistrationTimingChoice = .unchanged
    var input = ""

    init(environment: PlayEnvironment?) {
        baseline = environment
        choice = environment == nil ? .unknown : environment?.settings.noteTiming == nil ? .changed : .unchanged
        // User-provided current game setting; offered for confirmation, never saved implicitly.
        input = environment?.settings.noteTiming.map { decimalString($0) } ?? "0.10"
    }

    func snapshot(current: PlayEnvironment?, specification: TimingSpecification?) throws -> PlayEnvironment? {
        guard current == baseline else { throw CoreError.invalid("環境または固定タイミングが変わりました。現在の設定を確認し直してください。") }
        guard var environment = current else {
            guard choice == .unknown else { throw CoreError.invalid("固定タイミングを保存する環境を選択してください。") }
            return nil
        }
        switch choice {
        case .unchanged:
            guard environment.settings.noteTiming != nil else { throw CoreError.invalid("初回のノーツタイミングを入力するか、今回の値は不明を選んでください。") }
        case .changed:
            environment.settings.noteTiming = try Self.parse(input, specification: specification)
        case .unknown:
            environment.settings.noteTiming = nil
        }
        return environment
    }

    static func parse(_ input: String, specification: TimingSpecification?) throws -> Decimal {
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.range(of: "^[+-]?[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let value = Decimal(string: clean, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else {
            throw CoreError.invalid("ゲームで設定したノーツタイミングを数値で入力してください。")
        }
        if let specification {
            try specification.validateValue(value)
        }
        return value
    }
}

struct RegistrationTimingPanel: View {
    @Environment(\.appPalette) private var palette
    @Binding var confirmation: RegistrationTiming
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("今回のノーツタイミング", systemImage: "metronome").font(.headline)
            Text("固定値：" + (confirmation.baseline?.settings.noteTiming.map { decimalString($0) } ?? "未確定"))
                .monospacedDigit()
            if confirmation.baseline == nil {
                Text("環境不明で保存します。タイミングを固定する場合は記録する環境を選んでください。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("ゲームでタイミングを変更しましたか？", selection: $confirmation.choice) {
                    if confirmation.baseline?.settings.noteTiming != nil { Text("変更していない").tag(RegistrationTimingChoice.unchanged) }
                    Text(confirmation.baseline?.settings.noteTiming == nil ? "初回の値を確定する" : "変更した").tag(RegistrationTimingChoice.changed)
                    Text("今回の値は不明").tag(RegistrationTimingChoice.unknown)
                }.pickerStyle(.segmented)
                if confirmation.choice == .changed {
                    TextField("ゲームで設定した値", text: $confirmation.input).textFieldStyle(.roundedBorder)
                    Text("このプレイと今後の固定値に保存します。過去のプレイは変更しません。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if confirmation.choice == .unknown {
                    Text("このプレイのタイミングだけ不明として保存し、固定値は維持します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("設定スクショは不要です。変更していなければ固定値をそのまま使用します。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct FixedTimingEditor: View {
    @Bindable var model: AppModel
    var environment: PlayEnvironment
    var proposed: Decimal? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var confirmedInGame = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(environment.settings.noteTiming == nil ? "ノーツタイミングを確定" : "固定タイミングを変更").font(.title2.bold())
            Text("\(environment.name) · 現在 \(environment.settings.noteTiming.map { decimalString($0) } ?? "未確定")")
            TextField("ゲームで設定した値", text: $value).textFieldStyle(.roundedBorder)
            Text("ゲームの設定はアプリから変更されません。ゲームで設定済みの値だけを記録してください。設定スクショは不要です。過去のプレイ設定は保持します。")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("ゲームでこの値に設定したことを確認しました", isOn: $confirmedInGame)
            HStack {
                Button("取消") { dismiss() }; Spacer()
                Button("固定値として保存") { model.perform {
                    let parsed = try RegistrationTiming.parse(value, specification: model.timingSpecification)
                    try model.confirmFixedTiming(parsed, expected: environment); dismiss()
                } }.buttonStyle(.borderedProminent).disabled(!confirmedInGame || model.importing)
            }
        }.padding(28).frame(width: 560)
            .onAppear { value = (proposed ?? environment.settings.noteTiming).map { decimalString($0) } ?? "0.10" }
    }
}

struct TimingBiasPanel: View {
    @Environment(\.appPalette) private var palette
    var plays: [PlayRecord]
    var onShowAnalysis: () -> Void
    var body: some View {
        let summary = StatisticsService.summarize(plays.filter(\.confirmed))
        VStack(alignment: .leading, spacing: 10) {
            Label("個別譜面の偏り", systemImage: "chart.bar").font(.headline)
            Text(timingBiasLabel(summary.timingBias)).font(.title3.bold()).monospacedDigit()
            Text("FAST \(percent(summary.fastRate)) / SLOW \(percent(summary.slowRate))")
                .font(.callout.monospacedDigit())
            Text("確認済みの全履歴：\(summary.timingSampleCount)プレイ / \(summary.timingNoteCount.formatted())件（PERFECT＋GREAT）")
                .font(.caption).foregroundStyle(.secondary)
            Text("設定が異なる履歴も含みます。固定タイミングの調整は、傾向分析で現在の設定に揃えて確認できます。")
                .font(.caption).foregroundStyle(.secondary)
            Button("傾向分析でタイミングを確認", action: onShowAnalysis).buttonStyle(.bordered)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

func timingBiasLabel(_ bias: Double?) -> String {
    guard let bias else { return "詳細データなし" }
    if bias == 0 { return "FAST / SLOW 均衡 0.0%" }
    return "\(bias > 0 ? "SLOW" : "FAST")寄り \(bias > 0 ? "+" : "−")\(percent(abs(bias)))"
}

struct TimingTrendPanel: View {
    @Environment(\.appPalette) private var palette
    var model: AppModel
    var title: String
    var recommendation: TimingTrendRecommendation
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("曲を均等に扱った偏り").font(.caption).foregroundStyle(.secondary)
                    Text(timingBiasLabel(recommendation.songBias)).font(.title3.bold()).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("\(recommendation.songCount)曲 · \(recommendation.playCount)プレイ · \(recommendation.noteCount.formatted())件").font(.callout.monospacedDigit())
                    Text("\(recommendation.matchingSongCount)/\(recommendation.songCount)曲が同方向").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(recommendation.proposed.map { "\(decimalString(recommendation.current)) → \(decimalString($0)) を試す候補" } ?? recommendation.status.label)
                .font(.headline).foregroundStyle(recommendation.proposed == nil ? Color.primary : palette.accent)
            Text(recommendation.reason).font(.callout).foregroundStyle(.secondary)
            Text("詳細件数で加重した偏り：\(timingBiasLabel(recommendation.bias)) · FAST \(percent(recommendation.statistics.fastRate)) / SLOW \(percent(recommendation.statistics.slowRate))")
                .font(.caption).foregroundStyle(.secondary)
            if !recommendation.songs.isEmpty {
                DisclosureGroup("根拠となった曲と偏り") {
                    ForEach(sortedSongs) { evidence in
                        HStack {
                            Text(songTitle(evidence.songID)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(timingBiasLabel(evidence.statistics.timingBias)).monospacedDigit()
                            Text("\(evidence.statistics.timingSampleCount)回 / \(evidence.statistics.timingNoteCount.formatted())件")
                                .foregroundStyle(.secondary).frame(width: 145, alignment: .trailing)
                        }.font(.caption).padding(.vertical, 5)
                    }
                }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private func songTitle(_ id: UUID) -> String { model.state.songs.first { $0.id == id }?.title ?? "不明な曲" }
    private var sortedSongs: [TimingSongEvidence] {
        recommendation.songs.sorted {
            let a = songTitle($0.songID), b = songTitle($1.songID)
            return a == b ? $0.songID.uuidString < $1.songID.uuidString : a.localizedStandardCompare(b) == .orderedAscending
        }
    }
}
