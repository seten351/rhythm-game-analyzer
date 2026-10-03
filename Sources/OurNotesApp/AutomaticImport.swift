import Foundation
import ResultCore

enum ImportReceiptStatus: String { case automatic = "自動登録", manual = "確認済み", duplicate = "重複スキップ", failed = "登録できませんでした" }
struct ImportReceipt: Identifiable {
    var id = UUID()
    var title: String
    var status: ImportReceiptStatus
    var playID: UUID? = nil
    var message: String
    var imageCount = 1
}

extension AppModel {
    func setAutomaticRegistration(_ enabled: Bool) throws {
        guard !importing else { throw CoreError.invalid("解析が終わってから変更してください。") }
        var next = state; next.automaticRegistrationEnabled = enabled; try commit(next)
    }

    func assess(_ item: PendingImport, draft: ResultDraft? = nil, confirmed: Set<OCRField> = [], chartID: UUID? = nil) -> RegistrationAssessment? {
        guard let value = draft ?? item.result else { return nil }
        var assessment = AutomaticRegistrationService.assess(value, evidence: item.evidence, state: state, screenshotDates: item.screenshotDates,
                                                              threshold: preset?.confidenceThreshold ?? 0.9,
                                                              confirmedFields: item.editedFields.union(confirmed), selectedChartID: chartID)
        if let reason = item.automationBlockReason { assessment.issues.append(.init(reason: reason)); assessment.draft.issues.append(reason) }
        return assessment
    }

    /// Called only after all images have been analyzed. Saving each result remains atomic;
    /// a failed save retains its draft and pixels, and never changes in-memory history.
    func finalizeImportBatch() {
        for index in pending.indices {
            if let assessment = assess(pending[index]) { pending[index].assessment = assessment; pending[index].result = assessment.draft }
        }
        pairBatchResults()
        if pending.contains(where: { $0.settings != nil && $0.settings != batchEnvironment?.settings }) {
            batchEnvironment = nil
            notice = "設定画像は確認待ちです。結果は環境不明で登録し、設定の確認後に今回の履歴へ適用できます。"
        }
        for id in pending.map(\.id) {
            guard let index = pending.firstIndex(where: { $0.id == id }), let assessment = assess(pending[index]) else { continue }
            pending[index].assessment = assessment; pending[index].result = assessment.draft
            guard automaticRegistrationEnabled, assessment.canAutomaticallyRegister else { continue }
            let item = pending[index]
            let date = AutomaticDateSelection.resolve(item.screenshotDates)
            do {
                var environment = batchEnvironment
                if assessment.draft.gameID == "our-notes" { environment?.device = TimingEnvironmentPolicy.fixedDeviceName }
                var next = try ResultService.save(assessment.draft, to: state, environment: environment, targetChartID: assessment.chartID,
                                                  fingerprints: item.fingerprints, playedAt: date.playedAt,
                                                  screenshotDates: item.screenshotDates.isEmpty ? nil : item.screenshotDates, dateContext: date.context)
                next.plays[next.plays.count - 1].registrationMethod = .automatic
                try commit(next)
                let playID = next.plays.last!.id
                lastBatchPlayIDs.append(playID)
                importReceipts.append(.init(title: assessment.draft.title, status: .automatic, playID: playID,
                                           message: item.fingerprints.count > 1 ? "通常・詳細を照合して1プレイとして登録しました。" : "マスター照合・整合性チェックを通過しました。", imageCount: item.fingerprints.count))
                correction.invalidate(itemID: id)
                pending.removeAll { $0.id == id }
            } catch {
                pending[index].error = "保存できませんでした：\(error.localizedDescription)"
                pending[index].automationBlockReason = pending[index].error
            }
        }
    }

    private func pairBatchResults() {
        // Pair only mutually unique normal/detail screenshots with matching identity,
        // score, combo and nearby capture dates. Repeated plays remain separate.
        func identityMatches(_ a: PendingImport, _ b: PendingImport) -> Bool {
            guard let x = a.assessment, let y = b.assessment, let chartID = x.chartID, chartID == y.chartID,
                  Set([x.draft.kind, y.draft.kind]) == Set(["normal", "detail"]),
                  x.draft.score != nil, x.draft.score == y.draft.score, x.draft.combo != nil, x.draft.combo == y.draft.combo else { return false }
            let identity: Set<OCRField> = [.title, .difficulty, .level, .score, .combo]
            guard !x.issues.contains(where: { $0.field.map { identity.contains($0) } ?? false }),
                  !y.issues.contains(where: { $0.field.map { identity.contains($0) } ?? false }) else { return false }
            let first = AutomaticDateSelection.resolve(a.screenshotDates).playedAt, second = AutomaticDateSelection.resolve(b.screenshotDates).playedAt
            // Without dates it is unsafe to collapse two otherwise identical plays.
            guard let first, let second else { return false }
            return abs(first.timeIntervalSince(second)) <= 60
        }
        let initial = pending
        let neighbors = Dictionary(uniqueKeysWithValues: initial.map { item in (item.id, initial.filter { $0.id != item.id && identityMatches(item, $0) }.map(\.id)) })
        for item in initial {
            guard let links = neighbors[item.id], !links.isEmpty, let i = pending.firstIndex(where: { $0.id == item.id }) else { continue }
            guard links.count == 1, neighbors[links[0]]?.count == 1 else {
                pending[i].automationBlockReason = "同じプレイと思われる画像が複数あります。統合する組を確認してください。"; continue
            }
            guard let j = pending.firstIndex(where: { $0.id == links[0] }), let first = pending[i].result, let second = pending[j].result else { continue }
            do {
                guard first.achievement == .unknown || second.achievement == .unknown || first.achievement == second.achievement else { throw CoreError.invalid("通常・詳細の達成表示が矛盾しています。") }
                var merged = first
                merged.judgments = try ResultService.merged(first.judgments, second.judgments)
                if merged.achievement == .unknown { merged.achievement = second.achievement }
                merged.kind = "merged"
                try merged.validateForSave()
                pending[i].result = merged; pending[i].fingerprints += pending[j].fingerprints
                pending[i].evidence += pending[j].evidence; pending[i].screenshotDates += pending[j].screenshotDates
                pending[i].sourcePreviews.merge(pending[j].sourcePreviews) { value, _ in value }
                pending[i].name += " ＋ " + pending[j].name
                pending.remove(at: j)
            } catch {
                let reason = "同じプレイ候補の画像が矛盾しています。\(error.localizedDescription)"
                pending[i].automationBlockReason = reason; pending[j].automationBlockReason = reason
            }
        }
    }

    /// Focused review confirms only unresolved fields. The normal save validator still
    /// runs, while duplicate candidates require an explicit choice in the full editor.
    func registerReviewed(_ id: UUID, values: [OCRField: String], chartID: UUID?) throws {
        guard !importing, let item = pending.first(where: { $0.id == id }), var draft = item.result else { throw CoreError.invalid("確認する結果がありません。") }
        for (field, value) in values {
            guard let parsed = OCRCorrectionService.parsed(value, field: field) else { throw CoreError.invalid("\(field.label)の値を確認してください。") }
            RecognitionEvidence.apply(parsed, field: field, to: &draft)
        }
        guard let assessment = assess(item, draft: draft, confirmed: Set(values.keys), chartID: chartID) else {
            throw CoreError.invalid("確認が必要です。")
        }
        guard assessment.canAutomaticallyRegister else {
            var seen = Set<String>()
            let reasons = assessment.issues.map(\.reason).filter { seen.insert($0).inserted }
            throw CoreError.invalid(reasons.isEmpty ? "確認が必要です。" : reasons.joined(separator: "\n"))
        }
        let date = AutomaticDateSelection.resolve(item.screenshotDates)
        var timing = RegistrationTiming(environment: activeEnvironment)
        if activeEnvironment?.settings.noteTiming == nil { timing.choice = .unknown }
        try register(id, draft: assessment.draft, chartID: assessment.chartID, mergeID: nil, playedAt: date.playedAt, timing: timing, dateContext: date.context)
    }
}
