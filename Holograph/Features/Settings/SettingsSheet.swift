import SwiftUI

/// Settings sits *over* the launcher as a glass sheet rather than replacing it,
/// so the stage stays visible behind and the app keeps one visual identity.
@MainActor
struct SettingsSheet: View {
    let initialRoute: SettingsRoute?

    @Environment(LauncherViewModel.self) private var model
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var editorTarget: EditorTarget?
    @AppStorage(AirGesturePreferences.enabledKey) private var airGesturesEnabled = false
    @AppStorage(ClapPreferences.enabledKey) private var clapToOpenEnabled = false
    @AppStorage(HeadTrackingPreferences.enabledKey) private var headTrackingEnabled = false
    @AppStorage(SoundPreferences.effectsKey) private var soundEffectsEnabled = true
    @AppStorage(SoundPreferences.spokenLaunchKey) private var spokenLaunchEnabled = true

    @State private var pendingDelete: LauncherItem?
    @State private var isConfirmingRemoveAll = false
    @State private var testLaunchResult: TestLaunchResult?

    var body: some View {
        NavigationStack {
            List {
                addSection
                librarySection(for: nil)
                ForEach(model.allItems.folders) { folder in
                    librarySection(for: folder)
                }
                airGestureSection
                headTrackingSection
                clapSection
                soundSection
                maintenanceSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.settingsDone)
                }
            }
            .navigationDestination(item: $editorTarget) { target in
                AppEditorView(target: target, services: services, folders: model.allItems.folders)
            }
        }
        .tint(HoloTheme.cyanBright)
        .preferredColorScheme(.dark)
        .presentationBackground(.ultraThinMaterial)
        .presentationDetents([.large])
        .accessibilityIdentifier(AccessibilityID.settingsSheet)
        .onAppear(perform: applyInitialRoute)
        .alert(
            "Delete \(pendingDelete?.name ?? "app")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) {
                model.delete(id: item.id)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { item in
            Text(deleteMessage(for: item))
        }
        .alert("Remove everything?", isPresented: $isConfirmingRemoveAll) {
            Button("Remove All", role: .destructive) { model.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything you have added — apps, websites and folders — will be removed from the launcher. Nothing is uninstalled from your iPad.")
        }
        .alert(
            testLaunchResult?.title ?? "",
            isPresented: Binding(
                get: { testLaunchResult != nil },
                set: { if !$0 { testLaunchResult = nil } }
            ),
            presenting: testLaunchResult
        ) { _ in
            Button("OK", role: .cancel) { testLaunchResult = nil }
        } message: { result in
            Text(result.message)
        }
    }

    // MARK: - Sections

    /// The two things a user can add. Kept together and at the top, because
    /// "where do I put a new thing" should not be a hunt.
    private var addSection: some View {
        Section {
            Button {
                editorTarget = .add
            } label: {
                Label("Add App or Website", systemImage: "plus.circle.fill")
            }
            .accessibilityIdentifier(AccessibilityID.addApp)

            Button {
                editorTarget = .addFolder
            } label: {
                Label("Create Folder", systemImage: "folder.badge.plus")
            }
            .accessibilityIdentifier(AccessibilityID.addFolder)
        } header: {
            Text("Add")
        }
    }

    /// One section per scope: the wall itself, then each folder. Ordering is
    /// per section because that is exactly how the launcher orders them —
    /// dragging inside a folder must not disturb the wall.
    @ViewBuilder
    private func librarySection(for folder: LauncherItem?) -> some View {
        let contents = folder.map { model.children(of: $0.id) } ?? model.allItems.rootItems

        Section {
            if contents.isEmpty {
                Text(folder == nil
                     ? "Nothing here yet. Add an app or a website to fill the launcher."
                     : "This folder is empty. Use an item’s menu to move it in here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(contents) { item in
                    row(for: item)
                }
                .onMove { source, destination in
                    model.move(fromOffsets: source, toOffset: destination, in: folder?.id)
                }
                .onDelete { offsets in
                    guard let index = offsets.first, contents.indices.contains(index) else { return }
                    pendingDelete = contents[index]
                }
            }
        } header: {
            Text(folder?.name ?? "Main Launcher")
        } footer: {
            if folder == nil {
                Text("Drag to reorder, or use each item’s menu. The order here is the order on the launcher.")
            } else {
                Text("Deleting this folder puts everything in it back on the main launcher — nothing inside is lost.")
            }
        }
    }

    private func row(for item: LauncherItem) -> some View {
        HStack(spacing: 14) {
            IconArtworkView(item: item, size: 44)
                .overlay {
                    RoundedRectangle(cornerRadius: 44 * HoloTheme.tileCornerRatio, style: .continuous)
                        .strokeBorder(HoloTheme.cyan.opacity(0.35), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.body)
                    badge(item.kind.noun.uppercased())
                    if item.isDemo { badge("DEMO") }
                }
                Text(item.subtitle(folderCount: model.itemCount(inFolder: item.id)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // The row's identity sits here rather than on the enclosing stack.
            // An accessibility modifier on a plain container propagates down to
            // every element inside it, which was overwriting the menu's own
            // identifier with the row's and leaving the menu unaddressable.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.appRow(item.name))

            Spacer(minLength: 0)

            rowMenu(for: item)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.8)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(HoloTheme.cyan.opacity(0.22), in: Capsule())
            .foregroundStyle(HoloTheme.cyanBright)
    }

    private func rowMenu(for item: LauncherItem) -> some View {
        Menu {
            Button {
                editorTarget = .edit(item)
            } label: {
                Label(item.isFolder ? "Edit Folder" : "Edit", systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier(AccessibilityID.appRowEdit(item.name))

            if item.kind == .app, item.launchURL != nil {
                Button {
                    Task { await testLaunch(item) }
                } label: {
                    Label("Test Launch", systemImage: "arrow.up.forward.app")
                }
            }

            // Where it lives. Folders are never inside anything, so they are
            // the one kind this does not offer.
            if !item.isFolder, !model.allItems.folders.isEmpty {
                Menu {
                    Button("Main Launcher") { model.setParent(of: item.id, to: nil) }
                        .disabled(item.parentFolderID == nil)
                    ForEach(model.allItems.folders) { folder in
                        Button(folder.name) { model.setParent(of: item.id, to: folder.id) }
                            .disabled(item.parentFolderID == folder.id)
                    }
                } label: {
                    Label("Move To…", systemImage: "folder")
                }
            }

            // Reordering happens within the item's own scope: moving something
            // up inside a folder must not shuffle the wall behind it.
            let scope = item.parentFolderID.map { model.children(of: $0) } ?? model.allItems.rootItems
            if let index = scope.firstIndex(where: { $0.id == item.id }) {
                Button {
                    model.move(fromOffsets: IndexSet(integer: index), toOffset: index - 1, in: item.parentFolderID)
                } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .disabled(index == 0)
                .accessibilityIdentifier(AccessibilityID.appRowMoveUp(item.name))

                Button {
                    model.move(fromOffsets: IndexSet(integer: index), toOffset: index + 2, in: item.parentFolderID)
                } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .disabled(index >= scope.count - 1)
                .accessibilityIdentifier(AccessibilityID.appRowMoveDown(item.name))
            }

            Divider()

            Button(role: .destructive) {
                pendingDelete = item
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier(AccessibilityID.appRowDelete(item.name))
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(HoloTheme.cyanBright)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier(AccessibilityID.appRowMenu(item.name))
        .accessibilityLabel("Actions for \(item.name)")
    }

    /// Switched off until asked for, because it runs the camera. Turning it on
    /// is what asks for permission — nothing is requested at launch.
    private var airGestureSection: some View {
        Section {
            Toggle(isOn: $airGesturesEnabled) {
                Label("Wave to Change Apps", systemImage: "hand.wave")
            }
            .accessibilityIdentifier(AccessibilityID.airGestures)
            .onChange(of: airGesturesEnabled) { _, isOn in
                guard isOn else { return }
                Task { await confirmCameraAccess(for: .airGestures) }
            }
        } header: {
            Text("Air Gestures")
        } footer: {
            Text("Flick a hand left or right in front of the screen, from a foot or two away, and the wall follows your hand. There is a short pause afterwards so you can bring your hand back and set up the next one.\n\nFor a longer journey, put your fingertips together and sweep: the wall comes with you until you open your hand again.\n\nThe camera is used only while the launcher is open — nothing is recorded, and no video leaves the iPad.")
        }
    }

    /// Off by default, like every camera feature here. It shares the camera
    /// with air gestures rather than opening a second one.
    private var headTrackingSection: some View {
        Section {
            Toggle(isOn: $headTrackingEnabled) {
                Label("Head-Tracked 3D", systemImage: "cube.transparent")
            }
            .accessibilityIdentifier(AccessibilityID.headTracking)
            .onChange(of: headTrackingEnabled) { _, isOn in
                guard isOn else { return }
                Task { await confirmCameraAccess(for: .headTracking) }
            }
        } header: {
            Text("Depth")
        } footer: {
            Text("The launcher shifts perspective as you move, so the wall of tiles appears to hang in space behind the display rather than sit on it. The movement is deliberately small.\n\nHolograph estimates roughly where your head is and nothing else. It does not recognise faces, identify anyone, or store any picture of you: each frame is measured on this iPad and thrown away immediately, and no video ever leaves the device. Air gestures and this share one camera, so turning both on costs no more than either.")
        }
    }

    /// Switched off until asked for, because it runs the microphone. Same shape
    /// as the camera switch, and the same bargain: turning it on is what asks.
    private var clapSection: some View {
        Section {
            Toggle(isOn: $clapToOpenEnabled) {
                Label("Clap Twice to Open", systemImage: "hands.clap")
            }
            .accessibilityIdentifier(AccessibilityID.clapToOpen)
            .onChange(of: clapToOpenEnabled) { _, isOn in
                guard isOn else { return }
                Task { await confirmMicrophoneAccess() }
            }
        } header: {
            Text("Clap to Open")
        } footer: {
            Text("Two quick claps open whichever app is in the middle. Holograph listens for the shape of a clap — loud, instant, and alone — so talking and music are ignored.\n\nThe microphone is used only while the launcher is open. Nothing is recorded: each moment of sound becomes a single loudness number and is thrown away, and no audio leaves the iPad.")
        }
    }

    /// Asks for the microphone the moment the switch is turned on, and turns it
    /// back off if the answer is no.
    private func confirmMicrophoneAccess() async {
        #if os(iOS)
        guard await MicrophoneClapSource.requestAccess() else {
            clapToOpenEnabled = false
            model.alert = LauncherAlert(
                title: "Microphone access is off",
                message: MicrophoneClapSource.isAccessDenied
                    ? "Clap to open needs the microphone. Turn it on for Holograph in the Settings app, under Privacy & Security → Microphone."
                    : "Clap to open needs the microphone, and permission was not granted."
            )
            return
        }
        #endif
    }

    /// Which switch asked for the camera, so the explanation names the right
    /// feature when the answer is no.
    private enum CameraFeature {
        case airGestures
        case headTracking

        var name: String {
            switch self {
            case .airGestures: return "Air gestures"
            case .headTracking: return "Head-tracked 3D"
            }
        }
    }

    /// Asks for the camera the moment a switch is turned on, and turns it back
    /// off if the answer is no — a switch that claims to be on while nothing
    /// works is worse than one that refuses.
    private func confirmCameraAccess(for feature: CameraFeature) async {
        #if os(iOS)
        guard await HoloCameraSource.requestAccess() else {
            switch feature {
            case .airGestures: airGesturesEnabled = false
            case .headTracking: headTrackingEnabled = false
            }
            model.alert = LauncherAlert(
                title: "Camera access is off",
                message: HoloCameraSource.isAccessDenied
                    ? "\(feature.name) needs the camera. Turn it on for Holograph in the Settings app, under Privacy & Security → Camera."
                    : "\(feature.name) needs the camera, and permission was not granted."
            )
            return
        }
        #endif
    }

    /// Read straight from defaults by the sound service at the point of use, so
    /// flipping either of these takes effect on the very next tick.
    private var soundSection: some View {
        Section {
            Toggle(isOn: $soundEffectsEnabled) {
                Label("Sound Effects", systemImage: "waveform")
            }
            .accessibilityIdentifier(AccessibilityID.soundEffects)

            Toggle(isOn: $spokenLaunchEnabled) {
                Label("Say the App Name", systemImage: "speaker.wave.2")
            }
            .accessibilityIdentifier(AccessibilityID.spokenLaunch)
        } header: {
            Text("Sound")
        } footer: {
            Text("A tick as the carousel moves, and “Opening…” spoken as an app or website opens. Both play even when the iPad is on silent — turn them off here instead — and neither interrupts what you are already playing. Folders open silently: they are not going anywhere.\n\nThe voice is a neural one that runs entirely on this iPad. Nothing is sent anywhere, no account or connection is involved, and no system voice needs installing.")
        }
    }

    private var maintenanceSection: some View {
        Section {
            Button {
                model.restoreDemoApps()
            } label: {
                Label("Restore Demo Apps", systemImage: "sparkles")
            }
            .accessibilityIdentifier(AccessibilityID.restoreDemoApps)

            Button(role: .destructive) {
                isConfirmingRemoveAll = true
            } label: {
                Label("Remove Everything", systemImage: "trash")
            }
            .disabled(model.allItems.isEmpty)
            .accessibilityIdentifier(AccessibilityID.removeAllApps)
        } header: {
            Text("Library")
        } footer: {
            Text("Restoring demo apps replaces everything in your library — apps, websites and folders — with the five sample tiles. Demo tiles are placeholders; nothing on this iPad answers their links.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: AppInfo.versionDescription)
            VStack(alignment: .leading, spacing: 6) {
                Text("Holograph opens apps you already have installed by using the link each app registers with iPadOS.")
                Text("It never inspects what is installed on your iPad, and nothing you add leaves this device.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func deleteMessage(for item: LauncherItem) -> String {
        switch item.kind {
        case .folder:
            let count = model.itemCount(inFolder: item.id)
            guard count > 0 else { return "\(item.name) will be removed. It is empty." }
            return "\(item.name) will be removed. The \(count == 1 ? "item" : "\(count) items") inside it move back to the main launcher — nothing is deleted."
        case .website:
            return "\(item.name) will be removed from your launcher. The website itself is unaffected."
        case .app:
            return "\(item.name) will be removed from your launcher. The app itself stays installed."
        }
    }

    // MARK: - Behaviour

    private func applyInitialRoute() {
        guard editorTarget == nil, let initialRoute else { return }
        switch initialRoute {
        case .add:
            editorTarget = .add
        case .edit(let id):
            if let item = model.items.first(where: { $0.id == id }) {
                editorTarget = .edit(item)
            }
        }
    }

    private func testLaunch(_ item: LauncherItem) async {
        guard let launchURL = item.launchURL else { return }
        let opened = await model.testLaunch(launchURL)
        testLaunchResult = TestLaunchResult(succeeded: opened, name: item.name, url: launchURL)
    }
}

/// What the editor should be doing when it appears.
enum EditorTarget: Hashable, Identifiable {
    case add
    case addFolder
    case edit(LauncherItem)

    var id: String {
        switch self {
        case .add: return "add"
        case .addFolder: return "addFolder"
        case .edit(let item): return "edit-\(item.id.uuidString)"
        }
    }

    var existingItem: LauncherItem? {
        switch self {
        case .add, .addFolder: return nil
        case .edit(let item): return item
        }
    }

    /// What a *new* entry starts life as. Ignored when editing, where the kind
    /// comes from the entry itself.
    var newItemKind: LauncherItemKind {
        switch self {
        case .addFolder: return .folder
        case .add, .edit: return .app
        }
    }
}

/// The real outcome of a Test Launch — never a canned "success".
struct TestLaunchResult: Identifiable, Equatable {
    let id = UUID()
    let succeeded: Bool
    let name: String
    let url: URL

    var title: String { succeeded ? "\(name) opened" : "\(name) didn’t open" }

    var message: String {
        succeeded
            ? "iPadOS handed \(url.absoluteString) to another app."
            : "iPadOS declined to open \(url.absoluteString). Check that the app is installed and registers that link."
    }
}

enum AppInfo {
    static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

#Preview("Settings — populated") {
    SheetPreviewHost { _ in
        SettingsSheet(initialRoute: nil)
    }
}

#Preview("Settings — nothing added yet") {
    SheetPreviewHost(items: []) { _ in
        SettingsSheet(initialRoute: nil)
    }
}
