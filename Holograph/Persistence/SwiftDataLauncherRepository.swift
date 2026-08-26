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
            folderSortOrder: parent == nil ? 0 : try nextFolderOrder(in: parent),
            sortOrder: try nextWallOrder(),
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
        let joinedFolder = record.parentFolderID != (draft.kind == .folder ? nil : draft.parentFolderID)
        record.apply(draft, modifiedAt: now())
        // Joining a folder means going to the end of it. Its place on the wall
        // is untouched, because it never left the wall.
        if joinedFolder, let folder = record.parentFolderID {
            record.folderSortOrder = try nextFolderOrder(in: folder, excluding: record.identifier)
        }
        try save()
        try renumberEveryScope()
    }

    func delete(id: UUID) throws {
        let records = try storedRecords()
        guard let record = records.first(where: { $0.identifier == id }) else {
            throw LauncherRepositoryError.notFound
        }
        // A folder is a grouping, not a container that owns what it holds. Its
        // members are already on the wall, so losing the folder simply loses
        // the grouping.
        if record.kind == .folder {
            for member in records where member.parentFolderID == id {
                member.parentFolderID = nil
            }
        }
        context.delete(record)
        try save()
        try renumberEveryScope()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int, in parent: UUID?) throws {
        let records = try storedRecords()
        guard let folder = parent else {
            var wall = records
            guard !wall.isEmpty else { return }
            wall.move(fromOffsets: source, toOffset: destination)
            for (index, record) in wall.enumerated() where record.sortOrder != index {
                record.sortOrder = index
            }
            try save()
            return
        }
        var scope = records
            .filter { $0.parentFolderID == folder }
            .sorted { ($0.folderSortOrder ?? $0.sortOrder) < ($1.folderSortOrder ?? $1.sortOrder) }
        guard !scope.isEmpty else { return }
        scope.move(fromOffsets: source, toOffset: destination)
        for (index, record) in scope.enumerated() {
            record.folderSortOrder = index
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
        // Its place on the wall is untouched: it never left.
        if let parent {
            record.folderSortOrder = try nextFolderOrder(in: parent, excluding: id)
        }
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
        for (wallOrder, draft) in drafts.enumerated() {
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
                    folderSortOrder: order,
                    sortOrder: wallOrder,
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

    private func nextWallOrder() throws -> Int {
        (try storedRecords().map(\.sortOrder).max() ?? -1) + 1
    }

    private func nextFolderOrder(in folder: UUID?, excluding id: UUID? = nil) throws -> Int {
        guard let folder else { return 0 }
        let members = try storedRecords()
            .filter { $0.parentFolderID == folder && $0.identifier != id }
        return (members.compactMap(\.folderSortOrder).max() ?? -1) + 1
    }

    /// The wall numbers itself from zero, and so does each folder — separately,
    /// because a tile lives in both at once.
    private func renumberEveryScope() throws {
        let records = try storedRecords()
        var didChange = false
        for (index, record) in records.enumerated() where record.sortOrder != index {
            record.sortOrder = index
            didChange = true
        }
        for folder in Set(records.compactMap(\.parentFolderID)) {
            let members = records
                .filter { $0.parentFolderID == folder }
                .sorted { ($0.folderSortOrder ?? $0.sortOrder) < ($1.folderSortOrder ?? $1.sortOrder) }
            for (index, record) in members.enumerated() where record.folderSortOrder != index {
                record.folderSortOrder = index
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
