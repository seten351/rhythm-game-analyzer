import SwiftUI

/// The line and card share one event; the line's tail overlaps the card arrival.
struct BrandAchievementAppearance<Content: View>: View {
    let playID: UUID
    let claimPresentation: () -> Bool
    let colors: BrandColors
    let kind: HomeAchievementKind
    @ViewBuilder let content: (CGFloat) -> Content
    @Environment(\.appPalette) private var palette
    @BrandReduceMotion private var reduceMotion
    @State private var line: CGFloat = 1
    @State private var arrived = true
    @State private var celebrating = false
    var body: some View {
        ZStack(alignment: .topLeading) {
        content(celebrating ? 0 : 1)
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived || reduceMotion ? 0 : 8)
            .scaleEffect(arrived || reduceMotion ? 1 : 0.98)
        if celebrating {
            BrandNoteLines(colors: colors, role: .achievement(kind), progress: reduceMotion ? 1 : line)
                .padding(.leading, 16).padding(.top, 16)
                .accessibilityHidden(true).allowsHitTesting(false)
        }
        }
            .task(id: playID) {
                guard claimPresentation(), palette.usesBrandUI, !reduceMotion else { return }
                var instant = Transaction(); instant.disablesAnimations = true
                withTransaction(instant) { line = 0; arrived = false; celebrating = true }
                await Task.yield()
                withAnimation(.easeOut(duration: BrandMotion.lineDuration)) { line = 1 }
                withAnimation(.easeOut(duration: BrandMotion.cardDuration).delay(BrandMotion.cardDelay)) { arrived = true }
                do { try await Task.sleep(for: .seconds(BrandMotion.achievementDuration)) } catch { return }
                celebrating = false
            }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { var instant = Transaction(); instant.disablesAnimations = true; withTransaction(instant) { line = 1; arrived = true; celebrating = false } }
            }
    }
}
