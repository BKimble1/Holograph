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
        try storedRecords().compactMap(\.item)
    }

    @discardableResult
    func add(_ draft: LauncherItemDraft) throws -> LauncherItem {
        let parent = draft.kind == .folder ? nil : draft.parentFolderID
        let timestamp = now()
        let record = StoredLauncherApp(
            kind: draft.kind,
            name: draft.name,
            launchURLString: draft.launchURL?.absoluteString ?? "",
            fallbackURLString: draft.fallbackURL?.absoluteString,
            parentFolderID: parent,
            sortOrder: try nextSortOrder(in: parent),
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
        guard let record = try storedRecords().first(where: { $0.identifier == id }) else {
            throw LauncherRepositoryError.notFound
        }
        let movedScope = record.parentFolderID != (draft.kind == .folder ? nil : draft.parentFolderID)
        record.apply(draft, modifiedAt: now())
        // Landing in a different scope means joining the end of it rather than
        // keeping a position that belonged to somewhere else.
        if movedScope {
            record.sortOrder = try nextSortOrder(in: record.parentFolderID, excluding: record.identifier)
        }
        try save()
        try renumberEveryScope()
    }

    func delete(id: UUID) throws {
        let records = try storedRecords()
        guard let record = records.first(where: { $0.identifier == id }) else {
            throw LauncherRepositoryError.notFound
        }
        // A folder is a grouping, not a container that owns what it holds.
        if record.kind == .folder {
            let orphans = records.filter { $0.parentFolderID == id }
            var next = try nextSortOrder(in: nil)
            for orphan in orphans.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                orphan.parentFolderID = nil
                orphan.sortOrder = next
                next += 1
            }
        }
        context.delete(record)
        try save()
        try renumberEveryScope()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int, in parent: UUID?) throws {
        var scope = try storedRecords().filter { $0.parentFolderID == parent }
        guard !scope.isEmpty else { return }
        scope.move(fromOffsets: source, toOffset: destination)
        for (index, record) in scope.enumerated() where record.sortOrder != index {
            record.sortOrder = index
        }
        try save()
    }

    func setParent(of id: UUID, to parent: UUID?) throws {
        let records = try storedRecords()
        guard let record = records.first(where: { $0.identifier == id }) else {
            throw LauncherRepositoryError.notFound
        }
        guard record.kind != .folder else { return }
        guard parent == nil || records.contains(where: { $0.identifier == parent && $0.kind == .folder }) else {
            throw LauncherRepositoryError.notFound
        }
        guard record.parentFolderID != parent else { return }
        record.parentFolderID = parent
        record.sortOrder = try nextSortOrder(in: parent, excluding: id)
        record.modifiedAt = now()
        try save()
        try renumberEveryScope()
    }

    func removeAll() throws {
        for record in try storedRecords() {
            context.delete(record)
        }
        try save()
    }

    func replaceAll(with drafts: [LauncherItemDraft]) throws {
        for record in try storedRecords() {
            context.delete(record)
        }
        let timestamp = now()
        var next: [UUID?: Int] = [:]
        for draft in drafts {
            let parent = draft.kind == .folder ? nil : draft.parentFolderID
            let order = next[parent] ?? 0
            next[parent] = order + 1
            context.insert(
                StoredLauncherApp(
                    kind: draft.kind,
                    name: draft.name,
                    launchURLString: draft.launchURL?.absoluteString ?? "",
                    fallbackURLString: draft.fallbackURL?.absoluteString,
                    parentFolderID: parent,
                    sortOrder: order,
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
    /// handful of items, so there is nothing to gain from sorting in the store.
    private func storedRecords() throws -> [StoredLauncherApp] {
        do {
            let all = try context.fetch(FetchDescriptor<StoredLauncherApp>())
            return all.sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
        } catch {
            throw LauncherRepositoryError.storeUnavailable(error.localizedDescription)
        }
    }

    private func nextSortOrder(in parent: UUID?, excluding id: UUID? = nil) throws -> Int {
        let scope = try storedRecords()
            .filter { $0.parentFolderID == parent && $0.identifier != id }
        return (scope.map(\.sortOrder).max() ?? -1) + 1
    }

    /// Each scope numbers itself from zero, independently of every other.
    private func renumberEveryScope() throws {
        let records = try storedRecords()
        var didChange = false
        for scope in Set(records.map(\.parentFolderID)) {
            let members = records.filter { $0.parentFolderID == scope }
            for (index, record) in members.enumerated() where record.sortOrder != index {
                record.sortOrder = index
                didChange = true
            }
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
