import Foundation

/// A drop-in repository for previews, unit tests and the `-inMemoryStore`
/// launch argument. Deliberately mirrors `SwiftDataLauncherRepository`'s
/// ordering and timestamp behaviour so tests written against one hold for both.
@MainActor
final class InMemoryLauncherRepository: LauncherRepository {
    private var items: [LauncherItem]
    private let now: @Sendable () -> Date

    init(items: [LauncherItem] = [], now: @escaping @Sendable () -> Date = { .now }) {
        self.now = now
        self.items = items
            .sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
            .enumerated()
            .map { index, item in
                var updated = item
                updated.sortOrder = index
                return updated
            }
    }

    func fetchAll() throws -> [LauncherItem] { items }

    @discardableResult
    func add(_ draft: LauncherItemDraft) throws -> LauncherItem {
        let timestamp = now()
        let item = LauncherItem(
            name: draft.name,
            launchURL: draft.launchURL,
            fallbackURL: draft.fallbackURL,
            sortOrder: (items.map(\.sortOrder).max() ?? -1) + 1,
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
        item.name = draft.name
        item.launchURL = draft.launchURL
        item.fallbackURL = draft.fallbackURL
        item.iconData = draft.iconData
        item.isDemo = draft.isDemo
        item.modifiedAt = now()
        items[index] = item
    }

    func delete(id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw LauncherRepositoryError.notFound
        }
        items.remove(at: index)
        renumber()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        guard !items.isEmpty else { return }
        items.move(fromOffsets: source, toOffset: destination)
        renumber()
    }

    func removeAll() throws {
        items.removeAll()
    }

    func replaceAll(with drafts: [LauncherItemDraft]) throws {
        let timestamp = now()
        items = drafts.enumerated().map { index, draft in
            LauncherItem(
                name: draft.name,
                launchURL: draft.launchURL,
                fallbackURL: draft.fallbackURL,
                sortOrder: index,
                iconData: draft.iconData,
                isDemo: draft.isDemo,
                createdAt: timestamp,
                modifiedAt: timestamp
            )
        }
    }

    private func renumber() {
        items = items.enumerated().map { index, item in
            var updated = item
            updated.sortOrder = index
            return updated
        }
    }
}
