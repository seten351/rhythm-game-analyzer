import SwiftUI

/// Uneven, rising bands echo the logo without placing image content behind data.
private struct LogoRibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let bands: [(start: CGFloat, end: CGFloat, y: CGFloat, height: CGFloat)] = [
            (0.12, 0.68, 0.30, 0.025), (0.18, 0.88, 0.38, 0.055),
            (0.08, 0.97, 0.45, 0.055), (0.14, 0.94, 0.52, 0.055),
            (0.00, 0.88, 0.59, 0.055), (0.06, 1.00, 0.66, 0.025),
            (0.13, 0.93, 0.71, 0.055), (0.05, 0.85, 0.78, 0.055),
            (0.09, 0.94, 0.85, 0.025), (0.00, 0.72, 0.90, 0.055),
            (0.10, 0.56, 0.97, 0.055)
        ]
        var path = Path()
        for band in bands {
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + x * rect.width, y: rect.minY + (y - x * 0.50) * rect.height)
            }
            path.move(to: point(band.start, band.y))
            path.addLine(to: point(band.end, band.y))
            path.addLine(to: point(band.end, band.y + band.height))
            path.addLine(to: point(band.start, band.y + band.height))
            path.closeSubpath()
        }
        return path
    }
}

struct LogoRibbons: View {
    let palette: AppPalette
    var body: some View {
        LogoRibbonShape()
            .fill(LinearGradient(colors: palette.ribbonColors, startPoint: .bottomLeading, endPoint: .topTrailing))
            .clipped().accessibilityHidden(true).allowsHitTesting(false)
    }
}

struct SidebarBrand: View {
    let palette: AppPalette
    var body: some View {
        if palette.usesBrandUI {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    BrandScriptLabel(category: .ourNotes, size: 29)
                    BrandNoteLines(colors: palette.brand).scaleEffect(0.75).frame(width: 36)
                }
                Text("プレイ記録").font(.caption).foregroundStyle(palette.brand.secondaryText.color)
            }.padding(.horizontal, 18).padding(.top, 22)
                .accessibilityElement(children: .ignore).accessibilityLabel("Our Notes プレイ記録")
        } else if palette.usesLogoMotif {
            ZStack {
                LogoRibbons(palette: palette)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Our Notes").font(.system(size: 27, weight: .semibold, design: .serif)).italic()
                    Text("PLAY ANALYZER").font(.system(size: 8, weight: .semibold)).tracking(2)
                }.foregroundStyle(.white).shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }.frame(height: 115).padding(.horizontal, 12).padding(.top, 12)
                .accessibilityElement(children: .ignore).accessibilityLabel("OUR NOTES プレイ記録")
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text("OUR NOTES").font(.system(size: 12, weight: .bold, design: .rounded)).tracking(2).foregroundStyle(palette.accent)
                Text("プレイ記録").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.top, 22)
        }
    }
}
