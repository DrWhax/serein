// Port of ts/components/preferences/PreferencesBlockChooserDialog.dom.tsx: search the
// conversations (filterAndSortConversations) and pick one to block, confirming first.

import SignalI18n
import SwiftUI

public struct PreferencesBlockChooserDialog: View {
    let title: String
    let conversations: [SearchableConversation]
    let onBlock: (String) -> Void
    let onClose: () -> Void
    @State private var search = ""
    @State private var confirmBlock: SearchableConversation?
    @Environment(\.i18n) var i18n

    public init(title: String, conversations: [SearchableConversation], onBlock: @escaping (String) -> Void = { _ in }, onClose: @escaping () -> Void = {}) {
        self.title = title
        self.conversations = conversations
        self.onBlock = onBlock
        self.onClose = onClose
    }

    public var body: some View {
        let filtered = ConversationSearch.filterAndSort(conversations, searchTerm: search, regionCode: nil)
        AxoDialog.Content(size: .md) {
            AxoDialog.Header {
                AxoDialog.Title(title)
                AxoDialog.Close(action: onClose)
            }
            AxoDialog.Search {
                SearchInput(value: $search, placeholder: i18n("icu:Preferences--BlockChooser--Search--Placeholder"), noMargin: true) { EmptyView() }
            }
            AxoDialog.Body(padding: .onlyScrollbarGutter) {
                // h-96: the conversation list's own scroller.
                AxoDialog.AxoScrollContainer {
                    VStack(spacing: 0) {
                        ForEach(filtered) { c in
                            ContactListItem(c.listItem) { _ in confirmBlock = c }.frame(height: 52, alignment: .top)
                        }
                        if filtered.isEmpty {
                            CSSText(i18n("icu:Preferences__EditChatFolderPage__SelectChatsDialog__NoChats"), style: LegacyType.body1(), alignment: .center,
                                    color: .labelSecondary)
                                .frame(maxWidth: .infinity).padding(.top, 16)
                        }
                    }
                    .padding(.horizontal, 11)
                }
                .frame(height: 384)
            }
            AxoDialog.Footer {
                AxoDialog.Actions { AxoDialog.Action(i18n("icu:Preferences--BlockChooser--Done"), variant: .strongPrimary, action: onClose) }
            }
        }
        .viewportPortal {
            if let c = confirmBlock {
                AxoBaseDialog.Host {
                    MessageRequestActionsConfirmation(model: {
                        var m = MessageRequestModel(conversationId: c.id, conversationType: c.listItem.type == .group ? .group : .direct, conversationName: c.title)
                        m.blockConversation = { onBlock(c.id) }
                        return m
                    }(), state: .blocking) { if $0 == .default { confirmBlock = nil } }
                }
            }
        }
    }
}
