// Port of ts/components/Tooltip.dom.tsx + `.module-tooltip` (stylesheets/_modules.scss): the
// legacy hover tooltip, positioned by Popper next to its trigger (12px offset) with a 6px
// CSS-border arrow pointing at the trigger's centre.
//
// Shown while the trigger is hovered or focused (after `delay` ms when given; once a delayed
// tooltip has shown, others skip their delay until 300ms after the last one hides), or always
// when `sticky`. The bubble is an overlay of the trigger, so it never affects layout. Popper's
// flip / preventOverflow modifiers are not ported: the bubble stays on the requested side.

import SwiftUI

public enum TooltipPlacement: String, Sendable, Hashable, CaseIterable {
    case top, right, bottom, left
}

/// Upstream's global delay state (GLOBAL_TOOLTIP_DISABLE_DELAY / GLOBAL_EXIT_TIMER).
@MainActor final class TooltipDelayState {
    static let shared = TooltipDelayState()
    var delayDisabled = false
    var exitTask: Task<Void, Never>?
}

public struct Tooltip<Trigger: View, Content: View>: View {
    let direction: TooltipPlacement
    let sticky: Bool
    /// `theme === Theme.Dark`: `.module-tooltip--dark-theme` (dark colours in any theme).
    let forceDark: Bool
    let delay: Int?
    let hideArrow: Bool
    let trigger: Trigger
    let content: Content
    @State private var active = false
    @State private var showTask: Task<Void, Never>?

    public init(direction: TooltipPlacement = .top, sticky: Bool = false, forceDark: Bool = false, delay: Int? = nil, hideArrow: Bool = false,
                @ViewBuilder content: () -> Content, @ViewBuilder trigger: () -> Trigger) {
        self.direction = direction
        self.sticky = sticky
        self.forceDark = forceDark
        self.delay = delay
        self.hideArrow = hideArrow
        self.trigger = trigger()
        self.content = content()
    }

    public var body: some View {
        TooltipPopperLayout(direction: direction, offset: Self.offset) {
            trigger
            if active || sticky {
                TooltipBubble(direction: direction, forceDark: forceDark, hideArrow: hideArrow) { content }
                    .allowsHitTesting(false)
            }
        }
            .onHover { hoverChanged($0) }
    }

    func hoverChanged(_ hovering: Bool) {
        let state = TooltipDelayState.shared
        state.exitTask?.cancel()
        showTask?.cancel()
        guard let delay else {
            active = hovering
            return
        }
        if hovering && !state.delayDisabled {
            showTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                active = true
                state.delayDisabled = true
            }
            return
        }
        if !hovering {
            active = false
            if state.delayDisabled {
                state.exitTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    state.delayDisabled = false
                }
            }
            return
        }
        active = hovering
    }
}

extension Tooltip {
    /// `offsetDistanceModifier(12)`
    static var offset: CGFloat { 12 }
}

extension Tooltip where Content == CSSText {
    /// A tooltip whose `content` is a string (inherits the body's 14px/20px text).
    public init(_ content: String, direction: TooltipPlacement = .top, sticky: Bool = false, forceDark: Bool = false, delay: Int? = nil,
                hideArrow: Bool = false, @ViewBuilder trigger: () -> Trigger) {
        self.init(direction: direction, sticky: sticky, forceDark: forceDark, delay: delay, hideArrow: hideArrow,
                  content: { CSSText(content, type: .bodyLarge, alignment: .center) }, trigger: trigger)
    }
}

/// Popper: the layout takes the trigger's size (subview 0); the bubble (subview 1, at its
/// ideal size) is placed `offset` beyond the trigger's edge, centred on it, at a position
/// rounded to device pixels (Popper's roundOffsetsByDPR; 2× here).
struct TooltipPopperLayout: Layout {
    let direction: TooltipPlacement
    let offset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[0].sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        guard subviews.count > 1 else { return }
        let size = subviews[1].sizeThatFits(.unspecified)
        func px(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }
        let origin: CGPoint
        switch direction {
        case .top: origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.minY - offset - size.height)
        case .bottom: origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY + offset)
        case .left: origin = CGPoint(x: bounds.minX - offset - size.width, y: bounds.midY - size.height / 2)
        case .right: origin = CGPoint(x: bounds.maxX + offset, y: bounds.midY - size.height / 2)
        }
        subviews[1].place(at: CGPoint(x: px(origin.x), y: px(origin.y)), proposal: ProposedViewSize(size))
    }
}

/// `.module-tooltip` + `.module-tooltip-arrow`
struct TooltipBubble<Content: View>: View {
    let direction: TooltipPlacement
    let forceDark: Bool
    let hideArrow: Bool
    let content: Content
    @Environment(\.colorScheme) var scheme

    init(direction: TooltipPlacement, forceDark: Bool, hideArrow: Bool, @ViewBuilder content: () -> Content) {
        self.direction = direction
        self.forceDark = forceDark
        self.hideArrow = hideArrow
        self.content = content()
    }

    /// --tooltip-text-color / --tooltip-background-color ($color-gray-75 / -02, dark: -05 / -65)
    var textColor: AxoColor { forceDark ? AxoColor(LegacyColor.gray05) : AxoColor(light: LegacyColor.gray75, dark: LegacyColor.gray05) }
    var background: AxoColor { forceDark ? AxoColor(LegacyColor.gray65) : AxoColor(light: LegacyColor.gray02, dark: LegacyColor.gray65) }

    var body: some View {
        content
            .cssTextColor(textColor)
            .padding(EdgeInsets(top: 8, leading: 21, bottom: 8, trailing: 21))
            .background(RoundedRectangle(cornerRadius: 8).fill(background))
            .overlay {
                if !hideArrow {
                    TooltipArrowLayout(direction: direction) {
                        TooltipArrow(pointing: direction).fill(background)
                    }
                }
            }
    }
}

/// `.module-tooltip-arrow::after`: a 12×6 triangle centred on the edge facing the trigger, outside the bubble.
struct TooltipArrowLayout: Layout {
    let direction: TooltipPlacement
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frame: CGRect
        switch direction {
        case .top: frame = CGRect(x: b.midX - 6, y: b.maxY, width: 12, height: 6)
        case .bottom: frame = CGRect(x: b.midX - 6, y: b.minY - 6, width: 12, height: 6)
        case .left: frame = CGRect(x: b.maxX, y: b.midY - 6, width: 6, height: 12)
        case .right: frame = CGRect(x: b.minX - 6, y: b.midY - 6, width: 6, height: 12)
        }
        for s in subviews { s.place(at: frame.origin, proposal: ProposedViewSize(frame.size)) }
    }
}

/// The arrow: a 6px `border` triangle whose base lies on the bubble's edge.
struct TooltipArrow: Shape {
    let pointing: TooltipPlacement
    func path(in r: CGRect) -> Path {
        var p = Path()
        switch pointing {
        case .top:      // bubble above the trigger: arrow points down
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        case .bottom:
            p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.midX, y: r.minY))
        case .left:
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        case .right:
            p.move(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.midY))
        }
        p.closeSubpath()
        return p
    }
}
