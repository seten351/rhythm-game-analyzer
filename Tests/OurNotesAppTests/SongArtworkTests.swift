import AppKit
import Foundation
import XCTest
@testable import OurNotesApp
@testable import ResultCore

final class SongArtworkTests: XCTestCase {
    private let gameID = "our-notes"
    private let sourceID = "our-notes-community"
    private let externalSongID = "song-test-artwork"

    private func temporaryDirectory(_ name: String = "artwork-test") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func localTrash(in root: URL) -> @Sendable (URL) throws -> Void {
        { url in
            let destination = root.appendingPathComponent("test-trash", isDirectory: true)
                .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: destination)
        }
    }

    private func localTrashItems(in root: URL) throws -> [String] {
        let directory = root.appendingPathComponent("test-trash", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    private func key(gameID: String? = nil, sourceID: String? = nil, externalSongID: String? = nil) -> ArtworkKey {
        ArtworkKey(gameID: gameID ?? self.gameID,
                   sourceID: sourceID ?? self.sourceID,
                   externalSongID: externalSongID ?? self.externalSongID)
    }

    private func state(songID: UUID, retired: Bool = false, externalSongID: String? = nil) -> AppState {
        var state = AppState()
        let song = Song(id: songID, gameID: gameID, masterTitle: "テスト曲",
                        availability: retired ? .retired : .active)
        state.songs = [song]
        state.bindings = [CatalogBinding(gameID: gameID, sourceID: sourceID, kind: .song,
                                         externalID: externalSongID ?? self.externalSongID,
                                         internalID: songID)]
        return state
    }

    /// Build all test image bytes in memory. No user or repository artwork is read.
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

    private func isDecodablePNG(_ data: Data) -> Bool {
        guard let representation = NSBitmapImageRep(data: data) else { return false }
        return representation.pixelsWide > 0 && representation.pixelsHigh > 0
    }

    func testArtworkKeyUsesGameSourceAndExternalSongIdentity() {
        let base = key()
        XCTAssertEqual(base, key())
        XCTAssertNotEqual(base, key(gameID: "another-game"))
        XCTAssertNotEqual(base, key(sourceID: "another-source"))
        XCTAssertNotEqual(base, key(externalSongID: "another-song"))
    }

    func testPutAndReopenPreservesArtworkByCatalogKey() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let songID = UUID()
        let artworkKey = key()
        let image = try png(color: .systemBlue)
        let repository = ArtworkRepository(directory: directory, trash: localTrash(in: directory))
        _ = try await repository.reconcile(with: ArtworkCatalogSnapshot(state: state(songID: songID)))
        let saved = try await repository.put(png: image, for: artworkKey, localSongID: songID)

        XCTAssertEqual(saved.entries.count, 1)
        XCTAssertEqual(saved.entries.first?.key, artworkKey)
        XCTAssertEqual(saved.entries.first?.localSongIDs, [songID])

        let reopened = ArtworkRepository(directory: directory, trash: localTrash(in: directory))
        let loaded = try await reopened.data(for: artworkKey)
        XCTAssertNotNil(loaded)
        XCTAssertTrue(isDecodablePNG(try XCTUnwrap(loaded)))
    }

    func testImageCodecNormalizesGeneratedPNGAndRejectsMalformedBytes() throws {
        let normalized = try ArtworkImageCodec.normalizedPNG(from: png(color: .systemTeal))
        XCTAssertTrue(isDecodablePNG(normalized))
        XCTAssertLessThanOrEqual(normalized.count, 4 * 1024 * 1024)
        XCTAssertThrowsError(try ArtworkImageCodec.normalizedPNG(from: Data("not an image".utf8)))
        XCTAssertThrowsError(try ArtworkImageCodec.validateNormalizedPNG(Data("not a normalized PNG".utf8)))
    }

    func testInvalidPNGPutLeavesPreviouslyCommittedArtworkIntact() async throws {
        let directory = try temporaryDirectory("artwork-invalid-png")
        defer { try? FileManager.default.removeItem(at: directory) }
        let songID = UUID(), artworkKey = key()
        let catalog = ArtworkCatalogSnapshot(state: state(songID: songID))
        let repository = ArtworkRepository(directory: directory, trash: localTrash(in: directory))
        _ = try await repository.reconcile(with: catalog)
        _ = try await repository.put(png: png(color: .systemBlue), for: artworkKey, localSongID: songID)

        do {
            _ = try await repository.put(png: Data("malformed".utf8), for: artworkKey, localSongID: songID)
            XCTFail("Malformed image bytes must be rejected")
        } catch {
            let retained = try await repository.data(for: artworkKey)
            XCTAssertTrue(isDecodablePNG(try XCTUnwrap(retained)))
        }
    }

    @MainActor func testFacadeReplacesCachedImageAndClearsItAfterRemoval() async throws {
        let directory = try temporaryDirectory("artwork-facade")
        defer { try? FileManager.default.removeItem(at: directory) }
        let songID = UUID()
        let song = Song(id: songID, gameID: gameID, masterTitle: "テスト曲")
        let catalog = state(songID: songID)
        let input = directory.appendingPathComponent("user-selected.png")
        let store = SongArtworkStore(directory: directory.appendingPathComponent("managed", isDirectory: true), trash: localTrash(in: directory))
        store.setCatalog(catalog)

        // image() awaits the asynchronous catalog reconciliation before each assertion.
        let initialImage = await store.image(for: song)
        XCTAssertNil(initialImage)
        try png(color: .systemBlue).write(to: input, options: .atomic)
        try await store.register(url: input, for: song)
        let registeredImage = await store.image(for: song)
        let originalImage = try XCTUnwrap(registeredImage)

        try png(color: .systemRed).write(to: input, options: .atomic)
        try await store.register(url: input, for: song)
        let replacedImage = await store.image(for: song)
        let replacementImage = try XCTUnwrap(replacedImage)
        XCTAssertFalse(originalImage === replacementImage)

        try await store.remove(for: song)
        let removedImage = await store.image(for: song)
        XCTAssertNil(removedImage)
    }

    @MainActor func testFacadeRejectsAmbiguousActiveBindingButUsesArchivedAliasFallback() async throws {
        let directory = try temporaryDirectory("artwork-ambiguous-facade")
        defer { try? FileManager.default.removeItem(at: directory) }
        let songID = UUID()
        let song = Song(id: songID, gameID: gameID, masterTitle: "テスト曲")
        let initialState = state(songID: songID)
        let input = directory.appendingPathComponent("user-selected.png")
        try png(color: .systemBlue).write(to: input, options: .atomic)
        let store = SongArtworkStore(directory: directory.appendingPathComponent("managed", isDirectory: true), trash: localTrash(in: directory))
        store.setCatalog(initialState)
        _ = await store.image(for: song) // Wait for the initial reconciliation.
        try await store.register(url: input, for: song)
        let registeredImage = await store.image(for: song)
        XCTAssertNotNil(registeredImage)

        var conflictingActive = initialState
        conflictingActive.bindings.append(.init(gameID: gameID, sourceID: "another-source", kind: .song,
                                                 externalID: "different-external-song", internalID: songID))
        store.setCatalog(conflictingActive)
        let ambiguousImage = await store.image(for: song) // Awaits setCatalog's reconciliation.
        XCTAssertNil(ambiguousImage)
        XCTAssertNil(store.key(for: song))
        do {
            try await store.register(url: input, for: song)
            XCTFail("An active song with conflicting bindings must not accept artwork")
        } catch {
            // The ambiguous catalog identity must remain unresolved.
        }

        var archivedWithoutBindings = conflictingActive
        archivedWithoutBindings.songs[0].availability = .retired
        archivedWithoutBindings.bindings.removeAll()
        store.setCatalog(archivedWithoutBindings)
        let archivedImage = await store.image(for: song)
        XCTAssertNotNil(archivedImage, "A retired song may use its retained UUID artwork alias")
        XCTAssertEqual(store.key(for: song), key())
    }

    @MainActor func testFailedStateSaveDoesNotReconcileAwayArtwork() async throws {
        let directory = try temporaryDirectory("artwork-state-save")
        defer { try? FileManager.default.removeItem(at: directory) }
        let songID = UUID()
        let song = Song(id: songID, gameID: gameID, masterTitle: "テスト曲")
        let initialState = state(songID: songID)
        let repository = ArtworkStateRepository(storeURL: directory.appendingPathComponent("results.store"), stored: initialState)
        let artwork = SongArtworkStore(directory: directory.appendingPathComponent("managed", isDirectory: true), trash: localTrash(in: directory))
        let model = AppModel(inMemory: true, loadBundledCatalog: false, repository: repository, artwork: artwork)
        XCTAssertNil(model.startupError)

        let input = directory.appendingPathComponent("user-selected.png")
        try png(color: .systemBlue).write(to: input, options: .atomic)
        try await artwork.register(url: input, for: song)
        let beforeFailure = await artwork.image(for: song)
        let originalImage = try XCTUnwrap(beforeFailure)

        var removal = initialState
        removal.songs.removeAll()
        removal.bindings.removeAll()
        repository.failSaves = true
        do {
            try model.commit(removal)
            XCTFail("Expected the injected state save failure")
        } catch ArtworkTestFailure.injected {
            // Artwork reconciliation must wait until the state write succeeds.
        }

        XCTAssertEqual(model.state, initialState)
        let afterFailure = await artwork.image(for: song)
        XCTAssertTrue(originalImage === afterFailure)
    }

    func testCatalogIdentitySurvivesInternalSongUUIDRemapAndKeepsRetiredSongArtwork() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artworkKey = key()
        let oldSongID = UUID(), replacementSongID = UUID()
        let repository = ArtworkRepository(directory: directory, trash: localTrash(in: directory))
        _ = try await repository.reconcile(with: ArtworkCatalogSnapshot(state: state(songID: oldSongID)))
        _ = try await repository.put(png: png(color: .systemPink), for: artworkKey, localSongID: oldSongID)

        let reconciled = try await repository.reconcile(with: ArtworkCatalogSnapshot(state: state(songID: replacementSongID, retired: true)))
        let entry = try XCTUnwrap(reconciled.entries.first { $0.key == artworkKey })
        XCTAssertEqual(Set(entry.localSongIDs), [replacementSongID])
        let remappedData = try await repository.data(for: artworkKey)
        XCTAssertTrue(isDecodablePNG(try XCTUnwrap(remappedData)))

        var bindinglessRetired = state(songID: replacementSongID, retired: true)
        bindinglessRetired.bindings.removeAll()
        let noBindingSnapshot = ArtworkCatalogSnapshot(state: bindinglessRetired)
        XCTAssertNil(noBindingSnapshot.keysBySong[replacementSongID])
        let retainedAfterBindingLoss = try await repository.reconcile(with: noBindingSnapshot)
        XCTAssertEqual(retainedAfterBindingLoss.entries.first?.key, artworkKey)
        XCTAssertEqual(retainedAfterBindingLoss.entries.first?.localSongIDs, [replacementSongID])

        var ambiguousBindings = state(songID: replacementSongID, retired: true)
        ambiguousBindings.bindings.append(.init(gameID: gameID, sourceID: "another-source", kind: .song,
                                                  externalID: "same-local-song-different-catalog", internalID: replacementSongID))
        let ambiguousSnapshot = ArtworkCatalogSnapshot(state: ambiguousBindings)
        XCTAssertNil(ambiguousSnapshot.keysBySong[replacementSongID], "Conflicting catalog bindings stay unresolved")
        let retainedUnderAmbiguity = try await repository.reconcile(with: ambiguousSnapshot)
        XCTAssertEqual(retainedUnderAmbiguity.entries.first?.key, artworkKey)
        XCTAssertEqual(retainedUnderAmbiguity.entries.first?.localSongIDs, [replacementSongID])
    }

    func testDifferentCompositeKeysKeepTheirArtworkSeparate() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstSongID = UUID(), secondSongID = UUID()
        var state = AppState()
        state.songs = [Song(id: firstSongID, gameID: gameID, masterTitle: "一曲目"),
                       Song(id: secondSongID, gameID: gameID, masterTitle: "二曲目")]
        let base = key(), other = key(sourceID: "another-source")
        state.bindings = [CatalogBinding(gameID: gameID, sourceID: base.sourceID, kind: .song,
                                         externalID: base.externalSongID, internalID: firstSongID),
                          CatalogBinding(gameID: gameID, sourceID: other.sourceID, kind: .song,
                                         externalID: other.externalSongID, internalID: secondSongID)]
        let repository = ArtworkRepository(directory: directory, trash: localTrash(in: directory))
        let catalog = ArtworkCatalogSnapshot(state: state)
        _ = try await repository.reconcile(with: catalog)
        _ = try await repository.put(png: png(color: .systemBlue), for: base, localSongID: firstSongID)
        _ = try await repository.put(png: png(color: .systemRed), for: other, localSongID: secondSongID)

        let snapshot = try await repository.reconcile(with: catalog)
        XCTAssertEqual(Set(snapshot.entries.map(\.key)), [base, other])
        let baseData = try await repository.data(for: base)
        let otherData = try await repository.data(for: other)
        XCTAssertTrue(isDecodablePNG(try XCTUnwrap(baseData)))
        XCTAssertTrue(isDecodablePNG(try XCTUnwrap(otherData)))
    }

    func testFailedPrecommitWriteKeepsPreviouslyCommittedArtworkReadable() async throws {
        for checkpoint in [ArtworkWriteCheckpoint.imageStaged, .imageFinalized, .indexStaged] {
            let directory = try temporaryDirectory("artwork-failure")
            defer { try? FileManager.default.removeItem(at: directory) }
            let songID = UUID(), artworkKey = key()
            let snapshot = ArtworkCatalogSnapshot(state: state(songID: songID))
            let initialRepository = ArtworkRepository(directory: directory, trash: localTrash(in: directory))
            _ = try await initialRepository.reconcile(with: snapshot)
            _ = try await initialRepository.put(png: png(color: .systemBlue), for: artworkKey, localSongID: songID)
        let originalData = try await initialRepository.data(for: artworkKey)
        let originalBytes = try XCTUnwrap(originalData)

            let failingRepository = ArtworkRepository(directory: directory, trash: localTrash(in: directory), failure: { reached in
                if reached == checkpoint { throw ArtworkTestFailure.injected }
            })
            _ = try await failingRepository.reconcile(with: snapshot)
            do {
                _ = try await failingRepository.put(png: png(color: .systemRed), for: artworkKey, localSongID: songID)
                XCTFail("Expected injected failure at \(checkpoint)")
            } catch ArtworkTestFailure.injected {
                // The earlier committed version must remain addressable.
            }
            let previousData = try await failingRepository.data(for: artworkKey)
            XCTAssertEqual(previousData, originalBytes, "The previous bytes should survive failure at \(checkpoint)")
            let persisted = try await failingRepository.reconcile(with: snapshot)
            XCTAssertEqual(persisted.entries.count, 1)
        }
    }

    func testReconcileMovesRemovedArtworkToInjectedTrashOnlyAfterItIsUnreferenced() async throws {
        let directory = try temporaryDirectory("artwork-gc")
        let trashDirectory = directory.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let songID = UUID(), artworkKey = key()
        let repository = ArtworkRepository(directory: directory, trash: { url in
            let destination = trashDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
        })
        _ = try await repository.reconcile(with: ArtworkCatalogSnapshot(state: state(songID: songID, retired: true)))
        _ = try await repository.put(png: png(color: .systemGreen), for: artworkKey, localSongID: songID)

        let retained = try await repository.reconcile(with: ArtworkCatalogSnapshot(state: state(songID: songID, retired: true)))
        XCTAssertEqual(retained.entries.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trashDirectory.path).isEmpty)

        let removed = try await repository.reconcile(with: ArtworkCatalogSnapshot(state: AppState()))
        XCTAssertTrue(removed.entries.isEmpty)
        let removedData = try await repository.data(for: artworkKey)
        XCTAssertNil(removedData)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: trashDirectory.path).isEmpty)
    }

    func testReconcileDropsCorruptAssetFromIndexAndKeepsFileWhenTrashFails() async throws {
        let directory = try temporaryDirectory("artwork-corrupt-asset")
        defer { try? FileManager.default.removeItem(at: directory) }
        let trashDirectory = directory.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let songID = UUID(), artworkKey = key()
        let catalog = ArtworkCatalogSnapshot(state: state(songID: songID))
        let repository = ArtworkRepository(directory: directory, trash: { _ in
            throw ArtworkTestFailure.injected
        })
        _ = try await repository.reconcile(with: catalog)
        let saved = try await repository.put(png: png(color: .systemIndigo), for: artworkKey, localSongID: songID)
        let assetID = try XCTUnwrap(saved.entries.first?.assetID)
        let imageURL = directory.appendingPathComponent("images/\(assetID.uuidString).png")
        try Data("corrupt pixels".utf8).write(to: imageURL, options: .atomic)

        let reconciled = try await repository.reconcile(with: catalog)
        XCTAssertTrue(reconciled.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        let corruptData = try await repository.data(for: artworkKey)
        XCTAssertNil(corruptData)
        XCTAssertNotNil(reconciled.statusMessage)
        XCTAssertTrue(try localTrashItems(in: directory).isEmpty)
    }

    func testCorruptPrimaryIndexRecoversFromBackupWithoutDeletingArtwork() async throws {
        let directory = try temporaryDirectory("artwork-index-recovery")
        let trashDirectory = directory.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let songID = UUID(), artworkKey = key()
        let repository = ArtworkRepository(directory: directory, trash: localTrash(in: directory))
        let catalog = ArtworkCatalogSnapshot(state: state(songID: songID))
        _ = try await repository.reconcile(with: catalog)
        _ = try await repository.put(png: png(color: .systemOrange), for: artworkKey, localSongID: songID)
        try Data("broken index".utf8).write(to: directory.appendingPathComponent("index.json"), options: .atomic)

        let reopened = ArtworkRepository(directory: directory, trash: localTrash(in: directory))
        let recovered = try await reopened.reconcile(with: catalog)
        XCTAssertEqual(recovered.entries.map(\.key), [artworkKey])
        XCTAssertNotNil(recovered.statusMessage)
        let recoveredData = try await reopened.data(for: artworkKey)
        XCTAssertTrue(isDecodablePNG(try XCTUnwrap(recoveredData)))
        XCTAssertTrue(try localTrashItems(in: directory).isEmpty)
    }

    func testBothCorruptIndexesQuarantineManagedFilesAndLeaveUnknownFilesAlone() async throws {
        let directory = try temporaryDirectory("artwork-index-corrupt")
        let trashDirectory = directory.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let songID = UUID(), artworkKey = key()
        let repository = ArtworkRepository(directory: directory, trash: localTrash(in: directory))
        let catalog = ArtworkCatalogSnapshot(state: state(songID: songID))
        _ = try await repository.reconcile(with: catalog)
        let saved = try await repository.put(png: png(color: .systemPurple), for: artworkKey, localSongID: songID)
        let assetID = try XCTUnwrap(saved.entries.first?.assetID)
        let imagePath = directory.appendingPathComponent("images", isDirectory: true).appendingPathComponent("\(assetID).png")
        let unknown = directory.appendingPathComponent("user-note.txt")
        try Data("keep".utf8).write(to: unknown)
        for filename in ["index.json", "index.backup.json"] {
            try Data("broken index".utf8).write(to: directory.appendingPathComponent(filename), options: .atomic)
        }

        let reopened = ArtworkRepository(directory: directory, trash: localTrash(in: directory))
        let reset = try await reopened.reconcile(with: catalog)
        XCTAssertTrue(reset.entries.isEmpty)
        XCTAssertNotNil(reset.statusMessage)
        let resetData = try await reopened.data(for: artworkKey)
        XCTAssertNil(resetData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("test-trash").path).isEmpty)
    }

    func testTrashFailureDoesNotUndoIndexMutationAndNextReconcileRetriesCleanup() async throws {
        let directory = try temporaryDirectory("artwork-trash-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let songID = UUID(), artworkKey = key()
        let failTrash = ArtworkRepository(directory: directory, trash: { _ in throw ArtworkTestFailure.injected })
        let catalog = ArtworkCatalogSnapshot(state: state(songID: songID))
        _ = try await failTrash.reconcile(with: catalog)
        let saved = try await failTrash.put(png: png(color: .systemYellow), for: artworkKey, localSongID: songID)
        let assetID = try XCTUnwrap(saved.entries.first?.assetID)
        let imagePath = directory.appendingPathComponent("images", isDirectory: true).appendingPathComponent("\(assetID).png")

        let removed = try await failTrash.reconcile(with: ArtworkCatalogSnapshot(state: AppState()))
        XCTAssertTrue(removed.entries.isEmpty)
        let removedData = try await failTrash.data(for: artworkKey)
        XCTAssertNil(removedData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath.path), "Failed trash should leave a retryable orphan")

        let trashDirectory = directory.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let retrying = ArtworkRepository(directory: directory, trash: localTrash(in: directory))
        _ = try await retrying.reconcile(with: ArtworkCatalogSnapshot(state: AppState()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePath.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("test-trash").path).isEmpty)
    }
}

private enum ArtworkTestFailure: Error { case injected }

@MainActor private final class ArtworkStateRepository: StateRepository {
    let storeURL: URL
    var stored: AppState
    var failSaves = false

    init(storeURL: URL, stored: AppState) {
        self.storeURL = storeURL
        self.stored = stored
    }
    func load() throws -> AppState { stored }
    func save(_ state: AppState) throws {
        if failSaves { throw ArtworkTestFailure.injected }
        stored = state
    }
}
