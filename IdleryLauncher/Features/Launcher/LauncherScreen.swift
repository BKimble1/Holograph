import SwiftUI

/// The one screen this app has.
@MainActor
struct LauncherScreen: View {
    @Environment(LauncherViewModel.self) private var model
    @Environment(HoloMotion.self) private var motion

    @State private var settingsRoute: SettingsRoute?
    @State private var isSettingsPresented = false
    @FocusState private var isStageFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let layout = LauncherLayout(size: proxy.size)

            ZStack {
                HoloBackgroundView()
                stage(layout: layout)
                settingsButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, layout.isCompact ? 16 : 26)
                    .padding(.top, layout.isCompact ? 12 : 18)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(HoloTheme.backgroundDeep)
        .preferredColorScheme(.dark)
        .focusable()
        .focusEffectDisabled()
        .focused($isStageFocused)
        .onKeyPress(.leftArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.rightArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.return) { activateSelected(); return .handled }
        .onKeyPress(.space) { activateSelected(); return .handled }
        .onAppear { isStageFocused = true }
        .sheet(isPresented: $isSettingsPresented, onDismiss: { settingsRoute = nil }) {
            SettingsSheet(initialRoute: settingsRoute)
                .environment(model)
                .environment(motion)
        }
        .alert(
            failureTitle(for: model.launchFailure),
            isPresented: Binding(
                get: { model.launchFailure != nil },
                set: { if !$0 { model.launchFailure = nil } }
            ),
            presenting: model.launchFailure
        ) { failure in
            Button("Edit App") {
                model.launchFailure = nil
                present(route: .edit(failure.item.id))
            }
            .accessibilityIdentifier(AccessibilityID.launchFailureEdit)

            if failure.canOfferFallback {
                Button("Open Fallback") {
                    let item = failure.item
                    model.launchFailure = nil
                    Task { await model.launchFallback(for: item) }
                }
                .accessibilityIdentifier(AccessibilityID.launchFailureFallback)
            }

            Button("Cancel", role: .cancel) { model.launchFailure = nil }
                .accessibilityIdentifier(AccessibilityID.launchFailureCancel)
        } message: { failure in
            Text(failureMessage(for: failure))
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(
                get: { model.alert != nil },
                set: { if !$0 { model.alert = nil } }
            ),
            presenting: model.alert
        ) { _ in
            Button("OK", role: .cancel) { model.alert = nil }
        } message: { alert in
            Text(alert.message)
        }
    }

    // MARK: - Stage

    @ViewBuilder
    private func stage(layout: LauncherLayout) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            if model.isEmpty {
                EmptyLauncherView(tileSize: layout.tileSize) {
                    present(route: .add)
                }
                .transition(.opacity)
            } else {
                carousel(layout: layout)
                caption(layout: layout)
            }

            Spacer(minLength: 0)

            PageIndicator(count: model.items.count, selectedIndex: model.selectedIndex)
                .padding(.bottom, layout.isCompact ? 14 : 26)
        }
        .padding(.horizontal, layout.isCompact ? 8 : 0)
        .animation(motion.transition, value: model.isEmpty)
    }

    private func carousel(layout: LauncherLayout) -> some View {
        ZStack(alignment: .bottom) {
            HolographicCarousel(
                items: model.items,
                selectedID: nonClearingSelectionBinding,
                tileSize: layout.tileSize,
                launchProgress: model.launchProgress,
                onActivate: { item in
                    Task { await model.activate(item, animation: motion.transition) }
                }
            )
            .frame(height: layout.stageHeight)

            HoloPedestalView(
                width: layout.pedestalWidth,
                intensity: model.isLaunching ? 1 : 0.85
            )
            .frame(height: layout.tileSize * 0.17)
            .offset(y: layout.tileSize * 0.06)
            .allowsHitTesting(false)
        }
        .frame(height: layout.stageHeight)
    }

    private func caption(layout: LauncherLayout) -> some View {
        VStack(spacing: 8) {
            Text(model.selectedItem?.name ?? "")
                .font(.system(size: layout.titleFontSize, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: HoloTheme.cyan.opacity(0.45), radius: 12)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityIdentifier(AccessibilityID.selectedAppName)

            Text("TAP TO OPEN")
                .font(.system(size: layout.captionFontSize, weight: .semibold, design: .rounded))
                .tracking(2.6)
                .foregroundStyle(HoloTheme.secondaryText.opacity(0.8))
                .accessibilityIdentifier(AccessibilityID.tapToOpen)
        }
        .padding(.top, layout.captionSpacing)
        .animation(motion.transition, value: model.selectedID)
    }

    private var settingsButton: some View {
        Button {
            present(route: nil)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.settingsButton)
        .accessibilityLabel("Settings")
    }

    // MARK: - Behaviour

    /// `scrollPosition(id:)` writes `nil` while a drag is between two aligned
    /// items. Swallowing those keeps the selected app — and the caption below
    /// it — stable for the whole gesture.
    private var nonClearingSelectionBinding: Binding<UUID?> {
        Binding(
            get: { model.selectedID },
            set: { newValue in
                guard let newValue else { return }
                model.updateSelection(newValue)
            }
        )
    }

    private func moveSelection(by delta: Int) {
        guard !model.isEmpty else { return }
        withAnimation(motion.transition) {
            if delta < 0 {
                model.selectPrevious()
            } else {
                model.selectNext()
            }
        }
    }

    private func activateSelected() {
        Task { await model.launchSelected() }
    }

    private func present(route: SettingsRoute?) {
        settingsRoute = route
        isSettingsPresented = true
    }

    private func failureTitle(for failure: LaunchFailure?) -> String {
        guard let failure else { return "" }
        return "Couldn’t open \(failure.item.name)"
    }

    private func failureMessage(for failure: LaunchFailure) -> String {
        if failure.item.isDemo {
            return "\(failure.item.name) is a demo entry — nothing on this iPad registers \(failure.item.launchTargetDescription). Edit it to point at an app you have installed."
        }
        return "iPadOS declined to open \(failure.item.launchTargetDescription). The app may not be installed, or it may not register that link."
    }
}

/// Where the settings sheet should land when it opens.
enum SettingsRoute: Hashable {
    case add
    case edit(UUID)
}

#Preview("Launcher") {
    LauncherPreviewHost(items: LauncherItem.previewItems())
}

#Preview("Empty launcher") {
    LauncherPreviewHost(items: [])
}
