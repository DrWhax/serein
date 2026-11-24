// Joining a group from its link (ts/groups/joinViaLink.preload.ts): a group we are in opens with
// "You're already in this group", one we asked to join with "already requested"; otherwise
// GroupV2JoinDialog shows what the link's preview reveals (title, avatar, member count,
// description) and Join adds us, or asks the admins. Link errors use upstream's dialogs.

import Foundation
import GRDB
import SignalCore
import SignalUI

/// The join dialog's state.
struct GroupJoinPrompt {
    var link: GroupLink
    var info: PreJoinGroupInfo
    var avatar: RGBAImage?
    var avatarLoading: Bool
    var joining = false
}

extension SignalSession {
    /// A clicked or opened signal.group link.
    func openGroupLink(_ link: GroupLink) {
        guard let client = signalSession, let db = clientDatabase, let me = ourAci, let keys = try? GroupKeys(masterKey: link.masterKey) else { return }
        let media = media
        Task {
            let existing = try? await db.pool.read { db in
                try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE groupId = ?", arguments: [keys.groupIdBase64])
            }
            var group: GroupV2State?
            if let existing { group = try? await db.pool.read { try ConversationQueries.details($0, conversationId: existing)?.group } }
            if let existing, group?.member(me) != nil {
                await openNew(existing)
                toast = .alreadyGroupMember
                return
            }
            let info: PreJoinGroupInfo
            do {
                info = try await client.groups.preJoinInfo(link)
            } catch {
                groupLinkError(error, joining: false)
                return
            }
            if let existing, group?.pendingAdminApprovalV2.contains(where: { $0.aci == me }) == true {
                await openNew(existing)
                toast = .alreadyRequestedToJoin
                return
            }
            groupJoin = GroupJoinPrompt(link: link, info: info, avatar: nil, avatarLoading: info.avatarKey != nil)
            guard let key = info.avatarKey else { return }
            var image: RGBAImage?
            if let data = try? await client.groups.preJoinAvatar(link, key: key), let shown = try? await media.displayImage(data, maxDimension: 256) {
                image = RGBAImage(width: shown.width, height: shown.height, pixels: shown.rgba, scale: 2)
            }
            if groupJoin?.link == link {
                groupJoin?.avatar = image
                groupJoin?.avatarLoading = false
            }
        }
    }

    /// Join (or ask to): then the group opens.
    func joinGroupFromLink() {
        guard let client = signalSession, var prompt = groupJoin, !prompt.joining else { return }
        prompt.joining = true
        groupJoin = prompt
        Task {
            do {
                let keys = try await client.groups.join(prompt.link)
                groupJoin = nil
                let id = try await clientDatabase?.pool.read { db in
                    try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE groupId = ?", arguments: [keys.groupIdBase64])
                }
                if let id { await openNew(id) }
            } catch {
                groupJoin = nil
                groupLinkError(error, joining: true)
            }
        }
    }

    /// Upstream's link dialogs: revoked (403), ended (423), or the general failure.
    private func groupLinkError(_ error: Error, joining: Bool) {
        Self.trace("group link \(joining ? "join" : "preview") failed: \(error)")
        switch error {
        case HTTPError.status(403, _):
            composeError = ComposeError(key: "icu:GroupV2--join--link-revoked", args: [:], titleKey: "icu:GroupV2--join--link-revoked--title")
        case HTTPError.status(423, _):
            composeError = ComposeError(key: "icu:GroupV2--join--group-terminated", args: [:])
        case GroupLinkError.linkDisabled:
            composeError = ComposeError(key: "icu:GroupV2--join--link-revoked", args: [:], titleKey: "icu:GroupV2--join--link-revoked--title")
        default:
            composeError = ComposeError(key: "icu:GroupV2--join--general-join-failure", args: [:],
                                        titleKey: "icu:GroupV2--join--general-join-failure--title")
        }
    }

    /// An unparsable signal.group link (`parseGroupLink` failed).
    func invalidGroupLink() {
        composeError = ComposeError(key: "icu:GroupV2--join--invalid-link", args: [:], titleKey: "icu:GroupV2--join--invalid-link--title")
    }
}
