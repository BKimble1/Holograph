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

    func fetchAll() throws -> [LauncherItem] { items }

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
            sortOrder: nextSortOrder(in: parent),
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
        let movedScope = item.parentFolderID != parent
        item.kind = draft.kind
        item.name = draft.name
        item.launchURL = draft.launchURL
        item.fallbackURL = draft.fallbackURL
        item.parentFolderID = parent
        item.iconData = draft.iconData
        item.isDemo = draft.isDemo
        item.modifiedAt = now()
        if movedScope {
            item.sortOrder = nextSortOrder(in: parent, excluding: id)
        }
        items[index] = item
        renumber()
    }

    func delete(id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw LauncherRepositoryError.notFound
        }
        // A folder is a grouping, not a container that owns what it holds.
        if items[index].isFolder {
            var next = nextSortOrder(in: nil)
            for position in items.indices where items[position].parentFolderID == id {
                items[position].parentFolderID = nil
                items[position].sortOrder = next
                next += 1
            }
        }
        items.remove(at: index)
        renumber()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int, in parent: UUID?) throws {
        var scope = items.filter { $0.parentFolderID == parent }.sortedForDisplay()
        guard !scope.isEmpty else { return }
        scope.move(fromOffsets: source, toOffset: destination)
        for (index, moved) in scope.enumerated() {
            guard let position = items.firstIndex(where: { $0.id == moved.id }) else { continue }
            items[position].sortOrder = index
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
        items[index].sortOrder = nextSortOrder(in: parent, excluding: id)
        items[index].modifiedAt = now()
        renumber()
    }

    func removeAll() throws {
        items.removeAll()
    }

    func replaceAll(with drafts: [LauncherItemDraft]) throws {
        let timestamp = now()
        var next: [UUID?: Int] = [:]
        items = drafts.map { draft in
            let parent = draft.kind == .folder ? nil : draft.parentFolderID
            let order = next[parent] ?? 0
            next[parent] = order + 1
            return LauncherItem(
                kind: draft.kind,
                name: draft.name,
                launchURL: draft.launchURL,
                fallbackURL: draft.fallbackURL,
                parentFolderID: parent,
                sortOrder: order,
                iconData: draft.iconData,
                isDemo: draft.isDemo,
                createdAt: timestamp,
                modifiedAt: timestamp
            )
        }
    }

    // MARK: - Plumbing

    private func nextSortOrder(in parent: UUID?, excluding id: UUID? = nil) -> Int {
        let scope = items.filter { $0.parentFolderID == parent && $0.id != id }
        return (scope.map(\.sortOrder).max() ?? -1) + 1
    }

    /// Each scope numbers itself from zero, independently of every other.
    private func renumber() {
        for scope in Set(items.map(\.parentFolderID)) {
            let members = items.filter { $0.parentFolderID == scope }.sortedForDisplay()
            for (index, member) in members.enumerated() {
                guard let position = items.firstIndex(where: { $0.id == member.id }) else { continue }
                items[position].sortOrder = index
            }
        }
    }
}
