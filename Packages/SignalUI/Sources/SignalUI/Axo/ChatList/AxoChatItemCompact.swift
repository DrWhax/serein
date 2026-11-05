// Port of ts/axo/chatList/AxoChatItemCompact.dom.tsx: a compact chat list row — just
// the 40pt avatar (with badges over its top edge) in a 60 × 56 hover box.

import SwiftUI

public enum AxoChatItemCompact {
    /// `<AxoChatItemCompact.Root>`
    public struct Root<Content: View>: View {
        let content: Content
        public init(@ViewBuilder content: () -> Content) { self.content = content() }
        public var body: some View { AxoBaseChatItem.Root(compact: true, content: content) }
    }

    /// `<AxoChatItemCompact.Avatar>`: the avatar, then its Badges.
    public struct Avatar<Content: View>: View {
        let content: Content
        public init(@ViewBuilder content: () -> Content) { self.content = content() }
        public var body: some View { AxoBaseChatItem.Avatar(content: content) }
    }

    /// `<AxoChatItemCompact.IconAvatar>` (40pt)
    public struct IconAvatar: View {
        let symbol: AxoSymbol.Name
        public init(symbol: AxoSymbol.Name) { self.symbol = symbol }
        public var body: some View { AxoBaseChatItem.IconAvatar(size: 40, symbol: symbol) }
    }

    /// `<AxoChatItemCompact.Badges>`
    public struct Badges: View {
        let unreadCount: Int
        let markedUnread: Bool
        let mentioned: Bool
        public init(unreadCount: Int, markedUnread: Bool, mentioned: Bool) {
            self.unreadCount = unreadCount
            self.markedUnread = markedUnread
            self.mentioned = mentioned
        }
        public var body: some View {
            AxoBaseChatItem.Badges(unreadCount: unreadCount, markedUnread: markedUnread, mentioned: mentioned)
        }
    }

    /// `<AxoChatItemCompact.HiddenTrigger>`
    public struct HiddenTrigger: View {
        let label: String
        let action: () -> Void
        public init(label: String, onClick action: @escaping () -> Void) {
            self.label = label
            self.action = action
        }
        public var body: some View { AxoBaseChatItem.HiddenTrigger(label: label, action: action) }
    }
}
