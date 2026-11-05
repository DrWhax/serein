// Demo content for the Chats tab until SignalCore is wired in: a handful of chats that
// exercise the ported left-pane components (pinned, unread, typing, draft, muted, statuses)
// and an update banner.

import Foundation
import SignalUI

enum DemoData {
    static func conversations(now: Date) -> (pinned: [ConversationListItemData], chats: [ConversationListItemData], archived: [ConversationListItemData]) {
        func c(_ id: String, _ title: String, color: String, _ text: String?, status: LastMessageStatus? = nil, minutesAgo: Double,
               _ change: (inout ConversationListItemData) -> Void = { _ in }) -> ConversationListItemData {
            var d = ConversationListItemData(id: id, title: title,
                                             avatar: ConversationAvatarData(title: title, color: color),
                                             lastMessage: text.map { .init(text: $0, status: status) },
                                             lastUpdated: now.addingTimeInterval(-minutesAgo * 60))
            change(&d)
            return d
        }
        let pinned = [
            c("note", "Note to Self", color: "A120", "Buy oat milk 🥛", status: .read, minutesAgo: 3) { $0.isMe = true; $0.avatar.noteToSelf = true },
            c("alice", "Alice Chen", color: "A140", "See you at 7! 🎉", minutesAgo: 12) { $0.unreadCount = 3 },
        ]
        let chats = [
            c("bob", "Bob Marley", color: "A180", nil, minutesAgo: 1) { $0.isSomeoneTyping = true },
            c("team", "Signal Safe Team", color: "A110", "We should ship the left pane today. Snapshot tests are all green, emoji too 🔥",
              minutesAgo: 45) { $0.type = .group; $0.avatar.conversationType = .group; $0.unreadMentionsCount = 1; $0.unreadCount = 12 },
            c("carol", "Carol Danvers", color: "A170", "Sent you the photos", status: .delivered, minutesAgo: 60 * 5) { $0.isSelected = true },
            c("dave", "Dave Grohl", color: "A130", nil, minutesAgo: 60 * 26) {
                $0.shouldShowDraft = true
                $0.draftPreview = "I'll call you back after the show"
            },
            c("erin", "Erin Brockovich", color: "A160", "Muted chat, still here", status: .sent, minutesAgo: 60 * 24 * 3) {
                $0.muteExpiresAt = now.addingTimeInterval(3600)
            },
            c("frank", "Frank Ocean", color: "A200", "Message failed", status: .error, minutesAgo: 60 * 24 * 40),
        ]
        let archived = [c("old", "Old Group", color: "A210", "Bye", minutesAgo: 60 * 24 * 400)]
        return (pinned, chats, archived)
    }
}
