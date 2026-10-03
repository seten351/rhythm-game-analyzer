import AppKit
import SwiftUI
import XCTest
@testable import OurNotesApp

final class BrandStyleTests: XCTestCase {
    func testPersistedThemeChoicesRemainDistinctAndCompatible() {
        XCTAssertEqual(AppTheme(rawValue: "system"), .system)
        XCTAssertEqual(AppTheme(rawValue: "ourNotes"), .ourNotes)
        XCTAssertEqual(AppTheme(rawValue: "ourNotesLogo"), .ourNotesLogo)
        XCTAssertEqual(AppTheme(rawValue: "ourNotesBrand"), .ourNotesBrand)
        XCTAssertEqual(Set(AppTheme.allCases.map(\.rawValue)).count, 4)
        XCTAssertEqual(AppTheme.preferenceKey, "appearanceTheme")
        XCTAssertEqual(AppAppearance.preferenceKey, "appearanceMode")
        for theme in AppTheme.allCases {
            XCTAssertEqual(AppPalette(theme: theme).usesBrandUI, theme == .ourNotesBrand)
            XCTAssertEqual(AppPalette(theme: theme).usesLogoMotif, theme == .ourNotesLogo)
        }
    }

    func testEarlierPalettesKeepTheirOriginalColors() throws {
        let original: [(AppTheme, [UInt32], [UInt32])] = [
            (.ourNotes, [0xF4F3FA, 0xEAEAF5, 0xFFFFFF, 0xEDEFFC, 0x515FAC, 0x107780, 0x96529E, 0xD5D6EA],
                        [0x161725, 0x1C1D32, 0x252A45, 0x303758, 0xA7B9FF, 0x7CDBE4, 0xE0A9F0, 0x434C73]),
            (.ourNotesLogo, [0xF4F5F7, 0xE9EDF3, 0xFFFFFF, 0xEFF2F7, 0x4F5D80, 0x286F83, 0x92547E, 0xD1D9E5],
                            [0x191E2B, 0x222A3B, 0x293246, 0x333F56, 0xAFCBDF, 0x8DD3E3, 0xDFB5D3, 0x4D5D76])
        ]
        for (theme, light, dark) in original {
            for isDark in [false, true] {
                let palette = AppPalette(theme: theme, isDark: isDark)
                let actual = [palette.background, palette.sidebar, palette.surface, palette.raised,
                              palette.accent, palette.fc, palette.ap, palette.border]
                for (color, expected) in zip(actual, isDark ? dark : light) {
                    let rgb = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
                    XCTAssertEqual(rgb.redComponent, Double((expected >> 16) & 255) / 255, accuracy: 0.001)
                    XCTAssertEqual(rgb.greenComponent, Double((expected >> 8) & 255) / 255, accuracy: 0.001)
                    XCTAssertEqual(rgb.blueComponent, Double(expected & 255) / 255, accuracy: 0.001)
                }
            }
        }
    }

    func testBrandSmallTextHasContrastOnEverySurfaceInBothModes() {
        for isDark in [false, true] {
            let colors = BrandColors(isDark: isDark)
            for foreground in [colors.ink, colors.action, colors.achievement, colors.secondaryText] {
                for background in [colors.canvas, colors.surface, colors.raised] {
                    let a = luminance(foreground.hex), b = luminance(background.hex)
                    let contrast = (max(a, b) + 0.05) / (min(a, b) + 0.05)
                    XCTAssertGreaterThanOrEqual(contrast, 4.5,
                        "dark=\(isDark), foreground=\(foreground.hex), background=\(background.hex)")
                }
            }
        }
    }

    func testDecorativeLightColorsAreNotUsedAsSmallText() {
        let colors = BrandColors(isDark: false)
        XCTAssertNotEqual(colors.action, colors.noteBlue)
        XCTAssertNotEqual(colors.achievement, colors.notePink)
        XCTAssertEqual(BrandColors(isDark: true).action, BrandColors(isDark: true).noteBlue)
    }

    func testFontResolutionSkipsUnavailableFontsAndSupportsFallback() {
        XCTAssertNil(BrandTypography.availableScriptName(candidates: []))
        XCTAssertNil(BrandTypography.availableScriptName(candidates: ["OurNotesMissingFont-ForTest"]))
        XCTAssertEqual(BrandTypography.availableScriptName(candidates: ["OurNotesMissingFont-ForTest", "Helvetica"]), "Helvetica")
    }

    func testLineRolesReservePinkForSignaturesAndSpecialAchievements() {
        XCTAssertEqual(BrandLineRole.section.widths.count, 2, "Normal sections must not draw the third/pink line")
        XCTAssertEqual(BrandLineRole.signature.widths.count, 3)
        for (kind, dominant) in [(HomeAchievementKind.firstAP, 2), (.firstFC, 1), (.comboImproved, 0)] {
            let widths = BrandLineRole.achievement(kind).widths
            XCTAssertEqual(widths.count, 3)
            XCTAssertEqual(widths[dominant], widths.max(), "The achievement's semantic color must lead")
        }
    }

    func testSelectedRowsKeepReadableAchievementAndSecondaryText() {
        for isDark in [false, true] {
            let colors = BrandColors(isDark: isDark)
            let alpha = isDark ? 0.10 : 0.12
            let background = zip(components(colors.noteBlue.hex), components(colors.surface.hex))
                .map { $0 * alpha + $1 * (1 - alpha) }
            for foreground in [colors.ink, colors.action, colors.achievement, colors.secondaryText] {
                let a = luminance(foreground.hex), b = luminance(background)
                XCTAssertGreaterThanOrEqual((max(a, b) + 0.05) / (min(a, b) + 0.05), 4.5,
                    "Selected-row contrast, dark=\(isDark), foreground=\(foreground.hex)")
            }
        }
    }

    private func components(_ hex: UInt32) -> [Double] {
        [16, 8, 0].map { Double((hex >> $0) & 255) / 255 }
    }
    private func luminance(_ hex: UInt32) -> Double {
        luminance(components(hex))
    }
    private func luminance(_ components: [Double]) -> Double {
        components.enumerated().reduce(0) { sum, component in
            let value = component.element
            let linear = value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            return sum + linear * [0.2126, 0.7152, 0.0722][component.offset]
        }
    }
}
