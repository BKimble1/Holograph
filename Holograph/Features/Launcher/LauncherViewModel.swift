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

/// A website open inside Holograph. Identifiable so a sheet can be driven from
/// it, and carrying the item so the browser can title itself before the page
/// has loaded.
struct BrowsingSession: Identifiable, Equatable, Sendable {
    let id = UUID()
    let item: LauncherItem
    let url: URL
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
    /// Everything in the library, flat. Settings works from this; the wall does
    /// not.
    private(set) var allItems: [LauncherItem] = []
    /// What the wall shows: the root scope, or the open folder's contents.
    private(set) var items: [LauncherItem] = []
    private(set) var isLaunching = false
    /// 0...1 while the portal effect plays.
    private(set) var launchProgress: Double = 0

    /// The folder currently open over the wall, if any.
    private(set) var openFolderID: UUID?
    /// The website currently open in Holograph's own browser, if any.
    var browsing: BrowsingSession?

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
    /// Where the wall was before a folder was opened over it.
    private var rootSelectionBeforeFolder: UUID?

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

    /// The folder open over the wall, if any.
    var openFolder: LauncherItem? {
        guard let openFolderID else { return nil }
        return allItems.first { $0.id == openFolderID }
    }

    var isFolderOpen: Bool { openFolder != nil }

    func children(of folderID: UUID) -> [LauncherItem] {
        allItems.children(of: folderID)
    }

    /// How many things a folder holds, for its caption and its VoiceOver label.
    /// How many things each folder holds, keyed by folder, for the wall's own
    /// accessibility labels.
    var folderCounts: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for folder in allItems where folder.isFolder { counts[folder.id] = 0 }
        for item in allItems {
            guard let parent = item.parentFolderID, counts[parent] != nil else { continue }
            counts[parent, default: 0] += 1
        }
        return counts
    }

    func itemCount(inFolder id: UUID) -> Int {
        allItems.reduce(into: 0) { $0 += ($1.parentFolderID == id ? 1 : 0) }
    }

    /// What the wall should be showing right now.
    private var visibleScope: [LauncherItem] {
        if let openFolderID { return allItems.children(of: openFolderID) }
        return allItems.rootItems
    }

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
            allItems = try repository.fetchAll()
        } catch {
            logger.error("Fetch failed: \(error.localizedDescription, privacy: .public)")
            allItems = []
            alert = LauncherAlert(
                title: "Couldn’t open your library",
                message: error.localizedDescription
            )
        }
        // A folder that no longer exists cannot stay open over the wall.
        if let openFolderID, !allItems.contains(where: { $0.id == openFolderID && $0.isFolder }) {
            self.openFolderID = nil
        }
        items = visibleScope
        restoreSelectionIfPossible()
        prepareAnnouncements()
    }

    /// Warms the voice and renders the library's launch phrases in the
    /// background, so the first app opened after launch is as quick as the
    /// tenth. Nothing waits for this, and nothing breaks if it never finishes.
    private func prepareAnnouncements() {
        let items = allItems
        Task { [sound] in
            await sound.prepareAnnouncements(for: items)
        }
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
            allItems = try repository.fetchAll()
        } catch {
            logger.error("Reload failed: \(error.localizedDescription, privacy: .public)")
            alert = LauncherAlert(title: "Couldn’t reload your library", message: error.localizedDescription)
            return
        }
        if let openFolderID, !allItems.contains(where: { $0.id == openFolderID && $0.isFolder }) {
            self.openFolderID = nil
        }
        items = visibleScope

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
        // Only the wall's own selection is worth remembering between launches;
        // a tile inside a folder would be restored into a scope that is not
        // showing.
        if openFolderID == nil { selectionStore.saveSelection(id) }
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

    // MARK: - Folders

    /// Opens a folder over the wall. The wall keeps its own selection so
    /// closing puts the user back exactly where they were.
    func enterFolder(_ id: UUID) {
        guard let folder = allItems.first(where: { $0.id == id && $0.isFolder }) else { return }
        guard openFolderID == nil else { return }
        rootSelectionBeforeFolder = selectedID
        openFolderID = folder.id
        items = visibleScope
        selectedID = nil
        updateSelection(items.first?.id)
    }

    func closeFolder() {
        guard openFolderID != nil else { return }
        openFolderID = nil
        items = visibleScope
        selectedID = nil
        // Back to the folder tile the user came from, not to wherever the
        // carousel happens to land.
        updateSelection(rootSelectionBeforeFolder ?? items.first?.id)
        rootSelectionBeforeFolder = nil
    }

    // MARK: - Launching

    func launchSelected() async {
        guard let item = selectedItem, !isLaunching else { return }
        await performLaunch(of: item)
    }

    private func performLaunch(of item: LauncherItem) async {
        switch item.activation {
        case .openFolder(let id):
            // A folder stays inside Holograph, so it gets the tick rather than
            // the launch ceremony and the announcement.
            feedback.selectionChanged()
            withAnimation(motion.transition) { enterFolder(id) }
        case .openInHolograph(let url):
            await presentInHolograph(item, url: url)
        case .openExternally:
            await leaveForAnotherApp(item)
        case .unavailable:
            feedback.failure()
            launchFailure = LaunchFailure(item: item)
        }
    }

    /// A website: the same ceremony, but Holograph keeps the user.
    private func presentInHolograph(_ item: LauncherItem, url: URL) async {
        isLaunching = true
        feedback.launchImpact()
        sound.announceLaunch(of: item)
        await runPortalCeremony()
        finishCeremony()
        isLaunching = false
        browsing = BrowsingSession(item: item, url: url)
    }

    private func leaveForAnotherApp(_ item: LauncherItem) async {
        isLaunching = true
        feedback.launchImpact()
        // Spoken as the portal opens rather than after it: the ceremony and the
        // announcement are the same beat.
        sound.announceLaunch(of: item)
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

    /// Closing the Holo Browser. The wall is exactly as it was left.
    func closeBrowser() {
        browsing = nil
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
        perform("Couldn’t add that item") {
            let added = try repository.add(draft)
            reloadPreservingSelection()
            select(added.id)
        }
    }

    func update(id: UUID, with draft: LauncherItemDraft) {
        perform("Couldn’t save your changes") {
            try repository.update(id: id, with: draft)
            reloadPreservingSelection()
            // A rename changes what is said about a tile, so its announcement
            // has to be rendered again.
            prepareAnnouncements()
        }
    }

    func delete(id: UUID) {
        perform("Couldn’t delete that item") {
            try repository.delete(id: id)
            reloadPreservingSelection()
        }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int, in parent: UUID? = nil) {
        perform("Couldn’t reorder your library") {
            try repository.move(fromOffsets: source, toOffset: destination, in: parent)
            reloadPreservingSelection()
        }
    }

    /// Moves an app or website between the root wall and a folder.
    func setParent(of id: UUID, to parent: UUID?) {
        perform("Couldn’t move that item") {
            try repository.setParent(of: id, to: parent)
            reloadPreservingSelection()
        }
    }

    func removeAll() {
        perform("Couldn’t remove your library") {
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
