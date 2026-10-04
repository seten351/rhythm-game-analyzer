import AppKit
import CryptoKit
import Foundation
import ResultCore

/// Read-only defaults are separate from the user's transactional artwork store.
/// A catalog binding, never a title or local UUID, selects the jacket.
@MainActor final class BundledSongArtwork {
    struct Entry: Codable, Equatable {
        let key: ArtworkKey
        let fileName: String
        let sha256: String
        let title: String
        let sourceURL: String
    }
    struct Manifest: Codable {
        let version: Int
        let entries: [Entry]
    }
    static let shared: BundledSongArtwork? = Bundle.module.url(forResource: "Artwork", withExtension: nil, subdirectory: "Resources")
        .flatMap { try? BundledSongArtwork(directory: $0) }

    let entries: [ArtworkKey: Entry]
    private let directory: URL
    private let cache = NSCache<NSString, NSImage>()

    init(directory: URL) throws {
        self.directory = directory
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        guard data.count <= 512 * 1024 else { throw CoreError.invalid("同梱画像の索引が大きすぎます。") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.version == 1,
              manifest.entries.allSatisfy({ entry in
                  entry.key.isValid && entry.fileName.range(of: "^[a-f0-9]{64}\\.png$", options: .regularExpression) != nil &&
                  entry.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
              }),
              Set(manifest.entries.map(\.key)).count == manifest.entries.count,
              Set(manifest.entries.map(\.fileName)).count == manifest.entries.count else {
            throw CoreError.invalid("同梱画像の対応が不正です。")
        }
        entries = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.key, $0) })
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func image(for key: ArtworkKey) -> NSImage? {
        guard let entry = entries[key] else { return nil }
        let cacheKey = (entry.fileName + entry.sha256) as NSString
        if let image = cache.object(forKey: cacheKey) { return image }
        let url = directory.appendingPathComponent(entry.fileName)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: url),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == entry.sha256,
              (try? ArtworkImageCodec.validateNormalizedPNG(data)) != nil, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: cacheKey, cost: max(1, Int(image.size.width * image.size.height * 4)))
        return image
    }
}
