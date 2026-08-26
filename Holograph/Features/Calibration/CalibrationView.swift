import SwiftUI

/// The calibration screens: pick an exercise, do it, keep the result.
@MainActor
struct CalibrationSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(LauncherViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var running: CalibrationModel.Exercise?
    @State private var profile = CalibrationStore.load()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(CalibrationModel.Exercise.allCases) { exercise in
                        Button {
                            running = exercise
                        } label: {
                            row(for: exercise)
                        }
                        .accessibilityIdentifier(AccessibilityID.calibrationExercise(exercise.rawValue))
                    }
                } header: {
                    Text("Calibrate")
                } footer: {
                    Text("Holograph ships with thresholds tuned against an average hand, an average room and an average face. What they cannot know is that you flick from the wrist, sit closer than most, or clap quietly because it is late. Each exercise takes a few seconds and adjusts the launcher to you.")
                }

                if !profile.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            CalibrationStore.clear()
                            profile = CalibrationStore.load()
                        } label: {
                            Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                        }
                        .accessibilityIdentifier(AccessibilityID.calibrationReset)
                    } footer: {
                        Text(profile.measuredAt.map {
                            "Last calibrated \($0.formatted(date: .abbreviated, time: .shortened))."
                        } ?? "")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
            .navigationTitle("Calibration")
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
        .accessibilityIdentifier(AccessibilityID.calibrationSheet)
        .sheet(item: $running) { exercise in
            CalibrationRunView(
                model: CalibrationModel(exercise: exercise, sensor: services.calibration),
                onFinished: { profile = CalibrationStore.load() }
            )
            .environment(model)
        }
    }

    private func row(for exercise: CalibrationModel.Exercise) -> some View {
        HStack(spacing: 14) {
            Image(systemName: exercise.symbol)
                .font(.title3)
                .foregroundStyle(HoloTheme.cyanBright)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.title)
                    .foregroundStyle(.primary)
                Text(status(for: exercise))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func status(for exercise: CalibrationModel.Exercise) -> String {
        let done: Bool
        switch exercise {
        case .hand: done = profile.hasHand
        case .head: done = profile.hasHead
        case .clap: done = profile.hasClap
        }
        return done ? "Calibrated" : "Using defaults"
    }
}

/// One exercise, running.
@MainActor
struct CalibrationRunView: View {
    @State var model: CalibrationModel
    let onFinished: () -> Void

    @Environment(LauncherViewModel.self) private var launcher
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            HoloTheme.backgroundDeep.ignoresSafeArea()
            HoloBackgroundView().opacity(0.7)

            VStack(spacing: 28) {
                Spacer(minLength: 0)

                Image(systemName: model.exercise.symbol)
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(HoloTheme.cyanBright)
                    .shadow(color: HoloTheme.cyan.opacity(0.6), radius: 18)

                Text(model.exercise.title)
                    .font(.system(size: 27, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)

                Text(model.exercise.instruction)
                    .font(.callout)
                    .foregroundStyle(HoloTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 44)

                content

                Spacer(minLength: 0)

                controls
                    .padding(.bottom, 34)
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier(AccessibilityID.calibrationRun)
        .task { await beginIfPermitted() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            Color.clear.frame(height: 84)
        case .measuring:
            VStack(spacing: 12) {
                ProgressView(value: model.progress)
                    .tint(HoloTheme.cyanBright)
                    .frame(maxWidth: 280)
                Text(model.detail)
                    .font(.footnote)
                    .foregroundStyle(HoloTheme.secondaryText)
                    .accessibilityIdentifier(AccessibilityID.calibrationDetail)
            }
            .frame(height: 84)
        case .done(let message):
            message(message, symbol: "checkmark.circle.fill", tint: HoloTheme.cyanBright)
                .accessibilityIdentifier(AccessibilityID.calibrationResult)
        case .failed(let message):
            message(message, symbol: "exclamationmark.triangle.fill", tint: .orange)
                .accessibilityIdentifier(AccessibilityID.calibrationResult)
        }
    }

    private func message(_ text: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
        }
        .frame(height: 84)
    }

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .idle:
            Button("Start") { model.start() }
                .buttonStyle(.borderedProminent)
                .tint(HoloTheme.cyan)
                .accessibilityIdentifier(AccessibilityID.calibrationStart)
        case .measuring:
            Button("Stop") { model.giveUp() }
                .buttonStyle(.bordered)
                .tint(HoloTheme.cyan)
        case .done, .failed:
            HStack(spacing: 14) {
                Button("Try Again") { model.start() }
                    .buttonStyle(.bordered)
                    .tint(HoloTheme.cyan)
                Button("Done") {
                    onFinished()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(HoloTheme.cyan)
                .accessibilityIdentifier(AccessibilityID.calibrationDone)
            }
        }
    }

    /// Calibration needs the same permission the feature it is calibrating
    /// needs, and asking here means somebody can set the launcher up before
    /// turning anything on.
    private func beginIfPermitted() async {
        #if os(iOS)
        if model.exercise.needsCamera, await HoloCameraSource.requestAccess() == false {
            launcher.alert = LauncherAlert(
                title: "Camera access is off",
                message: "Calibrating hand flicks and head position needs the camera. Turn it on for Holograph in the Settings app, under Privacy & Security → Camera."
            )
            dismiss()
            return
        }
        if model.exercise.needsMicrophone, await MicrophoneClapSource.requestAccess() == false {
            launcher.alert = LauncherAlert(
                title: "Microphone access is off",
                message: "Calibrating your clap needs the microphone. Turn it on for Holograph in the Settings app, under Privacy & Security → Microphone."
            )
            dismiss()
            return
        }
        #endif
        model.start()
    }
}

extension CalibrationModel.Exercise: Hashable {}

#Preview("Calibration") {
    SheetPreviewHost { _ in
        CalibrationSheet()
    }
}
