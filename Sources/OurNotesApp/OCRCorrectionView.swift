import AppKit
import SwiftUI
import ResultCore

struct ImportCorrectionEditor: Equatable {
    var revision: UInt64 = 0
    var editedFields: Set<OCRField> = []
    mutating func changed(_ field: OCRField) { revision &+= 1; editedFields.insert(field) }
    mutating func adopting(_ candidate: OCRCorrectionCandidate, selection: inout ImportEditorSelection) {
        changed(candidate.field)
        if candidate.field == .title || candidate.field == .difficulty { selection.identityChanged() }
        if candidate.field == .score || candidate.field == .combo { selection.valuesChanged() }
    }
}

struct OCRCorrectionPanel: View {
    @Bindable var model: AppModel
    var itemID: UUID
    var editor: ImportCorrectionEditor
    var adopt: (OCRCorrectionCandidate) -> Void
    var context: OCRCorrectionContext { model.correctionContext(itemID, excluded: editor.editedFields) }
    var active: Bool { model.correction.targetID == itemID && model.correction.editorRevision == editor.revision }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OCR補助（AFM・Mac内で実行）").font(.headline)
            Text("OCR根拠のある候補だけを確認します。値は項目ごとに採用するまで変更されません。手入力した項目は対象外です。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("AFMで補正候補を確認") { model.requestCorrections(itemID, editorRevision: editor.revision, excluded: editor.editedFields) }
                    .disabled(model.importing || model.correction.isRunning || model.correction.availability.reason != nil || !context.fields.contains { !$0.candidates.isEmpty })
                if active && model.correction.isRunning {
                    ProgressView().controlSize(.small)
                    Button("中止") { model.correction.cancel() }
                }
            }
            if let reason = model.correction.availability.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            if context.fields.isEmpty { Text("AFM補助の対象項目はありません。通常の確認・手入力で登録できます。").font(.caption).foregroundStyle(.secondary) }
            if context.fields.contains(where: \.isSixNineAmbiguous) {
                Text("6/9判定曖昧：同じ読取領域のOCR候補だけを提示します。再読取やAFMでも一意に決まらない項目は、画像と照合して手動確認してください。ほかの判定数や合計からは補完しません。")
                    .font(.caption).foregroundStyle(.orange)
                ForEach(context.fields.filter(\.isSixNineAmbiguous)) { field in
                    Text(field.field.label + "のOCR候補：" + (field.candidates.isEmpty ? "候補が多いため手入力してください" : field.candidates.map(\.value).joined(separator: " / ")))
                        .font(.caption).textSelection(.enabled)
                }
            }
            if context.fields.contains(where: { $0.candidates.isEmpty }) {
                Text("許可候補を提示できない項目は補完しません：" + context.fields.filter { $0.candidates.isEmpty }.map { $0.field.label }.joined(separator: "、"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if active && !model.correction.message.isEmpty { Text(model.correction.message).font(.caption).foregroundStyle(.secondary) }
            if active {
                ForEach(model.correction.suggestions) { candidate in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(candidate.field.label).bold()
                            Text("元値：\(context.fields.first { $0.field == candidate.field }?.originalValue ?? "不明") → 候補：\(candidate.value)")
                            Spacer()
                            Button("この項目に採用") { adopt(candidate) }.disabled(model.correction.isRunning)
                        }.font(.callout)
                        if let field = context.fields.first(where: { $0.field == candidate.field }) {
                            Text("確認理由：" + field.reasons.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("OCR：\(candidate.tokens.map(\.text).joined(separator: " ")) · Vision信頼度 \(Int(candidate.confidence * 100))%" + (candidate.fromCatalog ? " · 曲名マスタ候補" : ""))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let image = model.pending.first(where: { $0.id == itemID })?.sourcePreviews[candidate.sourceID], let rect = candidate.tokens.first?.rect,
                           let crop = regionImage(image, rect: rect) {
                            Image(nsImage: crop).resizable().scaledToFit().frame(maxHeight: 80).frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel("\(candidate.field.label)のOCR根拠領域")
                        }
                    }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }.padding(16).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
    }
    private func regionImage(_ image: NSImage, rect: ResultCore.NormalizedRect) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let crop = cg.cropping(to: CGRect(x: rect.x * Double(cg.width), y: rect.y * Double(cg.height), width: rect.width * Double(cg.width), height: rect.height * Double(cg.height)).integral) else { return nil }
        return NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
    }
}
