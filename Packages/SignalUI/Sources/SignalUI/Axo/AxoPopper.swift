// Floating layers (upstream Radix Popper + Portal + AxoBaseLayer): a trigger publishes
// its frame and the content to float; `axoLayerHost()` at the window root (or a
// test stage) places the content beside the trigger the way Radix does — side,
// alignment, sideOffset, collision padding — above everything else.

import SwiftUI

public enum AxoPopper {
    public enum Side: Sendable { case top, right, bottom, left }
    public enum Align: Sendable { case start, center, end }

    public struct Placement: Sendable, Hashable {
        public var side: Side = .bottom
        public var align: Align = .center
        public var sideOffset: CGFloat = 0
        public var alignOffset: CGFloat = 0
        public var collisionPadding: CGFloat = 0
        /// Radix `hideWhenDetached`: hidden while the trigger is entirely outside the bounds.
        public var hideWhenDetached = false
        /// Radix Select `item-aligned`: the content's origin is the anchor's origin plus this
        /// offset (laid over the trigger), kept 10px inside the bounds; side and align unused.
        public var itemAligned: CGPoint? = nil
        public init(side: Side = .bottom, align: Align = .center, sideOffset: CGFloat = 0, alignOffset: CGFloat = 0, collisionPadding: CGFloat = 0,
                    hideWhenDetached: Bool = false) {
            self.side = side
            self.align = align
            self.sideOffset = sideOffset
            self.alignOffset = alignOffset
            self.collisionPadding = collisionPadding
            self.hideWhenDetached = hideWhenDetached
        }
    }

    /// Radix/floating-ui placement of a `size` box next to `anchor` inside `bounds`:
    /// flip to the opposite side when it doesn't fit, then shift along the cross axis to
    /// stay `collisionPadding` inside the bounds.
    public static func place(_ size: CGSize, anchor: CGRect, in bounds: CGRect, _ p: Placement) -> CGPoint {
        placeAndSide(size, anchor: anchor, in: bounds, p).0
    }

    public static func placeAndSide(_ size: CGSize, anchor: CGRect, in bounds: CGRect, _ p: Placement) -> (CGPoint, Side) {
        func origin(_ side: Side) -> CGPoint {
            let vertical = side == .top || side == .bottom
            var x: CGFloat, y: CGFloat
            if vertical {
                y = side == .bottom ? anchor.maxY + p.sideOffset : anchor.minY - p.sideOffset - size.height
                switch p.align {
                case .start: x = anchor.minX
                case .center: x = anchor.midX - size.width / 2
                case .end: x = anchor.maxX - size.width
                }
                x += p.alignOffset
            } else {
                x = side == .right ? anchor.maxX + p.sideOffset : anchor.minX - p.sideOffset - size.width
                switch p.align {
                case .start: y = anchor.minY
                case .center: y = anchor.midY - size.height / 2
                case .end: y = anchor.maxY - size.height
                }
                y += p.alignOffset
            }
            return CGPoint(x: x, y: y)
        }
        let inner = bounds.insetBy(dx: p.collisionPadding, dy: p.collisionPadding)
        var side = p.side
        var o = origin(side)
        let overflows: (CGPoint) -> Bool = { o in
            switch side {
            case .bottom: o.y + size.height > inner.maxY
            case .top: o.y < inner.minY
            case .right: o.x + size.width > inner.maxX
            case .left: o.x < inner.minX
            }
        }
        if overflows(o) {
            let opposite: Side = side == .bottom ? .top : side == .top ? .bottom : side == .left ? .right : .left
            let alt = origin(opposite)
            let saved = side
            side = opposite
            if !overflows(alt) { o = alt } else { side = saved }
        }
        if side == .top || side == .bottom {
            o.x = min(max(o.x, inner.minX), max(inner.minX, inner.maxX - size.width))
        } else {
            o.y = min(max(o.y, inner.minY), max(inner.minY, inner.maxY - size.height))
        }
        return (o, side)
    }

    /// Radix `<Arrow>`: drawn pointing down (for side = top); rotated for other sides.
    public struct Arrow {
        public var view: AnyView
        public var size: CGSize
        /// Minimum distance between the arrow and the content's corners (`arrowPadding`).
        public var padding: CGFloat
        public init(size: CGSize, padding: CGFloat, @ViewBuilder view: () -> some View) {
            self.view = AnyView(view())
            self.size = size
            self.padding = padding
        }
    }

    struct ArrowMetrics: Sendable { var size: CGSize; var padding: CGFloat }

    struct Entry: Identifiable {
        let id: String
        let anchor: Anchor<CGRect>
        let placement: Placement
        let content: AnyView
        /// Content for the opposite side, used when the popper flips (e.g. a tooltip whose
        /// arrow must point the other way); nil = same content.
        let flipped: AnyView?
        let arrow: Arrow?
        let dismiss: (() -> Void)?
        /// The clipping ancestors (scroll viewports) the trigger sits in (`axoPopperClip`).
        var clips: [Anchor<CGRect>] = []
    }

    struct EntriesKey: PreferenceKey {
        static var defaultValue: [Entry] { [] }
        static func reduce(value: inout [Entry], nextValue: () -> [Entry]) { value += nextValue() }
    }

    /// Places one floating entry within the host: subview 0 is the content, then the
    /// flipped content (if any), then the arrow (if any). The version that is not used is
    /// parked off-screen. With an arrow, the content moves out by the arrow's height and the
    /// arrow points at the anchor's centre, kept `padding` away from the content's corners.
    struct FloatingLayout: Layout {
        let anchor: CGRect
        let placement: Placement
        let hasFlipped: Bool
        let arrow: ArrowMetrics?
        /// The intersection of the trigger's clipping ancestors (host coordinates).
        var clip: CGRect? = nil
        /// Device pixels per point: the content's origin is rounded to device pixels.
        var scale: CGFloat = 2

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            proposal.replacingUnspecifiedDimensions()
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let local = anchor.offsetBy(dx: bounds.minX, dy: bounds.minY)
            var p = placement
            if let arrow { p.sideOffset += arrow.size.height }
            let size = subviews[0].sizeThatFits(.unspecified)
            var (origin, side) = AxoPopper.placeAndSide(size, anchor: local, in: bounds, p)
            if let offset = placement.itemAligned {
                // CONTENT_MARGIN = 10 (SelectItemAlignedPosition).
                let inner = bounds.insetBy(dx: 10, dy: 10)
                origin = CGPoint(x: min(max(local.minX + offset.x, inner.minX), max(inner.minX, inner.maxX - size.width)),
                                 y: min(max(local.minY + offset.y, inner.minY), max(inner.minY, inner.maxY - size.height)))
                side = placement.side
            }
            // floating-ui roundByDPR (relative to the host's origin). SwiftUI reports the anchor
            // already snapped to device pixels, so an exact half-pixel tie is an artefact of
            // that snapping: break ties to even.
            origin = CGPoint(x: bounds.minX + ((origin.x - bounds.minX) * scale).rounded(.toNearestOrEven) / scale,
                             y: bounds.minY + ((origin.y - bounds.minY) * scale).rounded(.toNearestOrEven) / scale)
            let flippedUsed = hasFlipped && side != placement.side
            let park = CGPoint(x: bounds.minX - 100_000, y: bounds.minY)
            // floating-ui `hide` (referenceHidden): the trigger lies wholly beyond the clipping
            // rect inset by the collision padding on some side.
            let visible = (clip.map { $0.offsetBy(dx: bounds.minX, dy: bounds.minY).intersection(bounds) } ?? bounds)
                .insetBy(dx: placement.collisionPadding, dy: placement.collisionPadding)
            if placement.hideWhenDetached && !local.intersects(visible) {
                for s in subviews { s.place(at: park, proposal: .unspecified) }
                return
            }
            subviews[0].place(at: flippedUsed ? park : origin, proposal: ProposedViewSize(size))
            if hasFlipped { subviews[1].place(at: flippedUsed ? origin : park, proposal: ProposedViewSize(size)) }
            // Arrow subviews: pointing down (used when the content is above) and up.
            guard let arrow, subviews.count >= (hasFlipped ? 4 : 3) else { return }
            let down = subviews[subviews.count - 2], up = subviews[subviews.count - 1]
            let box = CGRect(origin: origin, size: size)
            let a = arrow.size
            var point: CGPoint
            switch side {
            case .top, .bottom:
                let x = min(max(local.midX - a.width / 2, box.minX + arrow.padding), box.maxX - arrow.padding - a.width)
                point = CGPoint(x: x, y: side == .top ? box.maxY : box.minY - a.height)
            case .left, .right:
                let y = min(max(local.midY - a.width / 2, box.minY + arrow.padding), box.maxY - arrow.padding - a.width)
                point = CGPoint(x: side == .left ? box.maxX : box.minX - a.height, y: y)
            }
            let used = side == .bottom ? up : down
            (side == .bottom ? down : up).place(at: park, proposal: ProposedViewSize(a))
            used.place(at: point, proposal: ProposedViewSize(width: side == .top || side == .bottom ? a.width : a.height,
                                                             height: side == .top || side == .bottom ? a.height : a.width))
        }
    }
}

@MainActor func ArrowMetricsOf(_ a: AxoPopper.Arrow) -> AxoPopper.ArrowMetrics { AxoPopper.ArrowMetrics(size: a.size, padding: a.padding) }

extension View {
    /// Floats `content` beside this view while `isPresented` (rendered by the nearest `axoLayerHost`).
    public func axoPopper(id: String, isPresented: Bool, placement: AxoPopper.Placement, dismiss: (() -> Void)? = nil,
                          arrow: AxoPopper.Arrow? = nil, @ViewBuilder flipped: () -> some View = { EmptyView() }, hasFlipped: Bool = false,
                          @ViewBuilder content: () -> some View) -> some View {
        let view = AnyView(content())
        let flippedView = hasFlipped ? AnyView(flipped()) : nil
        return anchorPreference(key: AxoPopper.EntriesKey.self, value: .bounds) { anchor in
            isPresented ? [AxoPopper.Entry(id: id, anchor: anchor, placement: placement, content: view, flipped: flippedView, arrow: arrow,
                                           dismiss: dismiss)] : []
        }
    }

    /// Marks a clipping ancestor (a scroll viewport) for the poppers of triggers inside it:
    /// Radix `hideWhenDetached` hides one whose trigger is scrolled out of every such box.
    public func axoPopperClip() -> some View {
        transformAnchorPreference(key: AxoPopper.EntriesKey.self, value: .bounds) { entries, anchor in
            for i in entries.indices { entries[i].clips.append(anchor) }
        }
    }

    /// The window-level layer for poppers (menus, popovers, tooltips): Radix's portal target.
    public func axoLayerHost() -> some View {
        overlayPreferenceValue(AxoPopper.EntriesKey.self) { entries in AxoPopper.Layer(entries: entries) }
    }
}

extension AxoPopper {
    /// The layer host's content: each entry placed by `FloatingLayout`, at device-pixel
    /// origins (floating-ui `roundByDPR`).
    struct Layer: View {
        let entries: [Entry]
        @Environment(\.displayScale) var displayScale
        var body: some View {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    if let dismiss = entries.last?.dismiss {
                        Color.black.opacity(0.0001).onTapGesture { dismiss() }    // click outside closes
                    }
                    ForEach(entries) { e in
                        let clip = e.clips.map { geo[$0] }.reduce(nil as CGRect?) { acc, r in acc.map { $0.intersection(r) } ?? r }
                        AxoPopper.FloatingLayout(anchor: geo[e.anchor], placement: e.placement, hasFlipped: e.flipped != nil,
                                                  arrow: e.arrow.map { ArrowMetricsOf($0) }, clip: clip, scale: displayScale) {
                            e.content
                            if let f = e.flipped { f }
                            if let a = e.arrow {
                                a.view
                                a.view.rotationEffect(.degrees(180))
                            }
                        }
                    }
                }
            }
        }
    }
}
