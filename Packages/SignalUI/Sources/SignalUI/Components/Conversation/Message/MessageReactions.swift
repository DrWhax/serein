// Message.dom.tsx `MessageReactions` (stylesheets/_modules.scss .module-message__reactions): up to
// three reaction pills under the bubble — the most used emoji first, with counts — the third
// turning into "+N" when more emoji were used; your own reactions are highlighted.

import SignalI18n
import SwiftUI

public struct MessageReaction: Sendable, Hashable {
    public var emoji: String
    public var fromIsMe: Bool
    public var fromTitle: String
    /// Milliseconds since 1970.
    public var timestamp: Double
    public init(emoji: String, fromIsMe: Bool = false, fromTitle: String = "", timestamp: Double) {
        self.emoji = emoji
        self.fromIsMe = fromIsMe
        self.fromTitle = fromTitle
        self.timestamp = timestamp
    }

    /// `Emoji.getParent`: the emoji without skin-tone modifiers.
    var parent: String { String(String.UnicodeScalarView(emoji.unicodeScalars.filter { !(0x1F3FB...0x1F3FF).contains($0.value) })) }
}

/// `useGroupedAndOrderedReactions(reactions, 'parent')`: groups by parent emoji, each ordered
/// yours first then newest; groups by size, then by their first reaction's time (both
/// descending; stable, as lodash orderBy).
func groupedAndOrderedReactions(_ reactions: [MessageReaction]) -> [[MessageReaction]] {
    var order: [String] = []
    var groups: [String: [MessageReaction]] = [:]
    for r in reactions {
        if groups[r.parent] == nil { order.append(r.parent) }
        groups[r.parent, default: []].append(r)
    }
    func stableSorted<T>(_ a: [T], by less: (T, T) -> Bool) -> [T] {
        a.enumerated().sorted { x, y in less(x.element, y.element) || (!less(y.element, x.element) && x.offset < y.offset) }.map(\.element)
    }
    let inner = order.map { key in
        stableSorted(groups[key] ?? []) { a, b in
            a.fromIsMe != b.fromIsMe ? a.fromIsMe : a.timestamp > b.timestamp
        }
    }
    return stableSorted(inner) { a, b in
        a.count != b.count ? a.count > b.count : (a.first?.timestamp ?? 0) > (b.first?.timestamp ?? 0)
    }
}

struct MessageReactions: View {
    let reactions: [MessageReaction]
    let outgoing: Bool
    let toggleReactionViewer: (() -> Void)?
    @Environment(\.i18n) var i18n

    var body: some View {
        let ordered = groupedAndOrderedReactions(reactions)
        let toRender = Array(ordered.prefix(3))
        let someNotRendered = ordered.count > 3
        let maybeNotRendered = ordered.dropFirst(2)
        let notRenderedTotal = maybeNotRendered.reduce(0) { $0 + $1.count }
        let notRenderedIsMe = someNotRendered && maybeNotRendered.contains { $0.contains(where: \.fromIsMe) }
        HStack(spacing: 0) {
            ForEach(toRender.indices, id: \.self) { i in
                let group = toRender[i]
                let isMe = group.contains(where: \.fromIsMe)
                let isMore = i == toRender.count - 1 && someNotRendered
                let highlighted = isMore ? notRenderedIsMe : isMe
                pill(group: group, isMore: isMore, moreTotal: notRenderedTotal, highlighted: highlighted, countIsMe: isMore ? notRenderedIsMe : isMe)
            }
        }
        .frame(height: 22)
        // --incoming: padding-inline-end 8px, margin-inline-start 8px (mirrored for outgoing)
        .padding(.horizontal, 8)
    }

    func label(_ group: [MessageReaction]) -> String {
        let emoji = group.first?.emoji ?? ""
        if group.contains(where: \.fromIsMe) { return i18n("icu:Message__reaction-emoji-label--you", ["emoji": .string(emoji)]) }
        if group.count == 1 {
            return i18n("icu:Message__reaction-emoji-label--single", ["title": .string(group.first?.fromTitle ?? ""), "emoji": .string(emoji)])
        }
        return i18n("icu:Message__reaction-emoji-label--many", ["count": .number(Double(group.count)), "emoji": .string(emoji)])
    }

    func pill(group: [MessageReaction], isMore: Bool, moreTotal: Int, highlighted: Bool, countIsMe: Bool) -> some View {
        let count = group.count
        let countColor = countIsMe ? AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray15) : AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25)
        let countStyle = LegacyType.caption(weight: 600)
        return SwiftUI.Button { toggleReactionViewer?() } label: {
            HStack(spacing: 0) {
                if isMore {
                    CSSText("+\(moreTotal)", style: countStyle, wrap: .nowrap, color: countColor)
                } else {
                    FunStaticEmoji(group.first?.emoji ?? "", size: 16)
                    if count > 1 { CSSText("\(count)", style: countStyle, wrap: .nowrap, color: countColor).padding(.leading, 4) }
                }
            }
            // padding-inline 6px (with a count) inside the 1px border (border-box min widths).
            .padding(.horizontal, (count > 1 && !isMore ? 6 : 0) + 1)
            .frame(minWidth: count > 1 && !isMore ? 40 : 28, minHeight: 22)
            .background(highlighted ? AxoColor(light: LegacyColor.gray25, dark: LegacyColor.gray60) : AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray90),
                        in: Capsule())
            .overlay { Capsule().strokeBorder(AxoColor(light: LegacyColor.white, dark: LegacyColor.gray95), lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMore ? "+\(moreTotal)" : label(group))
    }
}
