// LeftPaneArchiveHelper (ts/components/leftPane/LeftPaneArchiveHelper.dom.tsx): archived chats
// under a back-button header and the archive helper text; searching inside one of them
// switches to the search helper's rows.

import SignalI18n
import SwiftUI

/// `.module-left-pane__header__contents`: back button, then the centred bold title
/// (padding-end 40 so it centres in the pane).
struct LeftPaneHeaderContents: View {
    let backLabel: String
    let back: () -> Void
    let title: String
    @Environment(\.navSidebarWidthBreakpoint) var breakpoint

    var body: some View {
        let narrow = breakpoint == .narrow
        HStack(spacing: 0) {
            NavSidebarBackButton(label: backLabel, action: back)
                .padding(.vertical, -4)
                .padding(.leading, narrow ? 0 : 12)
            if !narrow {
                CSSText(title, style: LegacyType.body1(weight: 600), alignment: .center,
                        color: AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05))
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, 40)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .frame(maxWidth: .infinity, alignment: narrow ? .center : .leading)
        .padding(.vertical, 15)
    }
}

public struct LeftPaneArchiveHelper: LeftPaneHelper {
    public var archivedConversations: [ConversationListItemData]
    public var searchConversation: SearchConversation?
    public var searchTerm: String
    public var isSearchingGlobally: Bool
    /// Set while searching in an archived conversation.
    public var search: LeftPaneSearchHelper?

    public init(archivedConversations: [ConversationListItemData], searchConversation: SearchConversation? = nil, searchTerm: String = "",
                isSearchingGlobally: Bool = false, search: LeftPaneSearchHelper? = nil) {
        self.archivedConversations = archivedConversations
        self.searchConversation = searchConversation
        self.searchTerm = searchTerm
        self.isSearchingGlobally = isSearchingGlobally
        self.search = search
    }

    public func headerContents(_ ctx: LeftPaneContext) -> AnyView? {
        AnyView(LeftPaneHeaderContents(backLabel: ctx.i18n("icu:backToInbox"), back: ctx.showInbox, title: ctx.i18n("icu:archivedConversations")))
    }

    public func backAction(_ ctx: LeftPaneContext) -> (() -> Void)? { ctx.showInbox }

    public func searchInput(_ ctx: LeftPaneContext) -> AnyView? {
        guard let searchConversation else { return nil }
        return AnyView(LeftPaneSearchInput(searchTerm: Binding(get: { searchTerm }, set: { ctx.updateSearchTerm($0) }), searchConversation: searchConversation,
                                           isSearchingGlobally: isSearchingGlobally, clearSearchQuery: ctx.clearSearchQuery,
                                           endConversationSearch: ctx.endConversationSearch, endSearch: ctx.endSearch))
    }

    public func preRows(_ ctx: LeftPaneContext) -> AnyView? {
        if let search { return search.preRows(ctx) }
        let i18n = ctx.i18n
        return AnyView(ArchiveHelperText(text: i18n(archivedConversations.isEmpty ? "icu:noArchivedConversations" : "icu:archiveHelperText")))
    }

    public func rows(_ i18n: Localizer) -> [ConversationListRow] {
        search?.rows(i18n) ?? archivedConversations.map { .conversation($0) }
    }
}

/// `.module-left-pane__archive-helper-text`: body-2 on a gray band, padding 1em.
struct ArchiveHelperText: View {
    let text: String
    @Environment(\.navSidebarWidthBreakpoint) var breakpoint
    var body: some View {
        if breakpoint != .narrow {
            CSSText(text, style: LegacyType.body2(), color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray75))
        }
    }
}
