import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    // Keep existing raw values so earlier theme choices continue to load.
    case system, ourNotes, ourNotesLogo, ourNotesBrand
    static let preferenceKey = "appearanceTheme"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "標準"
        case .ourNotes: return "アワーノーツ風"
        case .ourNotesLogo: return "アワーノーツ・ロゴ"
        case .ourNotesBrand: return "アワーノーツ・ロゴ（ブランド）"
        }
    }
    var summary: String {
        switch self {
        case .system: return "macOS標準の背景と、落ち着いた青緑のアクセント。"
        case .ourNotes: return "白紫・深い紺の背景に、青紫・シアン・ピンク。これまでのアワーノーツ風です。"
        case .ourNotesLogo: return "ロゴの青灰・水色・くすんだピンク。斜めに重なるラインをアクセントに。"
        case .ourNotesBrand: return "青灰の静かな面、水色の操作、くすみピンクの達成。細い手書き英字と3本のノーツライン。"
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    static let preferenceKey = "appearanceMode"
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return "システムに合わせる"; case .light: return "ライト"; case .dark: return "ダーク" }
    }
    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Original palette: official site and game result panels (2026-10-03).
/// Logo palette: the user-provided logo's slate, cyan and dusty pink ribbons.
/// No image assets or network access are needed for either theme.
struct AppPalette {
    var theme: AppTheme = .system
    var isDark = false
    var usesLogoMotif: Bool { theme == .ourNotesLogo }
    var usesBrandUI: Bool { theme == .ourNotesBrand }
    var brand: BrandColors { BrandColors(isDark: isDark) }
    private func color(_ light: UInt32, _ dark: UInt32) -> Color {
        let hex = isDark ? dark : light
        return Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    var background: Color {
        switch theme {
        case .system: return Color(nsColor: .windowBackgroundColor)
        case .ourNotes: return color(0xF4F3FA, 0x161725)
        case .ourNotesLogo: return color(0xF4F5F7, 0x191E2B)
        case .ourNotesBrand: return brand.canvas.color
        }
    }
    var sidebar: Color {
        switch theme {
        case .system: return Color(nsColor: .windowBackgroundColor)
        case .ourNotes: return color(0xEAEAF5, 0x1C1D32)
        case .ourNotesLogo: return color(0xE9EDF3, 0x222A3B)
        case .ourNotesBrand: return brand.surface.color
        }
    }
    var surface: Color {
        switch theme {
        case .system: return Color(nsColor: .controlBackgroundColor)
        case .ourNotes: return color(0xFFFFFF, 0x252A45)
        case .ourNotesLogo: return color(0xFFFFFF, 0x293246)
        case .ourNotesBrand: return brand.surface.color
        }
    }
    var raised: Color {
        switch theme {
        case .system: return Color(nsColor: .textBackgroundColor)
        case .ourNotes: return color(0xEDEFFC, 0x303758)
        case .ourNotesLogo: return color(0xEFF2F7, 0x333F56)
        case .ourNotesBrand: return brand.raised.color
        }
    }
    var accent: Color {
        switch theme {
        case .system: return color(0x087983, 0x5DCDDA)
        case .ourNotes: return color(0x515FAC, 0xA7B9FF)
        case .ourNotesLogo: return color(0x4F5D80, 0xAFCBDF)
        case .ourNotesBrand: return brand.action.color
        }
    }
    var fc: Color {
        switch theme {
        case .system: return accent
        case .ourNotes: return color(0x107780, 0x7CDBE4)
        case .ourNotesLogo: return color(0x286F83, 0x8DD3E3)
        case .ourNotesBrand: return brand.action.color
        }
    }
    var ap: Color {
        switch theme {
        case .system: return color(0x8F4796, 0xD993E7)
        case .ourNotes: return color(0x96529E, 0xE0A9F0)
        case .ourNotesLogo: return color(0x92547E, 0xDFB5D3)
        case .ourNotesBrand: return brand.achievement.color
        }
    }
    var border: Color {
        switch theme {
        case .system: return Color.primary.opacity(0.12)
        case .ourNotes: return color(0xD5D6EA, 0x434C73)
        case .ourNotesLogo: return color(0xD1D9E5, 0x4D5D76)
        case .ourNotesBrand: return brand.border.color
        }
    }
    var glow: Color {
        switch theme {
        case .system: return accent.opacity(0.05)
        case .ourNotes: return color(0xE1E9FC, 0x2E355B)
        case .ourNotesLogo: return color(0xE8EEF6, 0x364760)
        case .ourNotesBrand: return brand.surface.color
        }
    }
    var ribbonColors: [Color] {
        [color(0x505873, 0x7185A7), color(0x667D9F, 0x92B2CE),
         color(0x73B4CD, 0x86C8DC), color(0xC6A3BF, 0xD0AEC9)]
    }
    func achievementColor(_ kind: HomeAchievementKind) -> Color {
        if usesBrandUI && kind == .comboImproved { return brand.ink.color }
        return kind == .firstAP ? ap : fc
    }
}

private struct AppPaletteKey: EnvironmentKey {
    static let defaultValue = AppPalette()
}
extension EnvironmentValues {
    var appPalette: AppPalette {
        get { self[AppPaletteKey.self] }
        set { self[AppPaletteKey.self] = newValue }
    }
}
