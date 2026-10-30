import Foundation
import CoreData

// Only platform dependencies are stubbed; these tests compile the production container.
private var testRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
private var extensionProcess = false
extension FileManager {
    var altstoreSharedDirectory: URL? { nil }
    var applicationSupportDirectory: URL { testRoot }
}
extension Bundle {
    static func isAppExtension() -> Bool { extensionProcess }
}
final class RelationshipPreservingMergePolicy: NSMergePolicy, @unchecked Sendable {
    init() { super.init(merge: .mergeByPropertyObjectTrumpMergePolicyType) }
}
func debugLog(_ message: String) { print(message) }

@main
struct PersistentContainerTests {
    static func main() async throws {
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let shared = testRoot.appendingPathComponent("Shared")
        let local = testRoot.appendingPathComponent("LocalDatabase", isDirectory: true)
        precondition(PersistentContainer.databaseDirectory(sharedDirectory: shared, applicationSupportDirectory: testRoot, isAppExtension: false) == shared.appendingPathComponent("Database", isDirectory: true))
        precondition(PersistentContainer.databaseDirectory(sharedDirectory: nil, applicationSupportDirectory: testRoot, isAppExtension: true) == nil)

        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "Record"
        entity.managedObjectClassName = "NSManagedObject"
        let value = NSAttributeDescription()
        value.name = "value"
        value.attributeType = .stringAttributeType
        entity.properties = [value]
        model.entities = [entity]

        let first = PersistentContainer(name: "Test", managedObjectModel: model)
        precondition(first.persistentStoreDescriptions[0].url?.deletingLastPathComponent().standardizedFileURL == local.standardizedFileURL)
        try await first.loadPersistentStores()
        let writer = first.newBackgroundContext()
        try await writer.perform {
            let record = NSEntityDescription.insertNewObject(forEntityName: "Record", into: writer)
            record.setValue("survives relaunch", forKey: "value")
            try writer.save()
        }
        for store in first.persistentStoreCoordinator.persistentStores {
            try first.persistentStoreCoordinator.remove(store)
        }
        let second = PersistentContainer(name: "Test", managedObjectModel: model)
        try await second.loadPersistentStores()
        let reader = second.newBackgroundContext()
        try await reader.perform {
            let records = try reader.fetch(NSFetchRequest<NSManagedObject>(entityName: "Record"))
            precondition(records.count == 1)
            precondition(records[0].value(forKey: "value") as? String == "survives relaunch")
        }
        // Restoring App Group access must not silently replace the existing local database.
        precondition(PersistentContainer.databaseDirectory(sharedDirectory: shared, applicationSupportDirectory: testRoot, isAppExtension: false) == local)
        precondition(PersistentContainer.databaseDirectory(sharedDirectory: shared, applicationSupportDirectory: testRoot, isAppExtension: true) == shared.appendingPathComponent("Database", isDirectory: true))
        extensionProcess = true
        let ext = PersistentContainer(name: "Extension", managedObjectModel: model)
        do {
            try await ext.loadPersistentStores()
            fatalError("An extension must not create a private database")
        } catch DatabaseError.missingAppGroup { }
        precondition(ext.persistentStoreCoordinator.persistentStores.isEmpty)
        print("Persistent container regression tests passed")
    }
}
