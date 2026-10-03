import Foundation
import SwiftData
import ResultCore

enum StorageSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [StateSnapshot.self] }
    @Model final class StateSnapshot {
        @Attribute(.unique) var key: String
        var payload: Data
        init(key: String = "primary", payload: Data) { self.key = key; self.payload = payload }
    }
}
enum StorageMigrations: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [StorageSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

@MainActor protocol StateRepository {
    var storeURL: URL { get }
    func load() throws -> AppState
    func save(_ state: AppState) throws
}

@MainActor final class LocalRepository: StateRepository {
    let container: ModelContainer
    let context: ModelContext
    let storeURL: URL
    init(inMemory: Bool = false, storageDirectory: URL? = nil) throws {
        let base = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OurNotesAnalyzer", isDirectory: true)
        if !inMemory { try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true) }
        storeURL = base.appendingPathComponent("results.store")
        let schema = Schema(versionedSchema: StorageSchemaV1.self)
        let config = inMemory ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none) : ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, migrationPlan: StorageMigrations.self, configurations: [config])
        context = ModelContext(container); context.autosaveEnabled = false
    }
    func load() throws -> AppState {
        let rows = try context.fetch(FetchDescriptor<StorageSchemaV1.StateSnapshot>())
        guard let row = rows.first(where: { $0.key == "primary" }) else { return AppState() }
        let state = try JSONDecoder().decode(AppState.self, from: row.payload)
        guard state.schemaVersion == 1 else { throw CoreError.invalid("未対応の保存データ版です。元データを保持して起動を中止しました。") }
        return state
    }
    func save(_ state: AppState) throws {
        let encoded = try JSONEncoder().encode(state)
        do {
            let rows = try context.fetch(FetchDescriptor<StorageSchemaV1.StateSnapshot>())
            if let row = rows.first(where: { $0.key == "primary" }) { row.payload = encoded }
            else { context.insert(StorageSchemaV1.StateSnapshot(payload: encoded)) }
            try context.save()
        } catch { context.rollback(); throw error }
    }
}
