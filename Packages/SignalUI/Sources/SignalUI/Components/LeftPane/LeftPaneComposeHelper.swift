// LeftPaneComposeHelper (ts/components/leftPane/LeftPaneComposeHelper.dom.tsx): "New chat":
// the compose steps (no search term), contacts, groups, and the username / phone-number match
// for the search term.

import SignalI18n
import SwiftUI

/// `uuidFetchState`: lookups in flight, keyed "username:<name>" / "e164:<number>".
public typealias UUIDFetchState = Set<String>

public struct LeftPaneComposeHelper: LeftPaneHelper {
    public var composeContacts: [ContactListItemData]
    public var composeGroups: [GroupListItemData]
    public var searchTerm: String
    public var regionCode: String?
    public var username: String?
    public var uuidFetchState: UUIDFetchState
    /// Contacts' usernames and numbers, to hide a match already listed.
    public var contactUsernames: Set<String>
    public var contactE164s: Set<String>

    public init(composeContacts: [ContactListItemData], composeGroups: [GroupListItemData] = [], searchTerm: String = "", regionCode: String? = "US",
                username: String? = nil, uuidFetchState: UUIDFetchState = [], contactUsernames: Set<String> = [], contactE164s: Set<String> = []) {
        self.composeContacts = composeContacts
        self.composeGroups = composeGroups
        self.searchTerm = searchTerm
        self.regionCode = regionCode
        self.username = username
        self.uuidFetchState = uuidFetchState
        self.contactUsernames = contactUsernames
        self.contactE164s = contactE164s
    }

    public var listExtendsToEdges: Bool { true }

    var isUsernameVisible: Bool { username.map { !$0.isEmpty && !contactUsernames.contains($0) } ?? false }
    var phoneNumber: ParsedPhoneNumber? { username == nil ? PhoneNumberParsing.parse(searchTerm, regionCode: regionCode) : nil }
    var isPhoneNumberVisible: Bool { phoneNumber.map { !contactE164s.contains($0.e164) } ?? false }

    public func headerContents(_ ctx: LeftPaneContext) -> AnyView? {
        AnyView(LeftPaneHeaderContents(backLabel: ctx.i18n("icu:backToInbox"), back: ctx.showInbox, title: ctx.i18n("icu:newConversation")))
    }

    public func backAction(_ ctx: LeftPaneContext) -> (() -> Void)? { ctx.showInbox }

    public func searchInput(_ ctx: LeftPaneContext) -> AnyView? {
        AnyView(SearchInput(value: .constant(searchTerm), placeholder: ctx.i18n("icu:contactSearchPlaceholder"),
                            focusesOnAppear: true))    // ref={focusRef}
    }

    public func preRows(_ ctx: LeftPaneContext) -> AnyView? {
        guard rows(ctx.i18n).isEmpty else { return nil }
        // `.module-left-pane__compose-no-contacts`
        return AnyView(CSSText(ctx.i18n("icu:noConversationsFound"), style: LeftPaneMessageText.style, alignment: .center)
            .padding(.top, 27).padding(.horizontal, 14).frame(maxWidth: .infinity))
    }

    public func rows(_ i18n: Localizer) -> [ConversationListRow] {
        var out: [ConversationListRow] = []
        if searchTerm.isEmpty { out += [.createNewGroup, .findByUsername, .findByPhoneNumber] }
        let probablyUsername = UsernameSearch.isProbablyAUsername(searchTerm)
        if !composeContacts.isEmpty && !probablyUsername {
            out.append(.header(i18n("icu:contactsHeader")))
            out += composeContacts.map { .contact($0, hasContextMenu: true) }
        }
        if !composeGroups.isEmpty && !probablyUsername {
            out.append(.header(i18n("icu:groupsHeader")))
            out += composeGroups.map { .selectSingleGroup($0) }
        }
        if let username, isUsernameVisible {
            out.append(.header(i18n("icu:findByUsernameHeader")))
            out.append(.usernameSearchResult(username, isFetchingUsername: uuidFetchState.contains("username:\(username)")))
        }
        if let phoneNumber, isPhoneNumberVisible {
            out.append(.header(i18n("icu:findByPhoneNumberHeader")))
            out.append(.startNewConversation(phoneNumber, isFetching: uuidFetchState.contains("e164:\(phoneNumber.e164)")))
        }
        return out
    }
}
