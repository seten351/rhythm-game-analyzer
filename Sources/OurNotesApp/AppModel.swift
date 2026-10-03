import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import ResultCore

struct PendingImport: Identifiable {
    var id = UUID()
    var name: String
    var result: ResultDraft?
    var settings: PlaySettings?
    var image: NSImage?
    var fingerprints: [SourceFingerprint]
    var error: String?
    var evidence: [OCRReadEvidence] = []
    var sourcePreviews: [String: NSImage] = [:]
    var editedFields: Set<OCRField> = []
    var screenshotDates: [ScreenshotDateEvidence] = []
    var assessment: RegistrationAssessment?
    var automationBlockReason: String?
}

@MainActor @Observable final class AppModel {
    var state = AppState()
    var preset: GamePreset?
    private var bundledTiming: TimingSpecification?
    // Older imported OCR presets still use the now-confirmed game timing rules.
    var timingSpecification: TimingSpecification? { preset?.timing ?? (gameID == "our-notes" ? bundledTiming : nil) }
    var timingEnvironmentPolicy: TimingEnvironmentPolicy { gameID == "our-notes" ? .ourNotesFixedDevice : .strict }
    var errorMessage: String?
    var startupError: String?
    var notice = ""
    var pending: [PendingImport] = []
    var importing = false
    var processed = 0
    var importCount = 0
    var duplicateCount = 0
    var importReceipts: [ImportReceipt] = []
    var batchEnvironment: PlayEnvironment?
    var automaticRegistrationEnabled: Bool { state.automaticRegistrationEnabled ?? true }
    var automaticCount: Int { importReceipts.filter { $0.status == .automatic }.count }
    var failedCount: Int { importReceipts.filter { $0.status == .failed }.count + pending.filter { $0.error != nil }.count }
    var batchSummary: String {
        "\(processed)/\(importCount)枚を解析。\(automaticCount)件を自動登録、\(duplicateCount)枚を重複スキップ、\(failedCount)件が失敗。\(pending.count)件が確認待ちです。"
    }
    var selectedEnvironmentID: UUID?
    var pendingPreset: GamePreset?
    var lastBatchPlayIDs: [UUID] = []
    let correction: OCRCorrectionController
    private var repository: (any StateRepository)?
    private var importTask: Task<Void, Never>?
    private var releaseAfterCancellation = false
    var gameID: String { preset?.gameId ?? "our-notes" }
    var activeEnvironment: PlayEnvironment? { state.environments.first { $0.id == selectedEnvironmentID } }
    var storePath: String { repository?.storeURL.path ?? "" }
    var resourceDirectory: URL { Bundle.module.resourceURL!.appendingPathComponent("Resources") }

    init(inMemory: Bool = false, loadBundledCatalog: Bool = true, correctionProvider: any OCRCorrectionProviding = FoundationOCRCorrectionProvider(), correctionTimeout: Duration = .seconds(30), repository suppliedRepository: (any StateRepository)? = nil) {
        correction = OCRCorrectionController(provider: correctionProvider, timeout: correctionTimeout)
        do {
            let repository: any StateRepository = try suppliedRepository ?? LocalRepository(inMemory: inMemory); self.repository = repository; state = try repository.load()
            let imported = repository.storeURL.deletingLastPathComponent().appendingPathComponent("preset.json")
            let bundled = resourceDirectory.appendingPathComponent("our-notes-v1.json")
            bundledTiming = try JSONDecoder().decode(GamePreset.self, from: Data(contentsOf: bundled)).timing
            let chosen = !inMemory && FileManager.default.fileExists(atPath: imported.path) ? imported : bundled
            let preset = try JSONDecoder().decode(GamePreset.self, from: Data(contentsOf: chosen)); try preset.validate(); self.preset = preset
            if loadBundledCatalog { try installBundledCatalog() }
            selectedEnvironmentID = state.environments.first?.id
        } catch { startupError = "起動に失敗しました。保存データは変更していません。\n\(error.localizedDescription)" }
    }

    func commit(_ next: AppState) throws {
        guard let repository else { throw CoreError.invalid("保存先を開けません。") }
        try repository.save(next); state = next
    }
    func perform(_ action: () throws -> Void) { do { try action() } catch { errorMessage = error.localizedDescription } }

    private func installBundledCatalog() throws {
        let data = try Data(contentsOf: resourceDirectory.appendingPathComponent("our-notes-catalog.json"))
        let document = try JSONDecoder().decode(CatalogDocument.self, from: data)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let next = try OurNotesCatalog.install(document, digest: digest, into: state)
        if next != state { try commit(next) }
    }

    func chooseImages() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .heic]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.message = "スクショをまとめて選択してください。画像はアプリに恒久保存しません。"
        present(panel) { [weak self] in self?.importImages(panel.urls) }
    }
    func importImages(_ urls: [URL]) {
        guard !importing else { return }
        guard urls.allSatisfy(\.isFileURL) else { errorMessage = "ローカルの画像ファイルを選択してください。Web URLは読み込みません。"; return }
        guard pending.isEmpty else { errorMessage = "確認待ちの画像を登録または破棄してから、次の取込を開始してください。"; return }
        guard urls.count <= 100 else { errorMessage = "一度の取込は100枚までです。分けて取り込んでください。"; return }
        guard let preset else { errorMessage = "解析プリセットがありません。"; return }
        importing = true; processed = 0; importCount = urls.count; duplicateCount = 0; lastBatchPlayIDs = []; importReceipts = []; notice = ""
        batchEnvironment = activeEnvironment
        let knownTitles = state.songs.filter { $0.gameID == preset.gameId }.flatMap(\.allNames)
        importTask = Task { [weak self] in
            guard let self else { return }
            defer { self.importing = false; self.importTask = nil; if self.releaseAfterCancellation { self.pending.removeAll(); self.releaseAfterCancellation = false } }
            var seen = Set(self.state.plays.flatMap { $0.fingerprints.map(\.sha256) })
            var duplicates = 0
            for url in urls {
                if Task.isCancelled { break }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let alreadySeen = seen
                    let output: (ImageAnalysis?, String) = try await Task.detached(priority: .userInitiated) {
                        try autoreleasepool {
                            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                            if let size = attributes[.size] as? NSNumber, size.intValue > 80 * 1024 * 1024 { throw CoreError.invalid("80MBを超える画像です。") }
                            let data = try Data(contentsOf: url, options: .mappedIfSafe)
                            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                            if alreadySeen.contains(digest) { return (nil, digest) }
                            return (try ImageAnalyzer.analyze(data: data, preset: preset, knownTitles: knownTitles, filename: url.lastPathComponent), digest)
                        }
                    }.value
                    if Task.isCancelled { break }
                    if let analysis = output.0 {
                        seen.insert(analysis.sha256)
                        let preview = Self.preview(analysis.preview)
                        let kind: ScreenshotImageKind = analysis.settings != nil ? .settings : analysis.result?.kind == "detail" ? .detail : .normal
                        let dateEvidence = ScreenshotDateEvidence(imageKind: kind, candidates: analysis.screenshotDateCandidates)
                        self.pending.append(PendingImport(name: url.lastPathComponent, result: analysis.result, settings: analysis.settings, image: preview, fingerprints: analysis.result.map { [$0.fingerprint] } ?? [], evidence: analysis.evidence, sourcePreviews: analysis.result == nil ? [:] : [analysis.sha256: preview], screenshotDates: [dateEvidence]))
                    } else {
                        duplicates += 1
                        let play = self.state.plays.first { $0.fingerprints.contains { $0.sha256 == output.1 } }
                        self.importReceipts.append(.init(title: play?.titleAtPlay ?? "同一画像", status: .duplicate, playID: play?.id, message: "画像の指紋が完全一致したためスキップしました。"))
                    }
                } catch {
                    if Task.isCancelled { break }
                    self.importReceipts.append(.init(title: url.lastPathComponent, status: .failed, message: error.localizedDescription))
                }
                self.processed += 1
            }
            self.duplicateCount = duplicates
            if !Task.isCancelled { self.finalizeImportBatch() }
        }
    }
    func cancelImport() { importTask?.cancel(); notice = "取込を中止しました。処理済みの結果は確認できます。" }
    func finishSession() { correction.invalidate(); if importing { releaseAfterCancellation = true; importTask?.cancel() }; pending.removeAll() }
    func clearPending() { guard !importing else { return }; correction.invalidate(); pending.removeAll(); notice = "確認待ちの画像を解放しました。元画像は変更していません。" }
    func discardPending(_ id: UUID) { guard !importing else { return }; correction.invalidate(itemID: id); pending.removeAll { $0.id == id } }
    func correctionContext(_ id: UUID, excluded: Set<OCRField> = []) -> OCRCorrectionContext {
        guard let item = pending.first(where: { $0.id == id }), let draft = item.result, let preset else { return .init(fields: []) }
        let titles = state.songs.filter { $0.gameID == draft.gameID }.flatMap(\.allNames)
        return OCRCorrectionService.context(draft: draft, evidence: item.evidence, knownTitles: titles, confidenceThreshold: preset.confidenceThreshold, excluded: excluded.union(item.editedFields))
    }
    func requestCorrections(_ id: UUID, editorRevision: UInt64, excluded: Set<OCRField> = []) {
        guard !importing, pending.contains(where: { $0.id == id }) else { return }
        correction.start(itemID: id, revision: editorRevision, context: correctionContext(id, excluded: excluded))
    }
    static func preview(_ image: CGImage) -> NSImage {
        let scale = min(1, 1000 / Double(image.width)); let size = NSSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        let result = NSImage(size: size); result.lockFocus(); NSGraphicsContext.current?.cgContext.draw(image, in: CGRect(origin: .zero, size: size)); result.unlockFocus(); return result
    }
    static func samePlayCandidate(_ a: PendingImport, _ b: PendingImport) -> Bool {
        guard let x = a.result, let y = b.result else { return false }
        return x.gameID == y.gameID && normalizedName(x.title) == normalizedName(y.title) && normalizedName(x.difficulty) == normalizedName(y.difficulty) && x.score != nil && x.score == y.score && x.combo != nil && x.combo == y.combo
    }
    func updatePending(_ id: UUID, draft: ResultDraft, editedFields: Set<OCRField> = []) throws {
        guard !importing else { throw CoreError.invalid("解析完了後に修正してください。") }
        try draft.validateForSave()
        guard let i = pending.firstIndex(where: { $0.id == id }) else { throw CoreError.invalid("確認待ちの項目が見つかりません。") }
        correction.invalidate(itemID: id)
        if let previous = pending[i].result {
            pending[i].editedFields.formUnion(OCRField.allCases.filter { $0.value(in: previous) != $0.value(in: draft) })
        }
        pending[i].editedFields.formUnion(editedFields); pending[i].result = draft
    }
    func mergePending(_ firstID: UUID, _ secondID: UUID, corrected: ResultDraft? = nil, editedFields: Set<OCRField> = []) throws {
        guard !importing else { throw CoreError.invalid("解析完了後に統合してください。") }
        guard let i = pending.firstIndex(where: { $0.id == firstID }), let j = pending.firstIndex(where: { $0.id == secondID }), i != j, var first = corrected ?? pending[i].result, let second = pending[j].result else { throw CoreError.invalid("統合対象が見つかりません。") }
        let correctedFields = pending[i].result.map { previous in Set(OCRField.allCases.filter { $0.value(in: previous) != $0.value(in: first) }) } ?? []
        try first.validateForSave()
        guard second.kind != "unsupported-assist" else { throw CoreError.invalid("アシストモードは対応対象外です。") }
        var edited = pending[i]; edited.result = first
        guard Self.samePlayCandidate(edited, pending[j]) else { throw CoreError.invalid("同一プレイ候補ではありません。曲名・スコア等を確認してください。") }
        guard first.achievement == .unknown || second.achievement == .unknown || first.achievement == second.achievement else { throw CoreError.invalid("達成表示が矛盾しています。") }
        first.judgments = try ResultService.merged(first.judgments, second.judgments)
        if first.achievement == .unknown { first.achievement = second.achievement }
        first.issues = Array(Set(first.issues + second.issues)).sorted(); first.kind = "merged"
        try first.validateForSave()
        correction.invalidate(itemID: firstID); correction.invalidate(itemID: secondID)
        pending[i].editedFields.formUnion(correctedFields.union(editedFields))
        pending[i].result = first; pending[i].fingerprints += pending[j].fingerprints
        pending[i].evidence += pending[j].evidence
        pending[i].sourcePreviews.merge(pending[j].sourcePreviews) { existing, _ in existing }
        pending[i].editedFields.formUnion(pending[j].editedFields)
        let dateIDs = Set(pending[i].screenshotDates.map(\.id))
        pending[i].screenshotDates += pending[j].screenshotDates.filter { !dateIDs.contains($0.id) }
        pending[i].name += " ＋ " + pending[j].name; pending.remove(at: j)
    }
    func register(_ itemID: UUID, draft: ResultDraft, chartID: UUID?, mergeID: UUID?, playedAt: Date?, timing: RegistrationTiming? = nil, dateContext: PlayDateContext? = nil) throws {
        guard !importing else { throw CoreError.invalid("解析完了後に登録してください。") }
        guard let item = pending.first(where: { $0.id == itemID }) else { throw CoreError.invalid("確認待ちの項目が見つかりません。") }
        var next = state
        var snapshot = activeEnvironment
        if mergeID == nil {
            guard let timing else { throw CoreError.invalid("今回のノーツタイミングの変更有無を確認してください。") }
            snapshot = try timing.snapshot(current: activeEnvironment, specification: timingSpecification)
            if draft.gameID == "our-notes" { snapshot?.device = TimingEnvironmentPolicy.fixedDeviceName }
            if let snapshot, let index = next.environments.firstIndex(where: { $0.id == snapshot.id }) {
                if timing.choice == .changed { next.environments[index] = snapshot }
                if draft.gameID == "our-notes" { next.environments[index].device = TimingEnvironmentPolicy.fixedDeviceName }
            }
        }
        if let mergeID {
            // Additional images of an existing play retain that play's historical setting.
            next = try ResultService.merge(draft, into: mergeID, in: next, fingerprints: item.fingerprints, screenshotDates: item.screenshotDates)
        } else {
            next = try ResultService.save(draft, to: next, environment: snapshot, targetChartID: chartID, fingerprints: item.fingerprints, playedAt: playedAt, screenshotDates: item.screenshotDates.isEmpty ? nil : item.screenshotDates, dateContext: dateContext ?? (playedAt == nil ? nil : PlayDateContext(playedAtSource: .manual)))
            next.plays[next.plays.count - 1].registrationMethod = .manual
        }
        try commit(next)
        correction.invalidate(itemID: itemID)
        if mergeID == nil { lastBatchPlayIDs.append(next.plays.last!.id) }
        importReceipts.append(.init(title: draft.title, status: .manual, playID: mergeID ?? next.plays.last?.id, message: mergeID == nil ? "確認して登録しました。" : "既存の履歴へ統合しました。", imageCount: item.fingerprints.count))
        pending.removeAll { $0.id == itemID }
    }
    func saveEnvironment(_ environment: PlayEnvironment, expected: PlayEnvironment? = nil) throws {
        var environment = environment
        if gameID == "our-notes" { environment.device = TimingEnvironmentPolicy.fixedDeviceName }
        var next = state
        if let i = next.environments.firstIndex(where: { $0.id == environment.id }) {
            if let expected, next.environments[i] != expected { throw CoreError.invalid("環境設定が変わりました。開き直して確認してください。") }
            guard environment.settings.noteTiming == next.environments[i].settings.noteTiming else { throw CoreError.invalid("ノーツタイミングは固定タイミングの変更から確定してください。") }
            next.environments[i] = environment
        } else {
            guard environment.settings.noteTiming == nil else { throw CoreError.invalid("環境を追加してからタイミングを確定してください。") }
            next.environments.append(environment)
        }
        try commit(next); selectedEnvironmentID = environment.id
    }
    func confirmFixedTiming(_ value: Decimal, expected: PlayEnvironment) throws {
        guard !importing else { throw CoreError.invalid("解析完了後にタイミングを変更してください。") }
        let value = try RegistrationTiming.parse(decimalString(value), specification: timingSpecification)
        guard let index = state.environments.firstIndex(where: { $0.id == expected.id }), state.environments[index] == expected else {
            throw CoreError.invalid("環境または固定タイミングが変わりました。現在の設定を確認し直してください。")
        }
        var next = state
        next.environments[index].settings.noteTiming = value
        if gameID == "our-notes" { next.environments[index].device = TimingEnvironmentPolicy.fixedDeviceName }
        try commit(next)
        notice = "固定ノーツタイミングを\(decimalString(value))に更新しました。以降の登録で引き継ぎ、過去プレイは保持します。"
    }
    func applySettings(_ settings: PlaySettings, toBatch: Bool) {
        perform {
            var next = state
            guard let id = selectedEnvironmentID, let index = next.environments.firstIndex(where: { $0.id == id }) else { throw CoreError.invalid("設定の保存先となるプレイ環境を選んでください。") }
            var confirmedSettings = settings
            if let timing = settings.noteTiming {
                confirmedSettings.noteTiming = try RegistrationTiming.parse(decimalString(timing), specification: timingSpecification)
            } else {
                // An unread setting image must not erase the fixed value.
                confirmedSettings.noteTiming = next.environments[index].settings.noteTiming
            }
            next.environments[index].settings = confirmedSettings
            if gameID == "our-notes" { next.environments[index].device = TimingEnvironmentPolicy.fixedDeviceName }
            if toBatch { for i in next.plays.indices where lastBatchPlayIDs.contains(next.plays[i].id) { next.plays[i].environment = next.environments[index] } }
            try commit(next)
            notice = toBatch ? "設定を環境と今回登録したプレイへ適用しました。" : "環境の現在設定を更新しました。過去プレイは変更していません。"
        }
    }
    func choosePreset() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        present(panel) { [weak self] in
            guard let self, let url = panel.url else { return }
            self.perform {
                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let incoming = try JSONDecoder().decode(GamePreset.self, from: Data(contentsOf: url)); try incoming.validate()
                guard incoming.gameId == self.gameID, incoming.id == self.preset?.id else { throw CoreError.invalid("試作版はアワーノーツの同一プリセットIDに対応しています。") }
                if let current = self.preset {
                    guard incoming.version > current.version || incoming == current else { throw CoreError.invalid("同版の内容変更・旧版への更新はできません。版番号を増やしてください。") }
                }
                self.pendingPreset = incoming
            }
        }
    }
    private func present(_ panel: NSOpenPanel, accepted: @escaping @MainActor () -> Void) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            errorMessage = "ファイル選択を表示するウィンドウが見つかりません。"; return
        }
        panel.beginSheetModal(for: window) { response in
            if response == .OK { accepted() }
        }
    }
    func applyPreset() {
        perform {
            guard let incoming = pendingPreset, let repository else { return }
            try incoming.validate()
            let url = repository.storeURL.deletingLastPathComponent().appendingPathComponent("preset.json")
            try JSONEncoder().encode(incoming).write(to: url, options: .atomic)
            preset = incoming; pendingPreset = nil; notice = "解析プリセットを更新しました。既存履歴の版情報は変更していません。"
        }
    }
    func deletePlay(_ id: UUID) { perform { var next = state; next.plays.removeAll { $0.id == id }; try commit(next) } }
}
