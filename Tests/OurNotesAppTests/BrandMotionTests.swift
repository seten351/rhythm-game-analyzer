import XCTest
@testable import OurNotesApp

final class BrandMotionTests: XCTestCase {
    func testMotionIsLimitedToBrandThemeAndRespectsReduceMotion() {
        for theme in AppTheme.allCases {
            XCTAssertEqual(BrandMotion.isEnabled(theme: theme, reduceMotion: false), theme == .ourNotesBrand)
            XCTAssertFalse(BrandMotion.isEnabled(theme: theme, reduceMotion: true))
        }

        XCTAssertNotNil(BrandMotion.selection(reduceMotion: false))
        XCTAssertNil(BrandMotion.selection(reduceMotion: true))
    }

    func testStartupHistoryAndSkippedDuplicateOrFailedPlaysWithoutBatchIDsDoNotClaimMotion() {
        var ledger = BrandAchievementMotionLedger()
        let oldHistoryID = UUID()
        let duplicateID = UUID()
        let failedImportID = UUID()

        // The startup history and skipped outcomes do not appear in the newly
        // completed batch, so they cannot trigger an achievement presentation.
        for id in [oldHistoryID, duplicateID, failedImportID] {
            XCTAssertFalse(ledger.claim(playID: id, batchPlayIDs: [], theme: .ourNotesBrand, reduceMotion: false))
        }
        XCTAssertTrue(ledger.presentedPlayIDs.isEmpty)
    }

    func testClaimedAchievementDoesNotReplayWhenPageIsReopenedOrRecordIsEdited() {
        var ledger = BrandAchievementMotionLedger()
        let playID = UUID()
        let batch = [playID]

        XCTAssertTrue(ledger.claim(playID: playID, batchPlayIDs: batch, theme: .ourNotesBrand, reduceMotion: false))
        // Re-rendering the same achievement after navigating away or editing its record is the same presentation.
        XCTAssertFalse(ledger.claim(playID: playID, batchPlayIDs: batch, theme: .ourNotesBrand, reduceMotion: false))
        XCTAssertEqual(ledger.presentedPlayIDs, [playID])
    }

    func testAchievementSeenWithReduceMotionDoesNotReplayWhenReduceMotionIsDisabled() {
        var ledger = BrandAchievementMotionLedger()
        let playID = UUID()
        let batch = [playID]

        XCTAssertFalse(ledger.claim(playID: playID, batchPlayIDs: batch, theme: .ourNotesBrand, reduceMotion: true))
        XCTAssertFalse(ledger.claim(playID: playID, batchPlayIDs: batch, theme: .ourNotesBrand, reduceMotion: false))
        XCTAssertEqual(ledger.presentedPlayIDs, [playID])
    }

    func testClaimsAreIndependentAcrossAchievementsAndBatches() {
        var ledger = BrandAchievementMotionLedger()
        let first = UUID()
        let second = UUID()
        let nextBatch = UUID()

        XCTAssertTrue(ledger.claim(playID: first, batchPlayIDs: [first, second], theme: .ourNotesBrand, reduceMotion: false))
        XCTAssertTrue(ledger.claim(playID: second, batchPlayIDs: [first, second], theme: .ourNotesBrand, reduceMotion: false))
        XCTAssertFalse(ledger.claim(playID: first, batchPlayIDs: [first, second], theme: .ourNotesBrand, reduceMotion: false))
        XCTAssertTrue(ledger.claim(playID: nextBatch, batchPlayIDs: [nextBatch], theme: .ourNotesBrand, reduceMotion: false))
        XCTAssertEqual(ledger.presentedPlayIDs, [first, second, nextBatch])
    }

    func testAchievementClaimOnNonBrandThemeIsRecordedWithoutMotionReplay() {
        var ledger = BrandAchievementMotionLedger()
        let playID = UUID()

        XCTAssertFalse(ledger.claim(playID: playID, batchPlayIDs: [playID], theme: .ourNotesLogo, reduceMotion: false))
        XCTAssertTrue(ledger.presentedPlayIDs.contains(playID))
        XCTAssertFalse(ledger.claim(playID: playID, batchPlayIDs: [playID], theme: .ourNotesBrand, reduceMotion: false))
    }

    func testBackdropHitTestDismissesOnlyInsideParentAndOutsideSheet() {
        let parent = CGRect(x: 100, y: 100, width: 800, height: 600)
        let sheet = CGRect(x: 250, y: 240, width: 500, height: 320)

        XCTAssertTrue(SheetBackdropHitTest.shouldDismiss(point: CGPoint(x: 150, y: 150), sheetFrame: sheet, backdropFrame: parent))
        XCTAssertFalse(SheetBackdropHitTest.shouldDismiss(point: CGPoint(x: 400, y: 400), sheetFrame: sheet, backdropFrame: parent))
        XCTAssertFalse(SheetBackdropHitTest.shouldDismiss(point: CGPoint(x: 50, y: 150), sheetFrame: sheet, backdropFrame: parent))
    }

    func testInteractiveFixtureAddsThreeNewAchievementsAndCannotRegisterThemTwice() async {
        await MainActor.run {
            let verification = BrandMotionVerification()
            XCTAssertNil(verification.model.startupError)
            let baselineCount = verification.model.state.plays.count
            XCTAssertTrue(verification.model.lastBatchPlayIDs.isEmpty)
            verification.addAchievements()
            let model = verification.model
            XCTAssertNil(model.errorMessage)
            let snapshot = HomePresentation.snapshot(state: model.state, gameID: model.gameID, batchPlayIDs: model.lastBatchPlayIDs)
            XCTAssertEqual(Set(snapshot.achievements.map { $0.kind.rawValue }), [0, 1, 2])
            XCTAssertEqual(snapshot.focusCount, 3)
            XCTAssertEqual(model.state.plays.count, baselineCount + 3)
            verification.addAchievements()
            XCTAssertEqual(model.state.plays.count, baselineCount + 3)
        }
    }
}
