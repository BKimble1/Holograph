import Foundation
import SwiftData

@MainActor
final class SwiftDataLauncherRepository: LauncherRepository {
    /// Held for the repository's lifetime. A `ModelContext` on its own is not
    /// enough — once the container it came from is released, SwiftData has no
    /// active container for the model and traps on the next fetch.
    private let container: ModelContainer
    private let context: ModelContext
    private let now: @Sendable () -> Date

    init(container: ModelContainer, now: @escaping @Sendable () -> Date = { .now }) {
        self.container = container
        self.context = container.mainContext
        self.now = now
    }

    func fetchAll() throws -> [LauncherItem] {
        try storedApps().compactMap(\.item)
    }

    @discardableResult
    func add(_ draft: LauncherItemDraft) throws -> LauncherItem {
        let existing = try storedApps()
        let timestamp = now()
        let record = StoredLauncherApp(
            name: draft.name,
            launchURLString: draft.launchURL.absoluteString,
            fallbackURLString: draft.fallbackURL?.absoluteString,
            sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1,
            iconData: draft.iconData,
            isDemo: draft.isDemo,
            createdAt: timestamp,
            modifiedAt: timestamp
        )
        context.insert(record)
        try save()
        guard let item = record.item else {
            throw LauncherRepositoryError.writeFailed("The launch link couldn’t be stored.")
        }
        return item
    }

    func update(id: UUID, with draft: LauncherItemDraft) throws {
        guard let record = try storedApps().first(where: { $0.identifier == id }) else {
            throw LauncherRepositoryError.notFound
        }
        record.apply(draft, modifiedAt: now())
        try save()
    }

    func delete(id: UUID) throws {
        guard let record = try storedApps().first(where: { $0.identifier == id }) else {
            throw LauncherRepositoryError.notFound
        }
        context.delete(record)
        try save()
        try normalizeSortOrder()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        var records = try storedApps()
        guard !records.isEmpty else { return }
        records.move(fromOffsets: source, toOffset: destination)
        for (index, record) in records.enumerated() where record.sortOrder != index {
            record.sortOrder = index
        }
        try save()
    }

    func removeAll() throws {
        for record in try storedApps() {
            context.delete(record)
        }
        try save()
    }

    func replaceAll(with drafts: [LauncherItemDraft]) throws {
        for record in try storedApps() {
            context.delete(record)
        }
        let timestamp = now()
        for (index, draft) in drafts.enumerated() {
            context.insert(
                StoredLauncherApp(
                    name: draft.name,
                    launchURLString: draft.launchURL.absoluteString,
                    fallbackURLString: draft.fallbackURL?.absoluteString,
                    sortOrder: index,
                    iconData: draft.iconData,
                    isDemo: draft.isDemo,
                    createdAt: timestamp,
                    modifiedAt: timestamp
                )
            )
        }
        try save()
    }

    // MARK: - Plumbing

    /// Ordering happens in Swift rather than in the fetch. A launcher holds a
    /// handful of apps, so there is nothing to gain from sorting in the store.
    private func storedApps() throws -> [StoredLauncherApp] {
        do {
            let all = try context.fetch(FetchDescriptor<StoredLauncherApp>())
            return all.sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
        } catch {
            throw LauncherRepositoryError.storeUnavailable(error.localizedDescription)
        }
    }

    private func normalizeSortOrder() throws {
        let records = try storedApps()
        var didChange = false
        for (index, record) in records.enumerated() where record.sortOrder != index {
            record.sortOrder = index
            didChange = true
        }
        if didChange { try save() }
    }

    private func save() throws {
        do {
            try context.save()
        } catch {
            throw LauncherRepositoryError.writeFailed(error.localizedDescription)
        }
    }
}
