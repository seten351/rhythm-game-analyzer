import SwiftUI

struct AppearanceSettings: View {
    @AppStorage(AppTheme.preferenceKey) private var theme = AppTheme.system
    @AppStorage(AppAppearance.preferenceKey) private var appearance = AppAppearance.system
    @Environment(\.appPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("アプリの配色", systemImage: "paintpalette").font(.title2.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 12)], spacing: 12) {
                ForEach(AppTheme.allCases) { value in themeOption(value) }
            }.frame(maxWidth: 930, alignment: .leading)
            Text(theme.summary).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Text("表示モード").font(.callout.weight(.medium))
                Picker("表示モード", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { value in Text(value.title).tag(value) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 390)
                    .accessibilityIdentifier("settings.appearanceMode")
            }
            Text("配色と表示モードは別々に選べます。選択は次回起動時も保持します。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func themeOption(_ value: AppTheme) -> some View {
        let preview = AppPalette(theme: value, isDark: palette.isDark)
        return Button { theme = value } label: {
            VStack(alignment: .leading, spacing: 10) {
                ThemeSample(palette: preview).frame(height: 72)
                HStack(spacing: 5) {
                    Text(value.title).font(.callout.weight(.medium)).lineLimit(2)
                        .frame(height: 34, alignment: .topLeading)
                    Spacer(minLength: 0)
                    Image(systemName: theme == value ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(theme == value ? palette.accent : Color.secondary.opacity(0.4))
                }
            }.padding(12).background(palette.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(theme == value ? palette.accent : palette.border, lineWidth: theme == value ? 2 : 1) }
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel(value.title)
            .accessibilityAddTraits(theme == value ? .isSelected : [])
            .accessibilityIdentifier("settings.theme.\(value.rawValue)")
    }
}

private struct ThemeSample: View {
    let palette: AppPalette
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4).fill(palette.sidebar).frame(width: 30)
                .overlay(alignment: .top) { Capsule().fill(palette.accent).frame(width: 16, height: 3).padding(.top, 10) }
            VStack(alignment: .leading, spacing: 7) {
                Capsule().fill(palette.accent).frame(width: 46, height: 4)
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 4).fill(palette.raised)
                        .overlay(alignment: .bottomLeading) { Capsule().fill(palette.fc).frame(width: 21, height: 4).padding(7) }
                    RoundedRectangle(cornerRadius: 4).fill(palette.raised)
                        .overlay(alignment: .bottomLeading) { Capsule().fill(palette.ap).frame(width: 21, height: 4).padding(7) }
                }
            }.padding(.vertical, 7)
        }.padding(8).background(palette.background)
            .overlay(alignment: .topTrailing) {
                if palette.usesBrandUI {
                    BrandNoteLines(colors: palette.brand).padding(.trailing, 5)
                } else if palette.usesLogoMotif { LogoRibbons(palette: palette).frame(width: 80, height: 45).opacity(0.6) }
            }.clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(palette.border.opacity(0.7)) }
            .accessibilityHidden(true)
    }
}
