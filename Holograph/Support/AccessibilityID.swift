import Foundation

/// Stable identifiers shared between the app and its UI tests.
///
/// Keeping them in one place means a rename shows up as a compile error in the
/// app target rather than a mysterious UI-test failure.
enum AccessibilityID {
    static let loadingScreen = "loading.screen"
    static let poweredByIdlery = "loading.poweredByIdlery"

    static let carousel = "launcher.carousel"
    static let settingsButton = "launcher.settingsButton"
    static let selectedAppName = "launcher.selectedAppName"
    static let tapToOpen = "launcher.tapToOpen"
    static let emptyStatePlaceholder = "launcher.emptyState"
    static let pageIndicator = "launcher.pageIndicator"

    static let settingsSheet = "settings.sheet"
    static let settingsDone = "settings.done"
    static let addApp = "settings.addApp"
    static let airGestures = "settings.airGestures"
    static let clapToOpen = "settings.clapToOpen"
    static let soundEffects = "settings.soundEffects"
    static let spokenLaunch = "settings.spokenLaunch"
    static let restoreDemoApps = "settings.restoreDemoApps"
    static let removeAllApps = "settings.removeAllApps"
    static let appList = "settings.appList"

    static let editorName = "editor.name"
    static let editorLaunchURL = "editor.launchURL"
    static let editorFallbackURL = "editor.fallbackURL"
    static let editorAppStoreLink = "editor.appStoreLink"
    static let editorLookUp = "editor.lookUp"
    static let editorSave = "editor.save"
    static let editorCancel = "editor.cancel"
    static let editorTestLaunch = "editor.testLaunch"
    static let editorValidationMessage = "editor.validationMessage"

    static let launchFailureSheet = "launchFailure.sheet"
    static let launchFailureEdit = "launchFailure.edit"
    static let launchFailureFallback = "launchFailure.fallback"
    static let launchFailureCancel = "launchFailure.cancel"

    static func carouselItem(_ name: String) -> String { "launcher.item.\(name)" }
    static func appRow(_ name: String) -> String { "settings.row.\(name)" }
    static func appRowMenu(_ name: String) -> String { "settings.row.menu.\(name)" }
    static func appRowEdit(_ name: String) -> String { "settings.row.edit.\(name)" }
    static func appRowDelete(_ name: String) -> String { "settings.row.delete.\(name)" }
    static func appRowMoveUp(_ name: String) -> String { "settings.row.moveUp.\(name)" }
    static func appRowMoveDown(_ name: String) -> String { "settings.row.moveDown.\(name)" }
}
