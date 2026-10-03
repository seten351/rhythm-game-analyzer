import Foundation

/// Export-only wrapper: missing values are explicit JSON null, never omitted or zero-filled.
@propertyWrapper public struct ExportNullable<Value: Codable & Sendable>: Codable, Sendable {
    public var wrappedValue: Value?
    public init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer(); wrappedValue = c.decodeNil() ? nil : try c.decode(Value.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let value = wrappedValue { try c.encode(value) } else { try c.encodeNil() }
    }
}

public struct AnalysisExportAppInfo: Codable, Sendable {
    public var name: String
    public var version: String
    public var build: String
    public init(name: String = "Our Notes Analyzer", version: String, build: String) {
        self.name = name; self.version = version; self.build = build
    }
}

public struct AnalysisExportDocument: Codable, Sendable {
    public var format: String
    public var formatVersion: Int
    public var analysisRulesVersion: Int
    public var app: AnalysisExportAppInfo
    public var exportedAt: Date
    public var gameID: String
    public var exportedPlayCount: Int
    public var excludedUnconfirmedPlayCount: Int
    public var songs: [AnalysisExportSong]
    public var charts: [AnalysisExportChart]
    public var plays: [AnalysisExportPlay]
    public var currentEnvironments: [AnalysisExportEnvironment]
    public var analysisRules: AnalysisExportRules
}

public struct AnalysisExportSong: Codable, Sendable {
    public var id: UUID
    public var gameID: String
    public var masterTitle: String
    public var title: String
    public var masterAliases: [String]
    public var userAliases: [String]
    public var availability: Availability
    public var provisional: Bool
    init(_ song: Song) {
        id = song.id; gameID = song.gameID; masterTitle = song.masterTitle; title = song.title
        masterAliases = song.masterAliases; userAliases = song.userAliases
        availability = song.availability; provisional = song.provisional
    }
}
public struct AnalysisExportChart: Codable, Sendable {
    public var id: UUID
    public var songID: UUID
    public var masterDifficulty: String
    @ExportNullable public var masterLevel: Int?
    public var difficulty: String
    @ExportNullable public var level: Int?
    public var availability: Availability
    init(_ chart: Chart) {
        id = chart.id; songID = chart.songID; masterDifficulty = chart.masterDifficulty; masterLevel = chart.masterLevel
        difficulty = chart.difficulty; level = chart.level; availability = chart.availability
    }
}
public struct AnalysisExportSettings: Codable, Sendable {
    @ExportNullable public var noteSpeed: Decimal?
    @ExportNullable public var noteTiming: Decimal?
    @ExportNullable public var chartPosition: Decimal?
    @ExportNullable public var mirror: Bool?
    init(_ settings: PlaySettings) {
        noteSpeed = settings.noteSpeed; noteTiming = settings.noteTiming
        chartPosition = settings.chartPosition; mirror = settings.mirror
    }
}
public struct AnalysisExportEnvironment: Codable, Sendable {
    public var id: UUID
    @ExportNullable public var name: String?
    @ExportNullable public var device: String?
    @ExportNullable public var audioOutput: String?
    @ExportNullable public var conditions: String?
    public var settings: AnalysisExportSettings
    init(_ environment: PlayEnvironment) {
        func known(_ value: String) -> String? { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value }
        id = environment.id; name = known(environment.name); device = known(environment.device)
        audioOutput = known(environment.audioOutput); conditions = known(environment.conditions)
        settings = AnalysisExportSettings(environment.settings)
    }
}
public struct AnalysisExportJudgment: Codable, Sendable {
    @ExportNullable public var total: Int?
    @ExportNullable public var fast: Int?
    @ExportNullable public var slow: Int?
    init(_ count: JudgmentCount) { total = count.total; fast = count.fast; slow = count.slow }
}
public struct AnalysisExportDateCandidate: Codable, Sendable {
    public var capturedAt: Date
    public var source: ScreenshotDateSource
    @ExportNullable public var metadataField: String?
    public var timeZone: String
    public var timeZoneAssumed: Bool
    init(_ candidate: ScreenshotDateCandidate) {
        capturedAt = candidate.capturedAt; source = candidate.source; metadataField = candidate.metadataField
        timeZone = candidate.timeZone; timeZoneAssumed = candidate.timeZoneAssumed
    }
}
public struct AnalysisExportScreenshotDate: Codable, Sendable {
    public var id: UUID
    public var imageKind: ScreenshotImageKind
    public var candidates: [AnalysisExportDateCandidate]
    init(_ evidence: ScreenshotDateEvidence) {
        id = evidence.id; imageKind = evidence.imageKind; candidates = evidence.candidates.map(AnalysisExportDateCandidate.init)
    }
}
public struct AnalysisExportPlay: Codable, Sendable {
    public var id: UUID
    public var chartID: UUID
    public var gameID: String
    public var confirmed: Bool
    public var titleAtPlay: String
    public var difficultyAtPlay: String
    @ExportNullable public var levelAtPlay: Int?
    public var score: Int
    @ExportNullable public var combo: Int?
    public var achievement: Achievement
    public var judgments: [String: AnalysisExportJudgment]
    @ExportNullable public var capturedAt: Date?
    @ExportNullable public var screenshotDates: [AnalysisExportScreenshotDate]?
    @ExportNullable public var selectedScreenshotDate: ScreenshotDateReference?
    @ExportNullable public var playedAt: Date?
    @ExportNullable public var playedAtSource: PlayDateSource?
    public var importedAt: Date
    public var orderDate: Date
    public var orderDateSource: String
    public var presetID: String
    public var presetVersion: Int
    @ExportNullable public var environmentSnapshot: AnalysisExportEnvironment?
    init(_ play: PlayRecord) {
        id = play.id; chartID = play.chartID; gameID = play.gameID; confirmed = play.confirmed
        titleAtPlay = play.titleAtPlay; difficultyAtPlay = play.difficultyAtPlay; levelAtPlay = play.levelAtPlay
        score = play.score; combo = play.combo; achievement = play.achievement
        judgments = Dictionary(uniqueKeysWithValues: Judgment.allCases.map { ($0.rawValue, AnalysisExportJudgment(play.judgments[$0] ?? .init())) })
        capturedAt = play.selectedScreenshotDate?.capturedAt
        screenshotDates = play.screenshotDates.map { $0.map(AnalysisExportScreenshotDate.init) }
        selectedScreenshotDate = play.dateContext?.selectedScreenshotDate
        playedAt = play.playedAt; playedAtSource = play.playedAt == nil ? nil : play.dateContext?.playedAtSource
        importedAt = play.importedAt; orderDate = play.orderDate
        orderDateSource = play.playedAt == nil ? "importedAt" : "playedAt"
        presetID = play.presetID; presetVersion = play.presetVersion
        environmentSnapshot = play.environment.map(AnalysisExportEnvironment.init)
    }
}

public struct AnalysisExportRules: Codable, Sendable {
    public var missingValues: String
    public var confirmedMeaning: String
    public var chronology: String
    public var judgmentRates: String
    public var fastSlowRates: String
    public var timingBias: String
    public var achievementRates: String
    public var catalogProgress: String
    public var grouping: String
    public var environmentComparison: String
    public var screenshotDates: String
    public var scoreComparison: String
    public var timingEnvironmentPolicy: String
    public var fixedDeviceName: String
    public var fixedDeviceAliases: [String]
    public var legacyBlankDeviceUsesFixedDevice: Bool
    public var audioOutputAndConditionsRequiredForTiming: Bool
    public var timingRecommendation: AnalysisExportTimingRules
    @ExportNullable public var currentTimingSpecification: TimingSpecification?
    init(specification: TimingSpecification?, policy: TimingEnvironmentPolicy) {
        missingValues = "null is unknown/unrecorded; 0 and false are known values. Do not fill missing totals from FAST/SLOW or current master/environment values."
        confirmedMeaning = "A saved, user-confirmed play may still have unknown fields. Pending OCR imports are excluded."
        chronology = "plays sorted by playedAt ?? importedAt ascending, then UUID string ascending; UUID ties do not imply actual play order. Dates are UTC ISO 8601 with fractional seconds."
        judgmentRates = "Only plays with all five judgment totals known; sum each judgment / sum all five totals, weighted by notes; no rate when denominator is zero."
        fastSlowRates = "Only plays with PERFECT.fast/slow and GREAT.fast/slow all known and their sum > 0; pooled FAST and SLOW counts use PERFECT + GREAT only."
        timingBias = "(SLOW - FAST) / (SLOW + FAST); positive is SLOW, negative is FAST."
        achievementRates = "Denominator: plays with achievement != unknown; FC includes fc and ap; AP includes ap only; none is known non-FC/AP."
        catalogProgress = "For overall progress, denominator is active charts whose song is also active. Retired charts and songs remain in the export for historical analysis. No confirmed history means unrecorded, not proof of never playing."
        grouping = "Group by difficultyAtPlay and levelAtPlay, not current chart values. null level is unknown. Keep separate play IDs for repeated plays."
        environmentComparison = "Compare historical environmentSnapshot.id and its settings values. Do not substitute currentEnvironments. Unknown settings do not establish matching conditions. Environment IDs alone do not identify a setting revision. Exact setting-change event times are not recorded."
        screenshotDates = "Each anonymous screenshot entry retains normalized capture-date evidence. Empty candidates means date unavailable; screenshotDates=null means legacy evidence not recorded. capturedAt is the selected candidate, not necessarily actual play time. Offset-less dates assume Asia/Tokyo; filenames are fallback evidence only."
        scoreComparison = "Score depends on song, band/skills and mode; use judgment precision separately. Band/skills/mode are not recorded."
        timingEnvironmentPolicy = policy == .ourNotesFixedDevice ? "ourNotesFixedDevice" : "strict"
        fixedDeviceName = TimingEnvironmentPolicy.fixedDeviceName
        fixedDeviceAliases = [TimingEnvironmentPolicy.fixedDeviceName, "M2 iPad Pro 11", "iPad Pro 11インチ (M2)", "iPad Pro 11 (M2)"]
        legacyBlankDeviceUsesFixedDevice = policy == .ourNotesFixedDevice
        audioOutputAndConditionsRequiredForTiming = policy == .strict
        timingRecommendation = AnalysisExportTimingRules()
        currentTimingSpecification = specification
    }
}
public struct AnalysisExportTimingRules: Codable, Sendable {
    public var maximumRecentPlays = TimingTrendService.maximumRecentPlaysPerChart
    public var minimumPlays = 3
    public var minimumSongs = TimingTrendService.minimumSongs
    public var minimumDetailCount = TimingTrendService.minimumDetailCount
    public var minimumAbsoluteBias = Decimal(string: "0.10")!
    public var directionAgreementNumerator = TimingTrendService.directionAgreementNumerator
    public var directionAgreementDenominator = TimingTrendService.directionAgreementDenominator
    public var scope = "Cross-song overall and levelAtPlay groups for one current environment. Individual charts display bias only."
    public var eligible = "confirmed, same gameID, known chart-to-song mapping, environment ID and all four settings equal, known nonnegative PERFECT/GREAT FAST/SLOW sum > 0; strict policy also matches device/audio/conditions; our-notes fixed-device policy requires current fixed device and accepts known aliases or legacy blank snapshot device, ignoring audio/conditions. Normalize device names with Unicode compatibility mapping, uppercase and whitespace removal. Select latest maximumRecentPlays per chart by orderDate descending, UUID string ascending on ties; select once before level splitting. UUID ties do not imply actual play order."
    public var aggregation = "Group selected plays by charts.songID. Each song bias pools its PERFECT/GREAT detail counts across charts, then songBias is the equal-weight mean of distinct song biases. Require minimumSongs and minimumDetailCount; minimumPlays alone is insufficient. abs(songBias) >= minimumAbsoluteBias; pooled note-weighted bias must have the same sign; directionAgreement is the fraction of songs with that sign, including tied songs in the denominator. Repeats and multiple difficulties of the same song do not increase song count."
    public var levelConflict = "Hold overall candidate when supported level candidates have opposite bias signs or a supported level candidate opposes the overall candidate. Supported means all candidate guards including sample, specification and one-step range pass; low-data/weak-bias levels do not block. Level candidates are references for trials at that level, not separate saved settings."
    public var unknownLevel = "null levelAtPlay remains in overall and in a separate unknown-level group; never generate a numeric candidate for the unknown-level group."
    public var prerequisites = "All current settings known; validated current timing specification, range and step; strict policy requires specified environment. Use one specification step only. Specification describes current rules, not each historical preset version. No recommendation when prerequisites fail."
}

public enum AnalysisExportService {
    public static let formatVersion = 1
    public static let analysisRulesVersion = 2
    public static func document(state: AppState, gameID: String, app: AnalysisExportAppInfo, exportedAt: Date = Date(), timingSpecification: TimingSpecification? = nil, timingEnvironmentPolicy: TimingEnvironmentPolicy = .strict) throws -> AnalysisExportDocument {
        let plays = state.plays.filter { $0.gameID == gameID && $0.confirmed }.sorted {
            if $0.orderDate != $1.orderDate { return $0.orderDate < $1.orderDate }
            return $0.id.uuidString < $1.id.uuidString
        }
        let songs = state.songs.filter { $0.gameID == gameID }.sorted { $0.id.uuidString < $1.id.uuidString }
        let songIDs = Set(songs.map(\.id))
        let charts = state.charts.filter { songIDs.contains($0.songID) }.sorted { $0.id.uuidString < $1.id.uuidString }
        let chartIDs = Set(charts.map(\.id))
        guard Set(songs.map(\.id)).count == songs.count, Set(charts.map(\.id)).count == charts.count,
              Set(plays.map(\.id)).count == plays.count else { throw CoreError.invalid("分析出力のIDが重複しています。") }
        for play in plays {
            try play.validateDateContext()
            guard chartIDs.contains(play.chartID) else { throw CoreError.invalid("プレイ \(play.id) の譜面参照 \(play.chartID) が見つかりません。") }
            if let reference = play.dateContext?.selectedScreenshotDate, play.selectedScreenshotDate == nil {
                throw CoreError.invalid("プレイ \(play.id) の撮影日時参照 \(reference.screenshotID) が見つかりません。")
            }
        }
        // Orphan charts cannot be assigned to the scoped game, so fail rather than silently omit them.
        let knownSongIDs = Set(state.songs.map(\.id))
        if let chart = state.charts.first(where: { !knownSongIDs.contains($0.songID) }) {
            throw CoreError.invalid("譜面 \(chart.id) の楽曲参照 \(chart.songID) が見つかりません。")
        }
        if let timingSpecification { try timingSpecification.validate() }
        return AnalysisExportDocument(format: "our-notes-analysis", formatVersion: formatVersion,
            analysisRulesVersion: analysisRulesVersion, app: app, exportedAt: exportedAt, gameID: gameID,
            exportedPlayCount: plays.count,
            excludedUnconfirmedPlayCount: state.plays.filter { $0.gameID == gameID && !$0.confirmed }.count,
            songs: songs.map(AnalysisExportSong.init), charts: charts.map(AnalysisExportChart.init),
            plays: plays.map(AnalysisExportPlay.init),
            currentEnvironments: state.environments.sorted { $0.id.uuidString < $1.id.uuidString }.map(AnalysisExportEnvironment.init),
            analysisRules: AnalysisExportRules(specification: timingSpecification, policy: timingEnvironmentPolicy))
    }
    public static func encode(_ document: AnalysisExportDocument) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            var c = encoder.singleValueContainer(); try c.encode(formatter.string(from: date))
        }
        return try encoder.encode(document)
    }
}
