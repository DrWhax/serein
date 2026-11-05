// ContactName (ts/components/conversation/ContactName.dom.tsx + stylesheets/components/
// ContactName.scss): the title (or first name when preferred) in the group member's contact
// name colour, the official badge for Note to Self / Signal's chat, then the group member
// label pill (GroupMemberLabel).
//
// The pill is an inline-block after a space: it stays on the name's line when it fits and
// wraps to its own line otherwise, capped at the container width (− its 2px start margin),
// its text ellipsised. It is `overflow: hidden`, so its baseline is its bottom margin edge:
// with `margin-bottom: -4px` (bubble), its bottom sits 4px below the text baseline.

import SwiftUI

/// `MemberLabelType`: the label text and optional emoji (nil: none; invalid: the placeholder).
public struct ContactLabel: Sendable, Hashable {
    public var labelString: String
    public var labelEmoji: String?
    public init(labelString: String, labelEmoji: String? = nil) {
        self.labelString = labelString
        self.labelEmoji = labelEmoji
    }
}

public struct ContactName: View {
    let title: String
    let firstName: String?
    let preferFirstName: Bool
    let isMe: Bool
    let isSignalConversation: Bool
    let contactNameColor: String?
    let contactLabel: ContactLabel?
    let style: CSSTextStyle
    let wrap: CSSTextWrap
    let onClick: (() -> Void)?
    @State private var hovered = false

    public init(title: String, firstName: String? = nil, preferFirstName: Bool = false, isMe: Bool = false, isSignalConversation: Bool = false,
                contactNameColor: String? = nil, contactLabel: ContactLabel? = nil, style: CSSTextStyle, wrap: CSSTextWrap = .truncate,
                onClick: (() -> Void)? = nil) {
        self.title = title
        self.firstName = firstName
        self.preferFirstName = preferFirstName
        self.isMe = isMe
        self.isSignalConversation = isSignalConversation
        self.contactNameColor = contactNameColor
        self.contactLabel = contactLabel
        self.style = style
        self.wrap = wrap
        self.onClick = onClick
    }

    var text: String { preferFirstName ? (firstName.flatMap { $0.isEmpty ? nil : $0 } ?? title) : title }

    /// `--contact-name-color-light / -dark`
    var nameColor: AxoColor? { contactNameColor.map { AxoTokens.Contact.color($0) } }

    public var body: some View {
        let name = HStack(spacing: 0) {
            CSSText(runs: [nameRun], style: style, wrap: wrap, color: nameColor)
            if isMe || isSignalConversation {
                CSSText("\u{00A0}", style: style, wrap: .nowrap)
                OfficialChatInlineBadge(size: style.size, weight: style.weight)
            }
        }
        Group {
            if let contactLabel {
                ContactNameFlow(space: CSSTextLayout.make("\u{00A0}", style, wrap: .nowrap, maxWidth: nil).width, lineHeight: style.lineHeight,
                                baseline: Self.baseline(style)) {
                    name
                    GroupMemberLabel(contactLabel: contactLabel, contactNameColor: contactNameColor, context: .bubble)
                }
            } else {
                name
            }
        }
        .contentShape(Rectangle())
        .onHover { if onClick != nil { hovered = $0 } }
        .onTapGesture { onClick?() }
        .accessibilityAddTraits(onClick != nil ? .isButton : [])
    }

    var nameRun: CSSTextRun {
        var r = Emojify.run(text)
        r.underline = hovered && onClick != nil     // :where(button):hover
        return r
    }

    /// The text baseline from the line top (Blink: half-leading floored, ascent rounded).
    static func baseline(_ style: CSSTextStyle) -> CGFloat {
        let font = style.ctFont
        let a = CTFontGetAscent(font).rounded(), d = CTFontGetDescent(font).rounded()
        return ((style.lineHeight - (a + d)) / 2).rounded(.down) + a
    }
}

/// The name, then the pill (subview 1) on the same line when it fits, else on the next line.
struct ContactNameFlow: Layout {
    let space: CGFloat
    let lineHeight: CGFloat
    let baseline: CGFloat
    static let margin: CGFloat = 2

    func frames(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (CGSize, CGRect, CGRect) {
        let limit = proposal.width ?? .infinity
        let name = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let pillIdeal = subviews[1].sizeThatFits(.unspecified)
        let pillMax = max(0, limit - Self.margin)
        let pillWidth = min(pillIdeal.width, pillMax)
        let pillHeight = pillIdeal.height
        // Bottom margin edge (−4px) on the baseline.
        let pillTop = baseline + 4 - pillHeight
        // The pill's line box grows the line where it pokes out above / below.
        let above = max(0, -pillTop), below = max(0, pillTop + pillHeight - lineHeight)
        let x = name.width + space + Self.margin
        if x + pillWidth <= limit + 0.01 {
            let nameRect = CGRect(origin: CGPoint(x: 0, y: above), size: name)
            let pill = CGRect(x: x, y: above + pillTop, width: pillWidth, height: pillHeight)
            return (CGSize(width: x + pillWidth, height: max(name.height, lineHeight) + above + below), nameRect, pill)
        }
        let nameRect = CGRect(origin: .zero, size: name)
        let pill = CGRect(x: Self.margin, y: name.height + above + pillTop, width: pillWidth, height: pillHeight)
        return (CGSize(width: max(name.width, Self.margin + pillWidth), height: name.height + lineHeight + above + below), nameRect, pill)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { frames(proposal, subviews).0 }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (_, name, pill) = frames(ProposedViewSize(width: proposal.width ?? bounds.width, height: nil), subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX + name.minX, y: bounds.minY + name.minY), proposal: ProposedViewSize(name.size))
        subviews[1].place(at: CGPoint(x: bounds.minX + pill.minX, y: bounds.minY + pill.minY), proposal: ProposedViewSize(pill.size))
    }
}

/// GroupMemberLabel: `.module-contact-name--label-pill` (font-body-small, radius 9, padding
/// 1px 6px, nowrap + ellipsis) with the emoji (12px, padding 2px 3px 2px 0) and the label.
public struct GroupMemberLabel: View {
    public enum Context: Sendable { case bubble, list, quote, contactModal }
    let contactLabel: ContactLabel
    let contactNameColor: String?
    let context: Context
    let emojiSize: CGFloat

    public init(contactLabel: ContactLabel, contactNameColor: String?, context: Context, emojiSize: CGFloat = 12) {
        self.contactLabel = contactLabel
        self.contactNameColor = contactNameColor
        self.context = context
        self.emojiSize = emojiSize
    }

    /// `missingEmojiPlaceholder`
    static let missingEmojiPlaceholder = "\u{2370}"

    var colors: (text: AxoColor, background: AxoColor) {
        let c = contactNameColor.map { AxoTokens.Contact.color($0) } ?? AxoColor(LegacyColor.gray60)
        func alpha(_ v: RGBA, _ a: Double) -> RGBA { RGBA(v.r, v.g, v.b, a) }
        let black = RGBA(0, 0, 0), white = RGBA(1, 1, 1)
        switch context {
        case .bubble:
            return (AxoColor(light: RGBA.mix(c.light, black, 0.7), dark: RGBA.mix(c.dark, white, 0.68)),
                    AxoColor(light: alpha(c.light, 0.14), dark: alpha(c.dark, 0.32)))
        case .list, .contactModal:
            return (AxoColor(light: RGBA.mix(c.light, black, 0.3), dark: RGBA.mix(c.dark, white, 0.25)),
                    AxoColor(light: alpha(c.light, 0.1), dark: alpha(c.dark, 0.32)))
        case .quote:
            return (AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05), AxoColor(light: LegacyColor.whiteAlpha36, dark: LegacyColor.whiteAlpha20))
        }
    }

    public var body: some View {
        if context == .contactModal { contactModalBody } else { pillBody }
    }

    @ViewBuilder var emojiBox: some View {
        if let emoji = contactLabel.labelEmoji {
            Group {
                if emoji.count == 1, let ch = emoji.first, CSSTextLayout.isEmoji(ch) {
                    FunStaticEmoji(emoji, size: emojiSize)
                } else {
                    CSSText(Self.missingEmojiPlaceholder, style: { var s = LegacyType.bodySmall(); s.lineHeight = 12; return s }(), wrap: .nowrap)
                }
            }
            .padding(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 3))
            .fixedSize()
        }
    }

    /// `--label-pill--contact-modal`: the inner box is body-1, top-aligned, and wraps
    /// (white-space: normal); the pill's -5px bottom margin leaves its button 1px shorter.
    var contactModalBody: some View {
        let (text, background) = colors
        return HStack(alignment: .top, spacing: 0) {
            emojiBox
            let runs = [Emojify.run(contactLabel.labelString, fontSizeOverride: emojiSize, topMargin: emojiSize / 6)]
            // An inline-block with overflow hidden + text-overflow ellipsis: it wraps where it
            // can; a line that still overflows is clipped with an ellipsis.
            WrapOrEllipsis {
                CSSText(runs: runs, style: LegacyType.body1(), wrap: .wrap)
                CSSText(runs: runs, style: LegacyType.body1(), wrap: .truncate)
            }
        }
        .cssTextColor(text)
        .padding(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .background(RoundedRectangle(cornerRadius: 9).fill(background))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .padding(.bottom, -1)
    }

    var pillBody: some View {
        let (text, background) = colors
        let style = LegacyType.bodySmall()
        return HStack(alignment: .center, spacing: 0) {
            if let emoji = contactLabel.labelEmoji {
                Group {
                    if emoji.count == 1, let ch = emoji.first, CSSTextLayout.isEmoji(ch) {
                        FunStaticEmoji(emoji, size: emojiSize)
                    } else {
                        CSSText(Self.missingEmojiPlaceholder, style: { var s = style; s.lineHeight = 12; return s }(), wrap: .nowrap)
                    }
                }
                .padding(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 3))
                .fixedSize()
            }
            // .module-contact-name--label-pill--text (UserText at the emoji size, top-aligned)
            CSSText(runs: [Emojify.run(contactLabel.labelString, fontSizeOverride: emojiSize, topMargin: emojiSize / 6)], style: style, wrap: .truncate)
                .layoutPriority(-1)
        }
        .frame(height: 16)
        .cssTextColor(text)
        .padding(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .background(RoundedRectangle(cornerRadius: 9).fill(background))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// Shows subview 0 (wrapping text) when it fits the proposed width, else subview 1 (the same
/// text truncated to one line).
struct WrapOrEllipsis: Layout {
    func choice(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Int {
        guard let w = proposal.width else { return 0 }
        return subviews[0].sizeThatFits(proposal).width > w + 0.01 ? 1 : 0
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let i = choice(proposal, subviews)
        let size = subviews[i].sizeThatFits(proposal)
        guard let w = proposal.width else { return size }
        // Shrink-to-fit: content wider than the space (wrapped or clipped) takes all of it.
        let maxContent = subviews[0].sizeThatFits(.unspecified).width
        return CGSize(width: maxContent > w + 0.01 ? w : min(size.width, w), height: size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let i = choice(proposal, subviews)
        subviews[i].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        subviews[1 - i].place(at: CGPoint(x: bounds.minX - 100_000, y: bounds.minY), proposal: .zero)
    }
}

/// FunStaticEmoji (ts/components/fun/FunEmoji.dom.tsx, `__Text` rendering): the emoji glyph
/// in Signal's emoji font, centred in a `size`² box.
public struct FunStaticEmoji: View {
    let emoji: String
    let size: CGFloat
    /// false when the emoji is drawn under a CSS transform (scale): Blink then snaps the
    /// baseline on the transformed device grid, not at this size.
    let snapsBaseline: Bool
    public init(_ emoji: String, size: CGFloat, snapsBaseline: Bool = true) {
        self.emoji = emoji
        self.size = size
        self.snapsBaseline = snapsBaseline
    }
    /// Over 16px, `.FunStaticEmoji__Text` has 0.5px top padding (at 2x) and Blink centres the
    /// emoji line in the box with Signal Emoji's hhea metrics (ascent 1em, descent 0.3125em,
    /// each rounded). That puts the baseline at size/2 + 0.25 + (A − D)/2, where the inline-emoji
    /// layout CSSText uses puts it at round(0.875 × size). Measured against the reaction
    /// stories (18px, 48px).
    var glyphShift: CGFloat {
        guard size > 16 else { return 0 }
        let a = size.rounded(), d = (size * 0.3125).rounded()
        // Blink rounds the glyph baseline down to the 2x device-pixel grid.
        let exact = size / 2 + 0.25 + (a - d) / 2
        let baseline = snapsBaseline ? (exact * 2).rounded(.down) / 2 : exact
        return baseline - (size * 0.875).rounded()
    }

    public var body: some View {
        CSSText(runs: [Emojify.run(emoji, fontSizeOverride: size)],
                style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: size, lineHeight: size), wrap: .nowrap)
            .offset(y: glyphShift)
            .frame(width: size, height: size)
            .accessibilityLabel(emoji)
    }
}
