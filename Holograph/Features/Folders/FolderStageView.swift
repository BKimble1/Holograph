import SwiftUI

/// The glass plate a folder opens on.
///
/// Opening a folder does not replace the wall — it lights a pane of dark glass
/// over it, names it, and lets the same carousel show what is inside. That is
/// deliberate: reusing the wall means a folder's contents get snapping,
/// keyboard control, VoiceOver, air gestures and clap-to-open exactly as the
/// root does, with none of it written twice. The environment stays visible
/// behind the glass, which is the whole point of opening *over* the stage
/// rather than navigating away from it.
@MainActor
struct FolderStageView: View {
    let folder: LauncherItem
    let itemCount: Int
    let isEmpty: Bool
    let onClose: () -> Void

    @Environment(HoloMotion.self) private var motion

    var body: some View {
        ZStack {
            plate
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                if isEmpty { emptyNote }
                Spacer(minLength: 0)
            }
        }
        .accessibilityIdentifier(AccessibilityID.folderStage)
        // Escape closes, on a hardware keyboard, from anywhere on the stage.
        .background {
            Button("Close Folder", action: onClose)
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    /// Dark glass with a cyan edge — the same material Settings sits on, lit
    /// from its border rather than filled with colour.
    private var plate: some View {
        RoundedRectangle(cornerRadius: 44, style: .continuous)
            .fill(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .overlay {
                RoundedRectangle(cornerRadius: 44, style: .continuous)
                    .fill(HoloTheme.backgroundDeep.opacity(0.42))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 44, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                HoloTheme.cyanBright.opacity(0.55),
                                HoloTheme.cyan.opacity(0.18),
                                HoloTheme.cyanBright.opacity(0.40),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.2
                    )
            }
            .shadow(color: HoloTheme.cyan.opacity(0.35), radius: 30)
            .padding(.horizontal, 18)
            .padding(.vertical, 22)
            .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: HoloTheme.cyan.opacity(0.45), radius: 10)
                    .lineLimit(1)
                Text(itemCount == 1 ? "1 item" : "\(itemCount) items")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(2.0)
                    .textCase(.uppercase)
                    .foregroundStyle(HoloTheme.secondaryText.opacity(0.85))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(folder.name), folder, \(itemCount == 1 ? "1 item" : "\(itemCount) items")")
            .accessibilityIdentifier(AccessibilityID.folderTitle)

            Spacer(minLength: 0)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay { Circle().strokeBorder(HoloTheme.cyan.opacity(0.32), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(folder.name)")
            .accessibilityIdentifier(AccessibilityID.folderClose)
        }
        .padding(.horizontal, 40)
        .padding(.top, 40)
    }

    private var emptyNote: some View {
        VStack(spacing: 8) {
            Text("Nothing in here yet")
                .font(.system(size: 19, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            Text("Add apps and websites to this folder in Settings.")
                .font(.footnote)
                .foregroundStyle(HoloTheme.secondaryText)
        }
        .accessibilityIdentifier(AccessibilityID.folderEmpty)
    }
}

#Preview("Folder stage") {
    ZStack {
        HoloBackgroundView()
        FolderStageView(
            folder: LauncherItem(kind: .folder, name: "Work"),
            itemCount: 4,
            isEmpty: false,
            onClose: {}
        )
    }
    .environment(HoloMotion())
}
