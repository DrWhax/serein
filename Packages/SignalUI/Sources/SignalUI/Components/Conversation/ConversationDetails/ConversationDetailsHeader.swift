// Port of ts/components/conversation/conversation-details/ConversationDetailsHeader.dom.tsx
// (stylesheets/components/ConversationDetailsHeader.scss): the centred 80px avatar, the title
// (title-1 at weight 400, 12px above, 8px below), the "group has ended" banner, and the
// subtitle (body-1 gray-60 / gray-25, 12px below): the group description, "Add group
// description…" when editable, the member count, or the contact's About.
//
// Donor badges are omitted (no donations). The avatar lightbox and badge dialog are callbacks.

import SignalI18n
import SwiftUI

public struct ConversationDetailsHeader: View {
    let avatar: ConversationAvatarData
    let title: String
    let canEdit: Bool
    let isGroup: Bool
    let isMe: Bool
    let isSignalConversation: Bool
    let isInSystemContacts: Bool
    let terminated: Bool
    let groupDescription: String?
    let about: String?
    let membersCount: Int?
    let pendingAvatarDownload: Bool
    let startAvatarDownload: () -> Void
    let showAvatar: () -> Void
    let startEditing: (Bool) -> Void
    let toggleAboutContactModal: () -> Void
    let onReadMoreDescription: () -> Void
    @Environment(\.i18n) var i18n

    public init(avatar: ConversationAvatarData, title: String, canEdit: Bool = false, isGroup: Bool, isMe: Bool = false,
                isSignalConversation: Bool = false, isInSystemContacts: Bool = false, terminated: Bool = false, groupDescription: String? = nil,
                about: String? = nil, membersCount: Int? = nil, pendingAvatarDownload: Bool = false, startAvatarDownload: @escaping () -> Void = {},
                showAvatar: @escaping () -> Void = {}, startEditing: @escaping (Bool) -> Void = { _ in },
                toggleAboutContactModal: @escaping () -> Void = {}, onReadMoreDescription: @escaping () -> Void = {}) {
        self.avatar = avatar
        self.title = title
        self.canEdit = canEdit
        self.isGroup = isGroup
        self.isMe = isMe
        self.isSignalConversation = isSignalConversation
        self.isInSystemContacts = isInSystemContacts
        self.terminated = terminated
        self.groupDescription = groupDescription
        self.about = about
        self.membersCount = membersCount
        self.pendingAvatarDownload = pendingAvatarDownload
        self.startAvatarDownload = startAvatarDownload
        self.showAvatar = showAvatar
        self.startEditing = startEditing
        self.toggleAboutContactModal = toggleAboutContactModal
        self.onReadMoreDescription = onReadMoreDescription
    }

    static let titleStyle = LegacyType.title1(weight: 400)
    static let subtitleColor = AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25)

    /// `shouldShowClickToView`
    var shouldShowClickToView: Bool { avatar.image == nil && !isMe && avatar.hasAvatar }

    var avatarView: some View {
        Avatar(strings: AvatarStrings(i18n: i18n), title: avatar.title, size: 80, conversationType: isGroup ? .group : .direct,
               color: avatar.color ?? "A200", image: avatar.image.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: avatar.hasAvatar,
               placeholderGradient: avatar.placeholderGradient ?? AxoTokens.Avatar.gradient(hash: 0), loading: pendingAvatarDownload,
               noteToSelf: isMe, blur: shouldShowClickToView ? .blurPictureWithClickToView : .noBlur) {
            if shouldShowClickToView { startAvatarDownload() } else { showAvatar() }
        }
    }

    /// `.ConversationDetailsHeader__title`: a centred flex row.
    func titleRow<Trailing: View>(_ text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 0) {
            CSSText(runs: [Emojify.run(text)], style: Self.titleStyle, wrap: .wrap, alignment: .center)
            trailing()
        }
        .padding(.top, 12).padding(.bottom, 8)
        .cssTextColor(.labelPrimary)
    }

    @ViewBuilder var subtitle: some View {
        if isGroup {
            if let groupDescription, !groupDescription.isEmpty {
                GroupDescription(title: title, text: groupDescription, alignment: .center, style: LegacyType.body1(), color: Self.subtitleColor,
                                 onReadMore: onReadMoreDescription)
                    .modifier(SubtitleBox())
            } else if canEdit {
                subtitleText(i18n("icu:ConversationDetailsHeader--add-group-description"))
            } else {
                subtitleText(i18n("icu:ConversationDetailsHeader--members", ["number": .number(Double(membersCount ?? 0))]))
            }
        } else if !isMe, let about, !about.isEmpty {
            About(text: about).cssTextColor(Self.subtitleColor).modifier(SubtitleBox())
        }
    }

    func subtitleText(_ text: String) -> some View {
        CSSText(text, style: LegacyType.body1(), alignment: .center, color: Self.subtitleColor).modifier(SubtitleBox())
    }

    struct SubtitleBox: ViewModifier {
        func body(content: Content) -> some View { content.padding(.bottom, 12) }
    }

    /// The "group has ended" banner: mb-3 px-2 py-[5px] curved-xl bg-primary, type-body-small.
    var terminatedBanner: some View {
        HStack(spacing: 4) {
            AxoSymbol.InlineGlyph("group-x", size: 12, weight: 400)
            CSSText(i18n("icu:ConversationDetails__GroupTerminatedBanner"), type: AxoType.bodySmall, color: .labelPrimary)
        }
        .cssTextColor(.labelPrimary)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(AxoColor.fillPrimary, in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 12)
    }

    public var body: some View {
        VStack(alignment: .center, spacing: 0) {
            avatarView
            if canEdit {
                SwiftUI.Button { startEditing(true) } label: { EditableTitle(row: titleRow(title) {}) }
                    .buttonStyle(.plain)
                if let groupDescription, !groupDescription.isEmpty {
                    subtitle
                } else {
                    SwiftUI.Button { startEditing(false) } label: { subtitle }.buttonStyle(.plain)
                }
            } else {
                if isMe || isSignalConversation {
                    titleRow((isMe ? i18n("icu:noteToSelf") : title) + "\u{00A0}") { OfficialChatInlineBadge(size: 26) }
                } else if isGroup {
                    titleRow(title) {}
                } else {
                    SwiftUI.Button(action: toggleAboutContactModal) {
                        titleRow(title) {
                            if isInSystemContacts {
                                CSSText("\u{00A0}", style: Self.titleStyle, wrap: .nowrap)
                                InContactsIcon().frame(width: 22, height: 22)
                            }
                            // __about-icon: 20px chevron, 2px down
                            SignalIcon("v3/chevron/chevron-right-bold", size: 20, color: AxoColor(light: LegacyColor.black, dark: LegacyColor.gray05))
                                .frame(width: 20, height: 20)
                                .offset(y: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if terminated { terminatedBanner }
                subtitle
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }
}

/// `__edit-button __title::after`: the edit pencil (24px, gray-60 / gray-25) fades in on hover,
/// overlapping the title's end without taking room.
struct EditableTitle<Row: View>: View {
    let row: Row
    @State private var hovered = false
    var body: some View {
        row
            .overlay(alignment: .trailing) {
                SignalIcon("v3/edit/edit", size: 24, color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
                    .frame(width: 24, height: 24)
                    .offset(x: 37)
                    .opacity(hovered ? 1 : 0)
                    .animation(.easeOut(duration: 0.1), value: hovered)
            }
            .onHover { hovered = $0 }
    }
}
