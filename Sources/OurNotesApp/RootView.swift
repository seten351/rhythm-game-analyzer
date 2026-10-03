import SwiftUI
import ResultCore

enum Page: String, CaseIterable, Identifiable {
    case home, library, imports, analysis, catalog, settings
    var id: String { rawValue }
    var title: String { switch self { case .home: return "成果ホーム"; case .library: return "楽曲・譜面"; case .imports: return "スクショ取込"; case .analysis: return "傾向分析"; case .catalog: return "楽曲マスタ"; case .settings: return "環境・プリセット" } }
    var icon: String { switch self { case .home: return "house"; case .library: return "music.note.list"; case .imports: return "tray.and.arrow.down"; case .analysis: return "chart.bar.xaxis"; case .catalog: return "square.stack.3d.up"; case .settings: return "slider.horizontal.3" } }
    var brandCategory: BrandCategory { switch self { case .home: return .ourNotes; case .library, .catalog: return .library; case .imports: return .imports; case .analysis: return .analysis; case .settings: return .settings } }
    var subtitle: String { switch self { case .home: return "FC・AP・コンボで、プレイの成果を確認"; case .library: return "未プレイからAPまで、譜面ごとの記録を確認"; case .imports: return "画像を追加すると、照合・確認を通過した結果を自動登録"; case .analysis: return "判定の偏りと、これまでの達成を確認"; case .catalog: return "Webで照合した全曲マスターを自動適用"; case .settings: return "プレイ環境・読取設定・アプリの配色" } }
}

struct RootView: View {
    @Bindable var model: AppModel
    @State private var page: Page? = .home
    @AppStorage(AppTheme.preferenceKey) private var theme = AppTheme.system
    @Environment(\.colorScheme) private var colorScheme
    @State private var showTimingAnalysis = false
    @State private var libraryBrowser = LibraryBrowserState()
    var body: some View {
        let palette = AppPalette(theme: theme, isDark: colorScheme == .dark)
        Group {
            if let startup = model.startupError {
                ContentUnavailableView { Label("起動できませんでした", systemImage: "externaldrive.badge.exclamationmark") } description: { Text(startup).textSelection(.enabled) }
            } else {
                NavigationSplitView {
                    VStack(alignment: .leading, spacing: 20) {
                        SidebarBrand(palette: palette)
                        if palette.usesBrandUI { BrandSidebarNavigation(selection: $page, pendingCount: model.pending.count) }
                        else {
                        List(selection: $page) {
                            ForEach([Page.home, .library, .imports, .analysis]) { item in
                                HStack { Label(item.title, systemImage: item.icon); Spacer(); if item == .imports && !model.pending.isEmpty { Text("\(model.pending.count)").font(.caption).foregroundStyle(.orange) } }.padding(.vertical, 4).tag(item)
                            }
                            Section("管理") { ForEach([Page.catalog, .settings]) { item in Label(item.title, systemImage: item.icon).padding(.vertical, 3).tag(item) } }
                        }.scrollContentBackground(.hidden)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Mac内で完結", systemImage: "checkmark.shield").foregroundStyle(palette.accent)
                            Text("画像を恒久保存しません").foregroundStyle(.secondary)
                            if !model.pending.isEmpty { Text("\(model.pending.count)件の確認待ち").foregroundStyle(.orange) }
                        }.font(.caption).padding(18)
                    }.background(palette.sidebar).navigationSplitViewColumnWidth(min: 195, ideal: 210)
                } detail: {
                    let selected = page ?? .home
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            if palette.usesBrandUI { BrandPageHeader(page: selected) }
                            else { VStack(alignment: .leading, spacing: 5) { Text(selected.title).font(.title2.weight(.semibold)); Text(selected.subtitle).font(.caption).foregroundStyle(.secondary) } }
                            Spacer()
                            if selected == .analysis {
                                Menu { Button("分析用JSONを出力…") { model.chooseAnalysisExport() } } label: { Label("書き出す", systemImage: "square.and.arrow.up") }.menuStyle(.borderlessButton).fixedSize().disabled(model.importing)
                            }
                            if selected != .imports { Button { page = .imports; if model.pending.isEmpty { model.chooseImages() } } label: { Label(model.pending.isEmpty ? "スクショ取込" : "取込結果を確認", systemImage: model.pending.isEmpty ? "plus" : "tray") }.buttonStyle(.borderedProminent).disabled(model.importing) }
                        }.padding(.horizontal, 28).padding(.vertical, 18)
                        if palette.usesLogoMotif {
                            Rectangle().fill(LinearGradient(colors: palette.ribbonColors, startPoint: .leading, endPoint: .trailing)).frame(height: 2)
                        } else { Divider() }
                        switch selected {
                        case .home: HomeView(model: model, onImport: {
                            page = .imports
                            if model.importCount == 0 && model.pending.isEmpty { model.chooseImages() }
                        }, onShowLibrary: { page = .library }, onShowChart: { record in
                            libraryBrowser.resetFilters()
                            libraryBrowser.includeArchived = record.song.availability == .retired || record.chart.availability == .retired
                            libraryBrowser.selectedID = record.chart.id
                            libraryBrowser.detailTab = .history
                            page = .library
                        })
                        case .library: LibraryView(model: model, browser: $libraryBrowser, onShowTimingAnalysis: { showTimingAnalysis = true; page = .analysis })
                        case .imports: ImportView(model: model)
                        case .analysis: AnalysisView(model: model, showTimingOnAppear: showTimingAnalysis)
                        case .catalog: CatalogView(model: model)
                        case .settings: SettingsView(model: model)
                        }
                    }.background(palette.background)
                }
            }
        }
        .onChange(of: page) { _, selected in if selected != .analysis { showTimingAnalysis = false } }
        .alert("処理できませんでした", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("閉じる") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: Binding(get: { model.pendingPreset != nil }, set: { if !$0 { model.pendingPreset = nil } })) {
            if let preset = model.pendingPreset { VStack(alignment: .leading, spacing: 18) {
                Text("解析プリセット更新").font(.title2.bold()); Text("\(preset.name) · v\(preset.version)")
                Text(preset.timing == nil ? "タイミング仕様は未設定です。" : "数値提案用の仕様が含まれます。単位・増減方向を確認してください。")
                HStack { Button("取消") { model.pendingPreset = nil }; Spacer(); Button("確認して適用") { model.applyPreset() }.buttonStyle(.borderedProminent) }
            }.padding(28).frame(width: 550) }
        }
        .onDisappear { model.finishSession() }
        .environment(\.appPalette, palette)
        .tint(palette.accent)
        .background(palette.background)
    }

}

struct MetricCard: View {
    @Environment(\.appPalette) private var palette
    var title: String
    var value: String
    var detail: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            if !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(palette.surface, in: RoundedRectangle(cornerRadius: 14)).overlay { RoundedRectangle(cornerRadius: 14).stroke(palette.border) }
    }
}
func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0 * 100) } ?? "—" }
func number(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "—" }
func playDateLabel(_ play: PlayRecord) -> String { "\(play.playedAt == nil ? "登録" : "プレイ") \(play.orderDate.formatted(date: .abbreviated, time: .shortened))" }
