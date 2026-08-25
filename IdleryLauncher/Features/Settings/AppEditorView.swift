import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Add or edit one launcher entry, with a live holographic preview of the
/// result sitting at the top of the form.
@MainActor
struct AppEditorView: View {
    @State private var editor: AppEditorViewModel
    @State private var photoItem: PhotosPickerItem?
    @State private var isImportingFile = false
    @State private var testResult: TestLaunchResult?

    @Environment(LauncherViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    init(target: EditorTarget, services: AppServices) {
        _editor = State(
            initialValue: AppEditorViewModel(
                item: target.existingItem,
                iconProcessor: services.iconProcessor,
                metadataProvider: services.metadataProvider
            )
        )
    }

    var body: some View {
        Form {
            previewSection
            detailsSection
            iconSection
            appStoreSection
            testSection
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(editor.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier(AccessibilityID.editorCancel)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save", action: save)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier(AccessibilityID.editorSave)
            }
        }
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: handleFileImport
        )
        .onChange(of: photoItem) { _, newValue in
            guard let newValue else { return }
            Task { await loadPhoto(newValue) }
        }
        .alert(
            testResult?.title ?? "",
            isPresented: Binding(
                get: { testResult != nil },
                set: { if !$0 { testResult = nil } }
            ),
            presenting: testResult
        ) { _ in
            Button("OK", role: .cancel) { testResult = nil }
        } message: { result in
            Text(result.message)
        }
    }

    // MARK: - Sections

    private var previewSection: some View {
        Section {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(HoloTheme.backgroundDeep)
                RadialGradient(
                    gradient: Gradient(colors: [HoloTheme.cyan.opacity(0.22), .clear]),
                    center: .center,
                    startRadius: 0,
                    endRadius: 160
                )
                VStack(spacing: 10) {
                    HolographicIconView(item: editor.previewItem, size: 132, intensity: 1)
                    HoloPedestalView(width: 168, intensity: 0.85)
                        .frame(height: 22)
                        .padding(.top, -14)
                    Text(editor.previewItem.name)
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                }
                .padding(.vertical, 22)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 268)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .accessibilityHidden(true)
        } header: {
            Text("Preview")
        }
    }

    private var detailsSection: some View {
        Section {
            LabeledField(title: "Name", error: editor.showsValidation ? editor.nameError : nil) {
                TextField("Field Notes", text: $editor.name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier(AccessibilityID.editorName)
            }

            LabeledField(title: "Launch link", error: editor.showsValidation ? editor.launchURLError : nil) {
                TextField("idler-offrent://launch", text: $editor.launchURLText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier(AccessibilityID.editorLaunchURL)
            }

            LabeledField(title: "Fallback link (optional)", error: editor.showsValidation ? editor.fallbackURLError : nil) {
                TextField("https://apps.apple.com/app/id000000000", text: $editor.fallbackURLText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier(AccessibilityID.editorFallbackURL)
            }
        } header: {
            Text("Details")
        } footer: {
            Text("The launch link is the URL scheme the target app registers, for example idler-offrent://launch. The fallback opens when that link isn’t available — an App Store page or website works well.")
        }
    }

    private var iconSection: some View {
        Section {
            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
            }

            Button {
                isImportingFile = true
            } label: {
                Label("Choose from Files", systemImage: "folder")
            }

            if editor.iconData != nil {
                Button(role: .destructive) {
                    editor.clearIcon()
                } label: {
                    Label("Remove Icon", systemImage: "xmark.circle")
                }
            }

            if editor.isImportingIcon {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing icon…").foregroundStyle(.secondary)
                }
            }

            if let iconError = editor.iconError {
                Text(iconError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Icon")
        } footer: {
            Text("Images are cropped to a square and resized so your library stays small. Without an icon the launcher shows the app’s initials.")
        }
    }

    private var appStoreSection: some View {
        Section {
            TextField("https://apps.apple.com/app/id000000000", text: $editor.appStoreLinkText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier(AccessibilityID.editorAppStoreLink)

            Button {
                Task { await editor.lookUpAppStoreLink() }
            } label: {
                if case .looking = editor.prefillState {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking up…")
                    }
                } else {
                    Label("Look Up Name and Icon", systemImage: "sparkle.magnifyingglass")
                }
            }
            .disabled(!editor.canLookUpAppStoreLink || editor.prefillState == .looking)
            .accessibilityIdentifier(AccessibilityID.editorLookUp)

            switch editor.prefillState {
            case .succeeded(let message):
                Text(message).font(.footnote).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.red)
            case .idle, .looking:
                EmptyView()
            }
        } header: {
            Text("Prefill from the App Store")
        } footer: {
            Text("Optional. Paste an App Store link to borrow the app’s name and artwork. This never sets the launch link — App Store links open the store, not the app.")
        }
    }

    private var testSection: some View {
        Section {
            Button {
                Task { await runTestLaunch() }
            } label: {
                Label("Test Launch", systemImage: "arrow.up.forward.app")
            }
            .disabled(editor.validatedLaunchURL == nil)
            .accessibilityIdentifier(AccessibilityID.editorTestLaunch)
        } footer: {
            Text("Asks iPadOS to open the launch link right now and reports exactly what happened.")
        }
    }

    // MARK: - Behaviour

    private func save() {
        guard let draft = editor.makeDraft() else { return }
        if let existing = editor.existingItem {
            model.update(id: existing.id, with: draft)
        } else {
            model.add(draft)
        }
        dismiss()
    }

    private func runTestLaunch() async {
        guard let url = editor.validatedLaunchURL else { return }
        let opened = await model.testLaunch(url)
        testResult = TestLaunchResult(
            succeeded: opened,
            name: editor.trimmedName.isEmpty ? "This link" : editor.trimmedName,
            url: url
        )
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        await editor.importIcon(from: data)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return }
            Task { await editor.importIcon(from: data) }
        case .failure:
            break
        }
    }
}

/// A titled form row with room for an inline validation message.
@MainActor
private struct LabeledField<Content: View>: View {
    let title: String
    let error: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(AccessibilityID.editorValidationMessage)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview("Add an app") {
    SheetPreviewHost { harness in
        NavigationStack {
            AppEditorView(target: .add, services: harness.services)
        }
    }
}

#Preview("Edit an app") {
    SheetPreviewHost { harness in
        NavigationStack {
            AppEditorView(
                target: .edit(harness.model.items.first ?? LauncherItem.previewItems()[0]),
                services: harness.services
            )
        }
    }
}
