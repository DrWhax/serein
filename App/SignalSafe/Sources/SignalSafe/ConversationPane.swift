// The open conversation (upstream ConversationView: ConversationHeader, Timeline, CompositionArea)
// over SignalSession's live timeline, and the mappings from SignalCore rows to SignalUI props.

import Foundation
import SignalCore
import SignalI18n
import SignalText
import SignalUI
import SwiftUI

struct ConversationPane: View {
    @Bindable var session: SignalSession
    let conversation: ConversationSummary
    let i18n: Localizer
    @Environment(\.axoModalStack) var modals

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
        conversationContent
            // Files dropped on the chat are staged as attachments (upstream's drop zone): a
            // file, or one a browser or Photos promises (AttachmentDrops.swift).
            .onDrop(of: [.fileURL, .image, .audiovisualContent, .data], isTargeted: nil) { session.stageDropped($0) }
    }

    var conversationContent: some View {
        let messages = session.messages
        let byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let index = Dictionary(messages.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        // The rows: consecutive call events, group updates or timer changes fold into one
        // (upstream mapItemsIntoCollapseSets); the divider and scroll target move to their rows.
        let mapped = CollapseSets.map(messages.map(collapseItem), oldestUnseenIndex: session.unreadMarker.flatMap { index[$0.oldestId] },
                                      scrollToIndex: session.scrollToMessageId.flatMap { index[$0] })
        let sets = Dictionary(mapped.sets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return VStack(spacing: 0) {
            ConversationHeader(conversation: header, hasStories: session.storyRing(conversation), isSelectMode: session.selectedMessageIds != nil,
                               isSignalConversation: isSignalChat,
                               outgoingCallButtonStyle: callButtonStyle,
                               contactSpoofingWarning: spoofingWarning, collidingAvatars: collidingAvatars, actions: headerActions) { EmptyView() }
            if session.activeAudioMessageId != nil {
                // While audio plays (in this chat or another) the mini-player takes the pinned bar's place.
                AudioMiniPlayer(session: session, i18n: i18n)
            } else if !session.pins.isEmpty {
                PinnedMessagesBar(pins: session.pinItems(you: i18n("icu:you")), current: $session.currentPinIndex, canPinMessages: session.canPinMessages,
                                  onPinGoTo: { session.goToMessage($0) }, onPinRemove: { session.unpin($0) },
                                  onPinsShowAll: { if let first = session.pins.first { session.goToMessage(first.messageId) } })
            }
            Timeline(id: conversation.id, items: mapped.sets.map(\.id), haveNewest: true, haveOldest: session.haveOldest,
                     isSignalConversation: isSignalChat,
                     isLoadingMessages: session.isLoadingOlder,
                     oldestUnseenIndex: mapped.unseenIndex, totalUnseen: session.unreadMarker?.count ?? 0,
                     unreadCount: session.unreadCounts.unread, unreadMentionsCount: session.unreadCounts.mentions,
                     scrollToIndex: mapped.scrollToIndex, scrollToIndexCounter: session.scrollCounter,
                     getTimestampForMessage: { byId[$0].map { Date(milliseconds: $0.sentAt) } }) { props in
                if let set = sets[props.id], let kind = set.kind, let i = index[props.id] {
                    TimelineCollapseRow(pane: self, set: set, kind: kind, messages: set.messages.compactMap { byId[$0.id] },
                                        previous: i > 0 ? messages[i - 1] : nil)
                        .equatable()
                } else if let m = byId[props.id], let i = index[props.id] {
                    TimelineRow(pane: self, message: m, previous: i > 0 ? messages[i - 1] : nil, next: i + 1 < messages.count ? messages[i + 1] : nil)
                        .equatable()
                }
            } renderHeroRow: {
                HeroRow { hero }
            } renderTypingBubble: {
                let typists = session.typingContacts(conversation.id)
                if !typists.isEmpty {
                    TypingBubble(conversationType: conversation.kind == .group ? .group : .direct, typingContacts: typists,
                                 showContactModal: { session.contactModalId = $0 })
                }
            } loadOlderMessages: { _ in
                session.loadOlderMessages()
            } scrollToOldestUnreadMention: { _ in
                session.scrollToOldestUnreadMention()
            } markMessageRead: { id in
                // A row's newest entry (a collapse set's last) is what was seen.
                let newest = sets[id]?.messages.last.flatMap { byId[$0.id] } ?? byId[id]
                if let newest { session.markVisibleRead(upTo: newest.receivedAt) }
            }
            .environment(\.messageTextSelectable, true)
            // A signal.link/call URL opens the call link's lobby instead of the browser.
            .environment(\.openURL, OpenURLAction { url in session.openInAppLink(url) ? .handled : .systemAction })
            .environment(\.textSelectionCenter, session.textSelection)
            if let selected = session.selectedMessageIds {
                SelectModeActions(selectedCount: selected.count,
                                  areSelectedMessagesForwardable: selected.allSatisfy { id in session.messages.first { $0.id == id }.map { $0.notice == nil && !$0.isDeleted && !$0.isViewOnce && $0.poll == nil } ?? false },
                                  onExitSelectMode: { session.exitSelectMode() }, onDeleteMessages: { session.requestDelete(selected) },
                                  onForwardMessages: { session.forward(selected) }, showTooManyToast: { session.toast = .tooManyMessagesToForward })
                    .background(AxoColor.surfacePrimary)
            } else {
                composer
            }
        }
        .background(AxoColor.surfacePrimary)
    }

    /// The timeline's first row (HeroRow): who this is, the name warnings, groups in common or
    /// members, and the safety tips for a message request.
    var hero: some View {
        let d = session.details?.conversationId == conversation.id ? session.details : nil
        let group = d?.group
        let me = session.ourAci
        var a = ConversationHero.Actions()
        let serviceId = conversation.kind == .private ? conversation.serviceId : nil
        a.toggleAboutContactModal = { if let serviceId { session.showAboutContact(serviceId) } }
        a.toggleProfileNameWarningModal = { [isGroup = conversation.kind == .group] in session.contactDialog = .profileNameWarning(isGroup: isGroup) }
        a.onShowSafetyTips = { session.contactDialog = .safetyTips }
        a.openConversationDetails = { session.pushPanel("ConversationDetails") }
        a.viewUserStories = { [session, conversation] in session.viewUserStories(conversation) }
        // The members line (`getGroupMemberships`), by their titles.
        let members = (group?.membersV2 ?? []).map { m in HeroMember(isMe: m.aci == me, titleShort: m.aci == me ? nil : session.contactTitle(m.aci)) }
        return ConversationHero(conversationType: conversation.kind == .group ? .group : .direct, title: title(conversation),
                                avatar: avatar(conversation), hasStories: session.storyRing(conversation), isMe: isNoteToSelf, isSignalConversation: isSignalChat,
                                acceptedMessageRequest: conversation.isAccepted,
                                hasProfileName: d?.hasProfileName ?? false, hasNickname: d?.hasNickname ?? false,
                                isInSystemContacts: d?.isInSystemContacts ?? false, isGroupNameVerified: d?.isGroupNameVerified ?? true,
                                groupDescription: group?.description,
                                sharedGroupNames: (d?.groupsInCommon ?? []).compactMap { session.conversation($0)?.title },
                                memberships: members, invitesCount: (group?.pendingMembersV2.count ?? 0) + (group?.pendingAdminApprovalV2.count ?? 0),
                                actions: a)
    }

    var composer: some View {
            CompositionArea(text: $session.draft, model: composerModel, actions: {
                var a = CompositionAreaActions()
                a.onCloseQuote = { session.quotedMessageId = nil }
                a.onToggleViewOnce = { session.draftViewOnce.toggle() }
                a.openShareContactDialog = { session.openShareContactDialog() }
                // A join request still waiting for an admin, withdrawn (`cancelJoinRequest`).
                a.cancelJoinRequest = { session.leaveGroup() }
                // AnnouncementsOnlyGroupBanner's admins: their 1:1 chat.
                a.showConversation = { session.openDirect(serviceId: $0) }
                // `onClickQuotedMessage`: the quoted message in the timeline.
                a.onClickQuote = { if let id = session.quotedMessageId { session.goToMessage(id) } }
                a.onCloseLinkPreview = { session.closeLinkPreview() }
                a.onEditLastMessage = { [isNoteToSelf] in session.editLastMessage(noteToSelf: isNoteToSelf) }
                a.discardEditMessage = { session.discardEdit() }
                a.onSubmit = { session.sendDraft() }
                a.setMediaQualitySetting = { session.composerHighQuality = $0 }
                a.launchMediaPicker = { session.pickAttachments(mediaOnly: true) }
                a.launchFilePicker = { session.pickAttachments(mediaOnly: false) }
                a.onAddAttachment = { session.pickAttachments(mediaOnly: false) }
                a.onCloseAttachment = { session.removeStaged(at: $0) }
                a.onClickAttachment = { session.editStaged(at: $0) }
                a.onClearAttachments = { session.clearStaged() }
                a.onPaste = { session.pasteAttachments($0) }
                a.onPickMention = { session.composer.insertMention($0) }
                a.startRecording = { session.startRecording() }
                a.openPollModal = { session.isCreatingPoll = true }
                return a
            }(), funPicker: AnyView(ComposerFunPicker(session: session)), renderSmartCompositionRecording: {
                let r = session.recording
                return AnyView(CompositionRecording(peaks: r?.peaks ?? [], errorDialog: r?.error, startedAt: r?.startedAt ?? .now,
                                                    onCancel: { session.cancelRecording() }, onSend: { session.sendRecording() },
                                                    errorRecording: { _ in session.cancelRecording() },
                                                    saveDraftRecordingIfNeeded: { session.saveDraftRecordingIfNeeded() }))
            })
            .environment(\.composerController, session.composer)
            .fixedSize(horizontal: false, vertical: true)    // its own height; the timeline takes the rest
            .onAppear {
                session.observeStickers()
                session.linkPreviewStrings = linkPreviewStrings
            }
    }

    /// The strings a preview we send carries (upstream fills them in the sender's language).
    var linkPreviewStrings: LinkPreviewStrings {
        let i18n = i18n
        return LinkPreviewStrings(stickerPackDescription: { i18n("icu:stickers--StickerPackLinkPreviewDescription", ["author": .string($0)]) },
                                  groupDescription: { i18n("icu:GroupV2--join--group-metadata--full", ["memberCount": .number(Double($0))]) },
                                  unknownGroup: i18n("icu:unknownGroup"), callLinkTitle: i18n("icu:calling__call-link-default-title"),
                                  callLinkDescription: i18n("icu:message--call-link-description"))
    }

    /// The MessageDetails panel (pushed over the conversation; back returns to it).
    func detailPanel(_ m: TimelineMessage, at i: Int) -> some View {
        let all = session.messages
        var message = props(m, previous: i > 0 ? all[i - 1] : nil, next: i + 1 < all.count ? all[i + 1] : nil)
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
                              expirationTimestamp: message.expirationTimestamp, isEditedMessage: m.isEdited,
                              showEditHistoryModal: { session.editHistoryMessageId = $0 },
                              toggleSafetyNumberModal: { id in session.showSafetyNumber((d?.recipients ?? []).first { $0.conversationId == id }?.serviceId) })
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
        a.skinTone = session.emojiSkinTone
        a.setSkinTone = { session.emojiSkinTone = $0 }
        a.recentEmojis = session.recentEmojis
        a.preferredReactions = session.preferredReactions
        a.openCustomizePreferredReactions = { session.openCustomizePreferredReactions() }
        a.useEmoji = { session.recordEmojiUse($0) }
        if !m.isDeleted && !m.body.isEmpty { a.copy = { session.copyText(id) } }
        a.select = { session.toggleSelect(id, selected: true) }
        if session.canEdit(m, noteToSelf: isNoteToSelf) { a.edit = { session.startEdit(id) } }
        if !m.isDeleted && session.canPinMessages {
            if m.isPinned { a.unpin = { session.unpin(id) } } else { a.pin = { session.requestPin(id) } }
        }
        // canDownload: a message's attachments, all downloaded (not a sticker or view-once media, and
        // an incoming one only in an accepted chat), saved where the user chooses.
        let viewOnce = m.isViewOnce && !m.isDeleted
        if !m.isDeleted && m.sticker == nil && !viewOnce && !m.attachments.isEmpty && m.attachments.allSatisfy(\.attachment.isDownloaded)
            && (m.direction == .outgoing || conversation.isAccepted) {
            a.download = { session.saveAttachments(m) }
        }
        if m.direction == .outgoing, m.status == .failed || m.status == .partialSent { a.retrySend = { session.retrySend(id) } }
        // canEndPoll: our own poll, still running, in a group that has not ended.
        if m.direction == .outgoing, let poll = m.poll, !poll.terminated, !m.isDeleted, session.details?.group?.terminated != true {
            a.endPoll = { session.endPoll(id) }
        }
        a.moreInfo = { session.messageDetailId = id }
        // canForward: not view-once media, deleted, or a poll.
        if !m.isDeleted && !viewOnce && m.poll == nil && (m.sticker != nil || !m.body.isEmpty || !m.attachments.isEmpty) { a.forward = { session.forward([id]) } }
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

    /// `getRenderableContactSpoofingWarning`: a message request named like a contact we talk
    /// to (until dismissed), or group members sharing a name not all acknowledged.
    var spoofingWarning: ContactSpoofingWarning? {
        guard let check = session.details?.contactSpoofing, check.isRenderable else { return nil }
        switch check {
        case .directConversationWithSameTitle: return .directConversationWithSameTitle
        case .multipleGroupMembersWithSameTitle(let collisions, _):
            return .multipleGroupMembersWithSameTitle(sharedNames: collisions.count, conversationIds: collisions.keys.sorted().flatMap { collisions[$0] ?? [] })
        }
    }

    /// CollidingAvatars: the two first people sharing the one shared name.
    var collidingAvatars: [ConversationAvatarData] {
        guard case .multipleGroupMembersWithSameTitle(_, let ids)? = spoofingWarning else { return [] }
        return ids.prefix(2).compactMap { session.conversation($0) }.map { c in
            let image = session.avatarImage(c.avatar)
            return ConversationAvatarData(title: c.title, color: c.color, image: image, hasAvatar: image != nil)
        }
    }

    /// The header's menu and buttons.
    /// `getOutgoingCallButtonStyle`: none for Note to Self, unaccepted or left chats; both for
    /// direct chats; video (or Join while a call is up) for groups.
    var callButtonStyle: OutgoingCallButtonStyle {
        guard session.calling != nil, conversation.isAccepted, !isNoteToSelf else { return .none }
        if conversation.kind == .group {
            guard let g = session.details?.group, let me = session.ourAci, g.member(me) != nil else { return .none }
            // Join while a call is going on here (ours, or someone else's as peeked).
            return session.activeCall?.conversationId == conversation.id || session.isAnybodyElseInGroupCall(conversation.id) ? .join : .justVideo
        }
        return .both
    }

    var headerActions: ConversationHeaderActions {
        var a = ConversationHeaderActions()
        a.onViewConversationDetails = { session.pushPanel("ConversationDetails") }
        a.onViewUserStories = { [session, conversation] in session.viewUserStories(conversation) }
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
        a.onReviewNameCollision = { session.reviewNameCollision() }
        a.onAcknowledgeNameCollisions = { session.acknowledgeNameCollisions() }
        let callId = conversation.id
        a.onOutgoingAudioCall = { session.openCallLobby(callId, video: false) }
        a.onOutgoingVideoCall = { session.openCallLobby(callId, video: true) }
        return a
    }

    /// Signal's release-notes chat: read-only, "official chat" (upstream `isSignalConversation`).
    var isSignalChat: Bool { conversation.kind == .private && ReleaseNotesChat.isSignalChat(serviceId: conversation.serviceId) }

    /// The message request actions (the request bar's, and a request-response notice's "Block or
    /// report" confirmation).
    var messageRequestModel: MessageRequestModel {
        var request = MessageRequestModel(conversationId: conversation.id, conversationType: conversation.kind == .group ? .group : .direct,
                                          conversationName: conversation.title)
        let id = conversation.id
        request.acceptConversation = { session.respond(id, .accept) }
        request.blockConversation = { session.respond(id, .block) }
        request.blockAndReportSpam = { session.respond(id, .blockAndSpam) }
        request.reportSpam = { session.respond(id, .spam) }
        request.deleteConversation = { session.respond(id, .delete) }
        let d = session.details?.conversationId == conversation.id ? session.details : nil
        request.isBlocked = d?.isBlocked ?? false
        request.isSignalConversation = isSignalChat
        return request
    }

    /// `onOpenMessageRequestActionsConfirmation`: the request confirmation dialog in `state`,
    /// moving between states as its buttons say.
    func openRequestConfirmation(_ state: MessageRequestState) {
        guard let modals else { return }
        let id = "message-request-\(conversation.id)"
        let model = messageRequestModel
        modals.present(id: id) {
            MessageRequestActionsConfirmation(model: model, state: state) { next in
                if next == .default { modals.dismiss(id: id) } else { openRequestConfirmation(next) }
            }
        }
    }

    var composerModel: CompositionAreaModel {
        let request = messageRequestModel
        let d = session.details?.conversationId == conversation.id ? session.details : nil
        let group = d?.group, me = session.ourAci ?? ""
        var m = CompositionAreaModel(conversationId: conversation.id, messageRequest: request)
        m.isSignalConversation = isSignalChat
        m.acceptedMessageRequest = conversation.isAccepted
        // The branch upstream picks from the conversation: blocked (unblock), invited, ended, left,
        // a join request waiting for an admin (cancel it), announcements only (admins may send).
        m.isBlocked = request.isBlocked
        m.left = d?.left ?? false
        m.terminated = group?.terminated ?? false
        m.areWePending = group?.isPending(me) ?? false
        m.areWePendingApproval = group?.isPendingApproval(me) ?? false
        m.announcementsOnly = group?.announcementsOnly ?? false
        m.areWeAdmin = group?.isAdmin(me) ?? false
        m.groupAdmins = (group?.membersV2 ?? []).filter { $0.role == GroupRole.administrator }.map { a in
            GroupAdmin(id: a.aci, avatar: ConversationAvatarData(title: a.aci == me ? i18n("icu:you") : session.contactTitle(a.aci), conversationType: .direct,
                                                                 color: session.contactColor(a.aci), image: session.avatarImage(session.contacts[a.aci]?.avatar)),
                       isMe: a.aci == me)
        }
        // Sharing a contact: behind upstream's remote config (`desktop.shareContact.prod`).
        m.isShareContactEnabled = session.shareContactEnabled
        // View-once: the toggle on a lone photo or video (`isViewOnceEligible`, checked again at send).
        m.isViewOnceSendEnabled = true
        m.isViewOnce = session.draftViewOnce
        m.quote = composerQuote
        m.quotedMessageId = session.quotedMessageId
        m.isEditingMessage = session.editingMessageId != nil
        m.mentionSuggestions = session.mentionSuggestions
        m.isRecording = session.recording != nil
        m.linkPreviewResult = session.composerLinkPreview
        m.linkPreviewLoading = m.linkPreviewResult != nil
        m.hasLinkPreview = m.linkPreviewResult != nil
        m.draftAttachments = session.staged.map { s in
            var a = SignalUI.MessageAttachment(contentType: s.contentType, fileName: s.fileName, size: s.data.count, width: s.width, height: s.height)
            a.image = s.preview
            return a
        }
        m.shouldSendHighQualityAttachments = session.sendsHighQuality
        m.conversationType = conversation.kind == .group ? .group : .direct
        m.groupVersion = conversation.kind == .group ? 2 : nil
        return m
    }

    /// A notice belongs to no author: it never collapses with the bubbles around it.
    func authorId(_ m: TimelineMessage) -> String {
        if m.notice != nil { return "notice:\(m.id)" }
        return m.direction == .outgoing ? (session.ourAci ?? "me") : (m.author ?? "unknown")
    }

    /// What upstream's canCollapseFor…Set ask of a timeline entry: group updates take the
    /// other chat-update notices (safety number, verification, profile and number changes,
    /// pins, ended polls) along; a group's ending, and the call in progress here, never fold.
    func collapseItem(_ m: TimelineMessage) -> CollapseSetItem {
        let kind: CollapseSetItem.Kind
        switch m.notice {
        case .keyChange, .verifiedChange, .profileChange, .changeNumber, .pinnedMessage, .pollTerminate: kind = .groupUpdate(changes: 1)
        case .groupChange(let json):
            let details = groupChange(json)?.details ?? []
            kind = details.first?.type == "terminated" ? .other : .groupUpdate(changes: max(1, details.count))
        case .timerChange(let seconds, _, _): kind = .timerChange(seconds == 0 ? nil : seconds)
        case .call(let callId, let details): kind = isCurrentCall(callId, details) ? .other : .callEvent
        case .deliveryIssue, .chatSessionRefreshed, .joinedSignal, .titleTransition, .conversationMerge, .phoneNumberDiscovery,
             .messageRequestResponse, .universalTimer, .contactRemoved, .resetSession, .unsupported, nil: kind = .other
        }
        return CollapseSetItem(id: m.id, kind: kind, isUnseen: m.isUnseen, date: Date(milliseconds: m.sentAt))
    }

    /// The call in progress in this chat: while a direct call is, every direct call notice here;
    /// for a group, the notice of the call (era) going on, as peeked.
    func isCurrentCall(_ callId: String?, _ details: SignalCore.CallHistoryDetails?) -> Bool {
        guard let details else { return false }
        if details.details.mode == .direct { return session.activeCall?.conversationId == conversation.id }
        return callId != nil && callId == session.peekedGroupCall(conversation.id)?.callId
    }

    /// A `group-v2-change` notice's change, in SignalUI's model (upstream's shape).
    func groupChange(_ json: Data) -> GroupV2ChangeModel? { try? JSONDecoder().decode(GroupV2ChangeModel.self, from: json) }

    /// A notice's row: its notification, selectable in select mode.
    func noticeRow(_ m: TimelineMessage, _ notice: TimelineNotice, next: TimelineMessage?) -> TimelineItem {
        TimelineItem(item: noticeItem(notice, m, next: next), isSelectMode: session.selectedMessageIds != nil,
                     isSelected: session.selectedMessageIds?.contains(m.id) ?? false,
                     toggleSelectMessage: { [session] shift, on in session.toggleSelect(m.id, shift: shift, selected: on) })
    }

    /// The timeline's notices (upstream TimelineItem's notification types).
    func noticeItem(_ notice: TimelineNotice, _ m: TimelineMessage, next: TimelineMessage?) -> TimelineItemType {
        switch notice {
        case .keyChange(let serviceId):
            let who = serviceId ?? conversation.serviceId
            return .safetyNumberNotification(SafetyNumberNotification(contactTitle: session.contactTitle(who),
                                                                      toggleSafetyNumberModal: { session.showSafetyNumber(who) }))
        case .verifiedChange(let verified, let local):
            return .verificationNotification(VerificationNotification(type: verified ? .markVerified : .markNotVerified, isLocal: local,
                                                                      contactTitle: conversation.title))
        case .deliveryIssue(let sender):
            let name = sender.map { session.contactTitle($0) }
            let inGroup = conversation.kind == .group
            return .deliveryIssue(DeliveryIssueNotification(senderName: name, inGroup: inGroup, onLearnMore: {
                session.contactDialog = .deliveryIssue(senderTitle: name ?? "", inGroup: inGroup)
            }))
        case .chatSessionRefreshed:
            return .chatSessionRefreshed(ChatSessionRefreshedNotification(onLearnMore: { session.contactDialog = .chatSessionRefreshed }))
        case .call(let callId, let details):
            return .callHistory(callNotification(m, callId: callId, details, next: next))
        case .groupChange(let json):
            guard let change = groupChange(json) else { return .unknown("group-v2-change") }
            let group = session.details?.conversationId == conversation.id ? session.details?.group : nil
            let me = session.ourAci
            return .groupV2Change(GroupV2Change(change: change, areWeAdmin: me.map { group?.isAdmin($0) ?? false } ?? false,
                                                groupMemberships: group?.membersV2.map { .init(aci: $0.aci, isAdmin: group?.isAdmin($0.aci) ?? false) },
                                                groupBannedMemberships: group?.bannedMembersV2.map(\.serviceId), groupName: title(conversation),
                                                ourAci: me, ourPni: nil, renderContact: { [session] in Emojify.run(session.contactTitle($0)) },
                                                blockGroupLinkRequests: { [session] in session.blockGroupLinkRequests($0) }))
        case .timerChange(let seconds, let source, let fromSync):
            // getPropsForTimerNotification
            let type: TimerNotification.Source = fromSync ? .fromSync : source == nil ? .fromMember : source == session.ourAci ? .fromMe : .fromOther
            return .timerNotification(TimerNotification(type: type, title: session.contactTitle(source), expireTimer: seconds == 0 ? nil : seconds))
        case .pinnedMessage(let source, let target):
            return .pinnedMessage(PinnedMessageNotification(senderTitle: session.contactTitle(source), senderIsMe: source != nil && source == session.ourAci,
                                                            expireTimer: expireTimer(m),
                                                            onScrollToPinnedMessage: { [session] in target.messageId.map(session.goToMessage) }))
        case .pollTerminate(let source, let question, let poll):
            return .pollTerminate(PollTerminateNotification(senderTitle: session.contactTitle(source), senderIsMe: source != nil && source == session.ourAci,
                                                            pollQuestion: question, expireTimer: expireTimer(m),
                                                            onViewPoll: { [session] in poll.messageId.map(session.goToMessage) }))
        case .profileChange(let changedId, let oldName, let newName):
            // getPropsForProfileChange: the contact who changed it (named when they are a
            // system contact); "Update" edits their nickname when they have one.
            let changed = changedId.flatMap { session.conversation($0) }
            let d = session.details?.conversationId == changedId ? session.details : nil
            return .profileChange(ProfileChangeNotification(oldName: oldName, newName: newName, contactTitle: changed.map(title) ?? i18n("icu:unknownContact"),
                                                            contactName: d?.isInSystemContacts == true ? changed.map(title) : nil,
                                                            hasNickname: d?.hasNickname ?? false,
                                                            onOpenEditNicknameAndNoteModal: { [session] in
                                                                if let id = changedId, let serviceId = changed?.serviceId {
                                                                    session.contactDialog = .nickname(conversationId: id, serviceId: serviceId)
                                                                }
                                                            }))
        case .changeNumber(let source):
            return .changeNumberNotification(ChangeNumberNotification(senderTitle: session.contactTitle(source), timestamp: Date(milliseconds: m.sentAt)))
        case .joinedSignal:
            return .joinedSignalNotification(JoinedSignalNotification(timestamp: Date(milliseconds: m.sentAt)))
        case .titleTransition(let oldTitle):
            return .titleTransitionNotification(TitleTransitionNotification(oldTitle: oldTitle ?? i18n("icu:unknownContact")))
        case .conversationMerge(let obsoleteTitle, let obsoleteNumber):
            return .conversationMerge(ConversationMergeNotification(conversationTitle: title(conversation), obsoleteConversationTitle: obsoleteTitle,
                                                                    obsoleteConversationNumber: obsoleteNumber))
        case .phoneNumberDiscovery(let e164):
            // The first group in common names where the number was seen (SmartPhoneNumberDiscovery).
            let d = session.details?.conversationId == conversation.id ? session.details : nil
            return .phoneNumberDiscovery(PhoneNumberDiscoveryNotification(conversationTitle: title(conversation), phoneNumber: e164,
                                                                          sharedGroup: d?.groupsInCommon.first.flatMap { session.conversation($0)?.title }))
        case .messageRequestResponse(let event):
            let isGroup = conversation.kind == .group
            let d = session.details?.conversationId == conversation.id ? session.details : nil
            return .messageRequestResponse(MessageRequestResponseNotification(
                event: MessageRequestResponseEvent(rawValue: event) ?? .accept, isGroup: isGroup, isBlocked: d?.isBlocked ?? false,
                renderedContact: isGroup ? nil : Emojify.run(title(conversation)),
                onBlockOrReport: { openRequestConfirmation(.reportingAndMaybeBlocking) },
                onLearnMore: { [session] in session.contactDialog = .safetyTips }))
        case .universalTimer:
            // The universal timer as it is now (getPropsForUniversalTimerNotification).
            let seconds = session.accountSettings.universalExpireTimer
            return .universalTimerNotification(UniversalTimerNotification(expireTimer: seconds > 0 ? seconds : nil))
        case .contactRemoved:
            return .contactRemovedNotification
        case .resetSession:
            return .resetSessionNotification
        case .unsupported(let canProcessNow):
            return .unsupportedMessage(UnsupportedMessage(canProcessNow: canProcessNow, contactTitle: session.contactTitle(m.author),
                                                          contactIsMe: m.author != nil && m.author == session.ourAci))
        }
    }

    /// A notice's disappearing timer (length, and when it runs out once started).
    func expireTimer(_ m: TimelineMessage) -> (length: TimeInterval, expiration: Date)? {
        guard let seconds = m.expireTimer, seconds > 0, let start = m.expirationStartTimestamp else { return nil }
        return (TimeInterval(seconds), Date(milliseconds: start + Int64(seconds) * 1000))
    }

    /// `getPropsForCallHistory`: the call, who started it, and for a group call whether it is
    /// still going (as peeked: only the call we are in or about to join is).
    func callNotification(_ m: TimelineMessage, callId: String?, _ details: SignalCore.CallHistoryDetails?, next: TimelineMessage?) -> CallingNotification {
        let nextIsCall = if case .call = next?.notice { true } else { false }
        let isSelectMode = session.selectedMessageIds != nil
        guard let h = details else {
            return CallingNotification(callHistory: nil, callCreator: nil, conversationId: conversation.id, groupCallEnded: nil, deviceCount: 0,
                                       maxDevices: .max, isNextItemCallingNotification: nextIsCall, isSelectMode: isSelectMode)
        }
        let d = h.details
        let history = SignalUI.CallHistoryDetails(mode: SignalUI.CallMode(rawValue: d.mode.rawValue) ?? .direct,
                                                  type: SignalUI.CallType(rawValue: d.type.rawValue) ?? .unknown,
                                                  direction: SignalUI.CallDirection(rawValue: d.direction.rawValue) ?? .unknown,
                                                  status: SignalUI.CallStatus(rawValue: h.status.rawValue) ?? .unknown,
                                                  timestamp: Date(milliseconds: d.timestamp))
        var creator: CallingNotification.Creator?
        if d.direction == .outgoing {
            creator = .init(title: i18n("icu:you"), isMe: true)
        } else if let ringer = d.ringerId {
            creator = .init(title: session.contactTitle(ringer), isMe: ringer == session.ourAci)
        }
        let peek = d.mode == .direct ? nil : session.peekedGroupCall(conversation.id)
        let ended = d.mode == .direct ? false : (callId == nil || callId != peek?.callId || (peek?.deviceCount ?? 0) == 0)
        return CallingNotification(callHistory: history, callCreator: creator, conversationId: conversation.id,
                                   activeConversationId: session.activeCall?.conversationId, groupCallEnded: ended,
                                   deviceCount: peek?.deviceCount ?? 0, maxDevices: peek?.maxDevices ?? .max,
                                   isNextItemCallingNotification: nextIsCall, isSelectMode: isSelectMode,
                                   onOutgoingAudioCall: { [session, id = conversation.id] in session.openCallLobby(id, video: false) },
                                   onOutgoingVideoCall: { [session, id = conversation.id] in session.openCallLobby(id, video: true) },
                                   returnToActiveCall: { [session] in session.callPip = false },
                                   onDelete: { [session] in session.requestDelete([m.id]) })
    }

    func grouping(_ m: TimelineMessage) -> TimelineGroupingInfo {
        var g = TimelineGroupingInfo(authorId: authorId(m), timestamp: Date(milliseconds: m.sentAt), status: m.status.map(Self.messageStatus))
        g.deletedForEveryone = m.isDeleted
        return g
    }

    func props(_ m: TimelineMessage, previous previousMessage: TimelineMessage?, next nextMessage: TimelineMessage?) -> MessageProps {
        var author = MessageProps.Author(id: authorId(m), title: m.direction == .outgoing ? i18n("icu:you") : session.contactTitle(m.author))
        author.isMe = m.direction == .outgoing
        author.color = m.direction == .outgoing ? nil : session.contactColor(m.author)
        if m.direction == .incoming { author.avatar = session.avatarImage(m.author.flatMap { session.contacts[$0]?.avatar }) }
        var p = MessageProps(id: m.id, direction: m.direction == .outgoing ? .outgoing : .incoming, author: author,
                             text: m.isDeleted ? nil : m.body, timestamp: Date(milliseconds: m.sentAt))
        p.conversationType = conversation.kind == .group ? .group : .direct
        p.isSignalConversation = isSignalChat
        if conversation.kind == .group, m.direction == .incoming, let aci = m.author, let g = session.details?.group {
            // The sender's name colour and member label in the group.
            p.contactNameColor = ContactNameColors.colors(g)[aci]
            if let member = g.member(aci), let s = member.labelString, !s.isEmpty { p.contactLabel = ContactLabel(labelString: s, labelEmoji: member.labelEmoji) }
        }
        p.status = m.status.map(Self.messageStatus)
        if m.direction == .outgoing { p.bubbleColor = session.bubbleColor(session.conversationColor) }
        let viewOnce = m.isViewOnce && !m.isDeleted
        if viewOnce {
            // View-once media (`isTapToView`): the tap-to-view row; its picture is never decoded
            // for the timeline, only once, when opened (ViewOnce.swift).
            p.attachments = m.attachments.map { t in
                var a = SignalUI.MessageAttachment(contentType: t.attachment.contentType, fileName: nil, size: t.attachment.size)
                a.isDownloaded = t.attachment.isDownloaded
                a.pending = t.attachment.pending ?? false
                return a
            }
            p.tapToView = TapToViewState(isExpired: m.direction == .incoming && m.isErased, isViewed: m.isViewed)
            p.openTapToView = { [session] in session.openTapToView(m) }
            p.showTapToViewNotAvailableModal = { [session] in
                session.contactDialog = .tapToViewNotAvailable(expired: m.isErased, name: session.contactTitle(m.author))
            }
        } else {
            p.attachments = m.attachments.map { attachment($0.attachment, alone: m.attachments.count == 1) }
        }
        if !viewOnce, let first = m.attachments.first?.attachment, (first.flags ?? 0) & 8 != 0, AttachmentPolicy.isVideo(first.contentType) {
            p.gifPlayer = session.gifPlayer(for: first)
        }
        // A video opens in the Lightbox from anywhere on it, its play button included (upstream
        // Message showLightbox); only GIF-flagged videos play in the bubble.
        if let st = m.sticker {
            // The sticker's own file (ours, or downloaded), else the installed pack's copy.
            p.isSticker = true
            let file = st.attachment
            var a = SignalUI.MessageAttachment(contentType: file?.contentType ?? "image/webp", fileName: nil, size: file?.size ?? 0,
                                               width: file?.width ?? 512, height: file?.height ?? 512)
            let image = (file?.isDownloaded == true ? file.flatMap { session.animatedImage(for: $0) } : nil)
                ?? session.animatedStickerImage(packId: st.packId, stickerId: st.stickerId)
            a.image = image
            a.isDownloaded = image != nil || file?.isDownloaded == true
            a.pending = file?.pending ?? false
            p.attachments = [a]
        }
        if let c = m.contact, !m.isDeleted {
            // A shared contact: the card opens its details; "Message" when they are on Signal.
            p.contact = session.sharedContactCard(c)
            p.openContactDetails = { [session] in session.openSharedContact(m) }
            p.startConversationWithSharedContact = { [session] in session.messageSharedContact(c) }
        }
        p.previews = m.previews.map(linkPreview)
        // A preview opens its (https) link in the browser.
        p.openLink = { [session] href in
            guard LinkPreviewRules.shouldPreviewHref(href), let url = URL(string: href) else { return }
            if !session.openInAppLink(url) { DesktopActions.openURL(url) }
        }
        if !viewOnce { p.showLightbox = { [session] i in session.openLightbox(m, index: i) } }
        if m.attachments.contains(where: { !$0.attachment.isDownloaded }) { p.kickOffAttachmentDownload = { [session] in session.downloadAttachments(m) } }
        if m.attachments.contains(where: { $0.attachment.pending == true }) { p.cancelAttachmentDownload = { [session] in session.cancelDownloads(m) } }
        if !viewOnce { p.saveAttachment = { [session] i in session.saveAttachments(m, only: i) } }
        if let first = m.attachments.first?.attachment, AttachmentPolicy.isAudio(first.contentType) {
            p.isVoiceMessagePlayed = m.direction == .outgoing || m.isViewed
            p.audioControls = session.audioControls(m)
            p.activeAudio = session.activeAudio(m)
        }
        p.deletedForEveryone = m.isDeleted
        // A delete for everyone that did not go out: "Delete failed" retries it.
        p.canRetryDeleteForEveryone = m.isDeleted && m.isDeleteForEveryoneFailed
        p.retryDeleteForEveryone = { [session, id = m.id] in session.retryDeleteForEveryone(id) }
        p.retryMessageSend = { [session, id = m.id] in session.retrySend(id) }
        p.showMessageDetails = { [session, id = m.id] in session.messageDetailId = id }
        p.isPinned = m.isPinned
        p.displayLimit = session.messageDisplayLimits[m.id]
        p.messageExpanded = { [session] limit in session.messageDisplayLimits[m.id] = limit }
        // Mentions ("@name", the member's current name) and styles.
        p.bodyRanges = m.bodyRanges.map { r in
            switch r.kind {
            case .mention(let aci):
                let name = session.contactTitle(aci)
                return BodyRange(start: r.start, length: r.length, kind: .mention(aci: aci, conversationID: aci, replacementText: name))
            case .style(let style):
                return BodyRange(start: r.start, length: r.length, kind: .formatting(BodyRange.Style(rawValue: style) ?? .none))
            }
        }
        if let poll = m.poll { p.poll = session.messagePoll(poll); p.canSendPollVote = !poll.terminated && conversation.isAccepted
            p.sendPollVote = { [session] indexes in session.vote(m.id, indexes) }
            p.showPollVotes = { [session] in session.contactDialog = .pollVotes(messageId: m.id) } }
        p.showMediaNoLongerAvailableToast = { [session] in session.toast = .mediaNoLongerAvailable }
        p.isEdited = m.isEdited
        if m.editHistory.count > 1 { p.showEditHistory = { [session] in session.editHistoryMessageId = m.id } }
        if let t = m.expireTimer, t > 0 {
            p.expirationLength = TimeInterval(t)
            p.expirationTimestamp = m.expirationStartTimestamp.map { Date(milliseconds: $0 + Int64(t) * 1000) }
        }
        let me = session.ourAci
        p.reactions = m.reactions.map {
            MessageReaction(emoji: $0.emoji, fromIsMe: $0.fromId == me, fromTitle: $0.fromId == me ? i18n("icu:you") : session.contactTitle($0.fromId),
                            timestamp: Double($0.timestamp), fromId: $0.fromId, fromColor: session.contactColor($0.fromId),
                            fromAvatar: session.avatarImage(session.contacts[$0.fromId]?.avatar))
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
        if session.reactionPickerMessageId == m.id { p.reactionPickerRequest = session.reactionPickerCount }
        let previous = previousMessage.map(grouping), next = nextMessage.map(grouping)
        p.shouldCollapseAbove = TimelineUtil.areMessagesInSameGroup(previous, unreadIndicator: false, grouping(m))
        p.shouldCollapseBelow = TimelineUtil.areMessagesInSameGroup(grouping(m), unreadIndicator: false, next)
        p.shouldHideMetadata = TimelineUtil.shouldHideMetadata(grouped: p.shouldCollapseBelow, grouping(m), next)
        return p
    }

    /// A stored link preview → the bubble's (its image decoded by the media service).
    func linkPreview(_ p: TimelinePreview) -> LinkPreview {
        var out = LinkPreview(url: p.url, domain: p.domain, title: p.title, description: p.description, date: p.date.map(Double.init),
                              image: p.image.map { attachment($0) })
        out.isStickerPack = p.isStickerPack
        out.isCallLink = p.isCallLink
        return out
    }

    /// SignalCore's attachment row → the bubble's attachment (pixels via the media service).
    /// `alone`: the message's only attachment, shown full size (animated, as upstream's `<img>`).
    func attachment(_ a: SignalCore.MessageAttachment, alone: Bool = false) -> SignalUI.MessageAttachment {
        var out = SignalUI.MessageAttachment(contentType: a.contentType, fileName: a.fileName, size: a.size, width: a.width, height: a.height)
        out.fileName = a.fileName
        out.width = a.width
        out.height = a.height
        out.isDownloaded = a.isDownloaded
        out.pending = a.pending ?? false
        out.isGifFlag = (a.flags ?? 0) & 8 != 0
        out.hasUrl = a.isDownloaded
        out.image = alone ? session.animatedImage(for: a) : session.image(for: a)
        if AttachmentPolicy.isAudio(a.contentType) { out.audioWaveform = session.audioWaveform(for: a) }
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
        case .partialSent: .partialSent
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
            FunPanelEmojis(recentEmojis: session.recentEmojis, skinTone: session.emojiSkinTone, onSelectEmoji: { session.insertEmoji($0) },
                           onSelectSkinTone: { session.emojiSkinTone = $0 })
        } stickers: {
            FunPanelStickers(packs: session.funStickerPacks, favorites: session.stickerState?.favorites.map(session.funSticker) ?? [],
                             recents: session.stickerState?.recents.map(session.funSticker) ?? [],
               isFavoriteStickersEnabled: session.favoriteStickersEnabled, showAddStickerPackButton: true,
               onSelectSticker: { s in session.sendSticker(packId: s.packId, stickerId: s.id); close() },
               onAddStickerPack: { close(); session.pushPanel("StickerManager") },
               onMarkStickerAsFavorite: { s, favorite in session.setStickerFavorite(packId: s.packId, stickerId: s.id, favorite) })
        } gifs: {
            FunPanelGifs(recentGifs: session.recentGifItems, source: session.gifSource, storedSearchInput: $gifSearch,
                         onSelectGif: { g in close(); session.selectGif(g.gif) }, onRemoveRecentGif: { session.removeRecentGif($0) }, onClose: { close() })
        }
    }
}

/// One timeline row (its date header and message). Equatable on what it is drawn from, so a
/// re-render of the timeline (scrolling, another row's change) skips it; what it reads from the
/// session while drawing (images, contacts, selection, pins…) still updates it through
/// observation.
struct TimelineRow: View, Equatable {
    let pane: ConversationPane
    let message: TimelineMessage
    let previous: TimelineMessage?
    let next: TimelineMessage?
    /// The pane's session, by identity (the session itself is main-actor state; == is not).
    let session: ObjectIdentifier

    init(pane: ConversationPane, message: TimelineMessage, previous: TimelineMessage?, next: TimelineMessage?) {
        self.pane = pane
        self.message = message
        self.previous = previous
        self.next = next
        session = ObjectIdentifier(pane.session)
    }

    nonisolated static func == (a: TimelineRow, b: TimelineRow) -> Bool {
        a.message == b.message && a.previous == b.previous && a.next == b.next && a.pane.conversation == b.pane.conversation
            && a.session == b.session
    }

    var body: some View {
        VStack(spacing: 0) {
            if TimelineUtil.shouldRenderDateHeader(isOldest: previous == nil, pane.grouping(message), previous: previous.map(pane.grouping)) {
                TimelineDateHeader(timestamp: Date(milliseconds: message.sentAt), isSignalConversation: pane.isSignalChat)
            }
            if let notice = message.notice {
                pane.noticeRow(message, notice, next: next)
            } else {
                TimelineItem(item: .message(pane.props(message, previous: previous, next: next)))
            }
        }
    }
}

/// A collapse set's row (upstream TimelineItem's `collapseSet`): its date header, then the
/// fold ("2 call events") over the set's notices. Equatable like TimelineRow.
struct TimelineCollapseRow: View, Equatable {
    let pane: ConversationPane
    let set: CollapseSet
    let kind: CollapseSetKind
    /// The set's entries, in order.
    let messages: [TimelineMessage]
    /// The entry before the set.
    let previous: TimelineMessage?
    let session: ObjectIdentifier

    init(pane: ConversationPane, set: CollapseSet, kind: CollapseSetKind, messages: [TimelineMessage], previous: TimelineMessage?) {
        self.pane = pane
        self.set = set
        self.kind = kind
        self.messages = messages
        self.previous = previous
        session = ObjectIdentifier(pane.session)
    }

    nonisolated static func == (a: TimelineCollapseRow, b: TimelineCollapseRow) -> Bool {
        a.set == b.set && a.messages == b.messages && a.previous == b.previous && a.pane.conversation == b.pane.conversation
            && a.session == b.session
    }

    var body: some View {
        let session = pane.session
        let selected = Set(session.selectedMessageIds ?? [])
        VStack(spacing: 0) {
            if let first = messages.first,
               TimelineUtil.shouldRenderDateHeader(isOldest: previous == nil, pane.grouping(first), previous: previous.map(pane.grouping)) {
                TimelineDateHeader(timestamp: Date(milliseconds: first.sentAt), isSignalConversation: pane.isSignalChat)
            }
            CollapseSetViewer(kind: kind, messages: set.messages, isGroup: pane.conversation.kind == .group,
                              isSelectMode: session.selectedMessageIds != nil, isSelected: set.messages.contains { selected.contains($0.id) },
                              targetedMessageId: session.scrollToMessageId,
                              onDelete: { session.requestDelete($0) },
                              onSelect: { ids in for id in ids { session.toggleSelect(id, selected: true) } }) { item in
                if let i = messages.firstIndex(where: { $0.id == item.id }), let notice = messages[i].notice {
                    pane.noticeRow(messages[i], notice, next: i + 1 < messages.count ? messages[i + 1] : nil)
                }
            }
        }
    }
}

/// `SmartMiniPlayer`: the playing voice note's sender ("You" for ours), play / pause, speed and
/// close (`unloadMessageAudio`).
struct AudioMiniPlayer: View {
    @Bindable var session: SignalSession
    let i18n: Localizer

    var body: some View {
        let title = session.activeAudioAuthor.map { session.contactTitle($0) } ?? i18n("icu:you")
        MiniPlayer(title: title, state: session.audioEngine?.isLoaded == true ? (session.audioPlaying ? .playing : .paused) : .loading,
                   currentTime: session.audioTime, duration: session.audioEngine?.duration, playbackRate: session.audioRate,
                   onPlay: { session.setAudioPlaying(true) }, onPause: { session.setAudioPlaying(false) },
                   onPlaybackRate: { session.setAudioRate($0) }, onClose: { session.stopAudio() })
    }
}
