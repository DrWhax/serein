// Theme selection (upstream ThemeType + AxoTheme): the user setting (system / light /
// dark) and the calling UI's force-dark override, applied as the SwiftUI colour scheme.

import SwiftUI

public enum ThemeSetting: String, Sendable, CaseIterable {
    case system, light, dark
}

struct ForceDarkKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Set by `.axoForceDark()` (calling screens); descendants stay dark whatever the setting.
    public var axoForceDark: Bool {
        get { self[ForceDarkKey.self] }
        set { self[ForceDarkKey.self] = newValue }
    }
}

public struct AxoTheme<Content: View>: View {
    let setting: ThemeSetting
    let content: Content
    @Environment(\.colorScheme) var systemScheme

    public init(_ setting: ThemeSetting, @ViewBuilder content: () -> Content) {
        self.setting = setting
        self.content = content()
    }

    public var body: some View {
        content.environment(\.colorScheme, scheme)
    }

    var scheme: ColorScheme {
        switch setting {
        case .system: systemScheme
        case .light: .light
        case .dark: .dark
        }
    }
}

extension View {
    /// Upstream `AxoTheme.ForceDark` / calling's dark-only UI.
    public func axoForceDark() -> some View {
        environment(\.colorScheme, .dark).environment(\.axoForceDark, true)
    }
}
