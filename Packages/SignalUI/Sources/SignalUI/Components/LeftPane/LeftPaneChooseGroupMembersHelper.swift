// LeftPaneChooseGroupMembersHelper (ts/components/leftPane/LeftPaneChooseGroupMembersHelper.dom.tsx):
// "Add members": selected contacts as pills, candidate contacts as checkboxes, the typed
// number / username as a checkbox, and Next / Skip in the footer.

import SignalI18n
import SwiftUI

public struct LeftPaneChooseGroupMembersHelper: LeftPaneHelper {
    public var candidateContacts: [ContactListItemData]
    public var selectedContacts: [ContactListItemData]
    public var searchTerm: String
    public var regionCode: String?
    public var username: String?
    public var ourE164: String?
    public var ourUsername: String?
    public var uuidFetchState: UUIDFetchState
    public var groupSizeRecommendedLimit: Int
    public var groupSizeHardLimit: Int
    /// e164s / usernames already selected (for the lookup checkboxes' state).
    public var selectedE164s: Set<String>
    public var selectedUsernames: Set<String>

    public init(candidateContacts: [ContactListItemData], selectedContacts: [ContactListItemData] = [], searchTerm: String = "",
                regionCode: String? = "US", username: String? = nil, ourE164: String? = nil, ourUsername: String? = nil,
                uuidFetchState: UUIDFetchState = [], groupSizeRecommendedLimit: Int = 151, groupSizeHardLimit: Int = 1001,
                selectedE164s: Set<String> = [], selectedUsernames: Set<String> = []) {
        self.candidateContacts = candidateContacts
        self.selectedContacts = selectedContacts
        self.searchTerm = searchTerm
        self.regionCode = regionCode
        self.username = username
        self.ourE164 = ourE164
        self.ourUsername = ourUsername
        self.uuidFetchState = uuidFetchState
        self.groupSizeRecommendedLimit = groupSizeRecommendedLimit
        self.groupSizeHardLimit = groupSizeHardLimit
        self.selectedE164s = selectedE164s
        self.selectedUsernames = selectedUsernames
    }

    public var listExtendsToEdges: Bool { true }

    var visibleUsername: String? {
        guard let username, username != ourUsername else { return nil }
        return username
    }
    var phoneNumber: ParsedPhoneNumber? {
        guard visibleUsername == nil, ourUsername == nil || username != ourUsername,
              let p = PhoneNumberParsing.parse(searchTerm, regionCode: regionCode), p.e164 != ourE164 else { return nil }
        return p
    }
    /// One fewer than the hard limit: we count too.
    var hasSelectedMaximum: Bool { selectedContacts.count >= groupSizeHardLimit - 1 }
    var hasExceededMaximum: Bool { selectedContacts.count > groupSizeHardLimit - 1 }

    public func headerContents(_ ctx: LeftPaneContext) -> AnyView? {
        AnyView(LeftPaneHeaderContents(backLabel: ctx.i18n("icu:chooseGroupMembers__back-button"), back: ctx.startComposing,
                                       title: ctx.i18n("icu:chooseGroupMembers__title")))
    }

    public func backAction(_ ctx: LeftPaneContext) -> (() -> Void)? { ctx.startComposing }

    public func searchInput(_ ctx: LeftPaneContext) -> AnyView? {
        AnyView(SearchInput(value: .constant(searchTerm), placeholder: ctx.i18n("icu:contactSearchPlaceholder"), focusesOnAppear: true))
    }

    public func preRows(_ ctx: LeftPaneContext) -> AnyView? {
        let i18n = ctx.i18n
        let empty = rows(i18n).isEmpty
        guard !selectedContacts.isEmpty || empty else { return nil }
        return AnyView(VStack(spacing: 0) {
            if !selectedContacts.isEmpty {
                ContactPills(count: selectedContacts.count) {
                    ForEach(selectedContacts, id: \.id) { c in
                        ContactPill(id: c.id, title: c.title, color: c.avatar.color ?? "A200",
                                    image: c.avatar.image.map { AnyView(PixelImage($0, fit: .cover)) },
                                    avatarStrings: AvatarStrings(i18n: i18n), removeLabel: i18n("icu:ContactPill--remove"),
                                    onClickRemove: ctx.removeSelectedContact)
                    }
                }
            }
            if empty {
                CSSText(i18n("icu:noContactsFound"), style: LeftPaneMessageText.style, alignment: .center)
                    .padding(.top, 27).padding(.horizontal, 14).frame(maxWidth: .infinity)
            }
        })
    }

    public func footer(_ ctx: LeftPaneContext) -> AnyView? {
        let i18n = ctx.i18n
        return AnyView(LegacyButton(i18n(selectedContacts.isEmpty ? "icu:chooseGroupMembers__skip" : "icu:chooseGroupMembers__next"),
                                    disabled: hasExceededMaximum, action: ctx.startSettingGroupMetadata))
    }

    public func rows(_ i18n: Localizer) -> [ConversationListRow] {
        guard !candidateContacts.isEmpty || phoneNumber != nil || visibleUsername != nil else { return [] }
        var out: [ConversationListRow] = []
        let selected = Set(selectedContacts.map(\.id))
        if !candidateContacts.isEmpty {
            out.append(.header(i18n("icu:contactsHeader")))
            out += candidateContacts.map { c in
                let checked = selected.contains(c.id)
                return .contactCheckbox(c, isChecked: checked, disabledReason: !checked && hasSelectedMaximum ? .maximumContactsSelected : nil)
            }
        }
        if let phoneNumber {
            out.append(.header(i18n("icu:findByPhoneNumberHeader")))
            out.append(.phoneNumberCheckbox(phoneNumber, isChecked: selectedE164s.contains(phoneNumber.e164),
                                            isFetching: uuidFetchState.contains("e164:\(phoneNumber.e164)")))
        }
        if let username = visibleUsername {
            out.append(.header(i18n("icu:findByUsernameHeader")))
            out.append(.usernameCheckbox(username, isChecked: selectedUsernames.contains(username),
                                         isFetching: uuidFetchState.contains("username:\(username)")))
        }
        out.append(.blank)    // room for the footer
        return out
    }
}
