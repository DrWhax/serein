// Port of ts/axo/AxoDragRegion.dom.tsx (+ AxoDragRegions.css): marks a view as a window
// drag region (Electron `-webkit-app-region: drag`): dragging it moves the window.
// Overlays (menus, call bars) suspend the non-`always` regions with
// `.axoDisableDragRegions(_:)` (upstream useDisableDragRegions).

import SwiftUI

public enum AxoDragRegion {
    /// `<AxoDragRegion.Root always>`
    public struct Root<Content: View>: View {
        let always: Bool
        let content: Content
        @Environment(\.axoDragRegionsDisabled) var disabled

        /// - Parameter always: stays draggable while drag regions are disabled (title bars).
        public init(always: Bool = false, @ViewBuilder content: () -> Content) {
            self.always = always
            self.content = content()
        }

        public var body: some View {
            if always || !disabled {
                content.gesture(WindowDragGesture())
            } else {
                content
            }
        }
    }
}

extension EnvironmentValues {
    /// Set while an overlay covers drag regions (`useDisableDragRegions`).
    @Entry public var axoDragRegionsDisabled: Bool = false
}

extension View {
    /// Suspends the non-`always` AxoDragRegions in this subtree while `condition` holds.
    public func axoDisableDragRegions(_ condition: Bool) -> some View {
        environment(\.axoDragRegionsDisabled, condition)
    }
}
