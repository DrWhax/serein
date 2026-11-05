// Port of ts/axo/AxoScrollArea.dom.tsx (+ AxoScrollArea.css): a scrollable container with
// configurable scrollbar gutters, optional scroll hints (edge lines) and an optional
// gradient mask.
//
//   <AxoScrollArea.Root scrollbarWidth="thin">
//     <AxoScrollArea.Hint edge="top"/> <AxoScrollArea.Hint edge="bottom"/>
//     <AxoScrollArea.Mask>
//       <AxoScrollArea.Viewport> <AxoScrollArea.Content>…</AxoScrollArea.Content> </AxoScrollArea.Viewport>
//     </AxoScrollArea.Mask>
//   </AxoScrollArea.Root>
//
// Layout follows the CSS: Root and Viewport are `size-full` (they fill a definite size
// proposed by the parent, and fit their content when the parent leaves an axis unspecified,
// e.g. under `.fixedSize()`, capped by maxWidth / maxHeight). `scrollbar-gutter: stable`
// reserves the classic vertical scrollbar's thickness on the inline edge(s); the content is
// clipped to the viewport's padding box (inside the gutters). Horizontal scrollbars overlay.
//
// Hints and the mask are scroll-driven animations upstream (animation-timeline: scroll()).
// They follow the scroll position; before there is one (no overflow, or a static render)
// they rest in their base style: hints transparent, mask fully opaque.
//
// Offscreen renderers (ImageRenderer, used by the snapshot tests) cannot draw AppKit-backed
// views such as ScrollView. With `\.axoStaticRendering` set, Viewport lays its content out
// as CSS does at scroll offset 0 and clips it, without a ScrollView.

import SwiftUI

public enum AxoScrollArea {
    /// Which directions the area scrolls.
    public enum Orientation: String, Sendable, CaseIterable { case vertical, horizontal, both }

    /// Width of the scrollbar track.
    public enum ScrollbarWidth: String, Sendable, CaseIterable {
        case wide, thin, none
        /// The classic vertical scrollbar's thickness (what `scrollbar-gutter: stable`
        /// reserves; upstream measures --axo-scrollbar-gutter-*-vertical at runtime).
        var gutter: CGFloat {
            switch self {
            case .wide: 15
            case .thin: 11
            case .none: 0
            }
        }
    }

    /// Space reserved for the scrollbar.
    public enum ScrollbarGutter: String, Sendable, CaseIterable {
        case unstable, stableOneEdge = "stable-one-edge", stableBothEdges = "stable-both-edges"
    }

    /// When the scrollbar thumb is visible.
    public enum ScrollbarVisibility: String, Sendable, CaseIterable { case auto, asNeeded = "as-needed" }

    /// Whether programmatic scrolling is animated by default.
    public enum ScrollBehavior: String, Sendable, CaseIterable { case auto, smooth }

    /// How the area behaves at the scroll boundary.
    public enum OverscrollBehavior: String, Sendable, CaseIterable { case auto, chain, contain, none }

    /// Which edge of the area a hint appears on.
    public enum Edge: String, Sendable, CaseIterable { case top, bottom, inlineStart = "inline-start", inlineEnd = "inline-end" }

    struct Context: Sendable, Equatable {
        var orientation: Orientation
        var scrollbarWidth: ScrollbarWidth
        var scrollbarGutter: ScrollbarGutter
        var scrollbarVisibility: ScrollbarVisibility
        var scrollBehavior: ScrollBehavior
        var overscrollBehavior: OverscrollBehavior

        var axes: Axis.Set {
            switch orientation {
            case .vertical: .vertical
            case .horizontal: .horizontal
            case .both: [.horizontal, .vertical]
            }
        }

        /// Inline-start / inline-end gutters of the vertical scrollbar.
        var gutters: (start: CGFloat, end: CGFloat) {
            let g = scrollbarWidth.gutter
            switch scrollbarGutter {
            case .unstable: return (0, 0)
            case .stableOneEdge: return (0, g)
            case .stableBothEdges: return (g, g)
            }
        }

        /// The vertical scrollbar's thickness (`--axo-scrollbar-gutter-*-vertical`).
        var verticalScrollbar: CGFloat { scrollbarWidth.gutter }
    }

    /// Scroll position of the Viewport, shared with Hint and Mask (upstream: scroll timelines).
    struct Metrics: Sendable, Equatable {
        var offset: CGPoint = .zero
        var contentSize: CGSize = .zero
        var containerSize: CGSize = .zero
        var maxOffset: CGPoint {
            CGPoint(x: max(0, contentSize.width - containerSize.width), y: max(0, contentSize.height - containerSize.height))
        }
    }

    @MainActor @Observable final class ScrollState {
        var metrics: Metrics?
        init() {}
    }

    /// Progress of a scroll-driven animation over [start, end] (px of scroll offset).
    static func progress(_ value: CGFloat, _ start: CGFloat, _ end: CGFloat) -> CGFloat {
        guard end > start else { return value >= end ? 1 : 0 }
        return min(1, max(0, (value - start) / (end - start)))
    }

    /**
     * <AxoScrollArea.Root>
     * --------------------------------------------------------------------------
     */

    /// Configures the area; children should be `Hint`, `Mask` and/or `Viewport`.
    public struct Root<Content: View>: View {
        let context: Context
        let maxWidth: CGFloat?
        let maxHeight: CGFloat?
        let content: Content
        @State private var state = ScrollState()

        public init(orientation: Orientation = .vertical, maxWidth: CGFloat? = nil, maxHeight: CGFloat? = nil, scrollbarWidth: ScrollbarWidth,
                    scrollbarGutter: ScrollbarGutter = .stableBothEdges, scrollbarVisibility: ScrollbarVisibility = .auto,
                    scrollBehavior: ScrollBehavior = .auto, overscrollBehavior: OverscrollBehavior = .none,
                    @ViewBuilder content: () -> Content) {
            context = Context(orientation: orientation, scrollbarWidth: scrollbarWidth, scrollbarGutter: scrollbarGutter,
                              scrollbarVisibility: scrollbarVisibility, scrollBehavior: scrollBehavior, overscrollBehavior: overscrollBehavior)
            self.maxWidth = maxWidth
            self.maxHeight = maxHeight
            self.content = content()
        }

        public var body: some View {
            // relative flex size-full flex-col overflow-hidden rounded-[2px]
            RootLayout(context: context, maxWidth: maxWidth, maxHeight: maxHeight) { content }
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .environment(\.axoScrollAreaContext, context)
                .environment(state)
        }
    }

    struct HintEdgeKey: LayoutValueKey { static let defaultValue: Edge? = nil }

    /// Sizes the Root from its scrolling child (Mask or Viewport), clamped to maxWidth /
    /// maxHeight, and positions Hints absolutely along the edges.
    struct RootLayout: Layout {
        let context: Context
        let maxWidth: CGFloat?
        let maxHeight: CGFloat?

        func clamp(_ p: ProposedViewSize) -> ProposedViewSize {
            ProposedViewSize(width: p.width.map { min($0, maxWidth ?? .infinity) }, height: p.height.map { min($0, maxHeight ?? .infinity) })
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let p = clamp(proposal)
            let main = subviews.filter { $0[HintEdgeKey.self] == nil }
            let fit = main.map { $0.sizeThatFits(p) }
            let w = p.width ?? fit.map(\.width).max() ?? 0
            let h = p.height ?? fit.map(\.height).max() ?? 0
            return CGSize(width: min(w, maxWidth ?? .infinity), height: min(h, maxHeight ?? .infinity))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let both = context.orientation == .both
            let insetEnd: CGFloat = both ? context.verticalScrollbar : 0
            let insetBottom: CGFloat = 0   // horizontal scrollbars overlay
            for s in subviews {
                guard let edge = s[HintEdgeKey.self] else {
                    s.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
                    continue
                }
                let w = bounds.width, h = bounds.height
                let frame: CGRect
                switch edge {
                case .top: frame = CGRect(x: 0, y: 0, width: w - insetEnd, height: 2)
                case .bottom: frame = CGRect(x: 0, y: h - insetBottom - 2, width: w - insetEnd, height: 2)
                case .inlineStart: frame = CGRect(x: 0, y: 0, width: 2, height: h - insetBottom)
                case .inlineEnd: frame = CGRect(x: w - insetEnd - 2, y: 0, width: 2, height: h - insetBottom)
                }
                s.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                        proposal: ProposedViewSize(width: max(0, frame.width), height: max(0, frame.height)))
            }
        }
    }

    /**
     * <AxoScrollArea.Viewport>
     * --------------------------------------------------------------------------
     */

    /// The scrollable element; place inside `Root` (or `Mask`), wrapping a `Content`.
    public struct Viewport<Content: View>: View {
        let content: Content
        @Environment(\.axoScrollAreaContext) var context
        @Environment(\.axoStaticRendering) var staticRendering
        @Environment(ScrollState.self) var state: ScrollState?

        public init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        public var body: some View {
            let ctx = context ?? Context(orientation: .vertical, scrollbarWidth: .thin, scrollbarGutter: .stableBothEdges,
                                         scrollbarVisibility: .auto, scrollBehavior: .auto, overscrollBehavior: .none)
            let gutters = ctx.gutters
            if staticRendering {
                // Overflow is clipped at the viewport's edge: the (hidden) scrollbar gutters
                // show the content scrolled under them, as in the captures.
                StaticViewportLayout(gutterStart: gutters.start, gutterEnd: gutters.end) { content }
                    .clipped()
                    .axoPopperClip()
            } else {
                let metrics = state?.metrics
                FitLayout(contentSize: metrics?.contentSize) {
                ScrollView(ctx.axes) {
                    content
                        .environment(\.axoScrollAreaViewportSize,
                                     metrics.map { CGSize(width: max(0, $0.containerSize.width - gutters.start - gutters.end), height: $0.containerSize.height) })
                        .padding(.leading, gutters.start)
                        .padding(.trailing, gutters.end)
                }
                .scrollIndicators(ctx.scrollbarWidth == .none ? .hidden : ctx.scrollbarVisibility == .asNeeded ? .automatic : .visible)
                .scrollBounceBehavior(ctx.overscrollBehavior == .auto || ctx.overscrollBehavior == .chain ? .automatic : .basedOnSize, axes: ctx.axes)
                .onScrollGeometryChange(for: Metrics.self) { g in
                    Metrics(offset: g.contentOffset, contentSize: g.contentSize, containerSize: g.containerSize)
                } action: { _, m in
                    state?.metrics = m
                }
                .axoPopperClip()
                }
            }
        }
    }

    /// The viewport at scroll offset 0, as CSS lays it out: the content box is the viewport
    /// minus the inline gutters (Content is `w-full`, so overflowing children overflow it),
    /// and an unspecified axis fits the content.
    struct StaticViewportLayout: Layout {
        let gutterStart: CGFloat
        let gutterEnd: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let gutters = gutterStart + gutterEnd
            let innerWidth = proposal.width.map { max(0, $0 - gutters) }
            let ideal = subviews.map { $0.sizeThatFits(ProposedViewSize(width: innerWidth, height: nil)) }
            let width = proposal.width ?? ((ideal.map(\.width).max() ?? 0) + gutters)
            let height = proposal.height ?? ideal.map(\.height).max() ?? 0
            return CGSize(width: width, height: height)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let inner = max(0, bounds.width - gutterStart - gutterEnd)
            for s in subviews {
                s.place(at: CGPoint(x: bounds.minX + gutterStart, y: bounds.minY), proposal: ProposedViewSize(width: inner, height: bounds.height))
            }
        }
    }

    /// A ScrollView fills what it is offered; an unspecified axis fits the measured content.
    struct FitLayout: Layout {
        let contentSize: CGSize?
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            CGSize(width: proposal.width ?? contentSize?.width ?? 0, height: proposal.height ?? contentSize?.height ?? 0)
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            for s in subviews { s.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
        }
    }

    /**
     * <AxoScrollArea.Content>
     * --------------------------------------------------------------------------
     */

    /// Wrapper for the content inside `Viewport`: `h-fit w-full min-h-full grow`.
    public struct Content<Children: View>: View {
        let children: Children
        @Environment(\.axoScrollAreaViewportSize) var viewportSize

        public init(@ViewBuilder content: () -> Children) {
            children = content()
        }

        public var body: some View {
            ContentLayout(viewportSize: viewportSize) { children }
        }
    }

    /// Width: the viewport's (w-full); height: the content's, at least the viewport's.
    struct ContentLayout: Layout {
        let viewportSize: CGSize?

        func minimum(_ proposal: ProposedViewSize) -> CGSize {
            CGSize(width: viewportSize?.width ?? proposal.width ?? 0, height: viewportSize?.height ?? proposal.height ?? 0)
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let m = minimum(proposal)
            let width = proposal.width ?? max(m.width, subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0)
            let h = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }.max() ?? 0
            return CGSize(width: width, height: max(h, m.height))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            for s in subviews {
                let h = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                s.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: max(h, bounds.height)))
            }
        }
    }

    /**
     * <AxoScrollArea.Hint>
     * --------------------------------------------------------------------------
     */

    /// A thin gradient line that fades in at a scroll edge when there is more content in
    /// that direction. Place inside `Root`, outside `Viewport`.
    public struct Hint: View {
        let edge: Edge
        let animationStartOffset: CGFloat
        let animationEndOffset: CGFloat
        @Environment(ScrollState.self) var state: ScrollState?
        @Environment(\.colorScheme) var scheme
        @Environment(\.layoutDirection) var direction

        public init(edge: Edge, animationStartOffset: CGFloat = 1, animationEndOffset: CGFloat = 20) {
            self.edge = edge
            self.animationStartOffset = animationStartOffset
            self.animationEndOffset = animationEndOffset
        }

        /// `axo-scroll-area-hint-reveal` (opacity 0 → 1) over the edge's scroll range;
        /// end edges run reversed. Without an active scroll timeline: opacity-0.
        var opacity: CGFloat {
            guard let m = state?.metrics else { return 0 }
            let vertical = edge == .top || edge == .bottom
            let offset = vertical ? m.offset.y : m.offset.x
            let maxOffset = vertical ? m.maxOffset.y : m.maxOffset.x
            guard maxOffset > 0 else { return 0 }
            switch edge {
            case .top, .inlineStart:
                return AxoScrollArea.progress(offset, animationStartOffset, animationEndOffset)
            case .bottom, .inlineEnd:
                return 1 - AxoScrollArea.progress(offset, maxOffset - animationEndOffset, maxOffset - animationStartOffset)
            }
        }

        public var body: some View {
            // from-(--axo-shadow-color-outline) dark:from-(--axo-shadow-color-elevation-1) to-transparent
            let from = (scheme == .dark ? AxoColor.shadowColorElevation1 : AxoColor.shadowColorOutline).value(for: scheme)
            let deg: Double = switch edge {
            case .top: 180                                       // bg-linear-to-b
            case .bottom: 0                                      // bg-linear-to-t
            case .inlineStart: direction == .rightToLeft ? 270 : 90
            case .inlineEnd: direction == .rightToLeft ? 90 : 270
            }
            CSSLinearGradientFill(CSSLinearGradient(deg: deg, start: from, end: RGBA(0, 0, 0, 0)))
                .opacity(opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .layoutValue(key: HintEdgeKey.self, value: edge)
        }
    }

    /**
     * <AxoScrollArea.Mask>
     * --------------------------------------------------------------------------
     */

    /// Fades content out at the scroll edges (a gradient alpha mask that follows the
    /// scroll position). Wrap `Viewport` with it.
    public struct Mask<Content: View>: View {
        let maskStart: CGFloat
        let maskPadding: CGFloat
        let maskEnd: CGFloat
        let animationStart: CGFloat
        let animationPadding: CGFloat
        let animationEnd: CGFloat
        let content: Content
        @Environment(ScrollState.self) var state: ScrollState?
        @Environment(\.axoScrollAreaContext) var context

        public init(maskStart: CGFloat = 0, maskPadding: CGFloat = 4, maskEnd: CGFloat = 40, animationStart: CGFloat? = nil,
                    animationPadding: CGFloat? = nil, animationEnd: CGFloat? = nil, @ViewBuilder content: () -> Content) {
            self.maskStart = maskStart
            self.maskPadding = maskPadding
            self.maskEnd = maskEnd
            self.animationStart = animationStart ?? maskStart
            self.animationPadding = animationPadding ?? maskPadding
            self.animationEnd = animationEnd ?? maskEnd * 3
            self.content = content()
        }

        /// (from, via) alphas of the start and end gradients on one axis; nil without an
        /// active scroll timeline on that axis (the mask is then opaque there).
        func alphas(offset: CGFloat, maxOffset: CGFloat) -> (start: (CGFloat, CGFloat), end: (CGFloat, CGFloat))? {
            guard maxOffset > 0 else { return nil }
            let p = AxoScrollArea.progress
            let start = (1 - p(offset, animationStart, animationPadding), 1 - p(offset, animationStart, animationEnd))
            let end = (p(offset, maxOffset - animationPadding, maxOffset - animationStart), p(offset, maxOffset - animationEnd, maxOffset - animationStart))
            return (start, end)
        }

        func gradient(_ alphas: (CGFloat, CGFloat), length: CGFloat, from: UnitPoint, to: UnitPoint) -> LinearGradient {
            let l = max(length, 1)
            return LinearGradient(stops: [
                .init(color: .black.opacity(alphas.0), location: min(1, maskStart / l)),
                .init(color: .black.opacity(alphas.1), location: min(1, maskPadding / l)),
                .init(color: .black, location: min(1, maskEnd / l)),
            ], startPoint: from, endPoint: to)
        }

        public var body: some View {
            let ctx = context
            let vGutter: CGFloat = ctx.map { $0.orientation != .horizontal ? $0.verticalScrollbar : 0 } ?? 0
            content
                .clipped()
                .mask {
                    if let m = state?.metrics {
                        GeometryReader { geo in
                            let w = max(0, geo.size.width - vGutter), h = geo.size.height
                            ZStack(alignment: .topLeading) {
                                Rectangle()
                                    .mask { if let a = alphas(offset: m.offset.y, maxOffset: m.maxOffset.y) { gradient(a.start, length: h, from: .top, to: .bottom) } else { Color.black } }
                                    .mask { if let a = alphas(offset: m.offset.y, maxOffset: m.maxOffset.y) { gradient(a.end, length: h, from: .bottom, to: .top) } else { Color.black } }
                                    .mask { if let a = alphas(offset: m.offset.x, maxOffset: m.maxOffset.x) { gradient(a.start, length: w, from: .leading, to: .trailing) } else { Color.black } }
                                    .mask { if let a = alphas(offset: m.offset.x, maxOffset: m.maxOffset.x) { gradient(a.end, length: w, from: .trailing, to: .leading) } else { Color.black } }
                                    .frame(width: w, height: h)
                                // The scrollbar strip stays fully visible.
                                Rectangle().frame(width: vGutter, height: h).offset(x: w)
                            }
                        }
                    } else {
                        Rectangle()
                    }
                }
        }
    }
}

extension EnvironmentValues {
    @Entry var axoScrollAreaContext: AxoScrollArea.Context? = nil
    /// The viewport's content-box size inside a ScrollView (Content's min-h-full / w-full).
    @Entry var axoScrollAreaViewportSize: CGSize? = nil
}
