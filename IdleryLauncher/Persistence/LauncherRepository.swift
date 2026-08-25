import Foundation

enum LauncherRepositoryError: LocalizedError, Equatable {
    case notFound
    case storeUnavailable(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "That app is no longer in your launcher."
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
    func fetchAll() throws -> [LauncherItem]
    @discardableResult func add(_ draft: LauncherItemDraft) throws -> LauncherItem
    func update(id: UUID, with draft: LauncherItemDraft) throws
    func delete(id: UUID) throws
    func move(fromOffsets source: IndexSet, toOffset destination: Int) throws
    func removeAll() throws
    func replaceAll(with drafts: [LauncherItemDraft]) throws
}
