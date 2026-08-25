import Foundation
import OSLog
import SwiftData

/// Builds the SwiftData stack, degrading to an in-memory store rather than
/// refusing to launch if the on-disk store is unreadable.
enum ModelContainerFactory {
    static var schema: Schema { Schema([StoredLauncherApp.self]) }

    private static var logger: Logger { Logger(subsystem: "com.idlery.launcher", category: "persistence") }

    struct Result {
        let container: ModelContainer
        /// `true` when the on-disk store failed to open and we fell back.
        let didFallBackToMemory: Bool
    }

    static func make(inMemory: Bool) -> Result {
        if inMemory {
            return Result(container: makeInMemoryContainer(), didFallBackToMemory: false)
        }
        do {
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            return Result(container: container, didFallBackToMemory: false)
        } catch {
            logger.error("Falling back to an in-memory store: \(error.localizedDescription, privacy: .public)")
            return Result(container: makeInMemoryContainer(), didFallBackToMemory: true)
        }
    }

    private static func makeInMemoryContainer() -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // An in-memory container has no external dependencies; if this
            // fails the process cannot function at all.
            fatalError("Unable to create an in-memory model container: \(error)")
        }
    }
}
