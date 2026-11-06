// The open chat's settings and group management (upstream ConversationHeader's menu,
// ConversationDetails and its panels): mute, disappearing messages, pin / archive / unread,
// block, report spam, delete, leave; and for groups members' roles and removal, requests and
// invites, permissions, the invite link, and our member label. SignalCore does the work
// (Messenger for the chat's state, GroupsService for group changes).

import AppKit
import Foundation
import SignalCore
import SignalUI

@MainActor extension SignalSession {
    func observeDetails() {
        detailsTask?.cancel()
        details = nil
        guard let id = selectedConversationId, let db = clientDatabase else { return }
        detailsTask = Task { [weak self] in
            do {
                for try await d in db.detailsUpdates(conversationId: id) { self?.details = d }
            } catch {}
        }
    }

    func observeMedia() {
        mediaTask?.cancel()
        guard let id = selectedConversationId, let db = clientDatabase else { return }
        mediaTask = Task { [weak self] in
            do {
                for try await m in db.mediaUpdates(conversationId: id) { self?.mediaItems = m }
            } catch {}
        }
    }

    // MARK: panels

    func pushPanel(_ name: String) {
        panels.append(name)
        if name == "AllMedia" { observeMedia() }
    }

    func popPanel() {
        guard let top = panels.popLast() else { return }
        if top == "AllMedia" {
            mediaTask?.cancel()
            mediaItems = []
        }
    }

    // MARK: the chat's state

    private func run(_ what: String, _ body: @escaping @Sendable (SignalClient.Session) async throws -> Void) {
        guard let session = signalSession else { return }
        Task {
            do { try await body(session) } catch { Self.trace("\(what) failed: \(error)") }
        }
    }

    /// `setMuteExpiration`: a duration, always, or (nil) unmute.
    func setMute(_ option: MuteOption?, for conversationId: String? = nil) {
        guard let id = conversationId ?? selectedConversationId else { return }
        // "Until…": the date and time come from MuteUntilDialog.
        if case .custom? = option { return customMuteFor = id }
        let until: Int64? = switch option {
        case .duration(let seconds): Int64(Date().timeIntervalSince1970 * 1000) + Int64(seconds) * 1000
        case .always, .custom: Int64.max
        case nil: nil
        }
        run("mute") { try await $0.messenger.setMuted(id, until: until) }
    }

    /// `setDisappearingMessages` (0: off).
    func setDisappearingTimer(_ seconds: Int) {
        guard let id = selectedConversationId else { return }
        run("timer") { try await $0.messenger.setDisappearingTimer(id, seconds: UInt32(max(0, seconds)), groups: $0.groups) }
    }

    func setPinnedChat(_ pinned: Bool, for conversationId: String? = nil) {
        guard let id = conversationId ?? selectedConversationId else { return }
        run("pin chat") { try await $0.messenger.setPinned(id, pinned) }
    }

    func setArchived(_ archived: Bool, for conversationId: String? = nil) {
        guard let id = conversationId ?? selectedConversationId else { return }
        run("archive") { try await $0.messenger.setArchived(id, archived) }
        if archived, id == selectedConversationId { selectedConversationId = nil }
    }

    func setMarkedUnread(_ unread: Bool, for conversationId: String? = nil) {
        guard let id = conversationId ?? selectedConversationId else { return }
        run("mark unread") { try await $0.messenger.setMarkedUnread(id, unread) }
    }

    func setBlocked(_ blocked: Bool) {
        guard let id = selectedConversationId else { return }
        run("block") { try await $0.messenger.setBlocked(id, blocked) }
    }

    func reportSpam(block: Bool) {
        guard let id = selectedConversationId else { return }
        respond(id, block ? .blockAndSpam : .spam)
    }

    /// `onDelete`: the chat and its messages go (here and on our other devices).
    func deleteChat(_ conversationId: String? = nil) {
        guard let id = conversationId ?? selectedConversationId else { return }
        respond(id, .delete)
    }

    func setNotifyWhileMuted(_ key: NotifyWhileMuted.Key, _ on: Bool) {
        guard let id = selectedConversationId, let d = details else { return }
        let defaults = notificationSettings
        var calls = d.notifyForCallsIfMuted ?? defaults.notifyForCallsIfMuted
        var mentions = d.notifyForMentionsIfMuted ?? defaults.notifyForMentionsIfMuted
        var replies = d.notifyForRepliesIfMuted ?? defaults.notifyForRepliesIfMuted
        switch key {
        case .calls: calls = on
        case .mentions: mentions = on
        case .replies: replies = on
        }
        let (c, m, r) = (calls, mentions, replies)
        run("notify while muted") { try await $0.messenger.setNotifyWhileMuted(id, calls: c, mentions: m, replies: r) }
    }

    // MARK: groups

    private var groupKeys: GroupKeys? { details?.masterKey.flatMap { try? GroupKeys(masterKey: $0) } }

    private func group(_ what: String, _ body: @escaping @Sendable (GroupsService, GroupKeys) async throws -> Void) {
        guard let keys = groupKeys else { return }
        run(what) { try await body($0.groups, keys) }
    }

    func leaveGroup() {
        group("leave") { try await $0.leave($1) }
    }

    /// `toggleAdmin`
    func toggleAdmin(_ aci: String) {
        let admin = details?.group?.isAdmin(aci) ?? false
        group("role") { try await $0.setRole($1, aci, role: admin ? GroupRole.default : GroupRole.administrator) }
    }

    func removeMember(_ aci: String) {
        group("remove member") { try await $0.removeMember($1, aci) }
    }

    func approveRequest(_ aci: String) {
        group("approve") { try await $0.approveRequest($1, aci) }
    }

    func denyRequest(_ aci: String) {
        group("deny") { try await $0.denyRequest($1, aci) }
    }

    /// `revokePendingMemberships`: invites revoked, requests denied.
    func revokePending(_ ids: [String]) {
        let requests = Set(details?.group?.pendingAdminApprovalV2.map(\.aci) ?? [])
        let denied = ids.filter(requests.contains), revoked = ids.filter { !requests.contains($0) }
        group("revoke") { groups, keys in
            for aci in denied { try await groups.denyRequest(keys, aci) }
            if !revoked.isEmpty { try await groups.revokeInvites(keys, revoked) }
        }
    }

    func setAttributesAccess(_ a: AccessControl) { group("attributes access") { try await $0.setAttributesAccess($1, a.rawValue) } }
    func setMembersAccess(_ a: AccessControl) { group("members access") { try await $0.setMembersAccess($1, a.rawValue) } }
    func setMemberLabelAccess(_ a: AccessControl) { group("label access") { try await $0.setMemberLabelAccess($1, a.rawValue) } }
    func setAnnouncementsOnly(_ on: Bool) { group("announcements") { try await $0.setAnnouncementsOnly($1, on) } }

    /// GroupLinkManagement: on (members join directly, or with approval), off, reset.
    func setGroupLink(enabled: Bool) {
        let approval = details?.group?.accessControl.addFromInviteLink == GroupAccess.administrator
        group("group link") { groups, keys in
            if enabled { try await groups.setInviteLink(keys, access: approval ? GroupAccess.administrator : GroupAccess.any) } else { try await groups.disableInviteLink(keys) }
        }
    }

    func setGroupLinkApproval(_ required: Bool) {
        group("link approval") { try await $0.setInviteLink($1, access: required ? GroupAccess.administrator : GroupAccess.any) }
    }

    func resetGroupLink() { group("reset link") { try await $0.resetInviteLink($1) } }

    /// The group's invite link, when it is on.
    var groupLinkURL: String? {
        guard let g = details?.group, let key = details?.masterKey, let pw = g.groupInviteLinkPassword.flatMap({ Data(base64Encoded: $0) }),
              g.accessControl.addFromInviteLink == GroupAccess.any || g.accessControl.addFromInviteLink == GroupAccess.administrator else { return nil }
        return GroupLink(masterKey: key, inviteLinkPassword: pw).url
    }

    func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// `updateGroupMemberLabel`: our own label (nil clears it); `done` reports success.
    func setOurMemberLabel(emoji: String?, label: String?, done: @escaping (Bool) -> Void) {
        guard let keys = groupKeys, let aci = ourAci, let session = signalSession else { return done(false) }
        Task {
            do {
                try await session.groups.setMemberLabel(keys, aci, emoji: emoji, label: label)
                done(true)
            } catch {
                Self.trace("member label failed: \(error)")
                done(false)
            }
        }
    }

    // MARK: search (left pane)

    var isSearching: Bool { !searchTerm.isEmpty || searchConversationId != nil }

    /// `updateSearchTerm`: results follow the term (debounced), in the searched chat or all.
    func updateSearch(_ term: String) {
        searchTerm = term
        runSearch()
    }

    func runSearch() {
        searchTask?.cancel()
        let term = searchTerm, scope = searchConversationId
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty, let db = clientDatabase else {
            searchHits = []
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let hits = (try? await db.pool.read { try ConversationQueries.searchMessages($0, query: term, conversationId: scope) }) ?? []
            guard !Task.isCancelled else { return }
            self?.searchHits = hits
        }
    }

    /// The header's 🔍: search within the open chat.
    func startConversationSearch() {
        guard let id = selectedConversationId else { return }
        stopComposing()
        searchConversationId = id
        runSearch()
    }

    func endConversationSearch() {
        searchConversationId = nil
        runSearch()
    }

    func endSearch() {
        searchTask?.cancel()
        searchTerm = ""
        searchConversationId = nil
        searchHits = []
    }

    /// A search result: open its chat at the message.
    func openSearchResult(conversationId: String, messageId: String) {
        if selectedConversationId == conversationId {
            goToMessage(messageId)
        } else {
            pendingScrollMessageId = messageId
            open(conversationId: conversationId)
        }
    }
}
