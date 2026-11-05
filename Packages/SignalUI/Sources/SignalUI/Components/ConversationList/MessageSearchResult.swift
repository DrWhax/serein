// MessageSearchResult (ts/components/conversationList/MessageSearchResult.dom.tsx): a message
// found by search: "{sender} to You" style header, the sent date, and the snippet with the
// matched words highlighted.

import SignalI18n
import SwiftUI

public struct MessageSearchResultPerson {
    public var title: String
    public var isMe: Bool
    public var type: AvatarConversationType
    public var avatar: ConversationAvatarData
    public init(title: String, isMe: Bool = false, type: AvatarConversationType = .direct, avatar: ConversationAvatarData? = nil) {
        self.title = title
        self.isMe = isMe
        self.type = type
        self.avatar = avatar ?? ConversationAvatarData(title: title, conversationType: .direct, noteToSelf: isMe)
    }
}

public struct MessageSearchResult: View {
    let id: String
    let conversationId: String
    let from: MessageSearchResultPerson?
    let to: MessageSearchResultPerson?
    let sentAt: Date
    let snippet: String
    let messageBody: String
    let bodyRanges: [BodyRange]
    let showConversation: (String, String) -> Void
    @Environment(\.i18n) var i18n

    public init(id: String, conversationId: String, from: MessageSearchResultPerson?, to: MessageSearchResultPerson?, sentAt: Date,
                snippet: String, body: String, bodyRanges: [BodyRange] = [], showConversation: @escaping (String, String) -> Void = { _, _ in }) {
        self.id = id
        self.conversationId = conversationId
        self.from = from
        self.to = to
        self.sentAt = sentAt
        self.snippet = snippet
        self.messageBody = body
        self.bodyRanges = bodyRanges
        self.showConversation = showConversation
    }

    public var body: some View {
        if let from, let to {
            BaseConversationListItem(avatar: avatar(from: from, to: to), headerDate: sentAt, onClick: { showConversation(conversationId, id) },
                                     headerName: { header(from: from, to: to) }, messageText: messageText, messageStatusIcon: EmptyView?.none)
        } else {
            Color.clear.frame(height: 0)
        }
    }

    func avatar(from: MessageSearchResultPerson, to: MessageSearchResultPerson) -> ConversationAvatarData {
        var a = from.avatar
        a.noteToSelf = from.isMe && to.isMe
        return a
    }

    var messageText: CSSText {
        let (cleaned, ranges) = BodyRanges.processForSearchResult(snippet: snippet, body: messageBody, bodyRanges: bodyRanges)
        let runs = MessageTextRenderer.runs(text: cleaned, bodyRanges: ranges, style: ConversationListItem.messageStyle, renderLocation: .searchResult)
        return CSSText(runs: runs, style: ConversationListItem.messageStyle, wrap: .clamp(2), color: ConversationListItem.messageColor)
    }

    func header(from: MessageSearchResultPerson, to: MessageSearchResultPerson) -> some View {
        let isNoteToSelf = from.isMe && to.isMe
        let style = LegacyType.body1(weight: 600)
        let text: String
        if isNoteToSelf {
            text = i18n("icu:noteToSelf")
        } else if from.isMe {
            text = to.type == .group ? i18n("icu:searchResultHeader--you-to-group", ["receiverGroup": .string(to.title)], bidi: .none)
                : i18n("icu:searchResultHeader--you-to-receiver", ["receiverContact": .string(to.title)], bidi: .none)
        } else if to.type == .group {
            text = i18n("icu:searchResultHeader--sender-to-group", ["sender": .string(from.title), "receiverGroup": .string(to.title)], bidi: .none)
        } else {
            text = i18n("icu:searchResultHeader--sender-to-you", ["sender": .string(from.title)], bidi: .none)
        }
        return CSSText(text, style: style, wrap: .truncate)
    }
}
