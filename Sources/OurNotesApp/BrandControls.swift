import SwiftUI

/// Scores pulse only when a mounted value improves for the same chart or card.
struct BrandMetricValue: View {
    let value: Int?
    let identity: UUID
    @Environment(\.appPalette) private var palette
    @BrandReduceMotion private var reduceMotion
    @State private var mounted = false
    @State private var pulseOpacity = 0.0
    @State private var pulseTask: Task<Void, Never>?

    private struct Snapshot: Equatable {
        let value: Int?
        let identity: UUID
    }

    var body: some View {
        Text(value?.formatted() ?? "—")
            .monospacedDigit()
            .overlay {
                Text(value?.formatted() ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(palette.accent)
                    .opacity(pulseOpacity)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            .onAppear { mounted = true }
            .onChange(of: Snapshot(value: value, identity: identity)) { previous, next in
                cancelPulse()
                guard mounted, previous.identity == next.identity,
                      let previousValue = previous.value, let nextValue = next.value,
                      nextValue > previousValue,
                      BrandMotion.isEnabled(theme: palette.theme, reduceMotion: reduceMotion) else { return }
                withAnimation(.easeOut(duration: 0.12)) { pulseOpacity = 1 }
                pulseTask = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(0.12)) } catch { return }
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.16)) { pulseOpacity = 0 }
                }
            }
            .onChange(of: reduceMotion) { _, reduced in if reduced { cancelPulse() } }
            .onChange(of: palette.theme) { _, _ in cancelPulse() }
            .onDisappear { mounted = false; cancelPulse() }
    }

    private func cancelPulse() {
        pulseTask?.cancel()
        pulseTask = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { pulseOpacity = 0 }
    }
}

/// The animation belongs to this body boundary, leaving its contents' values immediate.
struct BrandContentSwitch<Key: Hashable, Content: View>: View {
    let value: Key
    @ViewBuilder let content: () -> Content
    @Environment(\.appPalette) private var palette
    @BrandReduceMotion private var reduceMotion

    var body: some View {
        if palette.usesBrandUI {
            ZStack(alignment: .topLeading) {
                content()
                    .animation(nil, value: value)
                    .id(value)
                    .transition(.opacity)
            }
            .animation(.easeOut(duration: reduceMotion ? BrandMotion.reducedFadeDuration : BrandMotion.normalDuration), value: value)
        } else {
            content()
        }
    }
}

/// A filter or selection can change emptiness without being a saved-data event.
struct BrandSavedDataTransition<Content: View>: View {
    let isEmpty: Bool
    let savedPlayIDs: [UUID]
    @ViewBuilder let content: () -> Content
    @Environment(\.appPalette) private var palette
    @BrandReduceMotion private var reduceMotion
    @State private var opacity = 1.0
    @State private var appearanceTask: Task<Void, Never>?

    private struct BoundarySnapshot: Equatable {
        let isEmpty: Bool
        let savedPlayIDs: [UUID]
    }

    var body: some View {
        content()
            .opacity(opacity)
            .onChange(of: BoundarySnapshot(isEmpty: isEmpty, savedPlayIDs: savedPlayIDs)) { previous, next in
                if next.isEmpty { cancelAppearance() }
                guard palette.usesBrandUI, previous.isEmpty, !next.isEmpty,
                      previous.savedPlayIDs.isEmpty, !next.savedPlayIDs.isEmpty else { return }
                appearanceTask?.cancel()
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { opacity = 0 }
                appearanceTask = Task { @MainActor in
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: reduceMotion ? BrandMotion.reducedFadeDuration : BrandMotion.emptyDuration)) {
                        opacity = 1
                    }
                }
            }
            .onChange(of: palette.theme) { _, _ in cancelAppearance() }
            .onDisappear { cancelAppearance() }
    }

    private func cancelAppearance() {
        appearanceTask?.cancel()
        appearanceTask = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { opacity = 1 }
    }
}

struct BrandSegmentChoice<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var id: Value { value }
}

/// Brand tabs retain button semantics and support left/right keyboard navigation.
struct BrandSegmentedControl<Value: Hashable>: View {
    let choices: [BrandSegmentChoice<Value>]
    @Binding var selection: Value
    let accessibilityLabel: String
    @Environment(\.appPalette) private var palette
    @BrandReduceMotion private var reduceMotion
    @Namespace private var indicator
    @FocusState private var focusedChoice: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices) { choice in
                Button { selection = choice.value } label: {
                    Text(choice.label)
                        .font(.callout.weight(selection == choice.value ? .semibold : .regular))
                        .foregroundStyle(selection == choice.value ? palette.brand.ink.color : palette.brand.secondaryText.color)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .background {
                            ZStack {
                                if selection == choice.value {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(palette.brand.selection)
                                        .matchedGeometryEffect(id: "selection", in: indicator)
                                }
                            }
                            .animation(BrandMotion.selection(reduceMotion: reduceMotion), value: selection)
                        }
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedChoice, equals: choice.value)
                .accessibilityLabel(choice.label)
                .accessibilityAddTraits(selection == choice.value ? .isSelected : [])
                .onKeyPress(.leftArrow) { moveSelection(from: choice.value, offset: -1); return .handled }
                .onKeyPress(.rightArrow) { moveSelection(from: choice.value, offset: 1); return .handled }
            }
        }
        .padding(3)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func moveSelection(from value: Value, offset: Int) {
        guard let index = choices.firstIndex(where: { $0.value == value }), !choices.isEmpty else { return }
        let next = choices[min(max(index + offset, 0), choices.count - 1)].value
        selection = next
        focusedChoice = next
    }
}
