// ConversationListItem (ts/components/conversationList/ConversationListItem.dom.tsx): one chat
// in the list: name (+ mute icon), date, and the last message, draft, typing indicator,
// message-request or blocked note.

import SignalI18n
import SwiftUI

public struct ConversationListItemData {
    public struct LastMessage {
        public var text: String
        public var status: LastMessageStatus?
        public var deletedForEveryone: Bool
        public var isOutgoing: Bool
        public var authorName: String?
        public var deletedByAdminName: String?
        /// Shown before the text (e.g. an attachment emoji).
        public var prefix: String?
        /// Group chats: the sender, shown as "Name: ".
        public var author: String?
        public init(text: String, status: LastMessageStatus? = nil, deletedForEveryone: Bool = false, isOutgoing: Bool = false,
                    authorName: String? = nil, deletedByAdminName: String? = nil, prefix: String? = nil, author: String? = nil) {
            self.text = text
            self.status = status
            self.deletedForEveryone = deletedForEveryone
            self.isOutgoing = isOutgoing
            self.authorName = authorName
            self.deletedByAdminName = deletedByAdminName
            self.prefix = prefix
            self.author = author
        }
    }

    public var id: String
    public var title: String
    public var type: AvatarConversationType
    public var isMe: Bool
    public var isSelected: Bool
    public var isSignalConversation: Bool
    public var acceptedMessageRequest: Bool
    public var isBlocked: Bool
    public var removalStageJustNotification: Bool
    public var avatar: ConversationAvatarData
    public var lastMessage: LastMessage?
    public var lastUpdated: Date?
    public var markedUnread: Bool
    public var muteExpiresAt: Date?
    public var isSomeoneTyping: Bool
    public var shouldShowDraft: Bool
    public var draftPreview: String?
    /// `draftPreview.prefix` (e.g. 🎤 for a voice-note draft).
    public var draftPrefix: String?
    public var draftTimestamp: Date?
    public var unreadCount: Int
    public var unreadMentionsCount: Int

    public init(id: String, title: String, type: AvatarConversationType = .direct, isMe: Bool = false, isSelected: Bool = false,
                isSignalConversation: Bool = false, acceptedMessageRequest: Bool = true, isBlocked: Bool = false,
                removalStageJustNotification: Bool = false, avatar: ConversationAvatarData? = nil, lastMessage: LastMessage? = nil,
                lastUpdated: Date? = nil, markedUnread: Bool = false, muteExpiresAt: Date? = nil, isSomeoneTyping: Bool = false,
                shouldShowDraft: Bool = false, draftPreview: String? = nil, draftTimestamp: Date? = nil, unreadCount: Int = 0,
                unreadMentionsCount: Int = 0) {
        self.id = id
        self.title = title
        self.type = type
        self.isMe = isMe
        self.isSelected = isSelected
        self.isSignalConversation = isSignalConversation
        self.acceptedMessageRequest = acceptedMessageRequest
        self.isBlocked = isBlocked
        self.removalStageJustNotification = removalStageJustNotification
        self.avatar = avatar ?? ConversationAvatarData(title: title, conversationType: type, noteToSelf: isMe)
        self.lastMessage = lastMessage
        self.lastUpdated = lastUpdated
        self.markedUnread = markedUnread
        self.muteExpiresAt = muteExpiresAt
        self.isSomeoneTyping = isSomeoneTyping
        self.shouldShowDraft = shouldShowDraft
        self.draftPreview = draftPreview
        self.draftTimestamp = draftTimestamp
        self.unreadCount = unreadCount
        self.unreadMentionsCount = unreadMentionsCount
    }
}

public struct ConversationListItem: View {
    let data: ConversationListItemData
    let onClick: (String) -> Void
    let onMouseDown: (String) -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.conversationListNow) var fixedNow

    public init(_ data: ConversationListItemData, onClick: @escaping (String) -> Void = { _ in }, onMouseDown: @escaping (String) -> Void = { _ in }) {
        self.data = data
        self.onClick = onClick
        self.onMouseDown = onMouseDown
    }

    /// `__content__message__text`: font-body-2, gray, two lines then an ellipsis.
    static var messageStyle: CSSTextStyle { LegacyType.body2() }
    static var messageColor: AxoColor { AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25) }

    var isMuted: Bool { data.muteExpiresAt.map { (fixedNow ?? Date()) < $0 } ?? false }

    public var body: some View {
        let (text, date) = messageAndDate
        BaseConversationListItem(
            avatar: data.avatar, headerDate: date, messageTextIsAlwaysFullSize: true, isSelected: data.isSelected,
            markedUnread: data.markedUnread, unreadCount: data.unreadCount, unreadMentionsCount: data.unreadMentionsCount,
            buttonAriaLabel: i18n("icu:ConversationList__aria-label", [
                "lastMessage": .string(data.lastMessage?.text ?? i18n("icu:ConversationList__last-message-undefined")),
                "title": .string(data.title), "unreadCount": .number(Double(data.unreadCount)),
            ]),
            onClick: { onClick(data.id) }, onMouseDown: { onMouseDown(data.id) },
            headerName: { headerName },
            messageText: text,
            messageStatusIcon: statusIcon)
    }

    var headerName: some View {
        HStack(spacing: 0) {
            ContactName(title: data.isMe ? i18n("icu:noteToSelf") : data.title, isMe: data.isMe,
                        isSignalConversation: data.isSignalConversation, style: LegacyType.body1(weight: 600))
            if isMuted {
                SignalIcon("v3/bell/bell-slash-bold", size: 14, color: AxoColor(light: LegacyColor.gray45, dark: LegacyColor.gray25))
                    .frame(width: 14, height: 14)
                    .padding(.leading, 8)
            }
        }
    }

    var statusIcon: MessageStatusIcon? {
        guard !data.isBlocked, data.acceptedMessageRequest || data.removalStageJustNotification, !data.isSomeoneTyping,
              !(data.shouldShowDraft && data.draftPreview != nil), let last = data.lastMessage, !last.deletedForEveryone,
              let status = last.status else { return nil }
        return MessageStatusIcon(status: status)
    }

    /// The message line and the header date (the draft's time when a draft is shown).
    var messageAndDate: (AnyView?, Date?) {
        let style = Self.messageStyle, color = Self.messageColor
        if data.isBlocked {
            return (AnyView(HStack(spacing: 4) {
                SignalIcon("v3/block/block", size: 16, color: color).frame(width: 16, height: 16)
                CSSText(i18n("icu:ConversationListItem--blocked"), style: style, wrap: .truncate, color: color)
            }), data.lastUpdated)
        }
        if !data.acceptedMessageRequest && !data.removalStageJustNotification {
            return (AnyView(CSSText(i18n("icu:ConversationListItem--message-request"), style: LegacyType.body2(weight: 600), wrap: .clamp(2),
                                    color: color)), data.lastUpdated)
        }
        if data.isSomeoneTyping {
            return (AnyView(TypingAnimation().padding(.top, 5)), data.lastUpdated)
        }
        if data.shouldShowDraft, let draft = data.draftPreview {
            var prefix = CSSTextRun(i18n("icu:ConversationListItem--draft-prefix"), fontName: AxoFonts.interName(weight: 400, italic: true))
            prefix.marginEnd = 3
            var runs = [prefix]
            if let p = data.draftPrefix { runs.append(CSSTextRun(p + " ")) }
            runs.append(CSSTextRun(draft))
            for i in runs.indices.dropFirst() { runs[i].emojify = true }
            return (AnyView(CSSText(runs: runs, style: style, wrap: .clamp(2), color: color)), data.draftTimestamp)
        }
        if let last = data.lastMessage, last.deletedForEveryone {
            let text: String
            if let admin = last.deletedByAdminName {
                text = i18n("icu:message--deletedByAdmin", ["admin": .string(admin)])
            } else if last.isOutgoing {
                text = i18n("icu:message--deletedForEveryone--outgoing")
            } else {
                text = i18n("icu:message--deletedForEveryone--incoming", ["name": .string(last.authorName ?? "")])
            }
            var run = CSSTextRun(text, fontName: AxoFonts.interName(weight: 400, italic: true))
            run.marginEnd = 3
            return (AnyView(CSSText(runs: [run], style: style, wrap: .clamp(2),
                                    color: color)), data.lastUpdated)
        }
        if let last = data.lastMessage {
            var runs: [CSSTextRun] = []
            if data.type == .group, let author = last.author { runs.append(CSSTextRun(author + ": ")) }
            if let prefix = last.prefix { runs.append(CSSTextRun(prefix + " ")) }
            runs.append(CSSTextRun(last.text))
            for i in runs.indices { runs[i].emojify = true }    // MessageBody renders through Emojify
            return (AnyView(CSSText(runs: runs, style: style, wrap: .clamp(2), color: color)), data.lastUpdated)
        }
        return (nil, data.lastUpdated)
    }
}
