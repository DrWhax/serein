// Keeping groups current (ts/groups.preload.ts maybeUpdateGroup / getGroupUpdates /
// updateGroupViaSingleChange / updateGroupViaLogs / updateGroupViaState /
// generateLeftGroupChanges) and the avatar (applyNewAvatar / decryptGroupAvatar).

import Foundation
import GRDB
import LibSignalClient
import SignalProtos

public enum GroupsServiceError: Error, Equatable {
    case notFound
    case notAMember
    case badChange(String)
}

public actor GroupsService {
    let account: Account
    let database: SignalDatabase
    let api: GroupsAPI
    let store: AttachmentStore?
    /// Per-group serialization (`queueJob` per conversation upstream).
    var running: [String: Task<Void, Never>] = [:]
    var credentialProvider: CredentialProvider?
    var groupSender: GroupSender?

    public init(account: Account, database: SignalDatabase, api: GroupsAPI, store: AttachmentStore?) {
        self.account = account
        self.database = database
        self.api = api
        self.store = store
        ourAci = account.aci
        ourPni = account.pniServiceId
    }

    let ourAci: String
    let ourPni: String?

    /// Runs `body` after any earlier update of the same group.
    func serialized<T: Sendable>(_ groupId: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = running[groupId]
        let task = Task<T, any Error> {
            await previous?.value
            return try await body()
        }
        running[groupId] = Task { _ = try? await task.value }
        return try await task.value
    }

    /// `maybeUpdateGroup`: called with the groupV2 context of an incoming message (revision and
    /// optional signed change), or with neither to refresh.
    @discardableResult
    public func update(_ keys: GroupKeys, newRevision: Int? = nil, groupChange: Data? = nil, timestamp: UInt64? = nil) async throws -> [String] {
        try await serialized(keys.groupIdBase64) { try await self.updateNow(keys, newRevision: newRevision, groupChange: groupChange, timestamp: timestamp) }
    }

    func updateNow(_ keys: GroupKeys, newRevision: Int?, groupChange: Data?, timestamp: UInt64?) async throws -> [String] {
        let stored = try await database.pool.write { try GroupStore.conversation($0, keys: keys) }
        let ts = timestamp ?? UInt64(MessageStore.now())
        if let current = stored.state, let newRevision, newRevision <= current.revision { return [] }
        // A change for exactly the next revision is enough (`updateGroupViaSingleChange`), but
        // it reached us inside a member's message: only the server's signature over its actions
        // says the group service accepted it. Without that, any member could rewrite our view
        // of the group. A change that does not verify is ignored and the logs are fetched.
        if let current = stored.state, current.isMember(ourAci), let newRevision, newRevision == current.revision + 1, let groupChange,
           let actions = try Self.verifiedActions(groupChange, groupId: keys.groupId, serverParams: try api.credentials.serverParams()) {
            let decrypted = try GroupCipher(keys).decryptActions(actions)
            if decrypted.version == newRevision {
                return try await integrate([(decrypted, nil)], stored: stored, timestamp: ts)
            }
        }
        do {
            return try await updateViaLogs(keys, stored: stored, timestamp: ts)
        } catch HTTPError.status(403, _) {
            // Not (or no longer) a member: if we thought we were, record that we were removed;
            // a group we never had state for (storage service only) is marked left.
            guard let current = stored.state, current.isMember(ourAci) else {
                if stored.state == nil {
                    try await database.pool.write { db in
                        try MessageStore.updateConversationJSON(db, conversationId: stored.conversationId) { $0["left"] = true }
                    }
                }
                throw GroupsServiceError.notAMember
            }
            var removed = current
            removed.membersV2.removeAll { $0.aci == ourAci }
            let left = removed, ourAci = self.ourAci, ourPni = self.ourPni
            return try await database.pool.write { db in
                try GroupStore.save(db, conversationId: stored.conversationId, state: left, ourAci: ourAci)
                let messages = GroupDiff.extract(old: current, current: left, ourAci: ourAci, ourPni: ourPni, source: nil)
                return try GroupStore.appendChangeMessages(db, conversationId: stored.conversationId, messages, timestamp: ts)
            }
        }
    }

    /// Upstream getGroupUpdates' checks on a group change that came from a peer: an epoch we
    /// understand, the group server's notary signature over the actions (`verifyNotarySignature`),
    /// and actions that name this group. nil when any of them fails.
    static func verifiedActions(_ groupChange: Data, groupId: Data, serverParams: ServerPublicParams) throws -> Signalservice_GroupChange.Actions? {
        guard let change = try? Signalservice_GroupChange(serializedBytes: groupChange), change.changeEpoch <= GroupsAPI.supportedChangeEpoch,
              !change.serverSignature.isEmpty, !change.actions.isEmpty,
              let signature = try? NotarySignature(contents: change.serverSignature),
              (try? serverParams.verifySignature(message: change.actions, notarySignature: signature)) != nil,
              let actions = try? Signalservice_GroupChange.Actions(serializedBytes: change.actions),
              !actions.groupID.isEmpty, actions.groupID == groupId else { return nil }
        return actions
    }

    /// `updateGroupViaLogs`: every page from our revision (or the version we joined at).
    func updateViaLogs(_ keys: GroupKeys, stored: GroupStore.Stored, timestamp: UInt64) async throws -> [String] {
        var start: Int
        var includeFirstState: Bool
        if let current = stored.state, current.isMember(ourAci) {
            start = current.revision + 1
            includeFirstState = false
        } else {
            start = try await api.joinedAtVersion(keys)
            includeFirstState = true
        }
        var steps: [(DecryptedGroupActions?, Signalservice_Group?)] = []
        var endorsements: Data? = nil
        while true {
            let page = try await api.logs(keys, from: start, includeFirstState: includeFirstState, includeLastState: true)
            let cipher = try GroupCipher(keys)
            for entry in page.changes.groupChanges {
                var actions: DecryptedGroupActions? = nil
                if entry.hasGroupChange, let a = try? Signalservice_GroupChange.Actions(serializedBytes: entry.groupChange.actions) {
                    actions = try cipher.decryptActions(a)
                }
                steps.append((actions, entry.hasGroupState ? entry.groupState : nil))
            }
            if !page.changes.groupSendEndorsementsResponse.isEmpty { endorsements = page.changes.groupSendEndorsementsResponse }
            guard let range = page.range, range.end < range.current else { break }
            start = range.end + 1
            includeFirstState = false
        }
        return try await integrate(steps, stored: stored, timestamp: timestamp, endorsements: endorsements)
    }

    /// `integrateGroupChanges`: applies each step (its full state when given, else its actions),
    /// recording the diff of each.
    /// Replaces the local state with the server's from the version we joined at, adding no
    /// timeline messages (after a join, whose own message is already there).
    func resync(_ keys: GroupKeys) async throws {
        try await serialized(keys.groupIdBase64) {
            let stored = try await self.database.pool.write { try GroupStore.conversation($0, keys: keys) }
            let start = try await self.api.joinedAtVersion(keys)
            var steps: [(DecryptedGroupActions?, Signalservice_Group?)] = []
            var page = try await self.api.logs(keys, from: start, includeFirstState: true, includeLastState: true)
            var endorsements = page.changes.groupSendEndorsementsResponse
            while true {
                let cipher = try GroupCipher(keys)
                for entry in page.changes.groupChanges {
                    let actions = entry.hasGroupChange ? try? Signalservice_GroupChange.Actions(serializedBytes: entry.groupChange.actions) : nil
                    steps.append((try actions.map(cipher.decryptActions), entry.hasGroupState ? entry.groupState : nil))
                }
                guard let range = page.range, range.end < range.current else { break }
                page = try await self.api.logs(keys, from: range.end + 1, includeFirstState: false, includeLastState: true)
                if !page.changes.groupSendEndorsementsResponse.isEmpty { endorsements = page.changes.groupSendEndorsementsResponse }
            }
            _ = try await self.integrate(steps, stored: GroupStore.Stored(conversationId: stored.conversationId, keys: keys, state: nil, left: stored.left),
                                         timestamp: UInt64(MessageStore.now()), endorsements: endorsements.isEmpty ? nil : endorsements, silent: true)
        }
    }

    func integrate(_ steps: [(DecryptedGroupActions?, Signalservice_Group?)], stored: GroupStore.Stored, timestamp: UInt64,
                   endorsements: Data? = nil, silent: Bool = false) async throws -> [String] {
        let cipher = try GroupCipher(stored.keys)
        var state = stored.state
        var allKeys: [String: Data] = [:]
        var messages: [GroupChangeMessage] = []
        var addedBy: String? = nil
        let ourAci = self.ourAci, ourPni = self.ourPni
        let known = try await database.pool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT serviceId FROM conversations WHERE type = 'private' AND json_extract(json, '$.profileKey') IS NOT NULL"))
        }
        for (actions, snapshot) in steps {
            let old = state
            let next: GroupV2State
            var promoted: [String: String] = [:]
            if let snapshot {
                let (decrypted, keys) = try cipher.decryptState(snapshot)
                var withFlags = decrypted
                // Keep how members joined, for the diff of this step.
                if let actions, let o = old {
                    let applied = GroupChangeApply.apply(actions, to: o, ourAci: ourAci, hasProfileKey: { known.contains($0) })
                    promoted = applied.promotedAciToPni
                    withFlags.membersV2 = decrypted.membersV2.map { m in
                        var m = m
                        if let a = applied.state.member(m.aci) { m.joinedFromLink = a.joinedFromLink; m.approvedByAdmin = a.approvedByAdmin }
                        return m
                    }
                    allKeys.merge(applied.profileKeys) { a, _ in a }
                }
                allKeys.merge(keys) { _, b in b }
                next = withFlags
            } else if let actions, let o = old {
                guard actions.version > o.revision else { continue }
                let applied = GroupChangeApply.apply(actions, to: o, ourAci: ourAci, hasProfileKey: { known.contains($0) })
                promoted = applied.promotedAciToPni
                allKeys.merge(applied.profileKeys) { _, b in b }
                next = applied.state
            } else {
                continue
            }
            messages += GroupDiff.extract(old: old, current: next, ourAci: ourAci, ourPni: ourPni, source: actions?.sourceServiceId,
                                          promotedAciToPni: promoted)
            // Who added (or invited) us, for message requests (`addedBy`).
            let wasIn = old.map { $0.isMember(ourAci) || $0.isPending(ourAci) } ?? false
            if !wasIn {
                if let invited = next.pendingMembersV2.first(where: { $0.serviceId == ourAci }) { addedBy = invited.addedByUserId }
                else if next.isMember(ourAci), let src = actions?.sourceServiceId, src != ourAci { addedBy = src }
            }
            state = next
        }
        guard let final = state else { return [] }
        let previousAvatar = stored.state?.avatarUrl
        let learnt = allKeys, changeMessages = silent ? [] : messages, inviter = addedBy
        let ids = try await database.pool.write { db -> [String] in
            try GroupStore.save(db, conversationId: stored.conversationId, state: final, ourAci: ourAci)
            if let inviter {
                let by = try MessageStore.privateConversation(db, serviceId: inviter)
                try MessageStore.updateConversationJSON(db, conversationId: stored.conversationId) { $0["addedBy"] = by }
            }
            try GroupStore.saveProfileKeys(db, learnt, ourAci: ourAci)
            return try GroupStore.appendChangeMessages(db, conversationId: stored.conversationId, changeMessages, timestamp: timestamp)
        }
        if final.avatarUrl != previousAvatar { try? await refreshAvatar(stored.keys, conversationId: stored.conversationId, url: final.avatarUrl) }
        // Endorsements decode only against the exact member list they were issued for; a
        // partial local state (right after a join) keeps the old ones until the next fetch.
        if let endorsements, final.isMember(ourAci) { try? await saveEndorsements(endorsements, keys: stored.keys, members: final.membersV2.map(\.aci)) }
        if !final.isMember(ourAci) { try await database.pool.write { try GroupSendEndorsements.clear($0, groupId: stored.keys.groupIdBase64) } }
        return ids
    }

    // MARK: avatar

    /// `decryptGroupAvatar`: the CDN blob is a GroupAttributeBlob with the image.
    public static func decryptAvatar(_ blob: Data, keys: GroupKeys) throws -> Data {
        let attribute = try GroupCipher(keys).decryptAttribute(blob)
        guard case .avatar(let image)? = attribute.content else { throw GroupsServiceError.badChange("avatar blob") }
        return image
    }

    /// `applyNewAvatar`: downloads and stores the avatar (encrypted at rest), or removes it.
    func refreshAvatar(_ keys: GroupKeys, conversationId: String, url: String?) async throws {
        guard let url else {
            try await database.pool.write { try MessageStore.updateConversationJSON($0, conversationId: conversationId) { $0["avatar"] = nil } }
            return
        }
        guard let store else { return }
        let image = try Self.decryptAvatar(try await api.avatar(url), keys: keys)
        let saved = try store.storeLocally(image)
        try await database.pool.write { db in
            try MessageStore.updateConversationJSON(db, conversationId: conversationId) { json in
                json["avatar"] = ["url": url, "path": saved.path, "localKey": saved.localKey.base64EncodedString(), "hash": saved.plaintextHash,
                                  "size": image.count]
            }
        }
    }

    // MARK: endorsements (filled in with the sender-key send path)

    func saveEndorsements(_ response: Data, keys: GroupKeys, members: [String]) async throws {
        try await GroupSendEndorsements.save(response, keys: keys, members: members, account: account, database: database,
                                             serverPublicParams: api.credentials.serverParamsData)
    }
}
