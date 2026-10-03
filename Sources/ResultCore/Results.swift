import Foundation

public enum ResultService {
    public static func candidates(for draft: ResultDraft, in state: AppState) -> [PlayRecord] {
        state.plays.filter { play in
            guard play.gameID == draft.gameID, normalizedName(play.difficultyAtPlay) == normalizedName(draft.difficulty) else { return false }
            var names = [play.titleAtPlay]
            if let c = state.chart(for: play), let song = state.song(for: c) { names += song.allNames }
            guard names.contains(where: { normalizedName($0) == normalizedName(draft.title) }) else { return false }
            let sameValues = play.score == draft.score && play.combo == draft.combo
            let similarImage = play.fingerprints.contains { fp in
                guard fp.layout == draft.fingerprint.layout, let a = fp.perceptualHash, let b = draft.fingerprint.perceptualHash else { return false }
                return (a ^ b).nonzeroBitCount <= 6
            }
            return sameValues || similarImage
        }.sorted { $0.orderDate > $1.orderDate }
    }

    public static func matchingCharts(for draft: ResultDraft, in state: AppState) -> [Chart] {
        let songs = Set(state.songs.filter { $0.gameID == draft.gameID && $0.allNames.contains { normalizedName($0) == normalizedName(draft.title) } }.map(\.id))
        let canonical = canonicalChartIDs(gameID: draft.gameID, in: state)
        return state.charts.filter { songs.contains($0.songID) && normalizedName($0.difficulty) == normalizedName(draft.difficulty) && (canonical?.contains($0.id) ?? true) }
    }

    static func canonicalChartIDs(gameID: String, in state: AppState) -> Set<UUID>? {
        guard gameID == OurNotesCatalog.gameID, state.catalogs.contains(where: { $0.gameID == gameID && $0.sourceID == OurNotesCatalog.sourceID }) else { return nil }
        let active = Set(state.activeCharts(gameID: gameID).map(\.id))
        return Set(state.bindings.filter { $0.gameID == gameID && $0.sourceID == OurNotesCatalog.sourceID && $0.kind == .chart }.map(\.internalID)).intersection(active)
    }

    public static func save(_ draft: ResultDraft, to original: AppState, environment: PlayEnvironment?, targetChartID: UUID? = nil, fingerprints: [SourceFingerprint]? = nil, playedAt: Date? = nil, screenshotDates: [ScreenshotDateEvidence]? = nil, dateContext: PlayDateContext? = nil) throws -> AppState {
        try draft.validateForSave()
        let incoming = fingerprints ?? [draft.fingerprint]
        guard !incoming.isEmpty else { throw CoreError.invalid("画像の指紋がありません。") }
        guard Set(incoming.map(\.sha256)).count == incoming.count, incoming.allSatisfy({ !$0.sha256.isEmpty }) else { throw CoreError.invalid("画像の指紋が空欄または重複しています。") }
        let existing = Set(original.plays.flatMap { $0.fingerprints.map(\.sha256) })
        guard incoming.allSatisfy({ !existing.contains($0.sha256) }) else { throw CoreError.invalid("同一画像はすでに登録されています。") }
        var state = original
        let chartID: UUID
        let canonical = canonicalChartIDs(gameID: draft.gameID, in: state)
        if let targetChartID {
            guard let c = state.charts.first(where: { $0.id == targetChartID }), state.song(for: c)?.gameID == draft.gameID else { throw CoreError.invalid("選択した譜面が見つかりません。") }
            guard canonical?.contains(targetChartID) ?? true else { throw CoreError.invalid("正規マスターの譜面を選択してください。") }
            chartID = targetChartID
        } else {
            let charts = matchingCharts(for: draft, in: state)
            if charts.count > 1 { throw CoreError.invalid("同じ名前・難易度に複数譜面があります。対象譜面を選んでください。") }
            if let chart = charts.first { chartID = chart.id }
            else {
                guard canonical == nil else { throw CoreError.invalid("正規マスターに一致しません。曲名・難易度を修正するか、登録先の譜面を選択してください。") }
                let songs = state.songs.filter { $0.gameID == draft.gameID && $0.allNames.contains { normalizedName($0) == normalizedName(draft.title) } }
                guard songs.count <= 1 else { throw CoreError.invalid("同名曲が複数あります。対象譜面を選んでください。") }
                let song: Song
                if let existing = songs.first { song = existing }
                else { song = Song(gameID: draft.gameID, masterTitle: draft.title, provisional: true); state.songs.append(song) }
                let chart = Chart(songID: song.id, masterDifficulty: draft.difficulty, masterLevel: draft.level); chartID = chart.id; state.charts.append(chart)
            }
        }
        state.plays.append(PlayRecord(chartID: chartID, gameID: draft.gameID, titleAtPlay: draft.title, difficultyAtPlay: draft.difficulty, levelAtPlay: draft.level, score: draft.score!, combo: draft.combo, achievement: draft.achievement, judgments: draft.judgments, playedAt: playedAt, presetID: draft.presetID, presetVersion: draft.presetVersion, environment: environment, fingerprints: incoming, screenshotDates: screenshotDates, dateContext: dateContext))
        try state.plays.last!.validateDateContext()
        return state
    }

    public static func merged(_ lhs: [Judgment: JudgmentCount], _ rhs: [Judgment: JudgmentCount]) throws -> [Judgment: JudgmentCount] {
        func merge(_ a: Int?, _ b: Int?) throws -> Int? {
            if let a, let b, a != b { throw CoreError.invalid("両画像の判定数が矛盾しています。別プレイとして登録するか、値を修正してください。") }
            return a ?? b
        }
        var result: [Judgment: JudgmentCount] = [:]
        for j in Judgment.allCases {
            let a = lhs[j] ?? .init(), b = rhs[j] ?? .init()
            result[j] = try .init(total: merge(a.total, b.total), fast: merge(a.fast, b.fast), slow: merge(a.slow, b.slow))
        }
        return result
    }

    public static func merge(_ draft: ResultDraft, into playID: UUID, in original: AppState, fingerprints: [SourceFingerprint]? = nil, environment: PlayEnvironment? = nil, screenshotDates: [ScreenshotDateEvidence] = []) throws -> AppState {
        try draft.validateForSave()
        guard let index = original.plays.firstIndex(where: { $0.id == playID }), candidates(for: draft, in: original).contains(where: { $0.id == playID }) else { throw CoreError.invalid("同一プレイ候補が変わりました。確認し直してください。") }
        var state = original
        var play = state.plays[index]
        guard play.score == draft.score, play.combo == draft.combo else { throw CoreError.invalid("類似画像候補ですがスコア・コンボが異なります。同じプレイなら読取値を修正してから統合してください。") }
        if play.achievement != .unknown && draft.achievement != .unknown && play.achievement != draft.achievement { throw CoreError.invalid("達成表示が矛盾しています。") }
        play.judgments = try merged(play.judgments, draft.judgments)
        if play.achievement == .unknown { play.achievement = draft.achievement }
        let incoming = fingerprints ?? [draft.fingerprint]
        guard !incoming.isEmpty, incoming.allSatisfy({ !$0.sha256.isEmpty }) else { throw CoreError.invalid("画像の指紋がありません。") }
        let others = Set(state.plays.filter { $0.id != playID }.flatMap { $0.fingerprints.map(\.sha256) })
        guard incoming.allSatisfy({ !others.contains($0.sha256) }) else { throw CoreError.invalid("別プレイに登録済みの画像です。") }
        let hasNewImage = incoming.contains { fp in !play.fingerprints.contains { $0.sha256 == fp.sha256 } }
        for fp in incoming where !play.fingerprints.contains(where: { $0.sha256 == fp.sha256 }) { play.fingerprints.append(fp) }
        if hasNewImage && !screenshotDates.isEmpty {
            var dates = play.screenshotDates ?? []
            for evidence in screenshotDates where !dates.contains(where: { $0.id == evidence.id }) { dates.append(evidence) }
            play.screenshotDates = dates
        }
        if play.environment == nil { play.environment = environment }
        var check = draft; check.judgments = play.judgments; check.achievement = play.achievement; try check.validateForSave()
        play.confirmed = true; state.plays[index] = play
        return state
    }

    public static func update(_ play: PlayRecord, in original: AppState) throws -> AppState {
        try play.validateDateContext()
        guard let i = original.plays.firstIndex(where: { $0.id == play.id }) else { throw CoreError.invalid("プレイが見つかりません。") }
        let draft = ResultDraft(gameID: play.gameID, presetID: play.presetID, presetVersion: play.presetVersion, title: play.titleAtPlay, difficulty: play.difficultyAtPlay, level: play.levelAtPlay, score: play.score, combo: play.combo, achievement: play.achievement, judgments: play.judgments, fingerprint: play.fingerprints.first ?? .init(sha256: "", layout: "manual"), kind: "manual")
        try draft.validateForSave()
        var state = original; state.plays[i] = play; return state
    }
}
