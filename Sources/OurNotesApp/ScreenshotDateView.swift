import SwiftUI
import ResultCore

struct ImportDateSelection: Equatable {
    var useDate = false
    var date = Date()
    var selectedChoiceID: String?
    var playedAtSource: PlayDateSource = .manual
    private var evidence: [ScreenshotDateEvidence] = []
    private var initialized = false
    private var userChanged = false
    var choices: [ScreenshotDateChoice] { ScreenshotDateChoice.choices(in: evidence) }
    var selected: ScreenshotDateChoice? { choices.first { $0.id == selectedChoiceID } }
    var playedAt: Date? { useDate ? date : nil }
    var context: PlayDateContext {
        PlayDateContext(selectedScreenshotDate: selected?.reference, playedAtSource: useDate ? playedAtSource : nil)
    }
    mutating func updateEvidence(_ incoming: [ScreenshotDateEvidence]) {
        guard !initialized || evidence != incoming else { return }
        evidence = incoming; initialized = true
        if userChanged { return }
        if evidence.contains(where: \.hasConflict) {
            selectedChoiceID = nil; useDate = false; playedAtSource = .manual
        } else if let first = choices.first {
            selectedChoiceID = first.id; date = first.candidate.capturedAt; useDate = true; playedAtSource = .screenshot
        }
    }
    mutating func select(_ id: String?) {
        userChanged = true; selectedChoiceID = id
        if let selected { date = selected.candidate.capturedAt; useDate = true; playedAtSource = .screenshot }
        else { playedAtSource = .manual }
    }
    mutating func setDate(_ value: Date) { userChanged = true; date = value; playedAtSource = .manual }
    mutating func setUseDate(_ value: Bool) { userChanged = true; useDate = value }
}

struct ScreenshotDatePanel: View {
    @Binding var selection: ImportDateSelection
    var evidence: [ScreenshotDateEvidence]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("スクショ撮影日時", systemImage: "calendar").font(.headline)
            if selection.choices.isEmpty {
                Text("撮影日時は不明です。必要ならプレイ日時を手入力できます。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("撮影日時候補", selection: Binding(get: { selection.selectedChoiceID }, set: { selection.select($0) })) {
                    Text("候補を選ばず手入力").tag(nil as String?)
                    ForEach(selection.choices) { choice in Text(screenshotDateLabel(choice)).tag(Optional(choice.id)) }
                }
                if evidence.contains(where: \.hasConflict) {
                    Text("同じ画像に異なる日時の根拠があります。候補を選ぶか、日時不明で登録してください。")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let candidate = selection.selected?.candidate, candidate.timeZoneAssumed {
                    Text("タイムゾーンの記録がないため日本時間（Asia/Tokyo）として解釈しています。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("プレイ日時を指定", isOn: Binding(get: { selection.useDate }, set: { selection.setUseDate($0) }))
            if selection.useDate {
                DatePicker("プレイ日時", selection: Binding(get: { selection.date }, set: { selection.setDate($0) }))
                Text(selection.playedAtSource == .screenshot ? "スクショ撮影日時をプレイ日時に使用します。実際のプレイ日時とは異なる場合があります。" : "手入力したプレイ日時を使用します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("通常／詳細を統合しても、各画像の撮影日時根拠を個別に保持します。画像名やパスは保存しません。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

func screenshotDateLabel(_ choice: ScreenshotDateChoice) -> String {
    let kind: String
    switch choice.imageKind { case .normal: kind = "通常"; case .detail: kind = "詳細"; case .settings: kind = "設定"; case .unknown: kind = "画像" }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ja_JP"); formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
    formatter.dateFormat = "yyyy/MM/dd HH:mm:ss.SSS"
    let origin = choice.candidate.source == .filename ? "ファイル名" : choice.candidate.metadataField ?? "メタデータ"
    return "\(kind) · \(formatter.string(from: choice.candidate.capturedAt)) JST · \(origin)"
}
