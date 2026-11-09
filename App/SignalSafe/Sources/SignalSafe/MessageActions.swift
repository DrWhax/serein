// A timeline message's actions (upstream TimelineMessage's PropsActions and the
// conversations duck): react, reply (the composer's quote), copy, select mode, delete (for me
// / for everyone, DeleteMessagesModal), pin / unpin (PinMessageDialog), and the message
// details panel. The work is SignalCore's Messenger; this is the state and the glue.

import AppKit
import Foundation
import SignalCore
import SignalUI

/// An open DeleteMessagesModal.
struct DeleteMessagesRequest {
    var conversationId: String
    var messageIds: [String]
    var canDeleteForEveryone: Bool
    var needsAdminDelete: Bool
    var isDeletingOwnMessages: Bool
}

/// An open PinMessageDialog.
struct PinMessageRequest {
    var messageId: String
    var isDisappearing: Bool
    var hasMaxPinnedMessages: Bool
}

@MainActor extension SignalSession {
    /// `reactToMessage`: adds, changes or (`remove`) takes back our reaction.
    func react(_ messageId: String, emoji: String, remove: Bool) {
        guard let session = signalSession else { return }
        Task {
            do { try await session.messenger.react(to: messageId, emoji: emoji, remove: remove) } catch { Self.trace("react failed: \(error)") }
        }
    }

    /// `setQuoteByMessageId`: the composer quotes the message (sent with the next message).
    func reply(to messageId: String) {
        selectedMessageIds = nil
        quotedMessageId = messageId
    }

    /// `copyMessageText`
    func copyText(_ messageId: String) {
        guard let m = messages.first(where: { $0.id == messageId }), !m.body.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(m.body, forType: .string)
    }

    /// `toggleSelectMessage`: enters select mode with the message, or toggles it (shift: the
    /// range from the last selected message).
    func toggleSelect(_ messageId: String, shift: Bool = false, selected: Bool) {
        var ids = selectedMessageIds ?? []
        if shift, let anchor = ids.last, let a = messages.firstIndex(where: { $0.id == anchor }), let b = messages.firstIndex(where: { $0.id == messageId }) {
            for m in messages[min(a, b)...max(a, b)] where m.notice == nil && !ids.contains(m.id) { ids.append(m.id) }
        } else if selected {
            if !ids.contains(messageId) { ids.append(messageId) }
        } else {
            ids.removeAll { $0 == messageId }
        }
        let order = Dictionary(messages.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        selectedMessageIds = ids.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
    }

    func exitSelectMode() { selectedMessageIds = nil }

    /// `toggleDeleteMessagesModal`: opens the delete dialog (whether "for everyone" is offered
    /// comes from SignalCore's rules).
    func requestDelete(_ messageIds: [String]) {
        guard let session = signalSession, let conversationId = selectedConversationId, !messageIds.isEmpty else { return }
        Task {
            let check = (try? await session.messenger.canDeleteForEveryone(messageIds)) ?? (canDeleteForEveryone: false, needsAdminDelete: false, isDeletingOwnMessages: false)
            deleteRequest = DeleteMessagesRequest(conversationId: conversationId, messageIds: messageIds, canDeleteForEveryone: check.canDeleteForEveryone,
                                                  needsAdminDelete: check.needsAdminDelete, isDeletingOwnMessages: check.isDeletingOwnMessages)
        }
    }

    func deleteForMe(_ r: DeleteMessagesRequest) {
        deleteRequest = nil
        selectedMessageIds = nil
        guard let session = signalSession else { return }
        Task {
            do { try await session.messenger.deleteForMe(r.messageIds) } catch { Self.trace("delete for me failed: \(error)") }
        }
    }

    func deleteForEveryone(_ r: DeleteMessagesRequest) {
        deleteRequest = nil
        selectedMessageIds = nil
        guard let session = signalSession else { return }
        Task {
            for id in r.messageIds {
                do { try await session.messenger.deleteForEveryone(id) } catch { Self.trace("delete for everyone failed: \(error)") }
            }
        }
    }

    /// `showPinMessageDialog`
    func requestPin(_ messageId: String) {
        guard let m = messages.first(where: { $0.id == messageId }) else { return }
        let pinned = messages.filter(\.isPinned).count
        pinRequest = PinMessageRequest(messageId: messageId, isDisappearing: (m.expireTimer ?? 0) > 0, hasMaxPinnedMessages: pinned >= 3)
    }

    func pin(_ messageId: String, durationSeconds: Int?) {
        pinRequest = nil
        guard let session = signalSession else { return }
        Task {
            do { try await session.messenger.pin(messageId, durationSeconds: durationSeconds.map(UInt32.init)) } catch { Self.trace("pin failed: \(error)") }
        }
    }

    /// `onPinnedMessageRemove`
    func unpin(_ messageId: String) {
        guard let session = signalSession else { return }
        Task {
            do { try await session.messenger.unpin(messageId) } catch { Self.trace("unpin failed: \(error)") }
        }
    }

    /// How many times the disappearing-message pin warning was shown.
    var pinWarningSeenCount: Int {
        get { UserDefaults.standard.integer(forKey: "pinDisappearingMessageWarningSeen") }
        set { UserDefaults.standard.set(newValue, forKey: "pinDisappearingMessageWarningSeen") }
    }

    /// The message-details panel's delivery data, live while it is open.
    func observeMessageDetail() {
        messageDetailTask?.cancel()
        messageDetail = nil
        guard let id = messageDetailId, let db = clientDatabase else { return }
        messageDetailTask = Task { [weak self] in
            do {
                for try await d in db.deliveryDetailUpdates(messageId: id) { self?.messageDetail = d }
            } catch {}
        }
    }

    // MARK: pinned messages (PinnedMessagesBar)

    func observePins() {
        pinsTask?.cancel()
        pins = []
        currentPinIndex = nil
        guard let id = selectedConversationId, let db = clientDatabase else { return }
        pinsTask = Task { [weak self] in
            do {
                for try await p in db.pinnedMessagesUpdates(conversationId: id) {
                    guard let self else { return }
                    self.pins = p
                    if let i = self.currentPinIndex, i >= p.count { self.currentPinIndex = p.isEmpty ? nil : p.count - 1 }
                }
            } catch {}
        }
    }

    /// The bar's pins: sender and a preview of each pinned message.
    func pinItems(you: String) -> [Pin] {
        pins.map { p in
            var m = PinMessage(id: p.messageId)
            if !p.body.isEmpty { m.text = (p.body, []) }
            m.pollQuestion = p.pollQuestion
            m.viewOnceMedia = p.isViewOnce
            switch p.content {
            case .sticker: m.sticker = true
            case .photo: m.attachment = .image(p.attachment.flatMap { image(for: $0) })
            case .video: m.attachment = .video(p.attachment.flatMap { posterImage(for: $0) })
            case .gif: m.attachment = .gif
            case .voiceMessage: m.attachment = .voiceMessage
            case .audio, .file: m.attachment = .file(p.attachment?.fileName)
            case .text: break
            }
            let sender = p.outgoing ? you : contactTitle(p.author)
            return Pin(id: p.pinId, senderTitle: sender, message: m)
        }
    }

    /// Scrolls the timeline to a message (a pin's, a quote's) when it is loaded.
    func goToMessage(_ messageId: String) {
        guard messages.contains(where: { $0.id == messageId }) else { return Self.trace("go to message: not in the loaded timeline") }
        scrollToMessageId = messageId
        scrollCounter += 1
    }

    // MARK: the Fun picker (emoji and stickers)

    /// Recently used emoji, newest first (upstream's emoji usage, kept on this device).
    var recentEmojis: [String] {
        get { UserDefaults.standard.stringArray(forKey: "recentEmojis") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(32)), forKey: "recentEmojis") }
    }

    /// Inserts an emoji into the draft (at its end) and remembers it.
    func insertEmoji(_ emoji: String) {
        draft += emoji
        var recent = recentEmojis
        recent.removeAll { $0 == emoji }
        recent.insert(emoji, at: 0)
        recentEmojis = recent
    }

    /// Installed sticker packs, live.
    func observeStickers() {
        guard stickersTask == nil, let db = clientDatabase else { return }
        stickersTask = Task { [weak self] in
            do {
                for try await state in db.observe({ try Stickers.managerState($0) }) { self?.stickerPacks = state.installed }
            } catch {}
        }
    }

    /// A sticker's pixels (the plaintext from the sticker store → the media service), loaded once.
    func stickerImage(packId: String, stickerId: Int) -> RGBAImage? {
        let key = "\(packId)/\(stickerId)"
        if let hit = stickerImages[key] { return hit }
        guard let session = signalSession, !stickerLoading.contains(key) else { return nil }
        stickerLoading.insert(key)
        let media = media
        Task {
            defer { stickerLoading.remove(key) }
            guard let bytes = try? await session.stickers.stickerData(packId: packId, stickerId: stickerId),
                  let shown = try? await media.displayImage(bytes, maxDimension: 256) else { return }
            stickerImages[key] = RGBAImage(width: shown.width, height: shown.height, pixels: shown.rgba, scale: 2)
        }
        return nil
    }

    /// `sendStickerMessage` to the open conversation.
    func sendSticker(packId: String, stickerId: Int) {
        guard let session = signalSession, let c = selectedConversation else { return }
        Task {
            do {
                if c.kind == .group {
                    guard let key = c.masterKey else { return }
                    _ = try await session.messenger.sendSticker(packId: packId, stickerId: stickerId, masterKey: key)
                } else if let to = c.serviceId {
                    _ = try await session.messenger.sendSticker(packId: packId, stickerId: stickerId, to: to)
                }
            } catch {
                Self.trace("sticker send failed: \(error)")
            }
        }
    }

    /// A GIF from the picker: the original MP4, sent as a looping GIF attachment.
    func sendGif(_ url: URL) {
        guard let giphy, let session = signalSession, let c = selectedConversation else { return }
        Task {
            do {
                let data = try await giphy.file(url)
                let a = [OutgoingAttachment(data: data, contentType: "video/mp4", flags: 8)]
                if c.kind == .group, let key = c.masterKey {
                    _ = try await session.messenger.sendGroupMessage("", attachments: a, masterKey: key)
                } else if let to = c.serviceId {
                    _ = try await session.messenger.sendMessage("", attachments: a, to: to)
                }
            } catch {
                Self.trace("gif send failed: \(error)")
            }
        }
    }

    /// The GIF panel's data (no in-picker preview playback).
    var gifSource: FunGifsDataSource {
        let giphy = giphy
        func page(_ r: PaginatedGifResults) -> FunGifsPage {
            FunGifsPage(next: r.next, gifs: r.gifs.map { g in
                FunGifItem(id: g.id, title: g.title, description: g.description,
                           previewMedia: FunGifMedia(url: g.previewMedia.url, width: g.previewMedia.width, height: g.previewMedia.height),
                           attachmentMedia: FunGifMedia(url: g.attachmentMedia.url, width: g.attachmentMedia.width, height: g.attachmentMedia.height))
            })
        }
        return FunGifsDataSource(trending: { limit, offset in
            guard let giphy else { throw GiphyError.invalidResponse("not ready") }
            return page(try await giphy.trending(limit: limit, offset: offset))
        }, search: { q, limit, offset in
            guard let giphy else { throw GiphyError.invalidResponse("not ready") }
            return page(try await giphy.search(q, limit: limit, offset: offset))
        }, previewPlayer: { [weak self] item in
            // The fixed-width preview MP4, decoded in the media service, looping.
            guard let self, let giphy, let data = try? await giphy.file(item.previewMedia.url),
                  let opened = try? await self.media.openVideo(data) else { return nil }
            let engine = VideoPlaybackEngine()
            engine.isLooping = true
            await engine.load(XPCVideoSource(media: self.media, session: opened.session), duration: opened.info.duration, rotation: opened.info.rotation)
            return engine
        })
    }

    // MARK: GIFs in the timeline

    /// A GIF attachment's looping player, opened in the media service once its file is here
    /// (at most 8 open; the oldest is closed).
    func gifPlayer(for a: SignalCore.MessageAttachment) -> VideoPlaybackEngine? {
        guard let path = a.path, a.isDownloaded else { return nil }
        if let p = gifPlayers[path] { return p }
        guard let session = signalSession, !gifLoading.contains(path) else { return nil }
        gifLoading.insert(path)
        let store = session.attachmentStore, media = media
        Task {
            defer { gifLoading.remove(path) }
            guard let bytes = try? await Task.detached(operation: { try store.plaintext(of: a) }).value ?? nil,
                  let opened = try? await media.openVideo(bytes) else { return Self.trace("gif: could not open") }
            let engine = VideoPlaybackEngine()
            engine.isLooping = true
            await engine.load(XPCVideoSource(media: media, session: opened.session), duration: opened.info.duration, rotation: opened.info.rotation)
            gifPlayers[path] = engine
            gifOrder.append(path)
            while gifOrder.count > 8 {
                let old = gifOrder.removeFirst()
                if let p = gifPlayers.removeValue(forKey: old) { await p.unload() }
            }
        }
        return nil
    }

    func closeGifPlayers() {
        let players = gifPlayers.values
        gifPlayers.removeAll()
        gifOrder = []
        Task { for p in players { await p.unload() } }
    }

    // MARK: editing (setMessageToEdit)

    /// `canEditMessage`: our own text message, not deleted or a poll, sent within a day (any
    /// time in Note to Self).
    func canEdit(_ m: TimelineMessage, noteToSelf: Bool) -> Bool {
        guard m.direction == .outgoing, !m.isDeleted, !m.body.isEmpty, m.sticker == nil else { return false }
        let ageOK = noteToSelf || Int64(Date().timeIntervalSince1970 * 1000) - m.sentAt < 86_400_000
        return ageOK && m.status != .pending
    }

    /// Starts editing a message: its text goes into the composer.
    func startEdit(_ messageId: String) {
        guard let m = messages.first(where: { $0.id == messageId }) else { return }
        selectedMessageIds = nil
        quotedMessageId = nil
        editingMessageId = messageId
        draft = m.body
    }

    /// ↑ in an empty composer: the newest message we can edit (`lastEditableMessageId`).
    func editLastMessage(noteToSelf: Bool) -> Bool {
        guard let m = messages.last(where: { $0.direction == .outgoing }), canEdit(m, noteToSelf: noteToSelf) else { return false }
        startEdit(m.id)
        return true
    }

    func discardEdit() {
        editingMessageId = nil
        draft = ""
    }

    /// ⌘⇧E (`Keyboard--toggle-reaction-picker`): the reaction picker of the newest message in
    /// the open chat that can be reacted to (not deleted; ours once sent).
    func toggleReactionPickerShortcut() {
        guard let target = messages.last(where: { m in
            m.notice == nil && !m.isDeleted && (m.direction == .incoming || m.status.map { $0 != .pending && $0 != .failed } ?? true)
        }) else { return }
        reactionPickerMessageId = target.id
        reactionPickerCount += 1
    }

    /// `retryMessageSend`
    func retrySend(_ messageId: String) {
        guard let session = signalSession else { return }
        Task {
            do { try await session.messenger.retrySend(messageId: messageId) } catch { Self.trace("retry failed: \(error)") }
        }
    }

    // MARK: polls

    /// A stored poll as the bubble's: each option's voters (whether each is us), totals.
    func messagePoll(_ p: TimelinePoll) -> MessagePoll {
        let me = conversations.first { $0.kind == .private && $0.serviceId != nil && $0.serviceId == ourAci }?.id
        var out = MessagePoll(question: p.question, options: p.options)
        out.allowMultiple = p.allowMultiple
        out.terminated = p.terminated
        let voters = p.votes.filter { !$0.optionIndexes.isEmpty }
        for v in voters {
            for i in v.optionIndexes where p.options.indices.contains(i) { out.votesByOption[i, default: []].append(v.fromConversationId == me) }
        }
        out.totalNumVotes = out.votesByOption.values.reduce(0) { $0 + $1.count }
        out.uniqueVoters = voters.count
        return out
    }

    /// `sendPollVote`: our choice (an empty list retracts).
    func vote(_ messageId: String, _ optionIndexes: [Int]) {
        guard let session = signalSession else { return }
        Task {
            do { try await session.messenger.vote(on: messageId, optionIndexes: optionIndexes) } catch { Self.trace("vote failed: \(error)") }
        }
    }

    /// PollCreateModal's poll, to the open chat.
    func createPoll(_ p: PollCreateType) {
        isCreatingPoll = false
        guard let session = signalSession, let id = selectedConversationId else { return }
        Task {
            do {
                _ = try await session.messenger.createPoll(question: p.question, options: p.options, allowMultiple: p.allowMultiple, conversationId: id)
            } catch {
                Self.trace("poll failed: \(error)")
            }
        }
    }
}
