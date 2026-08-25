import Foundation
import Observation
import OSLog
import SwiftUI

/// Presented when a deep link could not be opened.
struct LaunchFailure: Identifiable, Equatable {
    let id = UUID()
    let item: LauncherItem

    var canOfferFallback: Bool { item.fallbackURL != nil }
}

/// A non-blocking problem worth telling the user about (a failed save, a store
/// that could not be read).
struct LauncherAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

/// Owns the carousel's contents, its selection, and the launch ceremony.
///
/// It talks to storage and the system only through injected abstractions, so
/// every behaviour below — including "what happens when the selected app is
/// deleted" — is exercised by unit tests without a simulator.
@MainActor
@Observable
final class LauncherViewModel {
    private(set) var items: [LauncherItem] = []
    private(set) var isLaunching = false
    /// 0...1 while the portal effect plays.
    private(set) var launchProgress: Double = 0

    var launchFailure: LaunchFailure?
    var alert: LauncherAlert?

    /// The centred app. Kept in sync with the scroll position.
    ///
    /// Written through `updateSelection(_:)` rather than a `didSet` observer,
    /// which `@Observable` does not support.
    private(set) var selectedID: UUID?

    private let repository: LauncherRepository
    private let coordinator: LaunchCoordinator
    private let feedback: FeedbackProviding
    private let sound: SoundPlaying
    private let selectionStore: SelectionStoring
    private let motion: HoloMotion
    private let logger = Logger(subsystem: "com.idlery.holograph", category: "launcher")

    init(
        repository: LauncherRepository,
        launcher: AppLaunching,
        feedback: FeedbackProviding,
        sound: SoundPlaying,
        selectionStore: SelectionStoring,
        motion: HoloMotion
    ) {
        self.repository = repository
        self.coordinator = LaunchCoordinator(launcher: launcher)
        self.feedback = feedback
        self.sound = sound
        self.selectionStore = selectionStore
        self.motion = motion
    }

    // MARK: - Derived state

    var isEmpty: Bool { items.isEmpty }

    var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return items.firstIndex { $0.id == selectedID }
    }

    var selectedItem: LauncherItem? {
        guard let selectedIndex else { return nil }
        return items[selectedIndex]
    }

    // MARK: - Loading

    func load() {
        do {
            items = try repository.fetchAll()
        } catch {
            logger.error("Fetch failed: \(error.localizedDescription, privacy: .public)")
            items = []
            alert = LauncherAlert(
                title: "Couldn’t open your library",
                message: error.localizedDescription
            )
        }
        restoreSelectionIfPossible()
    }

    private func restoreSelectionIfPossible() {
        guard !items.isEmpty else {
            updateSelection(nil)
            return
        }
        if let current = selectedID, items.contains(where: { $0.id == current }) { return }
        if let remembered = selectionStore.loadSelection(),
           items.contains(where: { $0.id == remembered }) {
            updateSelection(remembered)
        } else {
            updateSelection(items[items.count / 2].id)
        }
    }

    /// Re-reads storage and keeps the selection sensible if the previously
    /// selected app is gone: we land on whatever now occupies its slot, or the
    /// last app when it was the final one.
    private func reloadPreservingSelection() {
        let previousID = selectedID
        let previousIndex = selectedIndex

        do {
            items = try repository.fetchAll()
        } catch {
            logger.error("Reload failed: \(error.localizedDescription, privacy: .public)")
            alert = LauncherAlert(title: "Couldn’t reload your apps", message: error.localizedDescription)
            return
        }

        guard !items.isEmpty else {
            updateSelection(nil)
            return
        }
        if let previousID, items.contains(where: { $0.id == previousID }) {
            updateSelection(previousID)
            return
        }
        let target = min(max(previousIndex ?? 0, 0), items.count - 1)
        updateSelection(items[target].id)
    }

    // MARK: - Selection

    /// The single write path for the selection: remembers it for next launch and
    /// gives a light tick when the user moves between apps.
    func updateSelection(_ id: UUID?) {
        guard selectedID != id else { return }
        let wasSelected = selectedID != nil
        selectedID = id
        selectionStore.saveSelection(id)
        if wasSelected, id != nil {
            feedback.selectionChanged()
            sound.selectionTick()
        }
    }

    func select(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        updateSelection(id)
    }

    func selectPrevious() {
        guard let index = selectedIndex, index > 0 else { return }
        updateSelection(items[index - 1].id)
    }

    func selectNext() {
        guard let index = selectedIndex, index < items.count - 1 else { return }
        updateSelection(items[index + 1].id)
    }

    /// Tapping a tile: a side tile comes to the centre first, the centred tile
    /// launches. The single place that policy lives, shared by taps, the
    /// keyboard and VoiceOver actions.
    func activate(_ item: LauncherItem, animation: Animation? = nil) async {
        guard item.id != selectedID else {
            await launchSelected()
            return
        }
        if let animation {
            withAnimation(animation) { select(item.id) }
        } else {
            select(item.id)
        }
    }

    // MARK: - Launching

    func launchSelected() async {
        guard let item = selectedItem, !isLaunching else { return }
        await performLaunch(of: item)
    }

    private func performLaunch(of item: LauncherItem) async {
        isLaunching = true
        feedback.launchImpact()
        // Spoken as the portal opens rather than after it: the ceremony and the
        // announcement are the same beat.
        sound.announceLaunch(of: item.name)
        await runPortalCeremony()

        let outcome = await coordinator.launch(item)
        finishCeremony()

        switch outcome {
        case .opened:
            isLaunching = false
        case .failed:
            isLaunching = false
            // Nothing opened, so the announcement is now wrong. Cut it before
            // the alert explains what actually happened.
            sound.cancelSpeech()
            feedback.failure()
            launchFailure = LaunchFailure(item: item)
        }
    }

    /// Used by the "Open Fallback" recovery action.
    func launchFallback(for item: LauncherItem) async {
        guard !isLaunching else { return }
        isLaunching = true
        let outcome = await coordinator.launchFallback(for: item)
        isLaunching = false
        if case .failed = outcome {
            feedback.failure()
            alert = LauncherAlert(
                title: "Fallback didn’t open",
                message: "iPadOS declined to open the fallback link for \(item.name)."
            )
        }
    }

    /// Fires a one-off launch used by the editor's Test Launch button. Does not
    /// touch the carousel's selection or ceremony state.
    func testLaunch(_ url: URL) async -> Bool {
        let probe = LauncherItem(name: "Test", launchURL: url)
        if case .opened = await coordinator.launch(probe) { return true }
        return false
    }

    private func runPortalCeremony() async {
        let duration = motion.launchCeremonyDuration
        withAnimation(.easeOut(duration: duration.seconds)) {
            launchProgress = 1
        }
        try? await Task.sleep(for: duration)
    }

    private func finishCeremony() {
        withAnimation(.easeIn(duration: 0.22)) {
            launchProgress = 0
        }
    }

    // MARK: - Library editing

    func add(_ draft: LauncherItemDraft) {
        perform("Couldn’t add that app") {
            let added = try repository.add(draft)
            reloadPreservingSelection()
            select(added.id)
        }
    }

    func update(id: UUID, with draft: LauncherItemDraft) {
        perform("Couldn’t save your changes") {
            try repository.update(id: id, with: draft)
            reloadPreservingSelection()
        }
    }

    func delete(id: UUID) {
        perform("Couldn’t delete that app") {
            try repository.delete(id: id)
            reloadPreservingSelection()
        }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        perform("Couldn’t reorder your apps") {
            try repository.move(fromOffsets: source, toOffset: destination)
            reloadPreservingSelection()
        }
    }

    func removeAll() {
        perform("Couldn’t remove your apps") {
            try repository.removeAll()
            reloadPreservingSelection()
        }
    }

    func restoreDemoApps() {
        perform("Couldn’t restore the demo apps") {
            try repository.replaceAll(with: DemoContent.drafts())
            updateSelection(nil)
            // A full load re-centres on the middle demo app, matching a fresh
            // first run rather than snapping to the leftmost icon.
            load()
        }
    }

    private func perform(_ failureTitle: String, _ work: () throws -> Void) {
        do {
            try work()
        } catch {
            logger.error("\(failureTitle, privacy: .public): \(error.localizedDescription, privacy: .public)")
            alert = LauncherAlert(title: failureTitle, message: error.localizedDescription)
        }
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
