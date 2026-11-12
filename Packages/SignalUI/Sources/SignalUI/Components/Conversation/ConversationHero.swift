// ConversationHero (ts/components/conversation/ConversationHero.dom.tsx): the card at the top
// of a chat's timeline — a 256px column, radius 32, 2px border-secondary, 20px padding (none
// on top) with the 72px avatar overlapping the top edge by 18px, the title (20/24 medium;
// a chevron when it opens the about modal), "Name not verified" (safety tint), the shared
// groups / group members line, an optional group description (2 lines, "read more"), and
// "Safety tips" for message requests. Note to Self and Signal's chat show the official badge.
//
// Subset: the avatar's click-to-download blur and the SafetyTipsModal are presented by the
// caller (`startAvatarDownload`, `onShowSafetyTips`).

import SignalI18n
import SwiftUI

/// `GroupV2Membership` as the hero reads it.
public struct HeroMember: Sendable, Hashable {
    public var isMe: Bool
    /// `titleShortNoDefault` (nil: not known yet).
    public var titleShort: String?
    public init(isMe: Bool = false, titleShort: String?) {
        self.isMe = isMe
        self.titleShort = titleShort
    }
}

public struct ConversationHero: View {
    public enum Kind: Sendable { case direct, group }
    let conversationType: Kind
    let title: String
    let avatar: ConversationAvatarData
    let hasStories: HasStories?
    let isMe: Bool
    let isSignalConversation: Bool
    let acceptedMessageRequest: Bool
    let hasProfileName: Bool
    let hasNickname: Bool
    let isInSystemContacts: Bool
    let isGroupNameVerified: Bool
    let groupDescription: String?
    let sharedGroupNames: [String]
    let memberships: [HeroMember]
    let invitesCount: Int
    let actions: Actions
    @Environment(\.i18n) var i18n

    public struct Actions {
        public var openConversationDetails: () -> Void = {}
        public var viewUserStories: () -> Void = {}
        public var toggleAboutContactModal: () -> Void = {}
        public var toggleProfileNameWarningModal: () -> Void = {}
        public var onShowSafetyTips: () -> Void = {}
        public var onReadMoreDescription: () -> Void = {}
        public init() {}
    }

    public init(conversationType: Kind, title: String, avatar: ConversationAvatarData, hasStories: HasStories? = nil, isMe: Bool = false,
                isSignalConversation: Bool = false, acceptedMessageRequest: Bool = true, hasProfileName: Bool = false, hasNickname: Bool = false,
                isInSystemContacts: Bool = false, isGroupNameVerified: Bool = false, groupDescription: String? = nil, sharedGroupNames: [String] = [],
                memberships: [HeroMember] = [], invitesCount: Int = 0, actions: Actions = Actions()) {
        self.conversationType = conversationType
        self.title = title
        self.avatar = avatar
        self.hasStories = hasStories
        self.isMe = isMe
        self.isSignalConversation = isSignalConversation
        self.acceptedMessageRequest = acceptedMessageRequest
        self.hasProfileName = hasProfileName
        self.hasNickname = hasNickname
        self.isInSystemContacts = isInSystemContacts
        self.isGroupNameVerified = isGroupNameVerified
        self.groupDescription = groupDescription
        self.sharedGroupNames = sharedGroupNames
        self.memberships = memberships
        self.invitesCount = invitesCount
        self.actions = actions
    }

    static var bodyMedium: CSSTextStyle { CSSTextStyle(AxoType.bodyMedium) }

    public var body: some View {
        VStack(spacing: 0) {
            Avatar(strings: AvatarStrings(i18n: i18n), title: avatar.title, size: 72, conversationType: avatar.conversationType,
                   color: avatar.color ?? "A200", image: avatar.image.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: avatar.hasAvatar,
                   noteToSelf: isMe, storyRing: isMe ? nil : hasStories, signalOfficial: isSignalConversation,
                   onClick: hasStories != nil ? actions.viewUserStories : nil)
                .padding(.top, -18)
            content
        }
        // p-5 pt-0 inside the 2px border (border-box, 256px wide)
        .padding(EdgeInsets(top: 2, leading: 22, bottom: 22, trailing: 22))
        .frame(width: 256)
        .background(RoundedRectangle(cornerRadius: 32).fill(isSignalConversation ? AxoColor.legacySignalConversationBg : AxoColor(RGBA(0, 0, 0, 0))))
        .overlay(RoundedRectangle(cornerRadius: 32).strokeBorder(AxoColor.borderSecondary, lineWidth: 2))
    }

    @ViewBuilder var content: some View {
        if isMe {
            titleView(i18n("icu:noteToSelf"), onClick: nil)
            officialBadge.padding(.vertical, 8)
            CSSText(i18n("icu:noteToSelfHero"), style: Self.bodyMedium, alignment: .center, color: .labelPrimary).padding(.top, 8)
        } else if isSignalConversation {
            titleView(title, onClick: nil)
            officialBadge.padding(.vertical, 8)
            CSSText(i18n("icu:ConversationHero--signal-official-account--description"), style: Self.bodyMedium, alignment: .center, color: .labelPrimary)
        } else if conversationType == .direct {
            titleView(title, onClick: actions.toggleAboutContactModal)
            if hasProfileName && !(hasNickname || isInSystemContacts) { nameNotVerified }
            line(SharedGroupNames.pieces(sharedGroupNames, i18n)).padding(.top, 10)
            if !acceptedMessageRequest { safetyTips }
        } else {
            titleView(title, onClick: nil)
            if !isGroupNameVerified { nameNotVerified }
            if let groupDescription, !groupDescription.isEmpty {
                GroupDescription(title: title, text: groupDescription, alignment: .center, onReadMore: actions.onReadMoreDescription)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
            line(GroupMembersNames.pieces(memberships, invitesCount: invitesCount, i18n), onAction: actions.openConversationDetails)
                .padding(.top, 10)
            if !acceptedMessageRequest { safetyTips }
        }
    }

    /// `mt-2.5 text-center type-body-medium text-primary`: the group glyph, then the names.
    func line(_ pieces: [AxoInlinePiece], onAction: @escaping () -> Void = {}) -> some View {
        AxoInlineFlowText(pieces: [.glyph(AxoSymbol.inlineGlyph("group", rtl: false)), .text("\u{00A0}")] + pieces, style: Self.bodyMedium,
                          alignment: .center, maxLines: nil) { _ in onAction() }
            .cssTextColor(.labelPrimary)
            .frame(maxWidth: .infinity)
    }

    /// `Title`: mt-3, 20px / 24px medium, centred; clickable with an 18px secondary chevron.
    @ViewBuilder func titleView(_ text: String, onClick: (() -> Void)?) -> some View {
        let style = CSSTextStyle(fontName: AxoFonts.interName(weight: 500), size: 20, lineHeight: 24)
        let name = ContactName(title: text, isMe: isMe, isSignalConversation: isSignalConversation, style: style, wrap: .wrap)
        Group {
            if let onClick {
                SwiftUI.Button(action: onClick) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        name
                        CSSText("\u{00A0}", style: style, wrap: .nowrap)
                        AxoSymbol.InlineGlyph("chevron-[end]", size: 18, weight: 400).cssTextColor(.labelSecondary)
                    }
                    // The 18px chevron's own line box (leading-6) extends the line by 1px.
                    .padding(.bottom, 1)
                }
                .buttonStyle(.plain)
            } else {
                name
            }
        }
        .cssTextColor(.labelPrimary)
        .padding(.top, 12)
    }

    /// `NameNotVerifiedWarning`: mt-2, rounded-3xl safety tint, px-2.5 py-1, body-medium medium safety.
    var nameNotVerified: some View {
        SwiftUI.Button(action: actions.toggleProfileNameWarningModal) {
            AxoInlineFlowText(pieces: [.glyph(AxoSymbol.inlineGlyph(conversationType == .direct ? "person-question" : "group-question", rtl: false)),
                                       .text("\u{00A0}" + i18n("icu:ConversationHero--name-not-verified"))],
                              style: CSSTextStyle(AxoType.bodyMedium, weight: 500), alignment: .center, maxLines: nil) { _ in }
                .cssTextColor(.labelSafety)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(AxoColor.fillSafetyTint))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    /// `OfficialChatBadge`
    var officialBadge: some View {
        AxoInlineFlowText(pieces: [.glyph(AxoSymbol.inlineGlyph("seal-check", rtl: false)), .text("\u{00A0}" + i18n("icu:ConversationHero--signal-official-chat-title"))],
                          style: CSSTextStyle(AxoType.bodyMedium, weight: 500), alignment: .center, maxLines: nil) { _ in }
            .cssTextColor(.legacyOfficialChatBadgeText)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(AxoColor.legacyOfficialChatBadgeBg))
            .fixedSize()
    }

    var safetyTips: some View {
        AxoButton.Root(i18n("icu:MessageRequestWarning__safety-tips-v2"), variant: .strongSecondary, size: .md, action: actions.onShowSafetyTips)
            .padding(.top, 12)
    }
}

extension CSSTextStyle {
    /// The type at another weight.
    init(_ type: AxoType, weight: Int) {
        self.init(type)
        fontName = AxoFonts.interName(weight: weight)
    }
}

/// SharedGroupNames (ts/components/SharedGroupNames.dom.tsx): up to three bold group names.
public enum SharedGroupNames {
    @MainActor public static func pieces(_ names: [String], _ i18n: Localizer) -> [AxoInlinePiece] {
        let first = Array(names.prefix(3))
        var args: [String: I18nArgument] = [:]
        var bold: [String: String] = [:]
        for (i, n) in first.enumerated() {
            let id = first.count == 1 ? "group" : "group\(i + 1)"
            args[id] = .element(id)
            bold[id] = n
        }
        let key: String
        switch names.count {
        case 0: return [.text(i18n("icu:no-groups-in-common"))]
        case 1: key = "icu:member-of-1-group"
        case 2: key = "icu:member-of-2-groups"
        case 3: key = "icu:member-of-3-groups"
        case 4: key = "icu:member-of-more-than-3-groups--one-more"
        default:
            key = "icu:member-of-more-than-3-groups--multiple-more"
            args["remainingCount"] = .number(Double(names.count - 3))
        }
        return i18n.richText(key, args).runs.map { run in
            switch run.content {
            case .text(let s): return .text(s)
            case .element(let id): return .styled(bold[id] ?? "", weight: 700, color: nil)     // <strong>
            }
        }
    }
}

extension SharedGroupNames {
    /// The same text as CSSText runs (group names in bold).
    @MainActor public static func runs(_ names: [String], _ i18n: Localizer) -> [CSSTextRun] {
        pieces(names, i18n).compactMap { piece in
            switch piece {
            case .text(let s): CSSTextRun(s)
            case .styled(let s, let weight, _): CSSTextRun(s, fontName: AxoFonts.interName(weight: weight))
            case .glyph, .action: nil
            }
        }
    }
}

/// GroupMembersNames (ts/components/GroupMembersNames.dom.tsx): the first three other members
/// (known names first), "you", the rest as a clickable count, and invites.
public enum GroupMembersNames {
    @MainActor public static func pieces(_ memberships: [HeroMember], invitesCount: Int, _ i18n: Localizer) -> [AxoInlinePiece] {
        let areWeInGroup = memberships.contains { $0.isMe }
        let others = memberships.filter { !$0.isMe }.map(\.titleShort)
        let sorted = others.enumerated().sorted { a, b in
            switch (a.element == nil, b.element == nil) {
            case (false, true): return true
            case (true, false): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
        let first = sorted.prefix(3).map { $0 ?? i18n("icu:unknownContactShort") }
        var args: [String: I18nArgument] = [:]
        var names: [String: String] = [:]
        func member(_ id: String, _ i: Int) {
            args[id] = .element(id)
            names[id] = first[i]
        }
        let key: String
        switch (areWeInGroup, first.count) {
        case (true, 0): key = "icu:ConversationHero--group-members-only-you"
        case (true, 1): key = "icu:ConversationHero--group-members-one-and-you"; member("member", 0)
        case (true, 2): key = "icu:ConversationHero--group-members-two-and-you"; member("member1", 0); member("member2", 1)
        case (true, _):
            key = "icu:ConversationHero--group-members-other-and-you"
            member("member1", 0); member("member2", 1); member("member3", 2)
            args["remainingCount"] = .number(Double(others.count + 1 - 3))
        case (false, 0): key = "icu:ConversationHero--group-members-zero"
        case (false, 1): key = "icu:ConversationHero--group-members-one"; member("member", 0)
        case (false, 2): key = "icu:ConversationHero--group-members-two"; member("member1", 0); member("member2", 1)
        case (false, _):
            member("member1", 0); member("member2", 1); member("member3", 2)
            if others.count == 3 {
                key = "icu:ConversationHero--group-members-three"
            } else {
                key = "icu:ConversationHero--group-members-other"
                args["remainingCount"] = .number(Double(others.count - 3))
            }
        }
        var list: [AxoInlinePiece] = i18n.richText(key, args).runs.map { run in
            switch run.content {
            case .text(let s): return run.tags.contains("clickable") ? .action(s, id: 0) : .text(s)
            case .element(let id): return .text(names[id] ?? "")
            }
        }
        if invitesCount > 0 {
            // "{memberList} (+N invited)": the list stays rich inside the outer message.
            let outer = i18n.richText("icu:ConversationHero--member-list-and-invited",
                                      ["memberList": .element("memberList"), "invitesCount": .number(Double(invitesCount))])
            list = outer.runs.flatMap { run -> [AxoInlinePiece] in
                switch run.content {
                case .text(let s): return [.text(s)]
                case .element: return list
                }
            }
        }
        return list
    }
}

/// GroupDescription (ts/components/conversation/GroupDescription.dom.tsx): the description
/// (GroupDescriptionText: emoji, links underlined in the text colour, newlines) clamped to
/// two lines, with a bold "read more" when it overflows, which opens the whole description in a
/// dialog titled with the group's name (`showFullDescription`; `onReadMore` is told as well).
public struct GroupDescription: View {
    let title: String
    let text: String
    let onReadMore: () -> Void
    /// The inherited text-align (the hero centres it).
    let alignment: CSSTextAlign
    /// The inherited font and colour (the hero: body-large, text-primary).
    let style: CSSTextStyle
    let color: AxoColor
    @Environment(\.i18n) var i18n
    @Environment(\.axoModalStack) var modals
    @State private var width: CGFloat = 0

    public init(title: String, text: String, alignment: CSSTextAlign = .start, style: CSSTextStyle = CSSTextStyle(AxoType.bodyLarge),
                color: AxoColor = .labelPrimary, onReadMore: @escaping () -> Void = {}) {
        self.title = title
        self.text = text
        self.alignment = alignment
        self.style = style
        self.color = color
        self.onReadMore = onReadMore
    }

    var runs: [CSSTextRun] {
        Linkify.runs(text, emojify: true).map { r in
            var r = r
            if r.action != nil { r.color = nil }          // [&_a]:text-primary [&_a]:underline
            return r
        }
    }

    var overflows: Bool {
        width > 0 && CSSTextLayout.make(runs: runs, style, wrap: .wrap, maxWidth: width, colors: nil).lines.count > 2
    }

    public var body: some View {
        VStack(alignment: alignment == .center ? .center : .leading, spacing: 0) {
            CSSText(runs: runs, style: style, wrap: .clamp(2), alignment: alignment)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            if overflows {
                SwiftUI.Button(action: showFullDescription) {
                    CSSText(i18n("icu:GroupDescription__read-more"), style: { var s = style; s.fontName = AxoFonts.interName(weight: 600); return s }(),
                            wrap: .nowrap)
                }
                .buttonStyle(.plain)
            }
        }
        .cssTextColor(color)
    }

    /// The whole description: AxoDialog md, the group's name, close.
    func showFullDescription() {
        onReadMore()
        guard let modals else { return }
        let id = "group-description"
        let runs = runs
        modals.present(id: id) {
            AxoDialog.Content(size: .md, hasFooter: false) {
                AxoDialog.Header {
                    AxoDialog.Title(title)
                    AxoDialog.Close { modals.dismiss(id: id) }
                }
                AxoDialog.Body {
                    CSSText(runs: runs, style: CSSTextStyle(AxoType.bodyLarge), wrap: .wrap).cssTextColor(.labelPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// SmartHeroRow's wrapper (ts/state/smart/HeroRow.preload.tsx, `mt-10 flex justify-center`):
/// the hero centred 40px below the top of the timeline. Storybook renders the bare hero.
public struct HeroRow<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        content.frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
    }
}
