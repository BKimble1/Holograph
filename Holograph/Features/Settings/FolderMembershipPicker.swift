import SwiftUI

/// Adds existing tiles to a folder.
///
/// Adding, not moving: everything here stays on the main launcher and simply
/// gains a second way to be reached. The list says so, because "add to folder"
/// reads like "take out of the launcher" to anybody who has used a Home Screen.
@MainActor
struct FolderMembershipPicker: View {
    let folder: LauncherItem
    let candidates: [LauncherItem]
    let onAdd: (LauncherItem) -> Void

    @Environment(\.dismiss) private var dismiss
    /// What has been added while this is open, so a row can say so without the
    /// list rearranging underneath the user's finger.
    @State private var added: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if candidates.isEmpty {
                        Text("Everything is already in this folder.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(candidates) { item in
                            row(for: item)
                        }
                    }
                } footer: {
                    Text("Whatever you add stays on the main launcher as well. A folder groups tiles; it does not take them away.")
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
            .navigationTitle("Add to \(folder.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(HoloTheme.cyanBright)
        .preferredColorScheme(.dark)
        .presentationBackground(.ultraThinMaterial)
        .accessibilityIdentifier(AccessibilityID.folderMemberPicker)
    }

    private func row(for item: LauncherItem) -> some View {
        Button {
            onAdd(item)
            added.insert(item.id)
        } label: {
            HStack(spacing: 14) {
                IconArtworkView(item: item, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .foregroundStyle(.primary)
                    Text(item.kind.noun.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: added.contains(item.id) ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(added.contains(item.id) ? HoloTheme.cyanBright : .secondary)
            }
        }
        .disabled(added.contains(item.id))
        .accessibilityIdentifier(AccessibilityID.folderCandidate(item.name))
        .accessibilityLabel("\(item.name), \(item.kind.noun)")
        .accessibilityHint(added.contains(item.id) ? "Already added." : "Adds \(item.name) to \(folder.name).")
    }
}

#Preview("Add to a folder") {
    SheetPreviewHost { harness in
        FolderMembershipPicker(
            folder: LauncherItem(kind: .folder, name: "Work"),
            candidates: harness.model.items,
            onAdd: { _ in }
        )
    }
}
