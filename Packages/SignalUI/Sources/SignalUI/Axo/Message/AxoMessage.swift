// Port of ts/axo/message/AxoMessage.dom.tsx: a chat message row and its bubble.
//
//   <AxoMessage.Root direction>                 article.flex.w-full.py-px (row / row-reverse)
//     <AxoMessage.Bubble collapseAbove collapseBelow>
//       <AxoMessage.Text text={{ body }}/>       inline type-body-large, pre-wrap
//       <AxoMessage.Meta>                        float-end: &nbsp; + inline-flex caption
//         <AxoMessage.MetaTimestamp/> <AxoMessage.MetaExpireTimer/>
//         <AxoMessage.MetaOutgoingStatus/> <AxoMessage.MetaAction/>
//       </AxoMessage.Meta>
//     </AxoMessage.Bubble>
//   </AxoMessage.Root>
//
// The bubble is `w-fit min-w-[25ch] max-w-[min(80ch,80%)] px-3 py-1.5` (border-box) and a
// flow root: the meta float sits at the end of the text's last line when it fits there,
// else on a line of its own below.

import Foundation
import SwiftUI

public enum AxoMessage {
    public enum Direction: String, Sendable, CaseIterable { case incoming, outgoing }

    /// Body text style (type-body-large) and its `ch` unit (the bubble's font).
    static let textStyle = CSSTextStyle(AxoType.bodyLarge)
    static var ch: CGFloat { CSSTextLayout.ch(textStyle) }
    static var nbspWidth: CGFloat {
        CSSTextLayout.make("\u{00A0}0", textStyle, wrap: .nowrap, maxWidth: nil).width - CSSTextLayout.make("0", textStyle, wrap: .nowrap, maxWidth: nil).width
    }
    static let metaType = AxoType.caption
    static var metaCh: CGFloat { CSSTextLayout.ch(CSSTextStyle(metaType)) }

    /**
     * <AxoMessage.Root>
     * --------------------------------------------------------------------------
     */

    public struct Root<Content: View>: View {
        let direction: Direction
        let content: Content

        public init(direction: Direction, @ViewBuilder content: () -> Content) {
            self.direction = direction
            self.content = content()
        }

        public var body: some View {
            content
                .frame(maxWidth: .infinity, alignment: direction == .incoming ? .leading : .trailing)
                .padding(.vertical, 1)
                .environment(\.axoMessageDirection, direction)
                .accessibilityElement(children: .contain)
        }
    }

    /**
     * <AxoMessage.Bubble>
     * --------------------------------------------------------------------------
     */

    public struct Bubble<Content: View>: View {
        let collapseAbove: Bool
        let collapseBelow: Bool
        let content: Content
        @Environment(\.axoMessageDirection) var direction

        public init(collapseAbove: Bool, collapseBelow: Bool, @ViewBuilder content: () -> Content) {
            self.collapseAbove = collapseAbove
            self.collapseBelow = collapseBelow
            self.content = content()
        }

        public var body: some View {
            let incoming = direction == .incoming
            let r = AxoRadius._2xl, small = AxoRadius.sm
            let shape = UnevenRoundedRectangle(
                topLeadingRadius: collapseAbove && incoming ? small : r,
                bottomLeadingRadius: collapseBelow && incoming ? small : r,
                bottomTrailingRadius: collapseBelow && !incoming ? small : r,
                topTrailingRadius: collapseAbove && !incoming ? small : r)
            FlowRootLayout(padding: EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12), minWidth: 25 * AxoMessage.ch,
                           maxWidth: 80 * AxoMessage.ch, maxFraction: 0.8) { content }
                .cssTextColor(incoming ? .labelPrimary : .labelPrimaryOncolor)
                .background(shape.fill(incoming ? AxoColor.surfaceMessageIncoming : AxoColor.surfaceMessageOutgoing))
                .clipShape(shape)
        }
    }

    /**
     * <AxoMessage.DeletedBubble>
     * --------------------------------------------------------------------------
     */

    public struct DeletedBubble<Content: View>: View {
        let content: Content

        public init(direction: Direction, @ViewBuilder content: () -> Content) {
            self.content = content()
        }

        public var body: some View {
            FlowRootLayout(padding: EdgeInsets(), minWidth: 0, maxWidth: .infinity, maxFraction: 1) { content }
        }
    }

    /// What a flow-root needs to know about its inline text child to place a float after it.
    struct InlineTextKey: LayoutValueKey { static let defaultValue: String? = nil }
    struct FloatKey: LayoutValueKey { static let defaultValue = false }

    /// A shrink-to-fit block holding inline text followed by an end float (`flow-root`).
    struct FlowRootLayout: Layout {
        let padding: EdgeInsets
        let minWidth: CGFloat
        let maxWidth: CGFloat
        /// max-width as a fraction of the containing block (`80%`).
        let maxFraction: CGFloat

        /// Border-box width: shrink-to-fit (text max-content + float), clamped.
        func width(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
            let body = subviews.lazy.compactMap { $0[InlineTextKey.self] }.first ?? ""
            let floatWidth = subviews.first { $0[FloatKey.self] }?.sizeThatFits(.unspecified).width ?? 0
            // Max-content: the hard lines, with the float after the last one.
            let natural = body.isEmpty ? [CGFloat(0)] : CSSTextLayout.make(body, AxoMessage.textStyle, wrap: .wrap, maxWidth: nil).widths
            let maxContent = max(natural.dropLast().max() ?? 0, (natural.last ?? 0) + floatWidth)
            let limit = min(maxWidth, (proposal.width ?? .infinity) * maxFraction)
            return max(minWidth, min(maxContent + padding.leading + padding.trailing, limit))
        }

        /// Content height and the float's top for a border-box width.
        func flow(width: CGFloat, _ subviews: Subviews) -> (height: CGFloat, floatTop: CGFloat) {
            let body = subviews.lazy.compactMap { $0[InlineTextKey.self] }.first ?? ""
            let float = subviews.first { $0[FloatKey.self] }
            let floatSize = float?.sizeThatFits(.unspecified) ?? .zero
            let inner = max(0, width - padding.leading - padding.trailing)
            let lines = body.isEmpty ? nil : CSSTextLayout.make(body, AxoMessage.textStyle, wrap: .wrap, maxWidth: inner)
            let count = CGFloat(lines?.lines.count ?? 0)
            let lineHeight = AxoMessage.textStyle.lineHeight
            var floatTop: CGFloat = 0
            if float != nil, count > 0 {
                // A float placed after the last word goes on that line if it fits, else below.
                floatTop = (lines?.widths.last ?? 0) + floatSize.width <= inner + 0.01 ? (count - 1) * lineHeight : count * lineHeight
            }
            let contentHeight = max(count * lineHeight, float == nil ? 0 : floatTop + floatSize.height)
            return (contentHeight + padding.top + padding.bottom, floatTop)
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let w = width(proposal, subviews)
            return CGSize(width: w, height: flow(width: w, subviews).height)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let inner = max(0, bounds.width - padding.leading - padding.trailing)
            let floatTop = flow(width: bounds.width, subviews).floatTop
            let x0 = bounds.minX + padding.leading, y0 = bounds.minY + padding.top
            for s in subviews {
                if s[FloatKey.self] {
                    let size = s.sizeThatFits(.unspecified)
                    s.place(at: CGPoint(x: x0 + inner - size.width, y: y0 + floatTop), proposal: ProposedViewSize(size))
                } else {
                    s.place(at: CGPoint(x: x0, y: y0), proposal: ProposedViewSize(width: inner, height: nil))
                }
            }
        }
    }

    /**
     * <AxoMessage.Text>
     * --------------------------------------------------------------------------
     */

    public struct TextValue: Sendable, Hashable {
        public var body: String
        public init(body: String) { self.body = body }
    }

    public struct Text: View {
        let text: TextValue

        public init(text: TextValue) {
            self.text = text
        }

        public var body: some View {
            CSSText(text.body, style: AxoMessage.textStyle, wrap: .wrap)
                .textSelection(.enabled)
                .layoutValue(key: InlineTextKey.self, value: text.body)
        }
    }

    /**
     * <AxoMessage.Meta>
     * --------------------------------------------------------------------------
     */

    /// `span.float-end`: a non-breaking space then `inline-flex gap-[0.5ch] type-caption`,
    /// baseline-aligned in a line of the body text.
    public struct Meta<Content: View>: View {
        let content: Content
        @Environment(\.axoMessageDirection) var direction

        public init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        public var body: some View {
            let offset = AxoInlineText.baseline(AxoMessage.textStyle) - AxoInlineText.baseline(CSSTextStyle(AxoMessage.metaType))
            HStack(alignment: .top, spacing: 0) {
                // &nbsp; (CSSText would let it hang like collapsible trailing space)
                Color.clear.frame(width: AxoMessage.nbspWidth, height: 1)
                HStack(alignment: .top, spacing: 0.5 * AxoMessage.metaCh) { content }
                    .frame(height: AxoMessage.metaType.lineHeight)
                    .padding(.top, offset)
                    .cssTextColor(direction == .incoming ? .labelSecondary : .labelSecondaryOncolor)
            }
            .frame(height: AxoMessage.textStyle.lineHeight, alignment: .top)
            .fixedSize()
            .layoutValue(key: FloatKey.self, value: true)
        }
    }

    /**
     * <AxoMessage.MetaTimestamp>
     * --------------------------------------------------------------------------
     */

    /// `time.min-w-[3.5ch].text-end`
    public struct MetaTimestamp: View {
        let sentAt: Date
        let display: String

        public init(sentAt: Date, _ display: String) {
            self.sentAt = sentAt
            self.display = display
        }

        public var body: some View {
            CSSText(display, type: AxoMessage.metaType, wrap: .nowrap)
                .frame(minWidth: 3.5 * AxoMessage.metaCh, alignment: .trailing)
                .accessibilityValue(sentAt.formatted(.iso8601))
        }
    }

    /// `<AxoMessage.MetaExpireTimer>`
    public struct MetaExpireTimer: View {
        let expireTimer: AxoExpireTimer.ExpireTimer
        let now: Date?

        public init(expireTimer: AxoExpireTimer.ExpireTimer, now: Date? = nil) {
            self.expireTimer = expireTimer
            self.now = now
        }

        public var body: some View {
            AxoExpireTimer.Root(expireTimer: expireTimer, type: AxoMessage.metaType, now: now)
        }
    }

    /// `<AxoMessage.MetaOutgoingStatus>`
    public struct MetaOutgoingStatus: View {
        let status: AxoOutgoingStatus.Status
        let label: String??

        public init(status: AxoOutgoingStatus.Status, label: String?? = nil) {
            self.status = status
            self.label = label
        }

        public var body: some View {
            AxoOutgoingStatus.Root(status: status, label: label, type: AxoMessage.metaType)
        }
    }

    /// `<AxoMessage.MetaAction>`: a text button in the meta (font inherited).
    public struct MetaAction: View {
        let label: String
        let action: () -> Void

        public init(_ label: String, onClick action: @escaping () -> Void) {
            self.label = label
            self.action = action
        }

        public var body: some View {
            Button(action: action) {
                CSSText(label, type: AxoMessage.metaType, wrap: .nowrap)
            }
            .buttonStyle(.plain)
        }
    }
}

extension EnvironmentValues {
    @Entry var axoMessageDirection: AxoMessage.Direction = .incoming
}
