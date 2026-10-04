import AppKit
import SwiftUI

/// Only captures/restores the native responder. Keyboard routing remains SwiftUI's.
@MainActor final class PlayDetailFocusRestoration {
    private weak var window: NSWindow?
    private weak var responder: NSResponder?
    func capture() { window = NSApp.keyWindow; responder = window?.firstResponder }
    func restore() {
        if let window, let responder { window.makeFirstResponder(responder) }
        window = nil; responder = nil
    }
}

private struct PlayDetailPresentedKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
    var playDetailPresented: Bool? {
        get { self[PlayDetailPresentedKey.self] }
        set { self[PlayDetailPresentedKey.self] = newValue }
    }
}

struct PlayDetailOverlay: View {
    let record: HomeRecord
    let onDismiss: (_ openHistory: Bool) -> Void
    @Environment(\.appPalette) private var palette
    @BrandReduceMotion private var reduceMotion
    @State private var visible = false
    @State private var closing = false
    @FocusState private var closeFocused: Bool
    @AccessibilityFocusState private var accessibilityCloseFocused: Bool
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(visible ? (palette.isDark ? 0.46 : 0.26) : 0)
                    .contentShape(Rectangle()).onTapGesture { close(openHistory: false) }
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("playDetail.backdrop")
                ScrollView {
                    HomeRecordDetail(record: record, onClose: { close(openHistory: false) },
                                     onShowChart: { close(openHistory: true) },
                                     closeFocus: $closeFocused, accessibilityCloseFocus: $accessibilityCloseFocused)
                }.frame(width: 540).frame(maxHeight: max(1, min(700, geometry.size.height - 48)))
                    .background(palette.raised, in: RoundedRectangle(cornerRadius: 20))
                    .overlay { RoundedRectangle(cornerRadius: 20).stroke(palette.border) }
                    .shadow(color: .black.opacity(palette.isDark ? 0.24 : 0.12), radius: 18, y: 8)
                    .opacity(visible ? 1 : 0).scaleEffect(visible || reduceMotion ? 1 : 0.98)
                    .disabled(closing).focusSection()
                    .accessibilityAddTraits(.isModal)
                    .accessibilityIdentifier("playDetail.dialog")
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.onAppear {
            withAnimation(.easeOut(duration: reduceMotion ? BrandMotion.reducedFadeDuration : BrandMotion.popupOpenDuration)) { visible = true }
            closeFocused = true; accessibilityCloseFocused = true
        }
    }
    private func close(openHistory: Bool) {
        guard !closing else { return }
        closing = true
        withAnimation(.easeOut(duration: reduceMotion ? BrandMotion.reducedFadeDuration : BrandMotion.popupCloseDuration), completionCriteria: .logicallyComplete) {
            visible = false
        } completion: { onDismiss(openHistory) }
    }
}
