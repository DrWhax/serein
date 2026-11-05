// Port of ts/axo/AxoTheme.dom.tsx: `AxoTheme.Override` sets (or forces) the colour scheme
// of a subtree; `AxoTheme.Inherit` re-applies the nearest override's scheme to content
// presented elsewhere (upstream: portals; here: popovers, sheets, windows).
//
// The shared Theme/AxoTheme.swift already declares a generic `AxoTheme<Content>` view (the
// app-level ThemeSetting root), so the parts are declared here as AxoThemeOverride /
// AxoThemeInherit, to be exposed as `AxoTheme.Override` / `AxoTheme.Inherit` once AxoTheme
// becomes a namespace (see the porting report).

import SwiftUI

/// `AxoTheme.ThemeOverride`
public enum AxoThemeOverrideValue: String, Sendable, CaseIterable {
    /// Reverts to the app's setting (which inherits from the OS).
    case auto
    case forceLight = "force-light"
    case forceDark = "force-dark"
}

extension EnvironmentValues {
    /// The nearest `AxoTheme.Override` (upstream ThemeOverrideContext).
    @Entry var axoThemeOverride: AxoThemeOverrideValue = .auto
    /// The app's colour scheme, recorded by the outermost override so that `auto` can
    /// escape from an enclosing force-light / force-dark (`scheme-light dark:scheme-dark`).
    @Entry var axoAppColorScheme: ColorScheme? = nil
}

struct AxoThemeOverrideModifier: ViewModifier {
    let theme: AxoThemeOverrideValue
    @Environment(\.colorScheme) var scheme
    @Environment(\.axoAppColorScheme) var appScheme

    func body(content: Content) -> some View {
        let app = appScheme ?? scheme
        let resolved: ColorScheme = switch theme {
        case .auto: app
        case .forceLight: .light
        case .forceDark: .dark
        }
        content
            .environment(\.colorScheme, resolved)
            .environment(\.axoAppColorScheme, app)
            .environment(\.axoThemeOverride, theme)
    }
}

/// `<AxoTheme.Override theme>`
public struct AxoThemeOverride<Content: View>: View {
    let theme: AxoThemeOverrideValue
    let content: Content

    public init(theme: AxoThemeOverrideValue, @ViewBuilder content: () -> Content) {
        self.theme = theme
        self.content = content()
    }

    public var body: some View {
        content.modifier(AxoThemeOverrideModifier(theme: theme))
    }
}

/// `<AxoTheme.Inherit>`: wrap presented content so it takes the active override's scheme.
public struct AxoThemeInherit<Content: View>: View {
    let content: Content
    @Environment(\.axoThemeOverride) var theme

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content.modifier(AxoThemeOverrideModifier(theme: theme))
    }
}
