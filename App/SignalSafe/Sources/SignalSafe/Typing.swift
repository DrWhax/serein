// Typing indicators (upstream TypingBubble, `typingContactIdTimestamps`, and the composer's
// `onTyping` throttle): ours are sent while composing — "started" at most every 10 s while
// keys keep coming, "stopped" after 3 s idle or when the draft empties — to the open chat's
// contact or group, online-only. Theirs show for 15 s (or until their message arrives) as the
// timeline's typing bubble and the chat list's animation. Both need the Typing indicators
// setting, as upstream.

import Foundation
import SignalCore
import SignalUI

@MainActor extension SignalSession {
    static let typingRefresh: TimeInterval = 10
    static let typingIdle: Duration = .seconds(3)
    static let typingShown: Duration = .seconds(15)

    /// The draft changed (keys typed, pasted, sent).
    func draftChangedForTyping() {
        guard accountSettings.typingIndicators, let c = selectedConversation, c.isAccepted, editingMessageId == nil else { return }
        if draft.isEmpty {
            sendTypingStopped()
            return
        }
        let now = Date()
        if typingSentTo != c.id || now.timeIntervalSince(typingSentAt ?? .distantPast) >= Self.typingRefresh {
            if let previous = typingSentTo, previous != c.id { sendTyping(previous, started: false) }
            typingSentTo = c.id
            typingSentAt = now
            sendTyping(c.id, started: true)
        }
        typingIdleTask?.cancel()
        typingIdleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.typingIdle)
            guard !Task.isCancelled else { return }
            self?.sendTypingStopped()
        }
    }

    func sendTypingStopped() {
        typingIdleTask?.cancel()
        guard let id = typingSentTo else { return }
        typingSentTo = nil
        typingSentAt = nil
        sendTyping(id, started: false)
    }

    private func sendTyping(_ conversationId: String, started: Bool) {
        guard let session = signalSession, let c = conversation(conversationId) else { return }
        Task {
            do {
                if c.kind == .group, let key = c.masterKey {
                    try await session.messenger.sendGroupTyping(masterKey: key, started: started)
                } else if let to = c.serviceId, to != ourAci {
                    try await session.messenger.sendTyping(to: to, started: started)
                }
            } catch {
                Self.trace("typing failed: \(error)")
            }
        }
    }

    /// A typing event: shown for 15 s, until "stopped", or until their message arrives.
    func receivedTyping(sender: String, started: Bool, groupId: Data?) {
        guard accountSettings.typingIndicators, sender != ourAci else { return }
        let target: ConversationSummary?
        if let groupId {
            let id = groupId.base64EncodedString()
            target = conversations.first { c in c.kind == .group && c.masterKey.flatMap { try? GroupKeys(masterKey: $0).groupIdBase64 } == id }
        } else {
            target = conversations.first { $0.kind == .private && $0.serviceId == sender }
        }
        guard let conversationId = target?.id else { return }
        if started {
            typing[conversationId, default: [:]][sender] = Date()
            let task = Task { [weak self] in
                try? await Task.sleep(for: Self.typingShown)
                guard !Task.isCancelled else { return }
                self?.clearTyping(conversationId, sender)
            }
            typingExpiry["\(conversationId)|\(sender)"]?.cancel()
            typingExpiry["\(conversationId)|\(sender)"] = task
        } else {
            clearTyping(conversationId, sender)
        }
    }

    /// Their message arrived: they are no longer typing there.
    func clearTyping(_ conversationId: String, _ sender: String) {
        typingExpiry.removeValue(forKey: "\(conversationId)|\(sender)")?.cancel()
        guard typing[conversationId]?[sender] != nil else { return }
        typing[conversationId]?[sender] = nil
        if typing[conversationId]?.isEmpty == true { typing[conversationId] = nil }
    }

    func isSomeoneTyping(_ conversationId: String) -> Bool { !(typing[conversationId]?.isEmpty ?? true) }

    /// The open chat's typists, oldest first (TypingBubble).
    func typingContacts(_ conversationId: String) -> [TypingContact] {
        (typing[conversationId] ?? [:]).sorted { $0.value < $1.value }.map { sender, _ in
            TypingContact(id: sender, title: contactTitle(sender), color: contactColor(sender))
        }
    }
}

@MainActor extension SignalSession {
    /// `MentionCompletion`: the open group's members (not us) whose name matches the "@query"
    /// (a word starting with it), sorted by name; at most 20.
    var mentionSuggestions: [ComposerController.Mention] {
        guard let q = mentionQuery, selectedConversation?.kind == .group, let g = details?.group else { return [] }
        let query = q.lowercased()
        let me = ourAci
        let members = g.membersV2.map(\.aci).filter { $0 != me }.map { aci in
            ComposerController.Mention(aci: aci, title: contactTitle(aci), color: contactColor(aci), avatar: avatarImage(contacts[aci]?.avatar))
        }
        let matches = query.isEmpty ? members : members.filter { m in
            m.title.lowercased().split(separator: " ").contains { $0.hasPrefix(query) } || m.title.lowercased().hasPrefix(query)
        }
        return Array(matches.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }.prefix(20))
    }

    /// Hooks the composer's mention callbacks to this session (once).
    func connectComposer() {
        composer.onMentionQuery = { [weak self] q in self?.mentionQuery = q }
        composer.pickFirstMention = { [weak self] in
            guard let self, let first = self.mentionSuggestions.first else { return false }
            self.composer.insertMention(first)
            return true
        }
    }
}
