import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import ResultCore
import Darwin

/// Catalog identity, independent of titles, chart IDs and locally allocated UUIDs.
struct ArtworkKey: Codable, Hashable, Sendable {
    let gameID: String
    let sourceID: String
    let externalSongID: String
    var isValid: Bool { [gameID, sourceID, externalSongID].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

struct ArtworkCatalogSnapshot: Sendable {
    let songIDs: Set<UUID>
    let archivedSongIDs: Set<UUID>
    let keysBySong: [UUID: ArtworkKey]
    init(state: AppState) {
        songIDs = Set(state.songs.map(\.id))
        archivedSongIDs = Set(state.songs.filter { $0.availability == .retired }.map(\.id))
        let songs = Dictionary(uniqueKeysWithValues: state.songs.map { ($0.id, $0) })
        let candidates = Dictionary(grouping: state.bindings.filter {
            $0.kind == .song && songs[$0.internalID]?.gameID == $0.gameID
        }, by: \.internalID)
        keysBySong = candidates.compactMapValues { bindings in
            let keys = Set(bindings.map { ArtworkKey(gameID: $0.gameID, sourceID: $0.sourceID, externalSongID: $0.externalID) }.filter(\.isValid))
            return keys.count == 1 ? keys.first : nil
        }
    }
}

struct ArtworkEntry: Codable, Equatable, Sendable {
    let key: ArtworkKey
    let assetID: UUID
    var localSongIDs: [UUID]
}

struct ArtworkRepositorySnapshot: Sendable {
    let entries: [ArtworkEntry]
    let statusMessage: String?
}

enum ArtworkWriteCheckpoint: Sendable { case imageStaged, imageFinalized, indexStaged }

private struct ArtworkIndex: Codable, Sendable {
    var version = 1
    var entries: [ArtworkEntry] = []
}

/// One serialized writer owns the index and immutable image files. The index
/// replacement is the commit point; no old asset is collected before that point.
actor ArtworkRepository {
    let directory: URL?
    private let trash: @Sendable (URL) throws -> Void
    private let failure: @Sendable (ArtworkWriteCheckpoint) throws -> Void
    private var index = ArtworkIndex()
    private var loaded = false
    private var catalog: ArtworkCatalogSnapshot?
    private var memoryImages: [UUID: Data] = [:]
    private var statusMessage: String?

    init(directory: URL?, trash: @escaping @Sendable (URL) throws -> Void = { url in
        _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }, failure: @escaping @Sendable (ArtworkWriteCheckpoint) throws -> Void = { _ in }) {
        self.directory = directory; self.trash = trash; self.failure = failure
    }

    func reconcile(with snapshot: ArtworkCatalogSnapshot) throws -> ArtworkRepositorySnapshot {
        try loadIfNeeded()
        catalog = snapshot
        var next = index
        next.entries = index.entries.compactMap { entry in
            var entry = entry
            let retained = entry.localSongIDs.filter { id in
                snapshot.songIDs.contains(id) && (snapshot.keysBySong[id] == nil || snapshot.keysBySong[id] == entry.key)
            }
            let current = snapshot.keysBySong.filter { $0.value == entry.key }.map(\.key)
            entry.localSongIDs = Array(Set(retained + current)).sorted { $0.uuidString < $1.uuidString }
            guard !entry.localSongIDs.isEmpty, assetIsValid(entry.assetID) else { return nil }
            return entry
        }
        if next.entries != index.entries { try commit(next) }
        else { checkpointAndCollect() }
        return result()
    }

    func put(png: Data, for key: ArtworkKey, localSongID: UUID) throws -> ArtworkRepositorySnapshot {
        try loadIfNeeded()
        guard key.isValid, let catalog, catalog.songIDs.contains(localSongID),
              catalog.keysBySong[localSongID] == key || (catalog.archivedSongIDs.contains(localSongID) && index.entries.contains(where: { $0.key == key && $0.localSongIDs.contains(localSongID) })) else {
            throw CoreError.invalid("画像の登録先を確認できません。楽曲を選び直してください。")
        }
        try ArtworkImageCodec.validateNormalizedPNG(png)
        let id = UUID()
        var finalized: URL?
        var temporary: URL?
        do {
            if let directory {
                try prepareDirectory(directory)
                let images = directory.appendingPathComponent("images", isDirectory: true)
                let staged = images.appendingPathComponent(".image-\(id.uuidString).tmp")
                temporary = staged
                try writeAndSynchronize(png, to: staged)
                try ArtworkImageCodec.validateNormalizedPNG(Data(contentsOf: staged))
                try failure(.imageStaged)
                let target = assetURL(id, in: directory)
                try FileManager.default.moveItem(at: staged, to: target)
                temporary = nil; finalized = target
                try failure(.imageFinalized)
            } else { memoryImages[id] = png }
            var next = index
            let aliases = next.entries.first { $0.key == key }?.localSongIDs ?? []
            next.entries.removeAll { $0.key == key }
            next.entries.append(.init(key: key, assetID: id, localSongIDs: Array(Set(aliases + [localSongID])).sorted { $0.uuidString < $1.uuidString }))
            try commit(next)
            return result()
        } catch {
            memoryImages[id] = nil
            // These files were never referenced by a committed index. Cleanup
            // can fail safely: the next startup collects them by managed name.
            for url in [temporary, finalized].compactMap({ $0 }) { try? trash(url) }
            throw error
        }
    }

    func remove(for key: ArtworkKey) throws -> ArtworkRepositorySnapshot {
        try loadIfNeeded()
        var next = index; next.entries.removeAll { $0.key == key }
        if next.entries != index.entries { try commit(next) } else { checkpointAndCollect() }
        return result()
    }

    func data(for key: ArtworkKey) throws -> Data? {
        try loadIfNeeded()
        guard let entry = index.entries.first(where: { $0.key == key }) else { return nil }
        if let directory {
            let url = assetURL(entry.assetID, in: directory)
            guard isRegularFile(url), let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024 else { return nil }
            let data = try Data(contentsOf: url)
            try ArtworkImageCodec.validateNormalizedPNG(data)
            return data
        }
        return memoryImages[entry.assetID]
    }

    private func result() -> ArtworkRepositorySnapshot { .init(entries: index.entries, statusMessage: statusMessage) }
    private func assetURL(_ id: UUID, in root: URL) -> URL { root.appendingPathComponent("images/\(id.uuidString).png") }
    private func assetIsValid(_ id: UUID) -> Bool {
        guard let directory else { return memoryImages[id] != nil }
        let url = assetURL(id, in: directory)
        guard isRegularFile(url), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 4 * 1024 * 1024, let data = try? Data(contentsOf: url),
              (try? ArtworkImageCodec.validateNormalizedPNG(data)) != nil else { return false }
        return true
    }
    private func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
    private func prepareDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        for url in [directory, directory.appendingPathComponent("images")] {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw CoreError.invalid("画像の保存先が不正です。") }
        }
        try fm.createDirectory(at: directory.appendingPathComponent("images", isDirectory: true), withIntermediateDirectories: true)
    }
    private func readIndex(_ url: URL) throws -> ArtworkIndex {
        guard isRegularFile(url) else { throw CoreError.invalid("画像索引を読めません。") }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024 else { throw CoreError.invalid("画像索引が大きすぎます。") }
        let data = try Data(contentsOf: url)
        guard data.count <= 4 * 1024 * 1024 else { throw CoreError.invalid("画像索引が大きすぎます。") }
        let value = try JSONDecoder().decode(ArtworkIndex.self, from: data)
        guard value.version == 1, value.entries.allSatisfy({ $0.key.isValid && !$0.localSongIDs.isEmpty }),
              Set(value.entries.map(\.key)).count == value.entries.count,
              Set(value.entries.map(\.assetID)).count == value.entries.count else { throw CoreError.invalid("画像索引の対応が不正です。") }
        return value
    }
    private func loadIfNeeded() throws {
        guard !loaded else { return }
        guard let directory else { loaded = true; return }
        try prepareDirectory(directory)
        let primary = directory.appendingPathComponent("index.json")
        let backup = directory.appendingPathComponent("index.backup.json")
        if let value = try? readIndex(primary) { index = value }
        else if let value = try? readIndex(backup) {
            index = value
            try prepareDirectory(directory)
            try atomicIndexWrite(value, at: primary, injectFailure: false)
            statusMessage = "楽曲画像の索引を復旧しました。"
        } else {
            let items = managedFiles()
            if !items.isEmpty {
                // Neither index is trustworthy. Preserve the files in Trash
                // rather than treating an unreadable index as proof of deletion.
                for url in items { try trash(url) }
                statusMessage = "楽曲画像の索引を復旧できなかったため、管理画像と索引をゴミ箱へ移しました。画像を再登録できます。"
            }
            index = ArtworkIndex()
            try atomicIndexWrite(index, at: primary, injectFailure: false)
        }
        loaded = true
    }
    private func writeAndSynchronize(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    private func atomicIndexWrite(_ value: ArtworkIndex, at destination: URL, injectFailure: Bool) throws {
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".index-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try writeAndSynchronize(try encoder.encode(value), to: temp)
        _ = try readIndex(temp)
        if injectFailure { try failure(.indexStaged) }
        // POSIX rename in the same directory is the sole index commit point.
        guard rename(temp.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private func commit(_ next: ArtworkIndex) throws {
        if let directory {
            try prepareDirectory(directory)
            // Leave a valid previous index and its images intact until primary
            // replacement succeeds. A failed replacement changes no references.
            try atomicIndexWrite(index, at: directory.appendingPathComponent("index.backup.json"), injectFailure: false)
            try atomicIndexWrite(next, at: directory.appendingPathComponent("index.json"), injectFailure: true)
        }
        index = next
        checkpointAndCollect()
    }
    private func checkpointAndCollect() {
        guard let directory else {
            let referenced = Set(index.entries.map(\.assetID))
            memoryImages = memoryImages.filter { referenced.contains($0.key) }
            return
        }
        do {
            try prepareDirectory(directory)
            // After a successful commit, advance the recovery checkpoint before
            // collecting old assets. If this fails, both generations stay safe.
            try atomicIndexWrite(index, at: directory.appendingPathComponent("index.backup.json"), injectFailure: false)
            let referenced = Set(index.entries.map { assetURL($0.assetID, in: directory).standardizedFileURL })
            for url in managedFiles() where !["index.json", "index.backup.json"].contains(url.lastPathComponent) && !referenced.contains(url.standardizedFileURL) {
                try trash(url)
            }
        } catch { statusMessage = "楽曲画像の整理を完了できませんでした。次回起動時に再試行します。\n\(error.localizedDescription)" }
    }
    private func managedFiles() -> [URL] {
        guard let directory else { return [] }
        let fm = FileManager.default
        var items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? []
        let images = directory.appendingPathComponent("images")
        if (try? images.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
            items += (try? fm.contentsOfDirectory(at: images, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? []
        }
        return items.filter { url in
            guard isRegularFile(url) else { return false }
            let name = url.lastPathComponent
            if url.deletingLastPathComponent() == directory {
                return name == "index.json" || name == "index.backup.json" || (name.hasPrefix(".index-") && name.hasSuffix(".tmp") && UUID(uuidString: String(name.dropFirst(7).dropLast(4))) != nil)
            }
            return (url.pathExtension == "png" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil) ||
                (name.hasPrefix(".image-") && name.hasSuffix(".tmp") && UUID(uuidString: String(name.dropFirst(7).dropLast(4))) != nil)
        }
    }
}

enum ArtworkImageCodec {
    static func normalizedPNG(from data: Data) throws -> Data {
        guard data.count <= 80 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?, [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier, "public.heif"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20000, height <= 20000 else { throw CoreError.invalid("画像が破損しているか、未対応または大きすぎます（PNG・JPEG・HEIC、80MB・最大辺20000pxまで）。") }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw CoreError.invalid("楽曲画像を読み込めませんでした。") }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else { throw CoreError.invalid("楽曲画像を保存できませんでした。") }
        // Re-encode pixels only: source filenames, EXIF and location aren't copied.
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CoreError.invalid("楽曲画像を保存できませんでした。") }
        return result as Data
    }
    static func validateNormalizedPNG(_ data: Data) throws {
        guard data.count <= 4 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 512, h <= 512, CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw CoreError.invalid("保存された楽曲画像を読めませんでした。") }
    }
}

@MainActor @Observable final class SongArtworkStore {
    private static var persistentStores: [URL: SongArtworkStore] = [:]
    static func persistent(at directory: URL) -> SongArtworkStore {
        let key = directory.standardizedFileURL
        if let existing = persistentStores[key] { return existing }
        let value = SongArtworkStore(directory: key); persistentStores[key] = value; return value
    }
    @ObservationIgnored let repository: ArtworkRepository
    @ObservationIgnored private let cache = NSCache<NSString, NSImage>()
    @ObservationIgnored private let bundled: BundledSongArtwork?
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var acknowledgedStatus: String?
    private var entries: [ArtworkEntry] = []
    private var snapshot = ArtworkCatalogSnapshot(state: AppState())
    private var generation = 0
    private(set) var revision = 0
    private(set) var statusMessage: String?
    private(set) var busySongIDs: Set<UUID> = []

    init(directory: URL? = nil, bundled: BundledSongArtwork? = nil, trash: @escaping @Sendable (URL) throws -> Void = { _ = try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        repository = ArtworkRepository(directory: directory, trash: trash)
        self.bundled = bundled ?? BundledSongArtwork.shared
        cache.totalCostLimit = 32 * 1024 * 1024
    }
    func setCatalog(_ state: AppState) {
        generation += 1; let ticket = generation
        snapshot = ArtworkCatalogSnapshot(state: state)
        let current = snapshot
        let previous = catalogTask
        catalogTask = Task {
            await previous?.value
            do {
                let result = try await repository.reconcile(with: current)
                guard !Task.isCancelled, ticket == generation else { return }
                apply(result)
            } catch { if !Task.isCancelled { statusMessage = "楽曲画像を準備できませんでした。\n\(error.localizedDescription)" } }
        }
    }
    func key(for song: Song) -> ArtworkKey? {
        if let key = snapshot.keysBySong[song.id] { return key }
        guard snapshot.archivedSongIDs.contains(song.id) else { return nil }
        let matches = entries.filter { $0.localSongIDs.contains(song.id) }
        return matches.count == 1 ? matches.first?.key : nil
    }
    func hasArtwork(for song: Song) -> Bool { key(for: song).map { key in entries.contains { $0.key == key } } ?? false }
    func hasBundledArtwork(for song: Song) -> Bool { key(for: song).map { bundled?.entries[$0] != nil } ?? false }
    func acknowledgeStatus() { acknowledgedStatus = statusMessage; statusMessage = nil }
    func image(for song: Song) async -> NSImage? {
        await catalogTask?.value
        guard let key = key(for: song) else { return nil }
        guard let entry = entries.first(where: { $0.key == key }) else { return bundled?.image(for: key) }
        let cacheKey = entry.assetID.uuidString as NSString
        if let image = cache.object(forKey: cacheKey) { return image }
        do {
            let data = try await repository.data(for: key)
            // A replacement may finish while the repository read is suspended.
            // Never publish that stale user image or overwrite a newer cache.
            guard entries.first(where: { $0.key == key })?.assetID == entry.assetID else { return nil }
            guard let data, let image = NSImage(data: data) else { return bundled?.image(for: key) }
            cache.setObject(image, forKey: cacheKey, cost: max(1, Int(image.size.width * image.size.height * 4)))
            return image
        } catch { return bundled?.image(for: key) }
    }
    func register(url: URL, for song: Song) async throws {
        await catalogTask?.value
        guard let key = key(for: song), !busySongIDs.contains(song.id) else { throw CoreError.invalid("この楽曲の画像を登録できません。") }
        busySongIDs.insert(song.id); defer { busySongIDs.remove(song.id) }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let png = try await Task.detached(priority: .userInitiated) {
            guard url.isFileURL else { throw CoreError.invalid("ローカル画像を選択してください。") }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 80 * 1024 * 1024 else { throw CoreError.invalid("80MBを超える画像です。") }
            return try ArtworkImageCodec.normalizedPNG(from: Data(contentsOf: url, options: .mappedIfSafe))
        }.value
        await catalogTask?.value
        guard snapshot.songIDs.contains(song.id), self.key(for: song) == key else { throw CoreError.invalid("画像の登録先が変わりました。楽曲を選び直してください。") }
        let ticket = generation
        let result = try await repository.put(png: png, for: key, localSongID: song.id)
        if ticket == generation { apply(result) }
        else { await catalogTask?.value }
    }
    func remove(for song: Song) async throws {
        await catalogTask?.value
        guard let key = key(for: song), !busySongIDs.contains(song.id) else { return }
        busySongIDs.insert(song.id); defer { busySongIDs.remove(song.id) }
        let ticket = generation
        let result = try await repository.remove(for: key)
        if ticket == generation { apply(result) }
        else { await catalogTask?.value }
    }
    private func apply(_ result: ArtworkRepositorySnapshot) {
        entries = result.entries; statusMessage = result.statusMessage == acknowledgedStatus ? nil : result.statusMessage
        cache.removeAllObjects(); revision += 1
    }
}

private struct SongArtworkEnvironmentKey: EnvironmentKey { static let defaultValue: SongArtworkStore? = nil }
extension EnvironmentValues {
    var songArtworkStore: SongArtworkStore? {
        get { self[SongArtworkEnvironmentKey.self] }
        set { self[SongArtworkEnvironmentKey.self] = newValue }
    }
}

struct SongArtworkView: View {
    let song: Song
    let size: CGFloat
    @Environment(\.songArtworkStore) private var store
    @Environment(\.appPalette) private var palette
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            palette.raised
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { BrandNoteLines(colors: palette.brand, role: .signature).scaleEffect(size / 80) }
        }.frame(width: size, height: size).clipped()
            .clipShape(RoundedRectangle(cornerRadius: size >= 64 ? 9 : 6))
            .overlay { RoundedRectangle(cornerRadius: size >= 64 ? 9 : 6).stroke(palette.border) }
            .accessibilityHidden(true).allowsHitTesting(false)
            .task(id: "\(song.id)-\(store?.revision ?? 0)") {
                image = nil
                let next = await store?.image(for: song)
                if !Task.isCancelled { image = next }
            }
    }
}

struct SongArtworkMenu: View {
    @Bindable var model: AppModel
    let song: Song
    var body: some View {
        Menu {
            Button(model.artwork.hasArtwork(for: song) ? "画像を変更…" : "画像を選ぶ…") { model.chooseArtwork(for: song) }
                .disabled(model.artwork.key(for: song) == nil)
            if model.artwork.hasArtwork(for: song) {
                Button(model.artwork.hasBundledArtwork(for: song) ? "既定の画像に戻す" : "画像を削除", role: .destructive) { Task { do { try await model.artwork.remove(for: song) } catch { model.errorMessage = error.localizedDescription } } }
            }
        } label: { Label("楽曲画像", systemImage: "photo") }
            .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
            .disabled(model.artwork.busySongIDs.contains(song.id))
            .accessibilityIdentifier("artwork.menu")
            .help(model.artwork.key(for: song) == nil ? "現行マスターの楽曲に画像を登録できます。" : "この曲のすべての譜面で画像を共有します。")
    }
}

extension AppModel {
    func chooseArtwork(for song: Song) {
        guard artwork.key(for: song) != nil else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "この曲の画像を選択します。元画像は変更せず、表示用コピーをMac内へ保存します。"
        present(panel) { [weak self] in
            guard let self, let url = panel.url else { return }
            Task { do { try await self.artwork.register(url: url, for: song) } catch { self.errorMessage = error.localizedDescription } }
        }
    }
}
