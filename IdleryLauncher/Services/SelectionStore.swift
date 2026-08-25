import Foundation

/// Remembers which app was centred so returning from Settings — or from the app
/// the user just launched — lands on the same icon.
protocol SelectionStoring: AnyObject {
    func loadSelection() -> UUID?
    func saveSelection(_ id: UUID?)
}

final class UserDefaultsSelectionStore: SelectionStoring {
    private enum Key {
        static let selection = "com.idlery.launcher.selectedAppID"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSelection() -> UUID? {
        guard let raw = defaults.string(forKey: Key.selection) else { return nil }
        return UUID(uuidString: raw)
    }

    func saveSelection(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: Key.selection)
        } else {
            defaults.removeObject(forKey: Key.selection)
        }
    }
}

final class InMemorySelectionStore: SelectionStoring {
    private var stored: UUID?

    init(stored: UUID? = nil) {
        self.stored = stored
    }

    func loadSelection() -> UUID? { stored }
    func saveSelection(_ id: UUID?) { stored = id }
}
