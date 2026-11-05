// Port of ts/axo/chatList/AxoChatItem.dom.tsx: a full chat list row (68pt with a 48pt
// avatar): label (+ icon) and timestamp over a two-line description, outgoing status and
// badges; or a label with a count / accessory.
//
// Content is a grid (_AxoBaseChatItem.css):
//   'label label-icon timestamp timestamp timestamp' auto
//   'description description description outgoing-status badges' auto
//   / minmax(0, max-content) auto 1fr auto auto

import Foundation
import SwiftUI

public enum AxoChatItem {
    /// `<AxoChatItem.Root>`
    public struct Root<Content: View>: View {
        let content: Content

        public init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        public var body: some View {
            AxoBaseChatItem.Root(compact: false, content: content)
        }
    }

    /// `<AxoChatItem.Avatar>`
    public struct Avatar<Content: View>: View {
        let content: Content

        public init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }

        public var body: some View { AxoBaseChatItem.Avatar(content: content) }
    }

    /// `<AxoChatItem.IconAvatar>` (48pt)
    public struct IconAvatar: View {
        let symbol: AxoSymbol.Name
        public init(symbol: AxoSymbol.Name) { self.symbol = symbol }
        public var body: some View { AxoBaseChatItem.IconAvatar(size: 48, symbol: symbol) }
    }

    enum Area: Sendable { case label, labelIcon, timestamp, description, outgoingStatus, badges }
    struct AreaKey: LayoutValueKey { static let defaultValue = Area.description }

    /// `<AxoChatItem.Content>`: the grid, filling the row (min-w-0 flex-1).
    public struct Content<Children: View>: View {
        let children: Children

        public init(@ViewBuilder content: () -> Children) {
            self.children = content()
        }

        public var body: some View {
            ContentGrid { children }
                .layoutValue(key: AxoBaseChatItem.FlexGrowKey.self, value: true)
        }
    }

    struct ContentGrid: Layout {
        func find(_ a: Area, _ subviews: Subviews) -> LayoutSubview? { subviews.first { $0[AreaKey.self] == a } }

        func columns(_ width: CGFloat, _ subviews: Subviews) -> (label: CGFloat, description: CGFloat) {
            let icon = find(.labelIcon, subviews)?.sizeThatFits(.unspecified).width ?? 0
            let time = find(.timestamp, subviews)?.sizeThatFits(.unspecified).width ?? 0
            let status = find(.outgoingStatus, subviews)?.sizeThatFits(.unspecified).width ?? 0
            let badges = find(.badges, subviews)?.sizeThatFits(.unspecified).width ?? 0
            let labelNatural = find(.label, subviews)?.sizeThatFits(.unspecified).width ?? 0
            return (max(0, min(labelNatural, width - icon - time)), max(0, width - status - badges))
        }

        func rowHeights(_ width: CGFloat, _ subviews: Subviews) -> (CGFloat, CGFloat) {
            let top = [Area.label, .labelIcon, .timestamp].compactMap { find($0, subviews)?.sizeThatFits(.unspecified).height }.max() ?? 0
            let cols = columns(width, subviews)
            let bottom = [find(.description, subviews)?.sizeThatFits(ProposedViewSize(width: cols.description, height: nil)).height,
                          find(.outgoingStatus, subviews)?.sizeThatFits(.unspecified).height,
                          find(.badges, subviews)?.sizeThatFits(.unspecified).height].compactMap { $0 }.max() ?? 0
            return (top, bottom)
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = proposal.width ?? 0
            let (top, bottom) = rowHeights(width, subviews)
            return CGSize(width: width, height: top + bottom)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let (top, _) = rowHeights(bounds.width, subviews)
            let cols = columns(bounds.width, subviews)
            let x0 = bounds.minX, y0 = bounds.minY
            var labelEnd = x0
            if let s = find(.label, subviews) {
                let h = s.sizeThatFits(.unspecified).height
                s.place(at: CGPoint(x: x0, y: y0 + (top - h) / 2), proposal: ProposedViewSize(width: cols.label, height: h))
                labelEnd = x0 + cols.label
            }
            if let s = find(.labelIcon, subviews) {
                let sz = s.sizeThatFits(.unspecified)
                s.place(at: CGPoint(x: labelEnd, y: y0 + (top - sz.height) / 2), proposal: ProposedViewSize(sz))
            }
            if let s = find(.timestamp, subviews) {
                let sz = s.sizeThatFits(.unspecified)
                s.place(at: CGPoint(x: bounds.maxX - sz.width, y: y0 + (top - sz.height) / 2), proposal: ProposedViewSize(sz))
            }
            var x = bounds.maxX
            for a in [Area.badges, .outgoingStatus] {
                if let s = find(a, subviews) {
                    let sz = s.sizeThatFits(.unspecified)
                    x -= sz.width
                    s.place(at: CGPoint(x: x, y: y0 + top), proposal: ProposedViewSize(sz))
                }
            }
            if let s = find(.description, subviews) {
                s.place(at: CGPoint(x: x0, y: y0 + top), proposal: ProposedViewSize(width: cols.description, height: nil))
            }
        }
    }

    /// `<AxoChatItem.Label>`: truncate type-title-small text-primary leading-4.5
    public struct Label: View {
        let text: String
        public init(_ text: String) { self.text = text }
        public var body: some View {
            CSSText(text, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 600), size: 14, lineHeight: 18,
                                              letterSpacing: AxoType.titleSmall.tracking * 14), wrap: .truncate, color: .labelPrimary)
                .layoutValue(key: AreaKey.self, value: .label)
        }
    }

    /// `<AxoChatItem.LabelIcon>`: ms-1.5 text-secondary, a 14pt icon.
    public struct LabelIcon: View {
        let symbol: AxoSymbol.Name
        let label: String?
        public init(symbol: AxoSymbol.Name, label: String?) {
            self.symbol = symbol
            self.label = label
        }
        public var body: some View {
            AxoSymbol.Icon(symbol, size: 14, label: label)
                .cssTextColor(.labelSecondary)
                .padding(.leading, 6)
                .layoutValue(key: AreaKey.self, value: .labelIcon)
        }
    }

    /// `<AxoChatItem.Timestamp>`: ms-1.5 whitespace-nowrap type-caption text-secondary
    public struct Timestamp: View {
        let timestamp: Date
        let display: String
        public init(timestamp: Date, _ display: String) {
            self.timestamp = timestamp
            self.display = display
        }
        public var body: some View {
            CSSText(display, type: .caption, wrap: .nowrap, color: .labelSecondary)
                .padding(.leading, 6)
                .layoutValue(key: AreaKey.self, value: .timestamp)
        }
    }

    /// `<AxoChatItem.Description>`: type-body-medium text-secondary line-clamp-2 h-9;
    /// children are inline text (`.text`, or `.styled` for the sender).
    public struct Description: View {
        let pieces: [AxoInlinePiece]
        @Environment(\.layoutDirection) var direction

        public init(_ pieces: [AxoInlinePiece]) {
            self.pieces = pieces
        }

        public var body: some View {
            AxoInlineFlowText(pieces: pieces, style: CSSTextStyle(AxoType.bodyMedium), alignment: .start, maxLines: 2, onAction: { _ in })
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .topLeading)
                .cssTextColor(.labelSecondary)
                .layoutValue(key: AreaKey.self, value: .description)
        }
    }

    /// The sender prefix of a description: `span.font-semibold.text-primary`.
    public static func sender(_ name: String, scheme: ColorScheme) -> AxoInlinePiece {
        .styled(name + ": ", weight: 600, color: AxoColor.labelPrimary.value(for: scheme))
    }

    /// `<AxoChatItem.OutgoingStatus>`: ms-1.5 mt-0.5, a 14pt glyph (leading-none),
    /// secondary or (error) destructive.
    public struct OutgoingStatus: View {
        let status: AxoOutgoingStatus.Status
        let label: String?
        public init(status: AxoOutgoingStatus.Status, label: String?) {
            self.status = status
            self.label = label
        }
        public var body: some View {
            AxoOutgoingStatus.Root(status: status, label: .some(label), type: AxoType(size: 14, lineHeight: 14, weight: 400, tracking: -0.006))
                .cssTextColor(status == .error ? .labelDestructive : .labelSecondary)
                .padding(.leading, 6)
                .padding(.top, 2)
                .layoutValue(key: AreaKey.self, value: .outgoingStatus)
        }
    }

    /// `<AxoChatItem.Badges>`
    public struct Badges: View {
        let unreadCount: Int
        let markedUnread: Bool
        let mentioned: Bool
        public init(unreadCount: Int, markedUnread: Bool, mentioned: Bool) {
            self.unreadCount = unreadCount
            self.markedUnread = markedUnread
            self.mentioned = mentioned
        }
        public var body: some View {
            AxoBaseChatItem.Badges(unreadCount: unreadCount, markedUnread: markedUnread, mentioned: mentioned)
                .layoutValue(key: AreaKey.self, value: .badges)
        }
    }

    /// `<AxoChatItem.HiddenTrigger>`
    public struct HiddenTrigger: View {
        let label: String
        let action: () -> Void
        public init(label: String, onClick action: @escaping () -> Void) {
            self.label = label
            self.action = action
        }
        public var body: some View { AxoBaseChatItem.HiddenTrigger(label: label, action: action) }
    }

    /// `<AxoChatItem.Count>`: a secondary count badge.
    public struct Count: View {
        let count: Int
        let label: String?
        public init(count: Int, label: String?) {
            self.count = count
            self.label = label
        }
        public var body: some View {
            AxoBadge.Root(variant: .secondary, size: .md, value: .count(count), max: AxoBaseChatItem.badgeMax, label: label)
        }
    }

    /// `<AxoChatItem.Accessory>`: flex shrink-0 items-center gap-2 (interactive children).
    public struct Accessory<Content: View>: View {
        let content: Content
        public init(@ViewBuilder content: () -> Content) { self.content = content() }
        public var body: some View { HStack(spacing: 8) { content }.zIndex(1) }
    }
}
