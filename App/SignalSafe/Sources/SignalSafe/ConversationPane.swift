// The open conversation (upstream ConversationView: ConversationHeader, Timeline, CompositionArea)
// over SignalSession's live timeline, and the mappings from SignalCore rows to SignalUI props.

import Foundation
import SignalCore
import SignalI18n
import SignalUI
import SwiftUI

struct ConversationPane: View {
    @Bindable var session: SignalSession
    let conversation: ConversationSummary
    let i18n: Localizer

    var body: some View {
        if let id = session.messageDetailId, let i = session.messages.firstIndex(where: { $0.id == id }) {
            detailPanel(session.messages[i], at: i)
        } else if let panel = session.panels.last {
            ConversationPanelView(session: session, conversation: conversation, i18n: i18n, name: panel, title: title, avatar: avatar).id(panel)
        } else {
            conversationView
        }
    }

    var conversationView: some View {
        let messages = session.messages
        let byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let index = Dictionary(messages.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return VStack(spacing: 0) {
            ConversationHeader(conversation: header, isSelectMode: session.selectedMessageIds != nil, outgoingCallButtonStyle: .none,
                               actions: headerActions) { EmptyView() }
            if !session.pins.isEmpty {
                PinnedMessagesBar(pins: session.pinItems(you: i18n("icu:you")), current: $session.currentPinIndex, canPinMessages: true,
                                  onPinGoTo: { session.goToMessage($0) }, onPinRemove: { session.unpin($0) },
                                  onPinsShowAll: { if let first = session.pins.first { session.goToMessage(first.messageId) } })
            }
            Timeline(id: conversation.id, items: messages.map(\.id), haveNewest: true, haveOldest: messages.count < 100,
                     scrollToIndex: session.scrollToMessageId.flatMap { index[$0] }, scrollToIndexCounter: session.scrollCounter,
                     getTimestampForMessage: { byId[$0].map { Date(milliseconds: $0.sentAt) } }) { props in
                if let m = byId[props.id], let i = index[props.id] {
                    VStack(spacing: 0) {
                        if TimelineUtil.shouldRenderDateHeader(isOldest: i == 0, grouping(m), previous: i > 0 ? grouping(messages[i - 1]) : nil) {
                            TimelineDateHeader(timestamp: Date(milliseconds: m.sentAt))
                        }
                        TimelineItem(item: .message(self.props(m, at: i, in: messages)))
                    }
                }
            } renderHeroRow: {
                HeroRow {
                    ConversationHero(conversationType: conversation.kind == .group ? .group : .direct, title: title(conversation),
                                     avatar: avatar(conversation), isMe: isNoteToSelf, acceptedMessageRequest: conversation.isAccepted)
                }
            } renderTypingBubble: {
                EmptyView()
            }
            if let selected = session.selectedMessageIds {
                SelectModeActions(selectedCount: selected.count,
                                  areSelectedMessagesForwardable: selected.allSatisfy { id in session.messages.first { $0.id == id }.map { !$0.isDeleted } ?? false },
                                  onExitSelectMode: { session.exitSelectMode() }, onDeleteMessages: { session.requestDelete(selected) },
                                  onForwardMessages: { session.forward(selected) })
                    .background(AxoColor.surfacePrimary)
            } else {
                composer
            }
        }
        .background(AxoColor.surfacePrimary)
    }

    var composer: some View {
            CompositionArea(text: $session.draft, model: composerModel, actions: {
                var a = CompositionAreaActions()
                a.onCloseQuote = { session.quotedMessageId = nil }
                a.onEditLastMessage = { [isNoteToSelf] in session.editLastMessage(noteToSelf: isNoteToSelf) }
                a.discardEditMessage = { session.discardEdit() }
                a.onSubmit = { session.sendDraft() }
                a.launchMediaPicker = { session.pickAttachments(mediaOnly: true) }
                a.launchFilePicker = { session.pickAttachments(mediaOnly: false) }
                a.onAddAttachment = { session.pickAttachments(mediaOnly: false) }
                a.onCloseAttachment = { session.removeStaged(at: $0) }
                a.onClearAttachments = { session.clearStaged() }
                return a
            }(), funPicker: AnyView(ComposerFunPicker(session: session)))
            .fixedSize(horizontal: false, vertical: true)    // its own height; the timeline takes the rest
            .onAppear { session.observeStickers() }
    }

    /// The MessageDetails panel (pushed over the conversation; back returns to it).
    func detailPanel(_ m: TimelineMessage, at i: Int) -> some View {
        var message = props(m, at: i, in: session.messages)
        message.actions = nil
        message.shouldCollapseAbove = false
        message.shouldCollapseBelow = false
        message.shouldHideMetadata = false
        let d = session.messageDetail
        let contacts: [MessageDetailContact] = m.direction == .outgoing
            ? (d?.recipients ?? []).map { r in
                var c = MessageDetailContact(id: r.conversationId, title: session.contactTitle(r.serviceId), color: session.contactColor(r.serviceId),
                                             avatar: session.avatarImage(r.serviceId.flatMap { session.contacts[$0]?.avatar }),
                                             status: SignalUI.SendStatus(rawValue: r.status), statusTimestamp: r.updatedAt.map(Date.init(milliseconds:)))
                c.isUnidentifiedDelivery = r.unidentified
                return c
            }
            : []
        return ConversationPanel(onBack: { session.messageDetailId = nil }) {
            EmptyView()
        } content: {
            ScrollView {
                MessageDetail(message: message, contacts: contacts, errors: d?.errors ?? [], sentAt: Date(milliseconds: m.sentAt),
                              receivedAt: m.direction == .incoming ? Date(milliseconds: d?.receivedAt ?? m.receivedAt) : nil,
                              expirationTimestamp: message.expirationTimestamp, isEditedMessage: m.isEdited)
            }
        }
    }

    /// TimelineMessage's actions for a message (upstream's `can…` rules).
    func actions(_ m: TimelineMessage) -> TimelineMessageActions {
        var a = TimelineMessageActions()
        let id = m.id
        // canReplyOrReact: not deleted, an accepted chat, and an outgoing message actually sent.
        let sent = m.status.map { $0 != .pending && $0 != .failed } ?? true
        if !m.isDeleted && conversation.isAccepted && (m.direction == .incoming || sent || isNoteToSelf) {
            a.react = { emoji, remove in session.react(id, emoji: emoji, remove: remove) }
            a.reply = { session.reply(to: id) }
        }
        a.selectedReaction = m.reactions.first { $0.fromId == session.ourAci }?.emoji
        var seen = Set<String>()
        a.messageEmojis = m.reactions.map(\.emoji).filter { seen.insert($0).inserted }
        if !m.isDeleted && !m.body.isEmpty { a.copy = { session.copyText(id) } }
        a.select = { session.toggleSelect(id, selected: true) }
        if session.canEdit(m, noteToSelf: isNoteToSelf) { a.edit = { session.startEdit(id) } }
        if !m.isDeleted {
            if m.isPinned { a.unpin = { session.unpin(id) } } else { a.pin = { session.requestPin(id) } }
        }
        a.moreInfo = { session.messageDetailId = id }
        if !m.isDeleted && (m.sticker != nil || !m.body.isEmpty || !m.attachments.isEmpty) { a.forward = { session.forward([id]) } }
        a.delete = { session.requestDelete([id]) }
        return a
    }

    /// A stored quote as the bubble's (or the composer's) quote.
    func quoteModel(_ q: TimelineQuote, in m: TimelineMessage?) -> QuoteModel {
        let fromMe = q.authorAci == session.ourAci
        var model = QuoteModel(authorTitle: fromMe ? i18n("icu:you") : session.contactTitle(q.authorAci), text: q.text)
        model.isFromMe = fromMe
        if let type = q.attachmentContentType {
            model.rawAttachment = QuotedAttachment(contentType: type, fileName: q.attachmentFileName, thumbnail: quoteThumbnail(q))
        }
        model.referencedMessageNotFound = m != nil && q.messageId == nil
        model.direction = m.map { $0.direction == .outgoing ? .outgoing : .incoming } ?? .compose
        return model
    }

    /// A quote's picture: its own thumbnail, else the quoted message's (when it is here).
    func quoteThumbnail(_ q: TimelineQuote) -> RGBAImage? {
        if let t = q.thumbnail, let image = session.image(for: t) { return image }
        guard let id = q.messageId, let original = session.messages.first(where: { $0.id == id })?.attachments.first?.attachment else { return nil }
        return AttachmentPolicy.isVideo(original.contentType) ? session.posterImage(for: original) : session.image(for: original)
    }

    /// The composer's quote: the message being replied to.
    var composerQuote: QuoteModel? {
        guard let id = session.quotedMessageId, let m = session.messages.first(where: { $0.id == id }) else { return nil }
        let author = m.direction == .outgoing ? (session.ourAci ?? "") : (m.author ?? "")
        var q = TimelineQuote(sentAt: m.sentAt, authorAci: author, text: m.body.isEmpty ? nil : m.body, isGiftBadge: false, messageId: m.id)
        if let first = m.attachments.first {
            q.attachmentContentType = first.attachment.contentType
            q.attachmentFileName = first.attachment.fileName
        }
        return quoteModel(q, in: nil)
    }

    var isNoteToSelf: Bool { conversation.kind == .private && conversation.serviceId != nil && conversation.serviceId == session.ourAci }

    func title(_ c: ConversationSummary) -> String {
        c.kind == .private && c.serviceId != nil && c.serviceId == session.ourAci ? i18n("icu:noteToSelf") : c.title
    }

    func avatar(_ c: ConversationSummary) -> ConversationAvatarData {
        let me = c.kind == .private && c.serviceId != nil && c.serviceId == session.ourAci
        var a = ConversationAvatarData(title: title(c), conversationType: c.kind == .group ? .group : .direct, color: c.color,
                                       image: me ? nil : session.avatarImage(c.avatar))
        a.noteToSelf = me
        return a
    }

    var header: ConversationHeaderModel {
        var h = ConversationHeaderModel(id: conversation.id, type: conversation.kind == .group ? .group : .direct, title: title(conversation))
        h.color = conversation.color
        if !isNoteToSelf, let image = session.avatarImage(conversation.avatar) {
            h.avatar = image
            h.hasAvatar = true
        }
        h.isMe = isNoteToSelf
        h.isArchived = conversation.isArchived
        h.isPinned = conversation.isPinned
        h.acceptedMessageRequest = conversation.isAccepted
        if let d = session.details {
            h.expireTimer = d.expireTimer
            h.isMuted = (d.muteExpiresAt ?? 0) > Int64(Date().timeIntervalSince1970 * 1000)
            h.isBlocked = d.isBlocked
            h.isArchived = d.isArchived
            h.isPinned = d.isPinned
            h.markedUnread = d.markedUnread
            h.left = d.left
            if let g = d.group, let me = session.ourAci {
                h.areWeAdmin = g.isAdmin(me)
                h.announcementsOnly = g.announcementsOnly
                h.terminated = g.terminated
                h.canChangeTimer = g.accessControl.attributes != GroupAccess.administrator || g.isAdmin(me)
            }
        }
        return h
    }

    /// The header's menu and buttons.
    var headerActions: ConversationHeaderActions {
        var a = ConversationHeaderActions()
        a.onViewConversationDetails = { session.pushPanel("ConversationDetails") }
        a.onShowMembers = { session.pushPanel("ConversationDetails") }
        a.onViewAllMedia = { session.pushPanel("AllMedia") }
        a.onMuteExpirationChange = { session.setMute($0) }
        a.onDisappearingMessagesChange = { session.setDisappearingTimer($0) }
        a.onSetupCustomDisappearingTimeout = { [id = conversation.id] in session.customTimerFor = id }
        a.onAccept = { session.respond(conversation.id, .accept) }
        a.onBlock = { session.setBlocked(true) }
        a.onUnblock = { session.setBlocked(false) }
        a.onReportSpam = { session.reportSpam(block: false) }
        a.onDelete = { session.deleteChat() }
        a.onDeleteMessages = { session.deleteChat() }
        a.onLeaveGroup = { session.leaveGroup() }
        a.onArchive = { session.setArchived(true) }
        a.onUnarchive = { session.setArchived(false) }
        a.onPin = { session.setPinnedChat(true) }
        a.onUnpin = { session.setPinnedChat(false) }
        a.onMarkUnread = { session.setMarkedUnread(true) }
        a.onSelectModeEnter = { session.selectedMessageIds = [] }
        a.onSearchInConversation = { session.startConversationSearch() }
        return a
    }

    var composerModel: CompositionAreaModel {
        var request = MessageRequestModel(conversationId: conversation.id, conversationType: conversation.kind == .group ? .group : .direct,
                                          conversationName: conversation.title)
        let id = conversation.id
        request.acceptConversation = { session.respond(id, .accept) }
        request.blockConversation = { session.respond(id, .block) }
        request.blockAndReportSpam = { session.respond(id, .blockAndSpam) }
        request.reportSpam = { session.respond(id, .spam) }
        request.deleteConversation = { session.respond(id, .delete) }
        var m = CompositionAreaModel(conversationId: conversation.id, messageRequest: request)
        m.acceptedMessageRequest = conversation.isAccepted
        m.quote = composerQuote
        m.quotedMessageId = session.quotedMessageId
        m.isEditingMessage = session.editingMessageId != nil
        m.draftAttachments = session.staged.map { s in
            var a = SignalUI.MessageAttachment(contentType: s.contentType, fileName: s.fileName, size: s.data.count, width: s.width, height: s.height)
            a.image = s.preview
            return a
        }
        m.conversationType = conversation.kind == .group ? .group : .direct
        m.groupVersion = conversation.kind == .group ? 2 : nil
        return m
    }

    func authorId(_ m: TimelineMessage) -> String { m.direction == .outgoing ? (session.ourAci ?? "me") : (m.author ?? "unknown") }

    func grouping(_ m: TimelineMessage) -> TimelineGroupingInfo {
        var g = TimelineGroupingInfo(authorId: authorId(m), timestamp: Date(milliseconds: m.sentAt), status: m.status.map(Self.messageStatus))
        g.deletedForEveryone = m.isDeleted
        return g
    }

    func props(_ m: TimelineMessage, at i: Int, in all: [TimelineMessage]) -> MessageProps {
        var author = MessageProps.Author(id: authorId(m), title: m.direction == .outgoing ? i18n("icu:you") : session.contactTitle(m.author))
        author.isMe = m.direction == .outgoing
        author.color = m.direction == .outgoing ? nil : session.contactColor(m.author)
        if m.direction == .incoming { author.avatar = session.avatarImage(m.author.flatMap { session.contacts[$0]?.avatar }) }
        var p = MessageProps(id: m.id, direction: m.direction == .outgoing ? .outgoing : .incoming, author: author,
                             text: m.isDeleted ? nil : m.body, timestamp: Date(milliseconds: m.sentAt))
        p.conversationType = conversation.kind == .group ? .group : .direct
        if conversation.kind == .group, m.direction == .incoming, let aci = m.author, let g = session.details?.group {
            // The sender's name colour and member label in the group.
            p.contactNameColor = ContactNameColors.colors(g)[aci]
            if let member = g.member(aci), let s = member.labelString, !s.isEmpty { p.contactLabel = ContactLabel(labelString: s, labelEmoji: member.labelEmoji) }
        }
        p.status = m.status.map(Self.messageStatus)
        if m.direction == .outgoing { p.bubbleColor = session.bubbleColor(session.conversationColor) }
        p.attachments = m.attachments.map { attachment($0.attachment) }
        if let first = m.attachments.first?.attachment, (first.flags ?? 0) & 8 != 0, AttachmentPolicy.isVideo(first.contentType) {
            p.gifPlayer = session.gifPlayer(for: first)
        }
        if let st = m.sticker {
            // The sticker's own file (ours, or downloaded), else the installed pack's copy.
            p.isSticker = true
            let file = st.attachment
            var a = SignalUI.MessageAttachment(contentType: file?.contentType ?? "image/webp", fileName: nil, size: file?.size ?? 0,
                                               width: file?.width ?? 512, height: file?.height ?? 512)
            let image = (file?.isDownloaded == true ? file.flatMap { session.image(for: $0) } : nil)
                ?? session.stickerImage(packId: st.packId, stickerId: st.stickerId)
            a.image = image
            a.isDownloaded = image != nil || file?.isDownloaded == true
            a.pending = file?.pending ?? false
            p.attachments = [a]
        }
        p.showLightbox = { [session] i in session.openLightbox(m, index: i) }
        p.deletedForEveryone = m.isDeleted
        p.isPinned = m.isPinned
        p.isEdited = m.isEdited
        if let t = m.expireTimer, t > 0 {
            p.expirationLength = TimeInterval(t)
            p.expirationTimestamp = m.expirationStartTimestamp.map { Date(milliseconds: $0 + Int64(t) * 1000) }
        }
        let me = session.ourAci
        p.reactions = m.reactions.map {
            MessageReaction(emoji: $0.emoji, fromIsMe: $0.fromId == me, fromTitle: $0.fromId == me ? i18n("icu:you") : session.contactTitle($0.fromId),
                            timestamp: Double($0.timestamp))
        }
        if let q = m.quote {
            p.quote = quoteModel(q, in: m)
            if let target = q.messageId { p.scrollToQuotedMessage = { [session] in session.goToMessage(target) } }
        }
        if let selected = session.selectedMessageIds {
            p.isSelectMode = true
            p.isSelected = selected.contains(m.id)
            p.toggleSelectMessage = { [session] shift, on in session.toggleSelect(m.id, shift: shift, selected: on) }
        }
        p.actions = actions(m)
        let previous = i > 0 ? grouping(all[i - 1]) : nil, next = i + 1 < all.count ? grouping(all[i + 1]) : nil
        p.shouldCollapseAbove = TimelineUtil.areMessagesInSameGroup(previous, unreadIndicator: false, grouping(m))
        p.shouldCollapseBelow = TimelineUtil.areMessagesInSameGroup(grouping(m), unreadIndicator: false, next)
        p.shouldHideMetadata = TimelineUtil.shouldHideMetadata(grouped: p.shouldCollapseBelow, grouping(m), next)
        return p
    }

    /// SignalCore's attachment row → the bubble's attachment (pixels via the media service).
    func attachment(_ a: SignalCore.MessageAttachment) -> SignalUI.MessageAttachment {
        var out = SignalUI.MessageAttachment(contentType: a.contentType, fileName: a.fileName, size: a.size, width: a.width, height: a.height)
        out.fileName = a.fileName
        out.width = a.width
        out.height = a.height
        out.isDownloaded = a.isDownloaded
        out.pending = a.pending ?? false
        out.isGifFlag = (a.flags ?? 0) & 8 != 0
        out.hasUrl = a.isDownloaded
        out.image = session.image(for: a)
        if AttachmentPolicy.isVideo(a.contentType) {
            out.screenshot = session.posterImage(for: a)
            out.videoFrame = out.screenshot
        }
        return out
    }

    static func messageStatus(_ s: TimelineMessage.Status) -> MessageStatus {
        switch s {
        case .pending: .sending
        case .sent: .sent
        case .delivered: .delivered
        case .read: .read
        case .viewed: .viewed
        case .failed: .error
        }
    }
}

extension Date {
    init(milliseconds: Int64) { self.init(timeIntervalSince1970: TimeInterval(milliseconds) / 1000) }
}


/// The composer's Fun picker: emoji (into the draft), installed stickers and GIFs (sent).
struct ComposerFunPicker: View {
    @Bindable var session: SignalSession
    @State private var tab = FunPickerTabKey.emojis
    @State private var gifSearch = ""
    @Environment(\.axoMenuClose) var close

    var body: some View {
        FunPicker(tab: $tab) {
            // Stays open: pick several emoji in a row.
            FunPanelEmojis(recentEmojis: session.recentEmojis, onSelectEmoji: { session.insertEmoji($0) })
        } stickers: {
            FunPanelStickers(packs: session.stickerPacks.map { p in
                FunStickerPack(id: p.id, title: p.title, cover: session.stickerImage(packId: p.id, stickerId: p.coverStickerId),
                               stickers: p.stickers.map { FunStickerItem(id: $0.id, packId: p.id, image: session.stickerImage(packId: p.id, stickerId: $0.id), emoji: $0.emoji) })
            }, favorites: [], recents: [], onSelectSticker: { s in session.sendSticker(packId: s.packId, stickerId: s.id); close() })
        } gifs: {
            FunPanelGifs(recentGifs: [], source: session.gifSource, storedSearchInput: $gifSearch,
                         onSelectGif: { g in session.sendGif(g.gif.attachmentMedia.url); close() }, onClose: { close() })
        }
    }
}
