import Foundation

/// A drop-in repository for previews, unit tests and the `-inMemoryStore`
/// launch argument. Deliberately mirrors `SwiftDataLauncherRepository`'s
/// ordering, scoping and timestamp behaviour so tests written against one hold
/// for both.
@MainActor
final class InMemoryLauncherRepository: LauncherRepository {
    private var items: [LauncherItem]
    private let now: @Sendable () -> Date

    init(items: [LauncherItem] = [], now: @escaping @Sendable () -> Date = { .now }) {
        self.now = now
        self.items = items
        renumber()
    }

    /// Sorted on the way out, exactly as the SwiftData store does. Order is a
    /// property of the read rather than of the array, which is what lets each
    /// scope number itself independently.
    func fetchAll() throws -> [LauncherItem] { items.sortedForDisplay() }

    @discardableResult
    func add(_ draft: LauncherItemDraft) throws -> LauncherItem {
        let timestamp = now()
        let parent = draft.kind == .folder ? nil : draft.parentFolderID
        let item = LauncherItem(
            kind: draft.kind,
            name: draft.name,
            launchURL: draft.launchURL,
            fallbackURL: draft.fallbackURL,
            parentFolderID: parent,
            sortOrder: nextWallOrder(),
            folderSortOrder: nextFolderOrder(in: parent),
            iconData: draft.iconData,
            isDemo: draft.isDemo,
            createdAt: timestamp,
            modifiedAt: timestamp
        )
        items.append(item)
        return item
    }

    func update(id: UUID, with draft: LauncherItemDraft) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw LauncherRepositoryError.notFound
        }
        var item = items[index]
        let parent = draft.kind == .folder ? nil : draft.parentFolderID
        let joinedFolder = item.parentFolderID != parent
        item.kind = draft.kind
        item.name = draft.name
        item.launchURL = draft.launchURL
        item.fallbackURL = draft.fallbackURL
        item.parentFolderID = parent
        item.iconData = draft.iconData
        item.isDemo = draft.isDemo
        item.modifiedAt = now()
        // Joining a folder means going to the end of it. Its place on the wall
        // is untouched, because it never left the wall.
        if joinedFolder, parent != nil {
            item.folderSortOrder = nextFolderOrder(in: parent, excluding: id)
        }
        items[index] = item
        renumber()
    }

    func delete(id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw LauncherRepositoryError.notFound
        }
        // A folder is a grouping, not a container that owns what it holds. Its
        // members are already on the wall, so losing the folder simply loses
        // the grouping.
        if items[index].isFolder {
            for position in items.indices where items[position].parentFolderID == id {
                items[position].parentFolderID = nil
            }
        }
        items.remove(at: index)
        renumber()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int, in parent: UUID?) throws {
        guard let folder = parent else {
            var wall = items.rootItems
            guard !wall.isEmpty else { return }
            wall.move(fromOffsets: source, toOffset: destination)
            for (index, moved) in wall.enumerated() {
                guard let position = items.firstIndex(where: { $0.id == moved.id }) else { continue }
                items[position].sortOrder = index
            }
            return
        }
        var scope = items.children(of: folder)
        guard !scope.isEmpty else { return }
        scope.move(fromOffsets: source, toOffset: destination)
        for (index, moved) in scope.enumerated() {
            guard let position = items.firstIndex(where: { $0.id == moved.id }) else { continue }
            items[position].folderSortOrder = index
        }
    }

    func setParent(of id: UUID, to parent: UUID?) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw LauncherRepositoryError.notFound
        }
        guard !items[index].isFolder else { return }
        guard parent == nil || items.contains(where: { $0.id == parent && $0.isFolder }) else {
            throw LauncherRepositoryError.notFound
        }
        guard items[index].parentFolderID != parent else { return }
        items[index].parentFolderID = parent
        // Its place on the wall is untouched: it never left.
        if parent != nil {
            items[index].folderSortOrder = nextFolderOrder(in: parent, excluding: id)
        }
        items[index].modifiedAt = now()
        renumber()
    }

    func removeAll() throws {
        items.removeAll()
    }

    func replaceAll(with drafts: [LauncherItemDraft]) throws {
        let timestamp = now()
        var next: [UUID?: Int] = [:]
        items = drafts.enumerated().map { wallOrder, draft in
            let parent = draft.kind == .folder ? nil : draft.parentFolderID
            let order = next[parent] ?? 0
            next[parent] = order + 1
            return LauncherItem(
                kind: draft.kind,
                name: draft.name,
                launchURL: draft.launchURL,
                fallbackURL: draft.fallbackURL,
                parentFolderID: parent,
                sortOrder: wallOrder,
                folderSortOrder: order,
                iconData: draft.iconData,
                isDemo: draft.isDemo,
                createdAt: timestamp,
                modifiedAt: timestamp
            )
        }
    }

    // MARK: - Plumbing

    private func nextWallOrder() -> Int {
        (items.map(\.sortOrder).max() ?? -1) + 1
    }

    private func nextFolderOrder(in folder: UUID?, excluding id: UUID? = nil) -> Int {
        guard let folder else { return 0 }
        let members = items.filter { $0.parentFolderID == folder && $0.id != id }
        return (members.map(\.folderSortOrder).max() ?? -1) + 1
    }

    /// The wall numbers itself from zero, and so does each folder — separately,
    /// because a tile lives in both at once.
    private func renumber() {
        for (index, member) in items.rootItems.enumerated() {
            guard let position = items.firstIndex(where: { $0.id == member.id }) else { continue }
            items[position].sortOrder = index
        }
        for folder in Set(items.compactMap(\.parentFolderID)) {
            for (index, member) in items.children(of: folder).enumerated() {
                guard let position = items.firstIndex(where: { $0.id == member.id }) else { continue }
                items[position].folderSortOrder = index
            }
        }
    }
}
