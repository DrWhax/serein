// Port of ts/axo/AxoTooltip.dom.tsx (Radix Tooltip): a dim bubble beside its trigger
// (default side top, align center, sideOffset 6, collision padding 8) with an arrow for
// top/bottom placement; the label is balanced, clamped to 4 lines, 48…192 wide (228 with
// an accessory: keyboard shortcut or timestamp). Opens after 700ms of hover.

import SwiftUI

public enum AxoTooltip {
    public enum Side: Sendable { case top, bottom, inlineStart, inlineEnd }
    public enum Align: Sendable { case center, forceStart, forceEnd }

    static let arrowSize = CGSize(width: 20, height: 6)

    /// TOOLTIP_ARROW_PATH (20×6, pointing down).
    struct ArrowShape: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: 0))
            p.addQuadCurve(to: CGPoint(x: 5, y: 2), control: CGPoint(x: 3, y: 0))
            p.addLine(to: CGPoint(x: 8, y: 5))
            p.addQuadCurve(to: CGPoint(x: 10, y: 6), control: CGPoint(x: 9, y: 6))
            p.addQuadCurve(to: CGPoint(x: 12, y: 5), control: CGPoint(x: 11, y: 6))
            p.addLine(to: CGPoint(x: 15, y: 2))
            p.addQuadCurve(to: CGPoint(x: 20, y: 0), control: CGPoint(x: 17, y: 0))
            p.closeSubpath()
            return p.applying(CGAffineTransform(scaleX: r.width / 20, y: r.height / 6)).offsetBy(dx: r.minX, dy: r.minY)
        }
    }

    /// The bubble (`Tooltip.Content`).
    struct Bubble: View {
        /// An accessory's width plus the flex gap.
        static func width(_ s: String?, _ st: CSSTextStyle) -> CGFloat {
            s.map { CSSTextLayout.make($0, st, wrap: .nowrap, maxWidth: nil).width + 8 } ?? 0
        }
        let label: String
        let keyboardShortcut: String?
        let timestamp: String?
        var body: some View {
            let hasAccessory = keyboardShortcut != nil || timestamp != nil
            let shape = RoundedRectangle(cornerRadius: 14)
            let style = CSSTextStyle(.bodySmall)
            let available = (hasAccessory ? 228 : 192) - 20 - Self.width(keyboardShortcut, style) - Self.width(timestamp, CSSTextStyle(.caption))
            // Upstream pins the label's container to the rendered (balanced) text width.
            let labelWidth = CSSTextLayout.make(label, style, wrap: .balance, maxWidth: available).width
            CSSFlex(.row, gap: 8, justify: .center, align: .end, fitContent: true) {
                CSSText(label, type: .bodySmall, wrap: .balance, color: .labelPrimaryOncolor).flexItem(basis: labelWidth, minMain: 0)
                if let keyboardShortcut { CSSText(keyboardShortcut, type: .bodySmall, wrap: .nowrap, color: .labelSecondaryOncolor) }
                if let timestamp { CSSText(timestamp, type: .caption, wrap: .nowrap, color: .labelSecondaryOncolor) }
            }
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
            .frame(minWidth: 48)
            .modifier(MaxWidth(max: hasAccessory ? 228 : 192))
            .background(shape.fill(AxoColor.materialDimPrimary))
            .axoShadow(AxoShadow(light: AxoShadow.baseShadowElevation3.light, dark: AxoShadow.baseShadowElevation3.dark), in: shape)
        }
    }

    /// Shrink-to-fit with a max width (the label's container is pinned to its content width).
    struct MaxWidth: ViewModifier {
        let max: CGFloat
        func body(content: Self.Content) -> some View { L(max: max) { content } }
        struct L: Layout {
            let max: CGFloat
            func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
                let w = Swift.min(max, subviews[0].sizeThatFits(.unspecified).width)
                return subviews[0].sizeThatFits(ProposedViewSize(width: w, height: nil))
            }
            func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
                subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            }
        }
    }

    /// `<AxoTooltip.Root>`: wraps the trigger.
    public struct Root<Trigger: View>: View {
        let label: String
        let side: Side
        let align: Align
        let keyboardShortcut: String?
        let timestamp: String?
        let disabled: Bool
        let forceOpen: Bool
        let trigger: Trigger
        @State private var open = false
        @State private var hoverTask: Task<Void, Never>?
        @State private var id = UUID().uuidString
        @Environment(\.layoutDirection) var direction

        public init(label: String, side: Side = .top, align: Align = .center, keyboardShortcut: String? = nil, timestamp: String? = nil,
                    disabled: Bool = false, forceOpen: Bool = false, @ViewBuilder trigger: () -> Trigger) {
            self.label = label
            self.side = side
            self.align = align
            self.keyboardShortcut = keyboardShortcut
            self.timestamp = timestamp
            self.disabled = disabled
            self.forceOpen = forceOpen
            self.trigger = trigger()
        }

        var physicalSide: AxoPopper.Side {
            switch side {
            case .top: .top
            case .bottom: .bottom
            case .inlineStart: direction == .rightToLeft ? .right : .left
            case .inlineEnd: direction == .rightToLeft ? .left : .right
            }
        }

        public var body: some View {
            let vertical = side == .top || side == .bottom
            let a: AxoPopper.Align = align == .center ? .center : align == .forceStart ? .start : .end
            let placement = AxoPopper.Placement(side: physicalSide, align: a, sideOffset: 6, collisionPadding: 8, hideWhenDetached: true)
            let arrow = vertical ? AxoPopper.Arrow(size: AxoTooltip.arrowSize, padding: 14) {
                // Points away from the bubble: down when above the trigger, up when below.
                GeometryReader { _ in ArrowShape().fill(AxoColor.materialDimPrimary) }
            } : nil
            trigger
                .onHover { inside in
                    hoverTask?.cancel()
                    if inside && !disabled {
                        hoverTask = Task { try? await Task.sleep(for: .milliseconds(700)); if !Task.isCancelled { open = true } }
                    } else {
                        open = false
                    }
                }
                .axoPopper(id: id, isPresented: (open || forceOpen) && !disabled, placement: placement, arrow: arrow) {
                    Bubble(label: label, keyboardShortcut: keyboardShortcut, timestamp: timestamp)
                }
                .accessibilityHint(label)
        }
    }
}
