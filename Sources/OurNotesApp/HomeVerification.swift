import Foundation
import ResultCore
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor enum HomeVerification {
    static func previewModel(empty: Bool = false, artwork: SongArtworkStore? = nil) -> AppModel {
        if empty { return AppModel(inMemory: true, artwork: artwork) }
        let model = LibraryVerification.previewModel(artwork: artwork)
        guard model.startupError == nil else { return model }
        var state = model.state
        let featuredTitles = Set(["夢我夢中", "青春コンプレックス", "六兆年と一夜物語"])
        let latest = Dictionary(grouping: state.plays, by: \.chartID).compactMapValues { $0.max { $0.importedAt < $1.importedAt }?.id }
        let imported = Date()
        for index in state.plays.indices {
            let play = state.plays[index]
            if play.achievement == .unknown { state.plays[index].combo = nil }
            guard featuredTitles.contains(play.titleAtPlay) else { continue }
            if latest[play.chartID] == play.id {
                state.plays[index].importedAt = imported
                if play.titleAtPlay == "夢我夢中" { state.plays[index].combo = 850 }
                model.lastBatchPlayIDs.append(play.id)
                model.importReceipts.append(.init(title: play.titleAtPlay, status: .automatic, playID: play.id, message: "成果ホーム検証用の人工記録です。", imageCount: 2))
            } else { state.plays[index].combo = 600 }
        }
        do { try model.commit(state) } catch { model.startupError = error.localizedDescription }
        model.importCount = 6; model.processed = 6
        model.notice = "成果ホーム検証用の人工記録です。通常DBは使用していません。"
        return model
    }
}

/// Interactive, memory-only fixture for adding all three achievement kinds.
/// This control strip is available only through the motion-verification entry point.
@MainActor @Observable final class BrandMotionVerification {
    let model: AppModel
    private let incoming: [PlayRecord]
    var inserted = false
    var reduceMotion = false
    var preparingArtwork = false

    init(persistentArtwork: Bool = false) {
        let artwork = persistentArtwork ? SongArtworkStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OurNotesAnalyzer/VerificationArtwork", isDirectory: true)) : nil
        model = HomeVerification.previewModel(artwork: artwork)
        let ids = Set(model.lastBatchPlayIDs)
        incoming = model.state.plays.filter { ids.contains($0.id) }
        var baseline = model.state
        baseline.plays.removeAll { ids.contains($0.id) }
        do { try model.commit(baseline) } catch { model.startupError = error.localizedDescription }
        model.lastBatchPlayIDs = []
        model.importReceipts = []
        model.importCount = 0
    }

    func addAchievements() {
        guard !inserted else { return }
        var next = model.state
        next.plays += incoming
        do {
            try model.commit(next)
            model.lastBatchPlayIDs = incoming.map(\.id)
            model.importCount = incoming.count
            model.processed = incoming.count
            inserted = true
        } catch { model.errorMessage = error.localizedDescription }
    }

    func clearRecords() {
        var next = model.state; next.plays = []
        do {
            try model.commit(next); inserted = false; model.lastBatchPlayIDs = []; model.importCount = 0
            model.brandAchievementMotion = BrandAchievementMotionLedger()
        } catch { model.errorMessage = error.localizedDescription }
    }

    func updateNumber() {
        guard let id = incoming.first(where: { $0.titleAtPlay == "夢我夢中" })?.id,
              let index = model.state.plays.firstIndex(where: { $0.id == id }) else { return }
        var next = model.state
        next.plays[index].combo = (next.plays[index].combo ?? 0) + 10
        next.plays[index].score += 100
        do { try model.commit(next) } catch { model.errorMessage = error.localizedDescription }
    }

    func prepareArtwork(replacement: Bool = false) async {
        guard !preparingArtwork else { return }
        preparingArtwork = true; defer { preparingArtwork = false }
        do {
            for (index, title) in ["夢我夢中", "青春コンプレックス", "六兆年と一夜物語"].enumerated() {
                guard let song = model.state.songs.first(where: { $0.title == title }) else { continue }
                // Entirely synthetic pixels: no third-party song jacket is used.
                let data = try Self.syntheticArtwork(index: index + (replacement ? 3 : 0))
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("our-notes-artwork-\(UUID().uuidString).png")
                defer { try? FileManager.default.removeItem(at: url) }
                try data.write(to: url)
                try await model.artwork.register(url: url, for: song)
            }
        } catch { model.errorMessage = error.localizedDescription }
    }

    func removeArtwork() async {
        for title in ["夢我夢中", "青春コンプレックス", "六兆年と一夜物語"] {
            if let song = model.state.songs.first(where: { $0.title == title }) {
                do { try await model.artwork.remove(for: song) } catch { model.errorMessage = error.localizedDescription }
            }
        }
    }

    private static func syntheticArtwork(index: Int) throws -> Data {
        guard let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CoreError.invalid("検証画像を生成できません。") }
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.28, 0.52, 0.66), (0.62, 0.42, 0.62), (0.40, 0.55, 0.65), (0.72, 0.52, 0.32), (0.30, 0.62, 0.48), (0.55, 0.43, 0.73)]
        let color = colors[index % colors.count]
        context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.85)); context.setLineWidth(5)
        for offset in [0, 18, 36] { context.move(to: CGPoint(x: 22 + offset, y: 25)); context.addLine(to: CGPoint(x: 71 + offset, y: 103)); context.strokePath() }
        guard let image = context.makeImage() else { throw CoreError.invalid("検証画像を生成できません。") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CoreError.invalid("検証画像を生成できません。") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CoreError.invalid("検証画像を生成できません。") }
        return data as Data
    }
}

struct BrandMotionVerificationRoot: View {
    @Bindable var verification: BrandMotionVerification
    var body: some View {
        RootView(model: verification.model)
            .environment(\.brandMotionVerificationReduceMotion, verification.reduceMotion)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("検証 · 人工履歴／メモリDB／自作画像").font(.caption)
                    Button("初AP・初FC・コンボ更新を追加") { verification.addAchievements() }
                        .disabled(verification.inserted)
                    Toggle("モーションを減らす（検証）", isOn: $verification.reduceMotion)
                    Spacer()
                }
                HStack(spacing: 12) {
                    Button("記録ゼロへ") { verification.clearRecords() }
                    Button("数字を更新") { verification.updateNumber() }.disabled(!verification.inserted)
                    Button("自作画像を登録") { Task { await verification.prepareArtwork() } }
                    Button("自作画像へ置換") { Task { await verification.prepareArtwork(replacement: true) } }
                    Button("検証画像を削除") { Task { await verification.removeArtwork() } }
                }.disabled(verification.preparingArtwork)
                }.padding(10).background(.bar)
            }
    }
}
