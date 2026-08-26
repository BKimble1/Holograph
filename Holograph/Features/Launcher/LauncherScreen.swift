import SwiftUI

/// The one screen this app has.
@MainActor
struct LauncherScreen: View {
    @Environment(LauncherViewModel.self) private var model
    @Environment(HoloMotion.self) private var motion
    @Environment(AppServices.self) private var services

    @State private var settingsRoute: SettingsRoute?
    @State private var isSettingsPresented = false
    @FocusState private var isStageFocused: Bool
    @AppStorage(AirGesturePreferences.enabledKey) private var airGesturesEnabled = false
    @AppStorage(ClapPreferences.enabledKey) private var clapToOpenEnabled = false
    @AppStorage(HeadTrackingPreferences.enabledKey) private var headTrackingEnabled = false

    var body: some View {
        // The backdrop is a sibling of the stage rather than a layer inside it.
        // A GeometryReader is laid out *within* the safe area and then pinned to
        // proxy.size, so anything inside it has no inset left to expand into —
        // `ignoresSafeArea` there does nothing and the glow ends on a hard line
        // along the top edge. Out here it bleeds to the physical edges, while
        // the stage and its controls keep their safe-area geometry.
        ZStack {
            // The furthest layer, and so the slowest: the environment behind
            // the wall drifts a little as the viewer moves, which is most of
            // what sells the depth.
            HoloBackgroundView()
                .offset(scaledPerspective.offset(depth: 0.30, travel: 34))

            GeometryReader { proxy in
                let layout = LauncherLayout(size: proxy.size)

                ZStack {
                    // A folder lights a pane of glass over the wall rather than
                    // replacing it, so the environment stays visible behind.
                    if let folder = model.openFolder {
                        FolderStageView(
                            folder: folder,
                            itemCount: model.itemCount(inFolder: folder.id),
                            isEmpty: model.isEmpty,
                            onClose: { withAnimation(motion.transition) { model.closeFolder() } }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }

                    stage(layout: layout)
                        // The wall itself: nearer than the background, so it
                        // moves more, and turned very slightly towards wherever
                        // the viewer is sitting.
                        .offset(scaledPerspective.offset(depth: 1.0, travel: 18))
                        .rotation3DEffect(
                            .degrees(scaledPerspective.rotation(maximum: 4.5)),
                            axis: (x: 0, y: 1, z: 0),
                            anchor: .center,
                            anchorZ: 0,
                            perspective: 0.5
                        )
                        .rotation3DEffect(
                            .degrees(-scaledPerspective.y * scaledPerspective.strength * 2.6),
                            axis: (x: 1, y: 0, z: 0),
                            anchor: .center,
                            anchorZ: 0,
                            perspective: 0.5
                        )

                    if model.openFolder == nil {
                        settingsButton
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(.trailing, layout.isCompact ? 16 : 26)
                            .padding(.top, layout.isCompact ? 12 : 18)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .animation(motion.transition, value: model.openFolderID)
            }
        }
        .background(HoloTheme.backgroundDeep.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .focusable()
        .focusEffectDisabled()
        .focused($isStageFocused)
        .onKeyPress(.leftArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.rightArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.return) { activateSelected(); return .handled }
        .onKeyPress(.space) { activateSelected(); return .handled }
        .onKeyPress(.escape) {
            guard model.isFolderOpen else { return .ignored }
            withAnimation(motion.transition) { model.closeFolder() }
            return .handled
        }
        .onAppear { isStageFocused = true }
        // The camera and the microphone run only while the launcher is on
        // screen, switched on, and the scene is active — never behind Settings,
        // and never in the background.
        .onChange(of: airGesturesEnabled, initial: true) { _, _ in updateAirGestures() }
        .onChange(of: clapToOpenEnabled, initial: true) { _, _ in updateClapListening() }
        .onChange(of: headTrackingEnabled, initial: true) { _, _ in updateHeadTracking() }
        .onChange(of: motion.isSceneActive) { _, _ in updateAmbientInput() }
        .onChange(of: isSettingsPresented) { _, _ in updateAmbientInput() }
        .onChange(of: model.browsing?.id) { _, _ in updateAmbientInput() }
        .onDisappear {
            services.airGestures.stop()
            services.claps.stop()
            services.headTracking.stop()
        }
        .sheet(isPresented: $isSettingsPresented, onDismiss: { settingsRoute = nil }) {
            SettingsSheet(initialRoute: settingsRoute)
                .environment(model)
                .environment(motion)
        }
        .fullScreenCover(item: browsingBinding) { session in
            HoloBrowserHost(
                session: session,
                launcher: services.launcher,
                onClose: { model.closeBrowser() }
            )
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
                    present(route: nil)
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
                folderCounts: model.folderCounts,
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

            Text(captionForSelection)
                .font(.system(size: layout.captionFontSize, weight: .semibold, design: .rounded))
                .tracking(2.6)
                .foregroundStyle(HoloTheme.secondaryText.opacity(0.8))
                .accessibilityIdentifier(AccessibilityID.tapToOpen)
        }
        .padding(.top, layout.captionSpacing)
        .animation(motion.transition, value: model.selectedID)
    }

    /// What the caption under the wall says. A folder does not "open" anywhere,
    /// and a website opens here rather than somewhere else; saying so is the
    /// only warning the user gets before a tile behaves differently.
    private var captionForSelection: String {
        switch model.selectedItem?.kind {
        case .folder: return "TAP TO OPEN FOLDER"
        case .website: return "TAP TO BROWSE"
        case .app, .none: return "TAP TO OPEN"
        }
    }

    /// The browser is presented from the model's session, but `fullScreenCover`
    /// wants a binding it can clear when the user swipes it away.
    private var browsingBinding: Binding<BrowsingSession?> {
        Binding(
            get: { model.browsing },
            set: { model.browsing = $0 }
        )
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

    /// How much of the viewing position to actually apply. Reduce Motion and
    /// the test harness both go through `HoloMotion` rather than being decided
    /// again here.
    private var scaledPerspective: HeadPerspective {
        let scale = motion.headParallaxScale
        guard scale > 0 else { return .neutral }
        let live = motion.headPerspective
        return HeadPerspective(x: live.x, y: live.y, strength: live.strength * scale)
    }

    private func updateAmbientInput() {
        updateAirGestures()
        updateClapListening()
        updateHeadTracking()
    }

    /// Whether the launcher is in a position to be watching or listening at all.
    private var isForeground: Bool {
        motion.isSceneActive && !isSettingsPresented && model.browsing == nil
    }

    private func updateAirGestures() {
        guard airGesturesEnabled, isForeground else {
            services.airGestures.stop()
            return
        }

        // Only the two objects are captured, not the view: the handler outlives
        // this body, and a copied view struct would be a stale thing to hold.
        let model = model
        let motion = motion
        services.airGestures.onGesture = { gesture in
            guard !model.isEmpty else { return }
            // Flicks and drags both come through `selectionStep`, so there is
            // exactly one place that decides which way a hand sends the wall.
            withAnimation(motion.transition) {
                if gesture.selectionStep < 0 {
                    model.selectPrevious()
                } else {
                    model.selectNext()
                }
            }
        }
        services.airGestures.start()
    }

    private func updateClapListening() {
        guard clapToOpenEnabled, isForeground else {
            services.claps.stop()
            return
        }

        let model = model
        services.claps.onDoubleClap = {
            guard !model.isEmpty else { return }
            // The same thing tapping the centred tile does, ceremony and all.
            Task { await model.launchSelected() }
        }
        services.claps.start()
    }

    private func updateHeadTracking() {
        let motion = motion
        guard headTrackingEnabled, isForeground else {
            services.headTracking.stop()
            // Whatever the last frame said, straight-on is where a scene nobody
            // is watching belongs.
            withAnimation(.easeOut(duration: 0.45)) { motion.headPerspective = .neutral }
            return
        }
        // Only the object is captured, never the view: this handler outlives
        // any particular body evaluation.
        services.headTracking.onPerspective = { next in
            // No animation: the tracker has already smoothed this, and layering
            // a second smoother on top is what makes head tracking feel like
            // syrup rather than glass.
            motion.headPerspective = next
        }
        services.headTracking.start()
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
