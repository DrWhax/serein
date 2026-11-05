// Port of ts/components/conversation/conversation-details/ConversationDetailsMembershipList.dom.tsx:
// "N members" with a search button over an AxoContactList: "Add members", then you, the admins
// and the other members (each group by title), five at a time with "See all". Each row has a
// 36px avatar, the name (and the in-contacts icon) over the member label pill, and "Admin".
//
// GroupMembersSearchDialog is opened through `onOpenSearch`.

import SignalI18n
import SwiftUI

/// `GroupV2Membership` with the member colour from `memberColors`.
public struct GroupV2Membership: Identifiable {
    public var id: String
    public var avatar: ConversationAvatarData
    public var isMe = false
    public var isAdmin = false
    public var isInSystemContacts = false
    public var label: ContactLabel?
    public var contactNameColor: String?
    /// The member's conversation for search (profile name, username, e164, activeAt…); nil
    /// searches the title alone.
    public var searchable: SearchableConversation?
    public init(id: String, avatar: ConversationAvatarData, isMe: Bool = false, isAdmin: Bool = false, isInSystemContacts: Bool = false,
                label: ContactLabel? = nil, contactNameColor: String? = nil) {
        self.id = id
        self.avatar = avatar
        self.isMe = isMe
        self.isAdmin = isAdmin
        self.isInSystemContacts = isInSystemContacts
        self.label = label
        self.contactNameColor = contactNameColor
    }

    /// `sortMemberships`: you, then admins, then everyone else, each by title (Intl.Collator,
    /// base sensitivity).
    public static func sorted(_ memberships: [GroupV2Membership]) -> [GroupV2Membership] {
        func byTitle(_ a: GroupV2Membership, _ b: GroupV2Membership) -> Bool {
            a.avatar.title.compare(b.avatar.title, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == .orderedAscending
        }
        let me = memberships.filter(\.isMe)
        let admins = memberships.filter { !$0.isMe && $0.isAdmin }.sorted(by: byTitle)
        let others = memberships.filter { !$0.isMe && !$0.isAdmin }.sorted(by: byTitle)
        return Array(me.prefix(1)) + admins + others
    }
}

public struct ConversationDetailsMembershipList: View {
    let memberships: [GroupV2Membership]
    let canAddNewMembers: Bool
    let canAddLabel: Bool
    let isEditMemberLabelEnabled: Bool
    let isTerminated: Bool
    let maxShownMemberCount: Int
    let showContactModal: (String) -> Void
    let showLabelEditor: () -> Void
    let startAddingNewMembers: () -> Void
    let onOpenSearch: () -> Void
    @State private var showAllMembers = false
    @Environment(\.i18n) var i18n

    public init(memberships: [GroupV2Membership], canAddNewMembers: Bool = false, canAddLabel: Bool = false, isEditMemberLabelEnabled: Bool = false,
                isTerminated: Bool = false, maxShownMemberCount: Int = 5, showContactModal: @escaping (String) -> Void = { _ in },
                showLabelEditor: @escaping () -> Void = {}, startAddingNewMembers: @escaping () -> Void = {}, onOpenSearch: @escaping () -> Void = {}) {
        self.memberships = memberships
        self.canAddNewMembers = canAddNewMembers
        self.canAddLabel = canAddLabel
        self.isEditMemberLabelEnabled = isEditMemberLabelEnabled
        self.isTerminated = isTerminated
        self.maxShownMemberCount = maxShownMemberCount
        self.showContactModal = showContactModal
        self.showLabelEditor = showLabelEditor
        self.startAddingNewMembers = startAddingNewMembers
        self.onOpenSearch = onOpenSearch
    }

    var header: some View {
        let count = ["number": I18nArgument.number(Double(memberships.count))]
        let title = i18n(isTerminated ? "icu:ConversationDetailsMembershipList--terminated-title" : "icu:ConversationDetailsMembershipList--title", count)
        return HStack(alignment: .center, spacing: 0) {
            CSSText(title, type: AxoType.bodyMedium.weight(600), color: .labelPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            AxoIconButton.Root(label: i18n("icu:ConversationDetailsMembershipList__Search__AccessibilityLabel"), variant: .impliedSecondary,
                               size: .md, symbol: "search", action: onOpenSearch)
        }
    }

    func titleView(_ m: GroupV2Membership) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                CSSText(runs: [Emojify.run((m.isMe ? i18n("icu:you") : m.avatar.title) + "\u{00A0}")], style: CSSTextStyle(AxoType.bodyMedium), wrap: .wrap)
                if m.isInSystemContacts && !m.isMe { InContactsIcon() }
            }
            if let label = m.label, let color = m.contactNameColor {
                // __member-label: font-body-small; the inline pill in its 16px line box.
                GroupMemberLabel(contactLabel: label, contactNameColor: color, context: .list)
                    .frame(height: 22, alignment: .top)
            }
            if canAddLabel && isEditMemberLabelEnabled && m.isMe && (m.label == nil || m.contactNameColor == nil) {
                SwiftUI.Button(action: showLabelEditor) {
                    HStack(spacing: 0) {
                        CSSText(i18n("icu:ConversationDetailsMembershipList--add-member-label"), style: LegacyType.bodySmall(weight: 500), wrap: .nowrap)
                        SignalIcon("v3/chevron/chevron-right", size: 16, color: .labelSecondary).frame(width: 16, height: 16)
                    }
                    .padding(.leading, 5)
                }
                .buttonStyle(.plain)
                .padding(.leading, -5)
            }
        }
    }

    public var body: some View {
        let sorted = GroupV2Membership.sorted(memberships)
        let shouldHideRest = sorted.count - maxShownMemberCount > 1
        let shown = shouldHideRest && !showAllMembers ? maxShownMemberCount : sorted.count
        AxoContactList.Root(titleView: AnyView(header)) {
            if canAddNewMembers && !isTerminated {
                AxoContactList.ActionItem(symbol: "plus", title: i18n("icu:ConversationDetailsMembershipList--add-members"), onClick: startAddingNewMembers)
            }
            ForEach(sorted.prefix(shown)) { m in
                AxoContactList.Item(title: m.isMe ? i18n("icu:you") : m.avatar.title, titleView: AnyView(titleView(m)),
                                    value: m.isAdmin ? i18n("icu:GroupV2--admin") : nil, onClick: { showContactModal(m.id) }) {
                    ListAvatar(data: m.avatar, size: 36)
                } description: { EmptyView() } accessory: { EmptyView() }
            }
            if !showAllMembers && shouldHideRest {
                AxoContactList.ActionItem(symbol: "chevron-down", title: i18n("icu:ConversationDetailsMembershipList--show-all")) { showAllMembers = true }
            }
        }
    }
}
