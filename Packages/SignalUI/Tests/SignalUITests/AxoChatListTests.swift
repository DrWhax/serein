// AxoChatList stories (ts/axo/chatList/AxoChatList.dom.stories.tsx).

import Foundation
import SwiftUI
import Testing
@testable import SignalUI

@MainActor enum ChatListStory {
    struct Chat {
        var name: String
        var sender: String?
        var outgoingStatus: AxoOutgoingStatus.Status?
        var preview: String
        var time = "11:00 AM"
        var unreadCount: Int
        var markedUnread: Bool
        var mentioned: Bool
        var muted: Bool
        var initials: String { name.split(separator: " ").compactMap(\.first).map(String.init).joined() }
    }

    static let names = ["Alice Ahn", "Bob Baker", "Carol Chen", "Book Club", "Dan Diaz", "Erin Evans", "Family", "Frank Fu"]
    static let previews = [
        "Message preview", "Are we still on for tomorrow?",
        "Lorem ipsum dolor sit amet, consectetur adipisicing elit. Magni ipsum exercitationem est facilis, rerum ea reiciendis tempore sit magnam.",
        "Sounds good",
    ]

    static func chat(_ i: Int) -> Chat {
        Chat(name: names[i % names.count], sender: i % 3 == 0 ? "Sender" : nil, outgoingStatus: i % 4 == 2 ? .read : nil,
             preview: previews[i % previews.count], unreadCount: i % 5 == 1 ? i : 0, markedUnread: i % 6 == 2, mentioned: i % 10 == 1,
             muted: i % 7 == 3)
    }

    struct ChatAvatar: View {
        let chat: Chat
        let size: AxoAvatar.Size
        var body: some View {
            AxoAvatar.Root(size: size) {
                AxoAvatar.Content(label: nil) {
                    AxoAvatar.Initials(initials: chat.initials, color: AxoTokens.Avatar.colorName(hash: chat.name.count))
                }
            }
        }
    }

    struct FullItem: View {
        let chat: Chat
        @Environment(\.colorScheme) var scheme
        var body: some View {
            AxoChatItem.Root {
                AxoChatItem.Avatar { ChatAvatar(chat: chat, size: 48) }
                AxoChatItem.Content {
                    AxoChatItem.Label(chat.name)
                    if chat.muted { AxoChatItem.LabelIcon(symbol: "bell-slash", label: "Muted") }
                    AxoChatItem.Timestamp(timestamp: Date(timeIntervalSince1970: 0), chat.time)
                    AxoChatItem.Description((chat.sender.map { [AxoChatItem.sender($0, scheme: scheme)] } ?? []) + [.text(chat.preview)])
                    if let s = chat.outgoingStatus { AxoChatItem.OutgoingStatus(status: s, label: nil) }
                    AxoChatItem.Badges(unreadCount: chat.unreadCount, markedUnread: chat.markedUnread, mentioned: chat.mentioned)
                }
                AxoChatItem.HiddenTrigger(label: "\(chat.name), \(chat.preview)", onClick: {})
            }
        }
    }

    struct CompactItem: View {
        let chat: Chat
        var body: some View {
            AxoChatItemCompact.Root {
                AxoChatItemCompact.Avatar {
                    ChatAvatar(chat: chat, size: 40)
                    AxoChatItemCompact.Badges(unreadCount: chat.unreadCount, markedUnread: chat.markedUnread, mentioned: chat.mentioned)
                }
                AxoChatItemCompact.HiddenTrigger(label: "\(chat.name), \(chat.preview)", onClick: {})
            }
        }
    }

    struct Item: View {
        let compact: Bool
        let chat: Chat
        var body: some View {
            if compact { CompactItem(chat: chat) } else { FullItem(chat: chat) }
        }
    }

    struct ArchivedItem: View {
        let compact: Bool
        var body: some View {
            if compact {
                AxoChatItemCompact.Root {
                    AxoChatItemCompact.Avatar { AxoChatItemCompact.IconAvatar(symbol: "archive") }
                    AxoChatItemCompact.HiddenTrigger(label: "Archived Chats, 5 chats", onClick: {})
                }
            } else {
                AxoChatItem.Root {
                    AxoChatItem.Avatar { AxoChatItem.IconAvatar(symbol: "archive") }
                    AxoChatItem.Content { AxoChatItem.Label("Archived Chats") }
                    AxoChatItem.Count(count: 5, label: "5 archived chats")
                    AxoChatItem.HiddenTrigger(label: "View archived chats", onClick: {})
                }
            }
        }
    }

    /// `Sidebar`: rounded-2xl bg-surface-secondary py-2, w-20 / w-80
    struct Sidebar<Content: View>: View {
        let compact: Bool
        @ViewBuilder var content: Content
        var body: some View {
            content
                .padding(.vertical, 8)
                .frame(width: compact ? 80 : 320)
                .background(RoundedRectangle(cornerRadius: 16).fill(AxoColor.surfaceSecondary))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func allStates(compact: Bool) -> some View {
        var c0 = chat(0)
        c0.sender = "Sender"
        func with(_ f: (inout Chat) -> Void) -> Chat {
            var c = chat(0)
            f(&c)
            return c
        }
        let chats: [Chat] = [
            c0,
            with { $0.sender = "Sender"; $0.unreadCount = 5 },
            with { $0.sender = "Sender"; $0.unreadCount = 3; $0.mentioned = true; $0.muted = true },
            with { $0.markedUnread = true; $0.mentioned = true },
        ] + AxoOutgoingStatus.Status.allCases.map { s in with { $0.outgoingStatus = s } }
        return Sidebar(compact: compact) {
            AxoChatList.Root(compact: compact) {
                ForEach(Array(chats.enumerated()), id: \.offset) { Item(compact: compact, chat: $0.element) }
                ArchivedItem(compact: compact)
            }
        }
    }

    static func groups(compact: Bool) -> some View {
        Sidebar(compact: compact) {
            AxoChatList.Root(compact: compact) {
                AxoChatList.Group {
                    AxoChatList.Label("Pinned")
                    Item(compact: compact, chat: chat(0))
                    Item(compact: compact, chat: chat(1))
                }
                AxoChatList.Group {
                    AxoChatList.Label("Chats")
                    Item(compact: compact, chat: chat(2))
                    Item(compact: compact, chat: chat(3))
                }
            }
        }
    }

    static func loading() -> some View {
        Sidebar(compact: false) {
            AxoChatList.LoadingState {
                AxoBaseSpinner.Root(size: 24, weight: .regular, variant: .default, value: .indeterminate, track: false)
            }
        }
    }

    static func empty() -> some View {
        Sidebar(compact: false) { AxoChatList.EmptyState("No results for \u{201C}xyz\u{201D}") }
    }
}

@MainActor
@Suite struct AxoChatListTests {
    nonisolated static let ids = ["all-states", "all-states-compact", "groups", "groups-compact", "loading", "empty"]

    static func story(_ name: String) -> AnyView {
        switch name {
        case "all-states": AnyView(ChatListStory.allStates(compact: false))
        case "all-states-compact": AnyView(ChatListStory.allStates(compact: true))
        case "groups": AnyView(ChatListStory.groups(compact: false))
        case "groups-compact": AnyView(ChatListStory.groups(compact: true))
        case "loading": AnyView(ChatListStory.loading())
        default: AnyView(ChatListStory.empty())
        }
    }

    @Test(arguments: ids, ["light", "dark"])
    func story(name: String, theme: String) throws {
        try Snapshot.assertMatches(Self.story(name), story: "axo-chatlist-axochatlist--\(name)", theme: theme)
    }
}
