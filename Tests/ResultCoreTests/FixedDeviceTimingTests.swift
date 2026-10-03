import Foundation
import XCTest
@testable import ResultCore

final class FixedDeviceTimingTests: XCTestCase {
    private let chartID = UUID()
    private let specification = TimingSpecification(unit: "ゲーム内単位", step: Decimal(string: "0.01")!, minimum: -3, maximum: 3, slowCorrectionDirection: 1)
    private var environment: PlayEnvironment { PlayEnvironment(settings: .init(noteSpeed: 10, noteTiming: Decimal(string: "0.10"), chartPosition: 0, mirror: false)) }
    private func play(_ environment: PlayEnvironment, fast: Int = 50, slow: Int = 150) -> PlayRecord {
        PlayRecord(chartID: chartID, gameID: "our-notes", titleAtPlay: "Test", difficultyAtPlay: "EXPERT", score: 1, achievement: .unknown, judgments: [.perfect: .init(fast: fast, slow: slow), .great: .init(fast: 0, slow: 0)], presetID: "test", presetVersion: 2, environment: environment, fingerprints: [])
    }
    private func recommend(_ environment: PlayEnvironment, _ rows: [PlayRecord]) -> TimingRecommendation {
        TimingService.recommend(chartID: chartID, environment: environment, plays: rows, specification: specification, environmentPolicy: .ourNotesFixedDevice)
    }

    func testFixedDevicePoolsAudioAndOptionalNotesIncludingUnspecifiedLegacyMetadata() {
        let current = environment
        var speaker = current; speaker.device = TimingEnvironmentPolicy.fixedDeviceName; speaker.audioOutput = "スピーカー"; speaker.conditions = "自宅"
        var earphone = current; earphone.device = "iPad Pro 11 (M2)"; earphone.audioOutput = "イヤホン"; earphone.conditions = ""
        let rows = [play(current), play(speaker), play(earphone)], original = rows
        let result = recommend(current, rows)
        XCTAssertEqual(result.playCount, 3); XCTAssertEqual(result.noteCount, 600)
        XCTAssertEqual(result.proposed, Decimal(string: "0.11"))
        XCTAssertEqual(rows, original); XCTAssertFalse(current.isSpecified)
        let strict = TimingService.recommend(chartID: chartID, environment: current, plays: rows, specification: specification)
        XCTAssertNil(strict.proposed); XCTAssertEqual(strict.playCount, 1)
    }

    func testFixedPolicyStillExcludesDifferentDeviceGameChartEnvironmentSettingsAndUnconfirmedData() {
        let current = environment
        let valid = (0..<3).map { _ in play(current) }
        var differentDevice = current; differentDevice.device = "iPhone"
        var differentEnvironment = current; differentEnvironment.id = UUID()
        var changedTiming = current; changedTiming.settings.noteTiming = Decimal(string: "0.11")
        var changedSpeed = current; changedSpeed.settings.noteSpeed = 11
        var changedPosition = current; changedPosition.settings.chartPosition = 1
        var changedMirror = current; changedMirror.settings.mirror = true
        var invalid = [differentDevice, differentEnvironment, changedTiming, changedSpeed, changedPosition, changedMirror].map { play($0, fast: 100_000, slow: 0) }
        var otherGame = play(current); otherGame.gameID = "other"
        var otherChart = play(current); otherChart.chartID = UUID()
        var unconfirmed = play(current); unconfirmed.confirmed = false
        var incomplete = play(current); incomplete.judgments[.great] = nil
        var unknown = play(current); unknown.environment = nil
        invalid += [otherGame, otherChart, unconfirmed, incomplete, unknown]
        let result = recommend(current, valid + invalid)
        XCTAssertEqual(result.playCount, 3); XCTAssertEqual(result.noteCount, 600)
        XCTAssertEqual(result.proposed, Decimal(string: "0.11"))
    }

    func testFixedPolicyRequiresEveryActualSettingAndRetainsSampleRangeAndBiasGuards() {
        for key in [0, 1, 2, 3] {
            var current = environment
            switch key {
            case 0: current.settings.noteSpeed = nil
            case 1: current.settings.noteTiming = nil
            case 2: current.settings.chartPosition = nil
            default: current.settings.mirror = nil
            }
            let result = recommend(current, (0..<3).map { _ in play(current) })
            XCTAssertNil(result.proposed); XCTAssertTrue(result.reason.contains("現在値を確認"))
        }
        let current = environment
        XCTAssertNil(recommend(current, [play(current), play(current)]).proposed)
        XCTAssertNil(recommend(current, (0..<3).map { _ in play(current, fast: 20, slow: 80) }).proposed)
        // The screenshot's 3 plays / 2156 events / approximately -7.5% still means retain the fixed value.
        let pictured = [play(current, fast: 333, slow: 378), play(current, fast: 450, slow: 260), play(current, fast: 376, slow: 359)]
        let held = recommend(current, pictured)
        XCTAssertEqual(held.noteCount, 2156); XCTAssertEqual(held.playCount, 3)
        XCTAssertNil(held.proposed); XCTAssertTrue(held.reason.contains("10%未満"))
        var edge = current; edge.settings.noteTiming = 3
        XCTAssertNil(recommend(edge, (0..<3).map { _ in play(edge) }).proposed)
        var offGrid = current; offGrid.settings.noteTiming = Decimal(string: "0.105")
        XCTAssertNil(recommend(offGrid, (0..<3).map { _ in play(offGrid) }).proposed)
    }
}
