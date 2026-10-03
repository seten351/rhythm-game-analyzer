import AppKit
import SwiftUI

/// Decorative note colors and readable foregrounds have separate roles.
/// In particular, the pale blue/pink from the logo aren't small-text colors on white.
struct BrandColors {
    struct RGB: Equatable {
        let hex: UInt32
        var color: Color {
            Color(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255)
        }
    }
    let isDark: Bool
    private func tone(_ light: UInt32, _ dark: UInt32) -> RGB { RGB(hex: isDark ? dark : light) }
    var ink: RGB { tone(0x526675, 0xAFC2CF) }
    var noteBlue: RGB { tone(0x69B8D5, 0x72C7E5) }
    var notePink: RGB { tone(0xD58FA5, 0xE3A0B4) }
    var canvas: RGB { tone(0xEDF1F3, 0x10151A) }
    var surface: RGB { tone(0xF5F7F8, 0x171D22) }
    var raised: RGB { tone(0xFFFFFF, 0x1D252C) }
    var border: RGB { tone(0xD6DEE3, 0x303A42) }
    var action: RGB { tone(0x276C84, 0x72C7E5) }
    var achievement: RGB { tone(0x925069, 0xE3A0B4) }
    var secondaryText: RGB { tone(0x5C6871, 0xA4B2BD) }
    var selection: Color { noteBlue.color.opacity(isDark ? 0.10 : 0.12) }
}

enum BrandTypography {
    // Existing macOS fonts only. Resolve centrally so views never depend on a family.
    static let scriptCandidates = ["SnellRoundhand", "Apple-Chancery", "Noteworthy-Light"]
    static func availableScriptName(candidates: [String] = scriptCandidates) -> String? {
        candidates.first { NSFont(name: $0, size: 20) != nil }
    }
    static func script(size: CGFloat) -> Font {
        if let name = availableScriptName() { return .custom(name, fixedSize: size) }
        return .system(size: size, weight: .regular, design: .serif).italic()
    }
}

/// Script labels are category kickers, never data or operation labels.
enum BrandCategory: String {
    case ourNotes = "Our Notes", achievement = "Achievement", library = "Library"
    case imports = "Import", analysis = "Analysis", history = "History"
    case settings = "Settings", newRecord = "New Record"
}

enum BrandLineRole {
    case signature, section, achievement(HomeAchievementKind)
    var widths: [CGFloat] {
        switch self {
        case .signature: return [33, 37, 23]
        case .section: return [24, 18]
        case .achievement(.firstAP): return [19, 23, 31]
        case .achievement(.firstFC): return [20, 31, 12]
        case .achievement(.comboImproved): return [31, 25, 9]
        }
    }
    var size: CGSize {
        switch self {
        case .signature: return CGSize(width: 48, height: 25)
        case .section: return CGSize(width: 31, height: 16)
        case .achievement: return CGSize(width: 40, height: 18)
        }
    }
    var lineHeight: CGFloat { if case .signature = self { return 2 }; return 1.5 }
    func offset(for index: Int) -> CGSize {
        if case .signature = self { return CGSize(width: [0, 9, 23][index], height: [7, 12, 17][index]) }
        return CGSize(width: CGFloat(index) * (widths.count == 2 ? 7 : 4), height: CGFloat(index) * 4 + 3)
    }
}

/// Full signatures belong to page starts and special achievements; sections use ink/blue only.
struct BrandNoteLines: View {
    let colors: BrandColors
    var role: BrandLineRole = .signature
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(role.widths.indices, id: \.self) { index in
                Capsule().fill([colors.ink.color, colors.noteBlue.color, colors.notePink.color][index])
                    .frame(width: role.widths[index], height: role.lineHeight)
                    .offset(role.offset(for: index))
            }
        }.frame(width: role.size.width, height: role.size.height).rotationEffect(.degrees(-18))
            .accessibilityHidden(true).allowsHitTesting(false)
    }
}

struct BrandScriptLabel: View {
    let category: BrandCategory
    var size: CGFloat = 13
    @Environment(\.appPalette) private var palette
    var body: some View {
        Text(category.rawValue).font(BrandTypography.script(size: size)).foregroundStyle(palette.brand.ink.color)
            .lineLimit(1).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
    }
}

/// Japanese is the semantic title; English is a small, optional signature.
struct BrandSectionHeader: View {
    let title: String
    var category: BrandCategory? = nil
    var symbol: String? = nil
    var font: Font = .headline
    var role: BrandLineRole = .section
    var kickerSize: CGFloat = 13
    @Environment(\.appPalette) private var palette
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if palette.usesBrandUI { BrandNoteLines(colors: palette.brand, role: role) }
            VStack(alignment: .leading, spacing: 2) {
                if palette.usesBrandUI, let category { BrandScriptLabel(category: category, size: kickerSize) }
                Group {
                    if let symbol { Label(title, systemImage: symbol) }
                    else { Text(title) }
                }.font(font)
            }
        }
    }
}

struct BrandPageHeader: View {
    let page: Page
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            BrandSectionHeader(title: page.title, category: page.brandCategory, font: .title2.weight(.semibold), role: .signature, kickerSize: 15)
            Text(page.subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Replaces the large empty-state symbol; keeps the Japanese meaning and actions in each view.
struct BrandEmptyState: View {
    let title: String
    var description: String? = nil
    let category: BrandCategory
    var alignment: HorizontalAlignment = .center
    var titleFont: Font = .headline
    @Environment(\.appPalette) private var palette
    var body: some View {
        VStack(alignment: alignment, spacing: 9) {
            HStack(spacing: 8) {
                BrandNoteLines(colors: palette.brand, role: .section)
                BrandScriptLabel(category: category)
            }
            Text(title).font(titleFont)
            if let description { Text(description).font(.callout).foregroundStyle(.secondary) }
        }.multilineTextAlignment(alignment == .leading ? .leading : .center)
            .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
            .padding(12)
    }
}

struct BrandAccentMark: View {
    let color: Color
    var body: some View {
        Capsule().fill(color).frame(width: 3)
            .accessibilityHidden(true).allowsHitTesting(false)
    }
}

struct BrandSidebarNavigation: View {
    @Binding var selection: Page?
    let pendingCount: Int
    @Environment(\.appPalette) private var palette
    @FocusState private var hasKeyboardFocus: Bool
    var body: some View {
        List {
            ForEach([Page.home, .library, .imports, .analysis]) { item in navigationButton(item) }
            Section("管理") { ForEach([Page.catalog, .settings]) { item in navigationButton(item) } }
        }.listStyle(.sidebar).scrollContentBackground(.hidden)
            .focusable().focused($hasKeyboardFocus).focusEffectDisabled()
            .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
            .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
    }
    private func moveSelection(by offset: Int) {
        let pages = Page.allCases
        let index = pages.firstIndex(of: selection ?? .home) ?? 0
        selection = pages[min(pages.count - 1, max(0, index + offset))]
    }
    private func navigationButton(_ item: Page) -> some View {
        Button { selection = item; hasKeyboardFocus = true } label: {
            HStack(spacing: 8) {
                BrandAccentMark(color: selection == item ? palette.brand.noteBlue.color : .clear).frame(height: 24)
                Label(item.title, systemImage: item.icon)
                    .foregroundStyle(selection == item ? palette.brand.action.color : Color(nsColor: .labelColor))
                Spacer(minLength: 0)
                if item == .imports && pendingCount > 0 { Text("\(pendingCount)").font(.caption).foregroundStyle(.orange) }
            }.padding(.vertical, 4).padding(.horizontal, 6)
                .background(selection == item ? palette.brand.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(selection == item ? item.title + "、選択中" : item.title)
            .accessibilityAddTraits(selection == item ? .isSelected : [])
    }
}
