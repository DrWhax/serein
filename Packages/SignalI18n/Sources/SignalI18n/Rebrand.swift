// A rebranded build (Serein): the strings where upstream's "Signal" / "Signal Desktop" names
// this desktop app are rewritten to the build's name. Strings about the Signal network, the
// phone app, Signal PINs and accounts are left as they are: those still mean Signal.

public struct Rebrand: Sendable {
    /// The app's name, e.g. "Serein".
    public let name: String
    /// Whole-message replacements (ICU source), for every locale.
    public let messages: [String: String]

    public init(name: String, messages: [String: String] = [:]) {
        self.name = name
        self.messages = messages
    }

    /// Keys whose "Signal Desktop" is this app (other "Signal" words in them stay).
    static let desktopKeys: Set<String> = [
        "icu:CompositionArea--sms-only__body", "icu:DeleteDataAndRelinkConfirmationDialog__body", "icu:GroupV2--join--unknown-link-version",
        "icu:InstallScreenUpdateDialog--cannot-update__body", "icu:InstallScreenUpdateDialog--update-required__body",
        "icu:Install__confirm-data-deletion__body", "icu:UnsupportedOSErrorDialog__body", "icu:UnsupportedOSErrorToast",
        "icu:UnsupportedOSWarningDialog__body", "icu:WhatsNew__8.34--0", "icu:aboutSignalDesktop", "icu:audioCallingPermissionNeeded",
        "icu:audioPermissionNeeded", "icu:deleteAllDataBody", "icu:deleteOldIndexedDBData", "icu:expiredWarning", "icu:readOnlyVolume",
        "icu:signalDesktop", "icu:unlinkedWarning", "icu:unregisteredWarning", "icu:videoCallingPermissionNeeded",
    ]

    /// Keys whose every "Signal" is this app.
    static let appKeys: Set<String> = [
        "icu:appMenuQuit", "icu:welcomeToSignal", "icu:cantOpenSignalError", "icu:databaseError__startOldVersion",
        "icu:spellCheckWillBeEnabled", "icu:spellCheckWillBeDisabled", "icu:autoUpdateNewVersionMessage",
        "icu:downloadFullNewVersionMessage", "icu:autoUpdateRestartButtonLabel", "icu:minimizeToTrayNotification--title",
        "icu:minimizeToTrayNotification--body", "icu:calling__presenting--reconnecting--notification-body", "icu:calling__presenting--info",
        "icu:calling__presenting--info--unknown", "icu:calling__presenting--macos-permission-description",
        "icu:calling__presenting--permission-instruction-step3", "icu:ConfirmationDialog__Title--in-call-close-requested",
        "icu:Preferences__LanguageModal__Restart__Title", "icu:Preferences__content-protection--description", "icu:MediaPermissionsModal__step-2",
        "icu:messageLoop", "icu:EntryPoint--signal-logo", "icu:StandaloneRegistration--signal-logo",
        "icu:PlaintextExport--Error--DiskPermssions--Detail", "icu:InstallScreenUpdateDialog--updating-signal",
        "icu:InstallScreenUpdateDialog--auto-update__body", "icu:InstallScreenUpdateDialog--downloaded__body", "icu:cannotUpdateDetail-v2",
        "icu:cannotUpdateRequireManualDetail-v2", "icu:CrashReportDialog__body",
    ]

    /// The ICU source for `key`, rebranded.
    func apply(_ key: String, to source: String) -> String {
        if let message = messages[key] { return message.replacing("{appName}", with: name) }
        if Self.desktopKeys.contains(key) { return source.replacing("Signal Desktop", with: name) }
        if Self.appKeys.contains(key) { return source.replacing("Signal Desktop", with: name).replacing("Signal", with: name) }
        return source
    }
}
