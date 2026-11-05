// Port of ts/axo/_internal/AxoBaseDialog.dom.tsx: the modal host (full-window layer that
// centres the dialog, with the dimming overlay) and the shared dialog panel styling
// (curved-30, material-dialog, shadow-elevation-3, type-body-medium text-secondary).

import SwiftUI

public enum AxoBaseDialog {
    /// `<AxoBaseDialog.Host>` + overlay: fills the window, dims it, centres `content`.
    public struct Host<Content: View>: View {
        let content: Content
        public init(@ViewBuilder content: () -> Content) { self.content = content() }
        public var body: some View {
            ZStack {
                Rectangle().fill(AxoColor.fillOverlay).ignoresSafeArea()
                WholePointCenter { content.padding(4) }        // m-1
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// `items-center-safe justify-center-safe`: centred, but Chromium paints the (composited,
    /// animated) dialog at whole CSS pixels, rounding its centred origin (199.5 → 200).
    struct WholePointCenter: Layout {
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let child = subviews.first?.sizeThatFits(proposal) ?? .zero
            return CGSize(width: proposal.width ?? child.width, height: proposal.height ?? child.height)
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            guard let child = subviews.first else { return }
            let size = child.sizeThatFits(ProposedViewSize(bounds.size))
            // Math.round (halves up); the 4pt margin is whole, so rounding the padded origin
            // rounds the dialog's.
            func round(_ v: CGFloat) -> CGFloat { (v + 0.5).rounded(.down) }
            child.place(at: CGPoint(x: bounds.minX + round((bounds.width - size.width) / 2), y: bounds.minY + round((bounds.height - size.height) / 2)),
                        proposal: ProposedViewSize(size))
        }
    }

    /// `contentClassName`: the dialog panel. (Its backdrop-blur-thick only shows over
    /// non-uniform content behind the overlay.)
    struct Panel<Content: View>: View {
        let width: CGFloat?
        let content: Content
        /// `focus-visible:axo-focus-ring`: Radix focuses the panel itself when nothing in it can
        /// take the initial focus.
        var focused = false
        var body: some View {
            let shape = SuperellipseRect.curved(30)
            content
                .cssTextColor(.labelSecondary)
                .environment(\.axoInheritedTextSize, (13, 18))    // type-body-medium
                .frame(width: width)
                .background(shape.fill(AxoColor.materialDialog))
                .clipShape(shape)
                .axoShadow(.shadowElevation3, in: shape)
                .axoFocusRing(focused, in: shape)
        }
    }
}
