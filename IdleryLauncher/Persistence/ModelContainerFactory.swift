import Foundation
import OSLog
import SwiftData

/// Builds the SwiftData stack, degrading gracefully rather than refusing to
/// launch if the on-disk store is unreadable.
enum ModelContainerFactory {
    static var schema: Schema { Schema([StoredLauncherApp.self]) }

    private static var logger: Logger { Logger(subsystem: "com.idlery.launcher", category: "persistence") }

    enum Outcome {
        /// The on-disk store opened normally, or an in-memory store was asked for.
        case ready(ModelContainer)
        /// Neither store could be created. The caller runs on a plain in-memory
        /// repository so the launcher still works for this session.
        case unavailable(String)
    }

    static func make(inMemory: Bool) -> Outcome {
        if let container = container(inMemory: inMemory) {
            return .ready(container)
        }
        if !inMemory, let fallback = container(inMemory: true) {
            logger.error("On-disk store unavailable; running in memory for this session.")
            return .ready(fallback)
        }
        return .unavailable("The launcher’s database could not be opened.")
    }

    private static func container(inMemory: Bool) -> ModelContainer? {
        do {
            let configuration: ModelConfiguration
            if inMemory {
                configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            } else {
                configuration = ModelConfiguration(schema: schema, url: try storeURL())
            }
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            logger.error("Model container failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Naming the store explicitly — and creating its directory first — avoids
    /// depending on Application Support already existing, which is not
    /// guaranteed on a freshly installed container.
    private static func storeURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appending(path: "IdleryLauncher.store")
    }
}
