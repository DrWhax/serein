// Port of ts/components/conversation/ReactionViewer.dom.tsx (+ `.module-reaction-viewer` in
// stylesheets/_modules.scss): the popover listing who reacted. A header of category pills
// ("All · N", then each emoji with its count, in the default reaction order, others after),
// and below the reactors of the selected category, newest first. A picked category that no
// longer exists falls back to All (or closes the viewer when nothing is left).

import SignalI18n
import SwiftUI

/// `Reaction` in ReactionViewer.
public struct ReactionViewerReaction: Sendable, Hashable {
    public struct From: Sendable, Hashable {
        public var id: String
        public var title: String
        public var isMe = false
        public var color = "A200"
        public var avatar: RGBAImage?
        public init(id: String, title: String, isMe: Bool = false, color: String = "A200", avatar: RGBAImage? = nil) {
            self.id = id
            self.title = title
            self.isMe = isMe
            self.color = color
            self.avatar = avatar
        }
    }
    public var emoji: String
    public var timestamp: Date
    public var from: From
    public init(emoji: String, timestamp: Date, from: From) {
        self.emoji = emoji
        self.timestamp = timestamp
        self.from = from
    }
}

public enum ReactionEmoji {
    /// `DEFAULT_EMOJI_ORDER`
    public static let defaultOrder = ["❤️", "👍", "👎", "😂", "😮", "😢", "😡"]

    /// `Emoji.getParent`: the emoji without its skin-tone modifiers.
    public static func parent(_ emoji: String) -> String {
        var s = String.UnicodeScalarView()
        for u in emoji.unicodeScalars where !(0x1F3FB...0x1F3FF).contains(u.value) { s.append(u) }
        return String(s)
    }

    /// `Emoji.getDefaultPreferredReactionEmojis(SkinTone.None)`
    public static let defaultPreferred = ["❤️", "👍", "👎", "😂", "😮", "😢"]
}

public struct ReactionViewer: View {
    struct Category: Identifiable {
        var id: String
        var emoji: String?
        var count: Int
        var index: Int
    }

    let reactions: [ReactionViewerReaction]
    let onClose: (() -> Void)?
    @State private var selected: String
    @State private var allFocusVisible = true     // the All button takes focus on open
    @FocusState private var focused: String?
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering

    public init(reactions: [ReactionViewerReaction], pickedReaction: String? = nil, onClose: (() -> Void)? = nil) {
        self.reactions = reactions
        self.onClose = onClose
        _selected = State(initialValue: pickedReaction.map { ReactionEmoji.parent($0) } ?? "all")
    }

    /// Newest first; lodash orderBy is stable for equal timestamps.
    static func newestFirst(_ list: [ReactionViewerReaction]) -> [ReactionViewerReaction] {
        list.enumerated().sorted { a, b in
            a.element.timestamp != b.element.timestamp ? a.element.timestamp > b.element.timestamp : a.offset < b.offset
        }.map(\.element)
    }

    var groups: [String: [ReactionViewerReaction]] {
        var out: [String: [ReactionViewerReaction]] = ["all": Self.newestFirst(reactions)]
        var order: [String] = []
        var byParent: [String: [ReactionViewerReaction]] = [:]
        for r in reactions {
            let p = ReactionEmoji.parent(r.emoji)
            if byParent[p] == nil { order.append(p) }
            byParent[p, default: []].append(r)
        }
        for (p, list) in byParent { out[p] = Self.newestFirst(list) }
        return out
    }

    var categories: [Category] {
        // Object.groupBy keeps first-seen order; the sort below is stable.
        var order: [String] = []
        for r in reactions {
            let p = ReactionEmoji.parent(r.emoji)
            if !order.contains(p) { order.append(p) }
        }
        let groups = self.groups
        var out = [Category(id: "all", emoji: nil, count: reactions.count, index: 0)]
        for p in order {
            let list = groups[p] ?? []
            // The local user's reaction first, else the newest.
            guard let first = list.first(where: { $0.from.isMe }) ?? list.first else { continue }
            out.append(Category(id: p, emoji: first.emoji, count: list.count, index: ReactionEmoji.defaultOrder.firstIndex(of: p) ?? Int.max))
        }
        return out.enumerated().sorted { a, b in
            a.element.index != b.element.index ? a.element.index < b.element.index : a.offset < b.offset
        }.map(\.element)
    }

    /// `@include mixins.popper-shadow`
    static var popperShadow: [AxoShadowLayer] {
        [AxoShadowLayer(inset: false, x: 0, y: 8, blur: 20, spread: 0, color: RGBA(0, 0, 0, 0.3)),
         AxoShadowLayer(inset: false, x: 0, y: 0, blur: 8, spread: 0, color: RGBA(0, 0, 0, 0.05))]
    }

    var effectiveSelection: String { categories.contains { $0.id == selected } ? selected : "all" }

    public var body: some View {
        let categories = self.categories
        let rows = groups[effectiveSelection] ?? []
        VStack(spacing: 0) {
            header(categories)
            bodyRows(rows)
        }
        .frame(width: 320, height: 320)
        .background(RoundedRectangle(cornerRadius: 8).fill(AxoColor(light: LegacyColor.white, dark: LegacyColor.gray75)))
        .cssBoxShadow(Self.popperShadow, in: RoundedRectangle(cornerRadius: 8))
        .onKeyPress(.escape) { onClose?(); return onClose == nil ? .ignored : .handled }
        .onAppear { focused = "all" }
        .onChange(of: categories.map(\.id)) {
            if !categories.contains(where: { $0.id == selected }) {
                if reactions.isEmpty { onClose?() } else { selected = "all" }
            }
        }
    }

    @ViewBuilder func header(_ categories: [Category]) -> some View {
        let pills = HStack(spacing: 4) {
            ForEach(categories) { c in headerButton(c) }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 44)
        if staticRendering {
            Color.clear.frame(height: 44).overlay(alignment: .leading) { pills.fixedSize() }.clipped()
        } else {
            ScrollView(.horizontal, showsIndicators: false) { pills }.frame(height: 44)
        }
    }

    func headerButton(_ c: Category) -> some View {
        let text = AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05)
        let style = LegacyType.body2(weight: 600)
        let isSelected = effectiveSelection == c.id
        let showsFocus = c.id == "all" ? (focused == "all" || (allFocusVisible && staticRendering)) : focused == c.id
        return SwiftUI.Button {
            selected = c.id
        } label: {
            HStack(spacing: 0) {
                if let emoji = c.emoji {
                    FunStaticEmoji(emoji, size: 18)
                    CSSText("\(c.count)", style: style, wrap: .nowrap, color: text).padding(.leading, 4)
                } else {
                    CSSText(i18n("icu:ReactionsViewer--all") + "\u{2009}·\u{2009}\(c.count)", style: style, wrap: .nowrap, color: text)
                }
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 45, minHeight: 28)
            .background(Capsule().fill(isSelected ? AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray60) : AxoColor(RGBA(0, 0, 0, 0))))
            .overlay { if showsFocus { Capsule().inset(by: -2).strokeBorder(AxoColor(LegacyColor.ultramarine), lineWidth: 2) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .focused($focused, equals: c.id)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder func bodyRows(_ rows: [ReactionViewerReaction]) -> some View {
        let list = VStack(spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in row(r) }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .top)
        if staticRendering {
            list.fixedSize(horizontal: false, vertical: true).frame(height: 320 - 44, alignment: .top).clipped()
        } else {
            ScrollView(.vertical) { list }.frame(maxHeight: .infinity)
        }
    }

    func row(_ r: ReactionViewerReaction) -> some View {
        HStack(spacing: 0) {
            Avatar(strings: AvatarStrings(i18n: i18n), title: r.from.title, size: 32, conversationType: .direct, color: r.from.color,
                   image: r.from.avatar.map { AnyView(PixelImage($0, fit: .cover)) })
            CSSText(runs: [r.from.isMe ? CSSTextRun(i18n("icu:you")) : Emojify.run(r.from.title)], style: LegacyType.body1(weight: 600),
                    wrap: .truncate, color: AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
            // vertical-align: top in the div's 20px line box; the div is centred in the row.
            FunStaticEmoji(r.emoji, size: 18).frame(width: 18, height: 20, alignment: .top)
        }
        .frame(minHeight: 32)
    }
}
