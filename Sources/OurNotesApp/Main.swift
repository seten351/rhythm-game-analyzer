import AppKit
import SwiftUI
import ResultCore

@main enum Launcher {
    @MainActor static var verificationModel: AppModel?
    @MainActor static var motionVerification: BrandMotionVerification?
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--show-motion-verification") || Bundle.main.bundleIdentifier?.hasSuffix(".home.motion.verification") == true {
            motionVerification = BrandMotionVerification(persistentArtwork: Bundle.main.bundleIdentifier?.hasSuffix(".home.motion.verification") == true)
            verificationModel = motionVerification?.model
        }
        if verificationModel == nil, CommandLine.arguments.contains("--show-home-verification") || (Bundle.main.bundleIdentifier?.contains(".home.") == true && Bundle.main.bundleIdentifier?.hasSuffix(".verification") == true) {
            verificationModel = HomeVerification.previewModel(empty: CommandLine.arguments.contains("--home-empty") || Bundle.main.bundleIdentifier?.contains(".home.empty.") == true)
        }
        if verificationModel == nil, CommandLine.arguments.contains("--show-library-verification") || Bundle.main.bundleIdentifier?.hasSuffix(".library.verification") == true {
            verificationModel = LibraryVerification.previewModel()
        }
        if CommandLine.arguments.contains("--verify-auto-reimport") {
            exit(await AutomaticImportVerification.verifyReimport() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--verify-auto-import") {
            guard let model = await AutomaticImportVerification.run() else { exit(1) }
            if CommandLine.arguments.contains("--show-auto-import-verification") { verificationModel = model }
            else { return }
        }
        if verificationModel == nil, Bundle.main.bundleIdentifier?.hasSuffix(".verification") == true {
            verificationModel = AppModel(inMemory: true)
            verificationModel?.notice = "検証用の一時データです。通常の保存データは変更していません。"
        }
        if CommandLine.arguments.contains("--verify-analysis-export") {
            guard let model = await AnalysisExportVerification.run() else { exit(1) }
            if CommandLine.arguments.contains("--show-export-verification") { verificationModel = model }
            else { return }
        }
        if CommandLine.arguments.contains("--verify-afm") {
            if !(await AFMVerification.run()) { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--show-afm-verification") { verificationModel = AFMVerification.previewModel() }
        if CommandLine.arguments.contains("--show-timing-verification") { verificationModel = TimingVerification.previewModel() }
        if CommandLine.arguments.contains("--verify-workflow") {
            guard let model = await WorkflowVerification.run() else { exit(1) }
            if CommandLine.arguments.contains("--show-verification") { verificationModel = model }
            else { return }
        }
        if CommandLine.arguments.contains("--verify-images") { verifyImages(); return }
        if CommandLine.arguments.contains("--verify-storage") {
            do {
                let repository = try LocalRepository(inMemory: true)
                var state = AppState(); state.songs.append(Song(gameID: "our-notes", masterTitle: "ローカル保存検証"))
                try repository.save(state)
                guard try repository.load() == state else { throw CoreError.invalid("保存結果が一致しません。") }
                print("SwiftData local round-trip: PASS (in-memory, CloudKit disabled)")
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        OurNotesApplication.main()
    }
    static func verifyImages() {
        do {
            let resources = Bundle.module.resourceURL!.appendingPathComponent("Resources")
            let preset = try JSONDecoder().decode(GamePreset.self, from: Data(contentsOf: resources.appendingPathComponent("our-notes-v1.json")))
            let catalog = try JSONDecoder().decode(CatalogDocument.self, from: Data(contentsOf: resources.appendingPathComponent("our-notes-catalog.json")))
            guard let index = CommandLine.arguments.firstIndex(of: "--verify-images") else { return }
            let names = catalog.songs.flatMap { [$0.title] + $0.aliases }
            var outputs: [[String: Any]] = []
            for path in CommandLine.arguments.dropFirst(index + 1).filter({ !$0.hasPrefix("--") }) {
                let result = try autoreleasepool { try ImageAnalyzer.analyze(data: Data(contentsOf: URL(fileURLWithPath: path)), preset: preset, knownTitles: names) }
                var row: [String: Any] = ["file": URL(fileURLWithPath: path).lastPathComponent]
                if let draft = result.result {
                    row["title"] = draft.title; row["difficulty"] = draft.difficulty; row["level"] = draft.level ?? -1; row["score"] = draft.score ?? -1; row["combo"] = draft.combo ?? -1; row["achievement"] = draft.achievement.rawValue; row["kind"] = draft.kind; row["issues"] = draft.issues
                    row["judgments"] = Dictionary(uniqueKeysWithValues: draft.judgments.map { key, value in (key.rawValue, ["total": value.total as Any? ?? NSNull(), "fast": value.fast as Any? ?? NSNull(), "slow": value.slow as Any? ?? NSNull()]) })
                    if CommandLine.arguments.contains("--include-ocr-evidence") {
                        row["evidence"] = RecognitionEvidence.fields(draft: draft, evidence: result.evidence).map { field in
                            ["field": field.field.rawValue, "candidates": field.candidates.map { ["value": $0.value, "confidence": $0.confidence, "route": $0.route] as [String: Any] }] as [String: Any]
                        }
                    }
                }
                if let settings = result.settings { row["settings"] = ["noteSpeed": decimalString(settings.noteSpeed), "noteTiming": decimalString(settings.noteTiming), "chartPosition": decimalString(settings.chartPosition), "mirror": settings.mirror == true ? "ON" : "OFF"] }
                outputs.append(row)
            }
            let json = try JSONSerialization.data(withJSONObject: outputs, options: [.prettyPrinted, .sortedKeys]); print(String(decoding: json, as: UTF8.self))
        } catch { fputs("検証エラー: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}

struct OurNotesApplication: App {
    @State private var model = Launcher.verificationModel ?? AppModel()
    @AppStorage(AppAppearance.preferenceKey) private var appearance = AppAppearance.system
    @FocusedValue(\.playDetailPresented) private var playDetailPresented
    var body: some Scene {
        WindowGroup("Our Notes Analyzer") {
            Group {
                if let verification = Launcher.motionVerification { BrandMotionVerificationRoot(verification: verification) }
                else { RootView(model: model) }
            }.frame(minWidth: 1100, minHeight: 740)
                .onAppear { applyAppearance() }
                .onChange(of: appearance) { _, _ in applyAppearance() }
        }
            .defaultSize(width: 1280, height: 860)
            .commands {
                CommandGroup(after: .newItem) { Button("スクショを取り込む…") { model.chooseImages() }.keyboardShortcut("i").disabled(model.importing || !model.pending.isEmpty || playDetailPresented == true) }
            }
    }

    private func applyAppearance() {
        // Reset AppKit's override explicitly: clearing preferredColorScheme
        // can leave the previous appearance on an existing macOS window.
        // The verification suffix simulates a light system only while following
        // the system; an explicit user choice always wins.
        let mode = appearance == .system && Bundle.main.bundleIdentifier?.hasSuffix(".home.light.verification") == true ? AppAppearance.light : appearance
        NSApplication.shared.appearance = mode.nativeAppearance
    }
}
