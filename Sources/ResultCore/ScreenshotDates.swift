import Foundation

public enum ScreenshotDateSource: String, Codable, Sendable { case metadata, filename }
public enum ScreenshotImageKind: String, Codable, Sendable { case normal, detail, settings, unknown }
public enum PlayDateSource: String, Codable, Sendable { case screenshot, manual }

/// Normalized date evidence only. Never contains a filename, path, image hash or raw metadata.
public struct ScreenshotDateCandidate: Codable, Equatable, Sendable {
    public var capturedAt: Date
    public var source: ScreenshotDateSource
    public var metadataField: String?
    public var timeZone: String
    public var timeZoneAssumed: Bool
    public init(capturedAt: Date, source: ScreenshotDateSource, metadataField: String? = nil, timeZone: String, timeZoneAssumed: Bool) {
        self.capturedAt = capturedAt; self.source = source; self.metadataField = metadataField
        self.timeZone = timeZone; self.timeZoneAssumed = timeZoneAssumed
    }
}

/// A separate anonymous ID for each source image preserves both sides of a result pair.
public struct ScreenshotDateEvidence: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var imageKind: ScreenshotImageKind
    public var candidates: [ScreenshotDateCandidate]
    public init(id: UUID = UUID(), imageKind: ScreenshotImageKind, candidates: [ScreenshotDateCandidate] = []) {
        self.id = id; self.imageKind = imageKind; self.candidates = candidates
    }
    public var hasConflict: Bool { Set(candidates.map(\.capturedAt)).count > 1 }
}

public struct ScreenshotDateReference: Codable, Equatable, Sendable {
    public var screenshotID: UUID
    public var candidateIndex: Int
    public init(screenshotID: UUID, candidateIndex: Int) { self.screenshotID = screenshotID; self.candidateIndex = candidateIndex }
}

public struct PlayDateContext: Codable, Equatable, Sendable {
    public var selectedScreenshotDate: ScreenshotDateReference?
    public var playedAtSource: PlayDateSource?
    public init(selectedScreenshotDate: ScreenshotDateReference? = nil, playedAtSource: PlayDateSource? = nil) {
        self.selectedScreenshotDate = selectedScreenshotDate; self.playedAtSource = playedAtSource
    }
}

public struct ScreenshotDateChoice: Identifiable, Equatable, Sendable {
    public var reference: ScreenshotDateReference
    public var imageKind: ScreenshotImageKind
    public var candidate: ScreenshotDateCandidate
    public var id: String { "\(reference.screenshotID.uuidString):\(reference.candidateIndex)" }
    public static func choices(in evidence: [ScreenshotDateEvidence]) -> [Self] {
        evidence.flatMap { image in image.candidates.enumerated().map { index, candidate in
            Self(reference: .init(screenshotID: image.id, candidateIndex: index), imageKind: image.imageKind, candidate: candidate)
        } }.sorted {
            if $0.candidate.capturedAt != $1.candidate.capturedAt { return $0.candidate.capturedAt < $1.candidate.capturedAt }
            return $0.id < $1.id
        }
    }
}

extension PlayRecord {
    public var selectedScreenshotDate: ScreenshotDateCandidate? {
        guard let reference = dateContext?.selectedScreenshotDate,
              let image = screenshotDates?.first(where: { $0.id == reference.screenshotID }),
              image.candidates.indices.contains(reference.candidateIndex) else { return nil }
        return image.candidates[reference.candidateIndex]
    }
    public func validateDateContext() throws {
        if let reference = dateContext?.selectedScreenshotDate, selectedScreenshotDate == nil {
            throw CoreError.invalid("撮影日時の候補が見つかりません（\(reference.screenshotID)）。選び直してください。")
        }
        if dateContext?.playedAtSource == .screenshot {
            guard let playedAt, selectedScreenshotDate?.capturedAt == playedAt else {
                throw CoreError.invalid("スクショ日時と採用するプレイ日時が一致しません。候補か手入力を選び直してください。")
            }
        }
    }
}
