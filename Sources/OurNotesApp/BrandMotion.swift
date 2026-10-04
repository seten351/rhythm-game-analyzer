import SwiftUI

private struct BrandMotionVerificationReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var brandMotionVerificationReduceMotion: Bool {
        get { self[BrandMotionVerificationReduceMotionKey.self] }
        set { self[BrandMotionVerificationReduceMotionKey.self] = newValue }
    }
}

/// A verification override can only reduce motion, never bypass the OS preference.
@propertyWrapper struct BrandReduceMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var systemValue
    @Environment(\.brandMotionVerificationReduceMotion) private var verificationValue
    var wrappedValue: Bool { systemValue || verificationValue }
    init() {}
}

/// Motion stays local to decorative marks; navigation and data remain immediate.
enum BrandMotion {
    static let normalDuration = 0.16
    static let selectionDuration = 0.16
    static let achievementDuration = 0.28
    static let lineDuration = 0.22
    static let cardDelay = 0.08
    static let cardDuration = 0.20
    static let emptyDuration = 0.16
    static let popupOpenDuration = 0.16
    static let popupCloseDuration = 0.14
    static let reducedFadeDuration = 0.12

    static func isEnabled(theme: AppTheme, reduceMotion: Bool) -> Bool {
        theme == .ourNotesBrand && !reduceMotion
    }
    static func selection(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: selectionDuration)
    }
}

/// Session-only presentation state. Reopening a page, editing a record, or skipping
/// a duplicate must not replay a celebration. Saved history is never a trigger.
struct BrandAchievementMotionLedger {
    private(set) var presentedPlayIDs = Set<UUID>()

    mutating func claim(playID: UUID, batchPlayIDs: [UUID], theme: AppTheme, reduceMotion: Bool) -> Bool {
        guard batchPlayIDs.contains(playID), presentedPlayIDs.insert(playID).inserted else { return false }
        return BrandMotion.isEnabled(theme: theme, reduceMotion: reduceMotion)
    }
}

struct BrandAchievementNoteLines: View {
    let colors: BrandColors
    let kind: HomeAchievementKind
    let playID: UUID
    let claimPresentation: () -> Bool
    @BrandReduceMotion private var reduceMotion
    @State private var presentation = 0

    var body: some View {
        let motionReduced = reduceMotion
        return Color.clear.frame(width: 40, height: 18)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: presentation) { _, progress in
                BrandNoteLines(colors: colors, role: .achievement(kind), progress: motionReduced ? 1 : progress)
            } keyframes: { _ in
                MoveKeyframe(0)
                CubicKeyframe(1, duration: BrandMotion.achievementDuration)
            }
            .task(id: playID) { if claimPresentation() { presentation += 1 } }
            .accessibilityHidden(true).allowsHitTesting(false)
    }
}

/// Only the small brand signature appears; text and actions are available at once.
struct BrandEmptyMarkAppearance: ViewModifier {
    @Environment(\.appPalette) private var palette
    @BrandReduceMotion private var reduceMotion
    @State private var appeared = false
    private var enabled: Bool { palette.usesBrandUI }

    func body(content: Content) -> some View {
        content.opacity(!enabled || appeared ? 1 : 0)
            .animation(enabled ? .easeOut(duration: reduceMotion ? BrandMotion.reducedFadeDuration : BrandMotion.emptyDuration) : nil, value: appeared)
            .onAppear { appeared = true }
    }
}
