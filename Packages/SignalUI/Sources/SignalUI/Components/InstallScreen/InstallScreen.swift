// Ports of ts/components/installScreen/InstallScreenSignalLogo, InstallScreenLinkInProgressStep
// and InstallScreenErrorStep (stylesheets/components/InstallScreen*.scss, the `install-screen`
// mixin): full-window steps of linking this device.

import AppKit
import SignalI18n
import SwiftUI

/// Where this view sits in the window, for CSS `position: absolute` against the viewport
/// (the install screen's logo); zero when the view fills the window.
public struct ViewportOriginKey: EnvironmentKey { public static let defaultValue = CGPoint.zero }

/// The viewport's size, when this view does not fill it (see `viewportOrigin`).
public struct ViewportSizeKey: EnvironmentKey { public static let defaultValue: CGSize? = nil }

extension EnvironmentValues {
    public var viewportOrigin: CGPoint {
        get { self[ViewportOriginKey.self] }
        set { self[ViewportOriginKey.self] = newValue }
    }
    public var viewportSize: CGSize? {
        get { self[ViewportSizeKey.self] }
        set { self[ViewportSizeKey.self] = newValue }
    }
}

/// A React portal into `document.body`: `content` laid over the whole viewport. Under an
/// `axoViewport()` the portal measures where it sits in it; otherwise it uses the
/// `viewportOrigin` / `viewportSize` environment (zero / its own bounds).
struct ViewportPortal<Portal: View>: ViewModifier {
    let portal: Portal
    @Environment(\.viewportOrigin) var origin
    @Environment(\.viewportSize) var size
    @Environment(\.hasAxoViewport) var hasViewport
    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if hasViewport {
                GeometryReader { g in
                    let o = g.frame(in: .named(AxoViewport.coordinateSpace)).origin
                    placed(origin: o)
                }
            } else {
                placed(origin: origin)
            }
        }
    }
    func placed(origin: CGPoint) -> some View {
        portal.frame(width: size?.width, height: size?.height)
            .frame(maxWidth: size == nil ? .infinity : nil, maxHeight: size == nil ? .infinity : nil)
            .offset(x: -origin.x, y: -origin.y)
    }
}

/// The window's content (`document.body`): portals below it cover this view.
struct AxoViewport: ViewModifier {
    static let coordinateSpace = "axoViewport"
    func body(content: Content) -> some View {
        GeometryReader { g in
            content
                .environment(\.viewportSize, g.size)
                .environment(\.hasAxoViewport, true)
        }
        .coordinateSpace(.named(Self.coordinateSpace))
    }
}

extension EnvironmentValues {
    @Entry var hasAxoViewport = false
}

extension View {
    func viewportPortal(@ViewBuilder _ portal: () -> some View) -> some View { modifier(ViewportPortal(portal: portal())) }
    /// Marks this view as the viewport that `viewportPortal` content covers (the window root).
    public func axoViewport() -> some View { modifier(AxoViewport()) }
}

/// `InstallScreenSignalLogo`: `absolute inset-s-8 top-[calc(35px+var(--title-bar-drag-area-height))]`.
/// Placed against the viewport, or (`relativeToViewport: false`) against its parent, which
/// InstallScreenUpdateDialog makes `position: relative`.
public struct InstallScreenSignalLogo: View {
    let relativeToViewport: Bool
    @Environment(\.titleBarDragAreaHeight) var dragAreaHeight
    @Environment(\.viewportOrigin) var viewportOrigin
    public init(relativeToViewport: Bool = true) { self.relativeToViewport = relativeToViewport }
    public var body: some View {
        let origin = relativeToViewport ? viewportOrigin : .zero
        AxoBrand.LogoAndWordMark(maxWidth: 112)
            .padding(.leading, 32 - origin.x)
            .padding(.top, 35 + dragAreaHeight - origin.y)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityHidden(true)
    }
}

/// The `install-screen` mixin: the full window, content centred, gray-02 / gray-95.
struct InstallScreenFrame<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    static var background: AxoColor { AxoColor(light: LegacyColor.gray02, dark: LegacyColor.gray95) }
    static var text: AxoColor { AxoColor(light: LegacyColor.black, dark: LegacyColor.white) }
    var body: some View {
        ZStack {
            Rectangle().fill(Self.background)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            InstallScreenSignalLogo()
        }
        .overlay(alignment: .top) { TitlebarDragArea() }
    }

    /// `h1`: font-title-2.
    static func h1(_ text: String) -> some View {
        CSSText(text, style: LegacyType.title2(), alignment: .center, color: Self.text).accessibilityAddTraits(.isHeader)
    }

    /// `h2`: font-body-1.
    static func h2(_ text: String, color: AxoColor = text) -> some View {
        CSSText(text, style: LegacyType.body1(), alignment: .center, color: color)
    }
}

public struct InstallScreenLinkInProgressStep: View {
    @Environment(\.i18n) var i18n
    public init() {}
    public var body: some View {
        InstallScreenFrame {
            VStack(spacing: 0) {
                Spinner(svgSize: .normal, size: 50)
                InstallScreenFrame<EmptyView>.h1(i18n("icu:initialSync")).padding(.top, 18)
                InstallScreenFrame<EmptyView>.h2(i18n("icu:initialSync__subtitle"),
                                                 color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// `InstallScreenError`
public enum InstallScreenError: String, Sendable, CaseIterable {
    case tooManyDevices = "TooManyDevices"
    case tooOld = "TooOld"
    case connectionFailed = "ConnectionFailed"
    case qrCodeFailed = "QRCodeFailed"
}

public struct InstallScreenErrorStep: View {
    let error: InstallScreenError
    let quit: () -> Void
    let tryAgain: () -> Void
    @Environment(\.i18n) var i18n

    static let downloadURL = URL(string: "https://signal.org/download")!
    /// `LINK_SIGNAL_DESKTOP`
    static let desktopSupportURL = URL(string: "https://support.signal.org/hc/articles/360007320451#desktop_multiple_device")!

    public init(error: InstallScreenError, quit: @escaping () -> Void = {}, tryAgain: @escaping () -> Void = {}) {
        self.error = error
        self.quit = quit
        self.tryAgain = tryAgain
    }

    var content: (message: String, button: String, action: () -> Void, showQuit: Bool) {
        switch error {
        case .tooManyDevices: (i18n("icu:installTooManyDevices"), i18n("icu:installTryAgain"), tryAgain, false)
        case .tooOld: (i18n("icu:installTooOld"), i18n("icu:upgrade"), { NSWorkspace.shared.open(Self.downloadURL) }, true)
        case .connectionFailed: (i18n("icu:installConnectionFailed"), i18n("icu:installTryAgain"), tryAgain, false)
        case .qrCodeFailed: (i18n("icu:installUnknownError"), i18n("icu:Install__learn-more"), { NSWorkspace.shared.open(Self.desktopSupportURL) }, true)
        }
    }

    public var body: some View {
        let c = content
        InstallScreenFrame {
            VStack(spacing: 0) {
                InstallScreenFrame<EmptyView>.h1(i18n("icu:installErrorHeader"))
                InstallScreenFrame<EmptyView>.h2(c.message)
                HStack(spacing: 16) {
                    LegacyButton(c.button, action: c.action)
                    if c.showQuit { LegacyButton(i18n("icu:quit"), variant: .secondary, action: quit) }
                }
                .padding(.top, 16)
            }
            .padding(.horizontal, 32)
        }
    }
}
