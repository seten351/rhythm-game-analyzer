import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import OurNotesApp
@testable import ResultCore

final class BundledSongArtworkTests: XCTestCase {
    private let gameID = OurNotesCatalog.gameID
    private let sourceID = OurNotesCatalog.sourceID

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundled-artwork-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func localTrash(in root: URL) -> @Sendable (URL) throws -> Void {
        { url in
            let directory = root.appendingPathComponent("test-trash", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        }
    }

    private func png(color: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func key(_ externalID: String = "song-artwork-test",
                     gameID: String? = nil,
                     sourceID: String? = nil) -> ArtworkKey {
        ArtworkKey(gameID: gameID ?? self.gameID,
                   sourceID: sourceID ?? self.sourceID,
                   externalSongID: externalID)
    }

    private func catalogState(songID: UUID, title: String = "テスト曲",
                              externalID: String = "song-artwork-test",
                              gameID: String? = nil,
                              sourceID: String? = nil) -> AppState {
        var state = AppState()
        state.songs = [Song(id: songID, gameID: gameID ?? self.gameID, masterTitle: title)]
        state.bindings = [CatalogBinding(gameID: gameID ?? self.gameID,
                                         sourceID: sourceID ?? self.sourceID,
                                         kind: .song, externalID: externalID, internalID: songID)]
        return state
    }

    @MainActor private func bundledArtwork(in directory: URL, key: ArtworkKey, imageData: Data,
                                checksum: String? = nil) throws -> BundledSongArtwork {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = digest(imageData) + ".png"
        try imageData.write(to: directory.appendingPathComponent(fileName))
        let entry = BundledSongArtwork.Entry(key: key, fileName: fileName,
                                             sha256: checksum ?? digest(imageData),
                                             title: "Fixture", sourceURL: "https://example.invalid/artwork")
        let manifest = BundledSongArtwork.Manifest(version: 1, entries: [entry])
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        return try BundledSongArtwork(directory: directory)
    }

    @MainActor func testEveryBundledEntryDecodesAndMatchesCatalogSongKeysOneToOne() throws {
        let artwork = try XCTUnwrap(BundledSongArtwork.shared, "Bundled artwork manifest should load")
        let model = AppModel(inMemory: true, loadBundledCatalog: false)
        let catalogData = try Data(contentsOf: model.resourceDirectory.appendingPathComponent("our-notes-catalog.json"))
        let catalog = try JSONDecoder().decode(CatalogDocument.self, from: catalogData)
        let expectedKeys = Set(catalog.songs.map {
            ArtworkKey(gameID: OurNotesCatalog.gameID, sourceID: OurNotesCatalog.sourceID, externalSongID: $0.id)
        })

        XCTAssertEqual(Set(artwork.entries.keys), expectedKeys,
                       "Each catalog song should have exactly one bundled artwork key")
        XCTAssertEqual(artwork.entries.count, expectedKeys.count)
        for (key, entry) in artwork.entries {
            let image = try XCTUnwrap(artwork.image(for: key), "Bundled image failed to decode: \(entry.fileName)")
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
        }
    }

    @MainActor
    func testManualArtworkOverridesBundleReplacementInvalidatesCacheAndRemovalRestoresBundle() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artworkKey = key()
        let bundledPNG = try png(color: .systemBlue)
        let bundled = try bundledArtwork(in: directory.appendingPathComponent("bundle", isDirectory: true),
                                         key: artworkKey, imageData: bundledPNG)
        let store = SongArtworkStore(directory: directory.appendingPathComponent("managed", isDirectory: true), bundled: bundled, trash: localTrash(in: directory))
        let songID = UUID()
        let song = Song(id: songID, gameID: gameID, masterTitle: "テスト曲")
        store.setCatalog(catalogState(songID: songID))

        let loadedDefault = await store.image(for: song)
        let defaultImage = try XCTUnwrap(loadedDefault)
        let input = directory.appendingPathComponent("manual.png")
        try png(color: .systemRed).write(to: input)
        try await store.register(url: input, for: song)
        let loadedManual = await store.image(for: song)
        let manualImage = try XCTUnwrap(loadedManual)
        XCTAssertFalse(defaultImage === manualImage, "A registered manual image should override the bundled image")

        try png(color: .systemGreen).write(to: input)
        try await store.register(url: input, for: song)
        let loadedReplacement = await store.image(for: song)
        let replacementImage = try XCTUnwrap(loadedReplacement)
        XCTAssertFalse(manualImage === replacementImage, "Replacing manual artwork should invalidate the displayed image cache")

        try await store.remove(for: song)
        let loadedRestored = await store.image(for: song)
        let restoredImage = try XCTUnwrap(loadedRestored)
        XCTAssertTrue(defaultImage === restoredImage, "Removing manual artwork should reveal the cached bundled default")
    }

    @MainActor
    func testBundledIdentitySurvivesSongUUIDAndTitleChangesButRequiresSameGameAndSource() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artworkKey = key()
        let bundled = try bundledArtwork(in: directory.appendingPathComponent("bundle", isDirectory: true),
                                         key: artworkKey, imageData: png(color: .systemBlue))
        let store = SongArtworkStore(directory: directory.appendingPathComponent("managed", isDirectory: true), bundled: bundled, trash: localTrash(in: directory))
        let oldSongID = UUID()
        let oldSong = Song(id: oldSongID, gameID: gameID, masterTitle: "旧タイトル")
        store.setCatalog(catalogState(songID: oldSongID, title: "旧タイトル"))
        let loadedOriginal = await store.image(for: oldSong)
        let original = try XCTUnwrap(loadedOriginal)

        let remappedSongID = UUID()
        let remappedSong = Song(id: remappedSongID, gameID: gameID, masterTitle: "新タイトル")
        store.setCatalog(catalogState(songID: remappedSongID, title: "新タイトル"))
        let loadedRemapped = await store.image(for: remappedSong)
        let remapped = try XCTUnwrap(loadedRemapped)
        XCTAssertTrue(original === remapped, "The catalog external ID should select artwork across UUID and title changes")

        let wrongGameID = UUID()
        let wrongGameSong = Song(id: wrongGameID, gameID: "another-game", masterTitle: "新タイトル")
        store.setCatalog(catalogState(songID: wrongGameID, title: "新タイトル", gameID: "another-game"))
        let wrongGameImage = await store.image(for: wrongGameSong)
        XCTAssertNil(wrongGameImage)

        let wrongSourceID = UUID()
        let wrongSourceSong = Song(id: wrongSourceID, gameID: gameID, masterTitle: "新タイトル")
        store.setCatalog(catalogState(songID: wrongSourceID, title: "新タイトル", sourceID: "another-source"))
        let wrongSourceImage = await store.image(for: wrongSourceSong)
        XCTAssertNil(wrongSourceImage)
    }

    @MainActor func testManifestRejectsDuplicateKeysAndTraversalPaths() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageData = try png(color: .systemBlue)
        let fileName = digest(imageData) + ".png"
        let entry = BundledSongArtwork.Entry(key: key(), fileName: fileName, sha256: digest(imageData),
                                             title: "Fixture", sourceURL: "https://example.invalid/artwork")
        let duplicate = BundledSongArtwork.Manifest(version: 1, entries: [entry, entry])
        try JSONEncoder().encode(duplicate).write(to: directory.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try BundledSongArtwork(directory: directory), "Duplicate catalog keys must be rejected")

        let traversalManifest: [String: Any] = [
            "version": 1,
            "entries": [[
                "key": ["gameID": gameID, "sourceID": sourceID, "externalSongID": "song-artwork-test"],
                "fileName": "../outside.png", "sha256": digest(imageData),
                "title": "Fixture", "sourceURL": "https://example.invalid/artwork"
            ]]
        ]
        try JSONSerialization.data(withJSONObject: traversalManifest).write(to: directory.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try BundledSongArtwork(directory: directory), "Manifest paths must be flat hashed PNG names")
    }

    @MainActor func testBundledImageReturnsNilForChecksumMismatchOrMalformedPNG() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let validPNG = try png(color: .systemBlue)
        let mismatched = try bundledArtwork(in: directory.appendingPathComponent("checksum", isDirectory: true),
                                            key: key(), imageData: validPNG, checksum: String(repeating: "0", count: 64))
        XCTAssertNil(mismatched.image(for: key()), "A checksum mismatch must not produce an image")

        let brokenPNG = Data("not a PNG".utf8)
        let malformed = try bundledArtwork(in: directory.appendingPathComponent("broken", isDirectory: true),
                                           key: key(), imageData: brokenPNG)
        XCTAssertNil(malformed.image(for: key()), "A corrupt PNG must not produce an image even with a matching checksum")
    }
}
