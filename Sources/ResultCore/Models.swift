import Foundation

public enum Achievement: String, Codable, CaseIterable, Sendable {
    case unknown, none, fc, ap
    public var isFC: Bool { self == .fc || self == .ap }
    public var isAP: Bool { self == .ap }
    public var label: String {
        switch self { case .unknown: return "不明"; case .none: return "FC/APなし"; case .fc: return "FC"; case .ap: return "AP" }
    }
}

public enum Judgment: String, Codable, CaseIterable, Sendable {
    case perfect = "PERFECT", great = "GREAT", good = "GOOD", bad = "BAD", miss = "MISS"
}

public struct JudgmentCount: Codable, Equatable, Sendable {
    public var total: Int?
    public var fast: Int?
    public var slow: Int?
    public init(total: Int? = nil, fast: Int? = nil, slow: Int? = nil) { self.total = total; self.fast = fast; self.slow = slow }
}

public struct PlaySettings: Codable, Equatable, Sendable {
    public var noteSpeed: Decimal?
    public var noteTiming: Decimal?
    public var chartPosition: Decimal?
    public var mirror: Bool?
    public init(noteSpeed: Decimal? = nil, noteTiming: Decimal? = nil, chartPosition: Decimal? = nil, mirror: Bool? = nil) {
        self.noteSpeed = noteSpeed; self.noteTiming = noteTiming; self.chartPosition = chartPosition; self.mirror = mirror
    }
    public var isComplete: Bool { noteSpeed != nil && noteTiming != nil && chartPosition != nil && mirror != nil }
}

public struct PlayEnvironment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var device: String
    public var audioOutput: String
    public var conditions: String
    public var settings: PlaySettings
    public init(id: UUID = UUID(), name: String = "デフォルト", device: String = "", audioOutput: String = "", conditions: String = "通常プレイ", settings: PlaySettings = .init()) {
        self.id = id; self.name = name; self.device = device; self.audioOutput = audioOutput; self.conditions = conditions; self.settings = settings
    }
    public var isSpecified: Bool { !device.trimmingCharacters(in: .whitespaces).isEmpty && !audioOutput.trimmingCharacters(in: .whitespaces).isEmpty && !conditions.isEmpty }
}

public enum Availability: String, Codable, Sendable { case active, retired }

public struct Song: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var gameID: String
    public var masterTitle: String
    public var masterAliases: [String]
    public var userTitle: String?
    public var userAliases: [String]
    public var availability: Availability
    public var provisional: Bool
    public var title: String { userTitle ?? masterTitle }
    public var allNames: [String] { [title, masterTitle] + masterAliases + userAliases }
    public init(id: UUID = UUID(), gameID: String, masterTitle: String, masterAliases: [String] = [], userTitle: String? = nil, userAliases: [String] = [], availability: Availability = .active, provisional: Bool = false) {
        self.id = id; self.gameID = gameID; self.masterTitle = masterTitle; self.masterAliases = masterAliases; self.userTitle = userTitle; self.userAliases = userAliases; self.availability = availability; self.provisional = provisional
    }
}

public struct Chart: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var songID: UUID
    public var masterDifficulty: String
    public var masterLevel: Int?
    /// Catalog-supplied only. Never learned from OCR or inferred from a combo.
    public var noteCount: Int?
    public var userDifficulty: String?
    public var userLevel: Int?
    public var availability: Availability
    public var difficulty: String { userDifficulty ?? masterDifficulty }
    public var level: Int? { userLevel ?? masterLevel }
    public init(id: UUID = UUID(), songID: UUID, masterDifficulty: String, masterLevel: Int? = nil, userDifficulty: String? = nil, userLevel: Int? = nil, availability: Availability = .active, noteCount: Int? = nil) {
        self.id = id; self.songID = songID; self.masterDifficulty = masterDifficulty; self.masterLevel = masterLevel; self.userDifficulty = userDifficulty; self.userLevel = userLevel; self.availability = availability; self.noteCount = noteCount
    }
}

public enum BindingKind: String, Codable, Sendable { case song, chart }
public struct CatalogBinding: Codable, Equatable, Sendable {
    public var gameID: String
    public var sourceID: String
    public var kind: BindingKind
    public var externalID: String
    public var internalID: UUID
    public init(gameID: String, sourceID: String, kind: BindingKind, externalID: String, internalID: UUID) { self.gameID = gameID; self.sourceID = sourceID; self.kind = kind; self.externalID = externalID; self.internalID = internalID }
}
public struct CatalogImportState: Codable, Equatable, Sendable {
    public var gameID: String
    public var sourceID: String
    public var revision: Int
    public var digest: String
    public var isComplete: Bool
    public var generatedAt: String
    public var importedAt: Date
}

public struct SourceFingerprint: Codable, Equatable, Sendable {
    public var sha256: String
    public var perceptualHash: UInt64?
    public var layout: String
    public init(sha256: String, perceptualHash: UInt64? = nil, layout: String) { self.sha256 = sha256; self.perceptualHash = perceptualHash; self.layout = layout }
}

public enum RegistrationMethod: String, Codable, Sendable { case automatic, manual }

public struct PlayRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var chartID: UUID
    public var gameID: String
    public var titleAtPlay: String
    public var difficultyAtPlay: String
    public var levelAtPlay: Int?
    public var score: Int
    public var combo: Int?
    public var achievement: Achievement
    public var judgments: [Judgment: JudgmentCount]
    public var importedAt: Date
    public var playedAt: Date?
    public var presetID: String
    public var presetVersion: Int
    public var environment: PlayEnvironment?
    public var fingerprints: [SourceFingerprint]
    public var confirmed: Bool
    public var screenshotDates: [ScreenshotDateEvidence]?
    public var dateContext: PlayDateContext?
    public var registrationMethod: RegistrationMethod?
    public init(id: UUID = UUID(), chartID: UUID, gameID: String, titleAtPlay: String, difficultyAtPlay: String, levelAtPlay: Int? = nil, score: Int, combo: Int? = nil, achievement: Achievement = .unknown, judgments: [Judgment: JudgmentCount] = [:], importedAt: Date = Date(), playedAt: Date? = nil, presetID: String, presetVersion: Int, environment: PlayEnvironment? = nil, fingerprints: [SourceFingerprint] = [], confirmed: Bool = true, screenshotDates: [ScreenshotDateEvidence]? = nil, dateContext: PlayDateContext? = nil) {
        self.id = id; self.chartID = chartID; self.gameID = gameID; self.titleAtPlay = titleAtPlay; self.difficultyAtPlay = difficultyAtPlay; self.levelAtPlay = levelAtPlay; self.score = score; self.combo = combo; self.achievement = achievement; self.judgments = judgments; self.importedAt = importedAt; self.playedAt = playedAt; self.presetID = presetID; self.presetVersion = presetVersion; self.environment = environment; self.fingerprints = fingerprints; self.confirmed = confirmed
        self.screenshotDates = screenshotDates; self.dateContext = dateContext
    }
    public var orderDate: Date { playedAt ?? importedAt }
    public var timingCounts: (fast: Int, slow: Int)? {
        guard let p = judgments[.perfect], let g = judgments[.great], let pf = p.fast, let ps = p.slow, let gf = g.fast, let gs = g.slow else { return nil }
        return (pf + gf, ps + gs)
    }
}

public struct AppState: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var songs: [Song] = []
    public var charts: [Chart] = []
    public var bindings: [CatalogBinding] = []
    public var catalogs: [CatalogImportState] = []
    public var plays: [PlayRecord] = []
    public var environments: [PlayEnvironment] = [PlayEnvironment()]
    /// Optional for compatibility with existing schemaVersion 1 snapshots.
    public var automaticRegistrationEnabled: Bool?
    public init() {}
    public func song(for chart: Chart) -> Song? { songs.first { $0.id == chart.songID } }
    public func chart(for play: PlayRecord) -> Chart? { charts.first { $0.id == play.chartID } }
    public func activeCharts(gameID: String) -> [Chart] {
        let ids = Set(songs.filter { $0.gameID == gameID && $0.availability == .active }.map(\.id))
        return charts.filter { ids.contains($0.songID) && $0.availability == .active }
    }
}

public enum CoreError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let text): return text } }
}

public func normalizedName(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping.uppercased().filter { !$0.isWhitespace }
}

public func decimalString(_ value: Decimal?) -> String { value.map { NSDecimalNumber(decimal: $0).stringValue } ?? "" }
