// LeftPaneSearchHelper (ts/components/leftPane/LeftPaneSearchHelper.dom.tsx): search results in
// sections (Chats or "Filtered by unread", Contacts, Messages) with the clear-filter button,
// the loading skeleton while any section loads, and the no-results texts.

import SignalI18n
import SwiftUI

/// `MaybeLoadedSearchResultsType`
public enum SearchResults<T> {
    case loading
    case loaded([T])

    var isLoading: Bool { if case .loading = self { true } else { false } }
    var results: [T] { if case .loaded(let r) = self { r } else { [] } }
}

public struct LeftPaneSearchHelper: LeftPaneHelper {
    public var conversationResults: SearchResults<ConversationListItemData>
    public var contactResults: SearchResults<ConversationListItemData>
    public var messageResults: SearchResults<String>    // message ids
    public var searchTerm: String
    public var searchConversation: SearchConversation?
    public var searchConversationName: String?
    public var searchDisabled: Bool
    public var isSearchingGlobally: Bool
    public var filterByUnread: Bool

    public init(conversationResults: SearchResults<ConversationListItemData>, contactResults: SearchResults<ConversationListItemData>,
                messageResults: SearchResults<String>, searchTerm: String, searchConversation: SearchConversation? = nil,
                searchConversationName: String? = nil, searchDisabled: Bool = false, isSearchingGlobally: Bool = true, filterByUnread: Bool = false) {
        self.conversationResults = conversationResults
        self.contactResults = contactResults
        self.messageResults = messageResults
        self.searchTerm = searchTerm
        self.searchConversation = searchConversation
        self.searchConversationName = searchConversationName
        self.searchDisabled = searchDisabled
        self.isSearchingGlobally = isSearchingGlobally
        self.filterByUnread = filterByUnread
    }

    public var hidesHeader: Bool { false }

    var isLoading: Bool { conversationResults.isLoading || contactResults.isLoading || messageResults.isLoading }
    public var isScrollable: Bool { !isLoading }

    var mightHaveResults: Bool {
        conversationResults.isLoading || !conversationResults.results.isEmpty || contactResults.isLoading || !contactResults.results.isEmpty
            || messageResults.isLoading || !messageResults.results.isEmpty
    }
    var allEmpty: Bool { conversationResults.results.isEmpty && contactResults.results.isEmpty && messageResults.results.isEmpty }

    public func searchInput(_ ctx: LeftPaneContext) -> AnyView? {
        AnyView(LeftPaneSearchInput(searchTerm: .constant(searchTerm), searchConversation: searchConversation, disabled: searchDisabled,
                                    isSearchingGlobally: isSearchingGlobally, filterButtonEnabled: searchConversation == nil,
                                    filterPressed: filterByUnread, onFilterClick: ctx.updateFilterByUnread, clearSearchQuery: ctx.clearSearchQuery,
                                    endConversationSearch: ctx.endConversationSearch, endSearch: ctx.endSearch))
    }

    public func preRows(_ ctx: LeftPaneContext) -> AnyView? {
        let showChatFolders = filterByUnread && searchTerm.trimmingCharacters(in: .whitespaces).isEmpty && searchConversation == nil
        if mightHaveResults { return showChatFolders ? ctx.renderLeftPaneChatFolders() : nil }
        let i18n = ctx.i18n
        let body = LeftPaneMessageText.style
        var node: AnyView?
        if let name = searchConversationName {
            if !searchTerm.isEmpty {
                node = AnyView(CSSText(i18n("icu:noSearchResultsInConversation", ["searchTerm": .string(searchTerm), "conversationName": .string(name)]),
                                       style: body, alignment: .center)
                    .padding(.top, 27).padding(.horizontal, 14).frame(maxWidth: .infinity))
            }
        } else {
            let message: String
            if filterByUnread && !searchTerm.isEmpty {
                message = i18n("icu:noSearchResultsWithUnreadFilter", ["searchTerm": .string(searchTerm)])
            } else if filterByUnread {
                message = i18n("icu:noSearchResultsOnlyUnreadFilter")
            } else {
                message = i18n("icu:noSearchResults", ["searchTerm": .string(searchTerm)])
            }
            if filterByUnread {
                // `__no-search-results--withHeader`: column, margin 15 / 20, the header then the text.
                node = AnyView(VStack(spacing: 0) {
                    ConversationListHeader(text: i18n("icu:conversationsUnreadHeader")).frame(height: 28).padding(.bottom, 50)
                    CSSText(message, style: body, alignment: .center).frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 14).padding(.top, 15).padding(.bottom, 20))
            } else {
                node = AnyView(CSSText(message, style: body, alignment: .center)
                    .padding(.top, 27).padding(.horizontal, 14).frame(maxWidth: .infinity))
            }
        }
        guard showChatFolders else { return node }
        return AnyView(VStack(spacing: 0) {
            ctx.renderLeftPaneChatFolders()
            if let node { node }
        })
    }

    public func rows(_ i18n: Localizer) -> [ConversationListRow] {
        if isLoading { return [.searchResultsLoadingFakeHeader] + Array(repeating: .searchResultsLoadingFakeRow, count: 98) }
        var out: [ConversationListRow] = []
        if !conversationResults.results.isEmpty {
            out.append(.header(i18n(filterByUnread ? "icu:conversationsUnreadHeader" : "icu:conversationsHeader")))
            out += conversationResults.results.map { .conversation($0) }
        }
        if !contactResults.results.isEmpty {
            out.append(.header(i18n("icu:contactsHeader")))
            out += contactResults.results.map { .conversation($0) }
        }
        if !messageResults.results.isEmpty {
            out.append(.header(i18n("icu:messagesHeader")))
            out += messageResults.results.map { .messageSearchResult(messageId: $0) }
        }
        if filterByUnread { out.append(.clearFilterButton(isOnNoResultsPage: allEmpty)) }
        return out
    }
}

/// The left pane's inherited body text (Storybook / app body: 14px/20px, −0.084px).
enum LeftPaneMessageText {
    static var style: CSSTextStyle { CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 14, lineHeight: 20, letterSpacing: -0.084) }
}
