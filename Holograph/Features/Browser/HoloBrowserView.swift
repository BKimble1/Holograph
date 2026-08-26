import Observation
import SwiftUI
#if canImport(WebKit) && os(iOS)
import WebKit
#endif

/// What the chrome needs to know about the page, without knowing what a page is.
///
/// `@Observable` and free of WebKit types so the chrome can be previewed and
/// driven by a test without a web view anywhere near it.
@MainActor
@Observable
final class HoloBrowserModel {
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var pageTitle: String?
    var currentURL: URL?
    /// Set when a page could not be reached, so the browser says so instead of
    /// showing a blank rectangle.
    var failure: String?

    let item: LauncherItem
    let startURL: URL

    /// Commands the chrome sends to whatever is rendering. Set by the web view
    /// when it appears; harmless no-ops before that and in previews.
    var goBack: () -> Void = {}
    var goForward: () -> Void = {}
    var reload: () -> Void = {}
    /// Non-web links a page asked for, handed on by the policy.
    var openExternally: (URL) -> Void = { _ in }

    init(item: LauncherItem, startURL: URL) {
        self.item = item
        self.startURL = startURL
        self.currentURL = startURL
    }

    var title: String {
        // Before a page has loaded there is no title and often no host either,
        // and "https://" in the bar looks like something went wrong. The tile's
        // own name is the honest thing to show until the page says otherwise.
        if pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           currentURL?.host()?.isEmpty != false {
            return item.name
        }
        let resolved = HoloBrowserPolicy.title(for: currentURL, pageTitle: pageTitle)
        return resolved.isEmpty ? item.name : resolved
    }
}

/// A website, living inside Holograph.
///
/// Deliberately not a Safari hand-off: a website tile promises the site lives
/// in here, and being thrown out to another app the moment it is tapped would
/// break that promise and lose the user's place on the wall.
@MainActor
struct HoloBrowserView: View {
    let model: HoloBrowserModel
    let onClose: () -> Void

    @Environment(HoloMotion.self) private var motion

    var body: some View {
        ZStack {
            HoloTheme.backgroundDeep.ignoresSafeArea()

            VStack(spacing: 0) {
                chrome
                Divider().overlay(HoloTheme.cyan.opacity(0.25))
                content
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier(AccessibilityID.browser)
        // A hardware keyboard is a first-class way to use this: Escape closes,
        // exactly as it does in the folder stage.
        .background {
            Button("Close", action: onClose)
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Chrome

    private var chrome: some View {
        HStack(spacing: 10) {
            control("chevron.backward", label: "Back", enabled: model.canGoBack, action: model.goBack)
                .accessibilityIdentifier(AccessibilityID.browserBack)
            control("chevron.forward", label: "Forward", enabled: model.canGoForward, action: model.goForward)
                .accessibilityIdentifier(AccessibilityID.browserForward)
            control("arrow.clockwise", label: "Reload", enabled: true, action: model.reload)
                .accessibilityIdentifier(AccessibilityID.browserReload)

            titlePlate

            control("xmark", label: "Close", enabled: true, action: onClose)
                .accessibilityIdentifier(AccessibilityID.browserClose)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var titlePlate: some View {
        HStack(spacing: 8) {
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(HoloTheme.cyanBright)
            }
            Text(model.title)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(HoloTheme.cyan.opacity(0.10), in: Capsule())
        .overlay { Capsule().strokeBorder(HoloTheme.cyan.opacity(0.30), lineWidth: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Showing \(model.title)")
        .accessibilityIdentifier(AccessibilityID.browserTitle)
    }

    private func control(
        _ symbol: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? .white.opacity(0.92) : .white.opacity(0.28))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().strokeBorder(HoloTheme.cyan.opacity(enabled ? 0.32 : 0.12), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: - Page

    @ViewBuilder
    private var content: some View {
        #if canImport(WebKit) && os(iOS)
        ZStack {
            HoloWebView(model: model)
            if let failure = model.failure {
                unreachable(failure)
            }
        }
        #else
        unreachable("Web pages need WebKit, which this platform does not have.")
        #endif
    }

    private func unreachable(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(HoloTheme.cyanBright.opacity(0.7))
            Text("Couldn’t load \(model.item.name)")
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
            Text(message)
                .font(.footnote)
                .foregroundStyle(HoloTheme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Try Again", action: model.reload)
                .buttonStyle(.borderedProminent)
                .tint(HoloTheme.cyan)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HoloTheme.backgroundDeep)
        .accessibilityIdentifier(AccessibilityID.browserFailure)
    }
}

#if canImport(WebKit) && os(iOS)

/// The web view itself.
///
/// A persistent data store on purpose: a site the user has signed into should
/// still know them next time, exactly as it would in a browser. That state
/// belongs to WebKit and never touches the launcher's own library.
@MainActor
private struct HoloWebView: UIViewRepresentable {
    let model: HoloBrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        // Sites that would rather show a phone layout on an iPad are told the
        // truth about where they are.
        configuration.defaultWebpagePreferences.preferredContentMode = .recommended

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = UIColor(HoloTheme.backgroundDeep)
        webView.scrollView.backgroundColor = UIColor(HoloTheme.backgroundDeep)

        context.coordinator.observe(webView)
        model.goBack = { [weak webView] in webView?.goBack() }
        model.goForward = { [weak webView] in webView?.goForward() }
        model.reload = { [weak webView] in
            model.failure = nil
            if webView?.url == nil {
                webView?.load(URLRequest(url: model.startURL))
            } else {
                webView?.reload()
            }
        }

        webView.load(URLRequest(url: model.startURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // Stop the page before the view goes: a site left playing media in a
        // torn-down web view keeps the audio session busy.
        webView.stopLoading()
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let model: HoloBrowserModel
        private var observations: [NSKeyValueObservation] = []

        init(model: HoloBrowserModel) {
            self.model = model
        }

        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.canGoBack, options: [.initial, .new]) { [model] view, _ in
                    MainActor.assumeIsolated { model.canGoBack = view.canGoBack }
                },
                webView.observe(\.canGoForward, options: [.initial, .new]) { [model] view, _ in
                    MainActor.assumeIsolated { model.canGoForward = view.canGoForward }
                },
                webView.observe(\.isLoading, options: [.initial, .new]) { [model] view, _ in
                    MainActor.assumeIsolated { model.isLoading = view.isLoading }
                },
                webView.observe(\.title, options: [.initial, .new]) { [model] view, _ in
                    MainActor.assumeIsolated { model.pageTitle = view.title }
                },
                webView.observe(\.url, options: [.initial, .new]) { [model] view, _ in
                    MainActor.assumeIsolated { model.currentURL = view.url ?? model.startURL }
                },
            ]
        }

        func stopObserving() {
            observations.removeAll()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            switch HoloBrowserPolicy.decision(for: navigationAction.request.url) {
            case .allowInHolograph:
                decisionHandler(.allow)
            case .handToSystem(let url):
                decisionHandler(.cancel)
                model.openExternally(url)
            case .block:
                decisionHandler(.cancel)
            }
        }

        /// `target="_blank"` and `window.open`. A browser with one window loads
        /// them here rather than losing them, which is also what keeps the user
        /// inside Holograph.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if case .allowInHolograph = HoloBrowserPolicy.decision(for: navigationAction.request.url),
               navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.failure = nil
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            report(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            report(error)
        }

        private func report(_ error: Error) {
            // Cancellation is what a redirect or a stopped load looks like, and
            // is not worth an error screen.
            let nsError = error as NSError
            guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
            model.failure = error.localizedDescription
        }
    }
}

#endif

/// Owns the browser's model for exactly as long as the cover is up.
///
/// The model has to be created once per session, not once per layout pass: it
/// holds the back/forward state and the closures that drive the web view, and
/// rebuilding it on every body evaluation would reset the page under the user.
@MainActor
struct HoloBrowserHost: View {
    @State private var model: HoloBrowserModel
    private let onClose: () -> Void

    init(session: BrowsingSession, launcher: AppLaunching, onClose: @escaping () -> Void) {
        let model = HoloBrowserModel(item: session.item, startURL: session.url)
        // A page asking for a `tel:` or an app's own scheme still gets what it
        // asked for; it just does not get to take Holograph with it.
        model.openExternally = { url in
            Task { @MainActor in _ = await launcher.open(url) }
        }
        _model = State(initialValue: model)
        self.onClose = onClose
    }

    var body: some View {
        HoloBrowserView(model: model, onClose: onClose)
    }
}
