// App (ts/components/App.dom.tsx): picks the install screen, the standalone registration or
// the inbox, and hosts the window-level layers (global modals, call manager, lightbox, story
// viewer) above it. `.App` is the window's root: the portal target for poppers and the
// title-bar drag strip (TitlebarDragArea) on macOS.

import SwiftUI

public enum AppViewType: Sendable {
    /// Before the app has loaded (`app-loading-screen`).
    case blank
    case inbox
    case installer
    case standalone
}

public struct App<InstallScreen: View, Inbox: View, Overlays: View>: View {
    let appView: AppViewType
    let renderInstallScreen: () -> InstallScreen
    let renderInbox: () -> Inbox
    let renderOverlays: () -> Overlays
    @Environment(\.titleBarDragAreaHeight) var dragAreaHeight

    /// - Parameter renderOverlays: global modal container, call manager, lightbox, story viewer.
    public init(appView: AppViewType, @ViewBuilder renderInstallScreen: @escaping () -> InstallScreen,
                @ViewBuilder renderInbox: @escaping () -> Inbox, @ViewBuilder renderOverlays: @escaping () -> Overlays) {
        self.appView = appView
        self.renderInstallScreen = renderInstallScreen
        self.renderInbox = renderInbox
        self.renderOverlays = renderOverlays
    }

    public var body: some View {
        ZStack {
            switch appView {
            case .blank:
                Rectangle().fill(AxoColor.surfacePrimary)    // app-loading-screen (Phase 3 step 7)
            case .installer, .standalone:  // linked-device only: standalone registration is not offered
                renderInstallScreen()
            case .inbox:
                renderInbox()
            }
            renderOverlays()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { TitlebarDragArea() }
        .axoLayerHost()
    }
}

/// `TitlebarDragArea`: the fixed strip across the top of the window (the hidden title bar's
/// height) that drags the window.
public struct TitlebarDragArea: View {
    @Environment(\.titleBarDragAreaHeight) var height
    public init() {}
    public var body: some View {
        if height > 0 {
            AxoDragRegion.Root(always: true) {
                Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity).frame(height: height)
            }
            .accessibilityHidden(true)
        }
    }
}
