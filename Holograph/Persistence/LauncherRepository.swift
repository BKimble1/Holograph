import Foundation

enum LauncherRepositoryError: LocalizedError, Equatable {
    case notFound
    case storeUnavailable(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "That item is no longer in your launcher."
        case .storeUnavailable(let reason):
            return "Your launcher library couldn’t be opened. \(reason)"
        case .writeFailed(let reason):
            return "Your change couldn’t be saved. \(reason)"
        }
    }
}

/// The only door between the UI and storage.
///
/// Main-actor isolated because the SwiftData implementation is backed by a
/// `ModelContext` bound to the main context; the in-memory implementation
/// matches the contract so previews and tests behave identically.
@MainActor
protocol LauncherRepository: AnyObject {
    /// Everything, flat. Callers scope it with `rootItems` / `children(of:)`,
    /// which keeps the store simple and the filtering testable in isolation.
    func fetchAll() throws -> [LauncherItem]
    @discardableResult func add(_ draft: LauncherItemDraft) throws -> LauncherItem
    func update(id: UUID, with draft: LauncherItemDraft) throws
    /// Deleting a folder ungroups whatever it held rather than taking it down
    /// with it. Nobody expects a folder to be a shredder.
    func delete(id: UUID) throws
    /// Reorders within one scope — the root wall, or a single folder — because
    /// the two orderings are independent of each other.
    func move(fromOffsets source: IndexSet, toOffset destination: Int, in parent: UUID?) throws
    /// Moves one item between the root wall and a folder, or between folders.
    func setParent(of id: UUID, to parent: UUID?) throws
    func removeAll() throws
    func replaceAll(with drafts: [LauncherItemDraft]) throws
}
