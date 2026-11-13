// Sending to a group (ts/util/sendToGroup.preload.ts sendToGroupViaSenderKey /
// sendToGroupViaNormalSend): sender key distribution to devices that lack our key, one
// groupEncrypt'd message sealed for every device at once (sealedSenderMultiRecipientEncrypt),
// sent with a group send endorsement token; members without endorsements, and groups with
// fewer than two such members, get normal 1:1 sends.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos

/// `SenderKeyInfoType` on the conversation (`senderKeyInfo`).
struct SenderKeyInfo: Codable, Equatable {
    struct Device: Codable, Hashable { var id: UInt32; var serviceId: String; var registrationId: UInt32 }
    var createdAtDate: Int64
    var distributionId: String
    var memberDevices: [Device]
    /// Changes on every reset, even though the protocol distribution id is stable.
    var generation: String? = nil
    /// Confirmed deliveries, distinct from reservations: an interrupted send must redistribute.
    var deliveredDevices: [Device]? = nil
    /// Set when a member's identity key changed: the key is replaced before the next send.
    var needsReset: Bool?
}

public struct GroupSendResult: Sendable, Equatable {
    public var senderKeyRecipients: [String]
    public var normalRecipients: [String]
    public var unregistered: [String]
    /// Members left out because we blocked them.
    public var blocked: [String] = []
    /// Recipients left out because they are no longer members (content only).
    public var notMembers: [String] = []
}

/// Who a group send goes to, decided from the membership committed when it plans (after any
/// upload, and again on every retry).
struct GroupSendPlan: Equatable {
    /// Members: they get the payload, through our sender key when possible.
    var members: [String]
    /// Non-members a group update reaches (those it removes, invitees, requesters): one by
    /// one, never through our sender key.
    var outside: [String]
    /// Non-members content does not go to.
    var dropped: [String]

    static func make(recipients: [String], members: Set<String>, ourAci: String, update: Bool) -> GroupSendPlan {
        let all = Array(Set(recipients.filter { $0 != ourAci })).sorted()
        let inGroup = all.filter { members.contains($0) }, outside = all.filter { !members.contains($0) }
        return GroupSendPlan(members: inGroup, outside: update ? outside : [], dropped: update ? [] : outside)
    }
}

extension SenderKeyInfo {
    /// Our sender key after a removal: if a device we gave the key to belongs to an account that
    /// is not among this send's targets (members only), the key is replaced; the (new or
    /// current) key then goes to every target device that does not have it.
    static func rotation(distributed: [Device], current: Set<Device>, targets: Set<String>) -> (reset: Bool, distribute: Set<Device>) {
        let removed = Set(distributed).subtracting(current)
        let reset = removed.contains { !targets.contains($0.serviceId) }
        return (reset, reset ? current : current.subtracting(Set(distributed)))
    }

    /// Merge reservations or delivery completions with the latest persisted record. Neither
    /// set shrinks within a generation, including when sends overlap or stop part-way.
    static func recording(_ distributed: [Device], adding devices: some Sequence<Device>) -> [Device] {
        Array(Set(distributed).union(devices)).sorted { ($0.serviceId, $0.id) < ($1.serviceId, $1.id) }
    }
}

public struct GroupSender: Sendable {
    /// `getSenderKeyExpireDuration` default.
    static let senderKeyExpiry: Int64 = 90 * 86_400_000
    let account: Account
    let database: SignalDatabase
    let socket: SocketManager
    let sender: MessageSender

    public init(account: Account, database: SignalDatabase, socket: SocketManager, sender: MessageSender) {
        self.account = account
        self.database = database
        self.socket = socket
        self.sender = sender
    }

    /// The members a group send goes to: those we have not blocked (by service id or number).
    static func sendableRecipients(_ db: Database, _ serviceIds: [String]) throws -> [String] {
        try serviceIds.filter { try !MessageSender.isBlocked(db, serviceId: $0) }
    }

    public func send(_ payload: OutgoingPayload, keys: GroupKeys, recipients: [String], messageIds: [String] = [], attempt: Int = 0)
        async throws -> GroupSendResult
    {
        var payload = payload
        payload.groupId = keys.groupId
        try sender.authorization(to: nil, groupId: keys.groupId, messageIds: messageIds, retracting: payload.onlyRetracts)()
        try await PreKeyMaintenance(account: account, database: database, socket: socket).ensureKeysCurrent()
        let ourAci = account.aci
        // A membership change takes effect when it is committed here: the plan is made from the
        // membership now (after the caller's uploads, and again on a retry), and the submission
        // check refuses a group payload to a non-member. A group update also reaches those it
        // removes, one by one; content does not go to non-members.
        let update = payload.isGroupUpdateOnly
        let (plan, targets, outsideTargets) = try await database.pool.read { db in
            let plan = GroupSendPlan.make(recipients: recipients, members: try MessageSender.currentMembers(db, groupId: keys.groupId),
                                          ourAci: ourAci, update: update)
            // Contacts we blocked get nothing from us, in groups too (upstream getValidRecipients).
            return (plan, try Self.sendableRecipients(db, plan.members), try Self.sendableRecipients(db, plan.outside))
        }
        let blocked = (plan.members + plan.outside).filter { !targets.contains($0) && !outsideTargets.contains($0) }
        for t in outsideTargets {
            do { _ = try await sender.send(payload, to: t, messageIds: messageIds) } catch SendError.unregistered {}
        }
        guard !targets.isEmpty else {
            return GroupSendResult(senderKeyRecipients: [], normalRecipients: outsideTargets, unregistered: [], blocked: blocked, notMembers: plan.dropped)
        }
        let conversationId = try await database.pool.write { db in try GroupStore.conversation(db, keys: keys).conversationId }
        // Sessions for every recipient (fetchKeysForServiceIds).
        var untrusted: [String] = []
        for t in targets where try await database.pool.read({ db in try sender.activeDevices(db, serviceId: t) }).isEmpty {
            do { try await sender.fetchKeys(t, deviceId: nil) } catch SendError.untrustedIdentities(let ids) { untrusted += ids } catch {}
        }
        // Nothing goes to the group while a member's identity key awaits approval or is marked
        // unverified: the sender-key encryption would refuse them, and upstream fails the send
        // for everyone so the user decides first.
        untrusted += try await database.pool.read { db in try targets.filter { try ProtocolStore.needsApproval(db, serviceId: $0) } }
        if !untrusted.isEmpty { throw SendError.untrustedIdentities(Array(Set(untrusted)).sorted()) }
        let endorsements = try await database.pool.read { db in try GroupSendEndorsements.State.load(db, groupId: keys.groupIdBase64) }
        let now = Int64(Date().timeIntervalSince1970)
        let endorsed = endorsements.map { e in GroupSendEndorsements.isValidExpiration(e.expiration, now: now) ? Set(e.members.keys) : [] } ?? []
        let devices = try await database.pool.read { db in
            try targets.map { t in (t, try sender.activeDevices(db, serviceId: t)) }.filter { !$0.1.isEmpty }
        }
        let senderKeyTargets = devices.filter { endorsed.contains($0.0) }
        var normal = targets.filter { t in !senderKeyTargets.contains { $0.0 == t } }
        var viaSenderKey: [String] = []
        var unregistered: [String] = []
        // Group stories go to each member (sealed, `story=true`).
        if senderKeyTargets.count >= 2, let endorsements, !payload.story {
            do {
                (viaSenderKey, unregistered) = try await sendViaSenderKey(payload, keys: keys, conversationId: conversationId,
                                                                          devices: senderKeyTargets, endorsements: endorsements, messageIds: messageIds)
            } catch SendError.notAMember where attempt < 3 {
                // Someone was removed while this send was under way: plan again.
                return try await send(payload, keys: keys, recipients: recipients, messageIds: messageIds, attempt: attempt + 1)
            } catch SignalError.mismatchedDevices(let entries, _) where attempt < 3 {
                for e in entries {
                    let id = e.account.serviceIdString.lowercased()
                    try await database.pool.write { db in try sender.archive(db, serviceId: id, devices: e.extraDevices + e.staleDevices) }
                    for d in e.missingDevices + e.staleDevices { try? await sender.fetchKeys(id, deviceId: d) }
                }
                return try await send(payload, keys: keys, recipients: recipients, messageIds: messageIds, attempt: attempt + 1)
            }
        } else {
            normal = targets
        }
        var dropped = plan.dropped
        for t in normal {
            do { _ = try await sender.send(payload, to: t, messageIds: messageIds) } catch SendError.unregistered { unregistered.append(t) } catch SendError.notAMember {
                dropped.append(t)
            }
        }
        return GroupSendResult(senderKeyRecipients: viaSenderKey, normalRecipients: normal + outsideTargets, unregistered: unregistered,
                               blocked: blocked, notMembers: dropped)
    }

    static func storedInfo(_ db: Database, _ conversationId: String) throws -> SenderKeyInfo? {
        let json = try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE id = ?", arguments: [conversationId]).map(MessageStore.jsonObject) ?? [:]
        return try json["senderKeyInfo"].map { try JSONDecoder().decode(SenderKeyInfo.self, from: JSONSerialization.data(withJSONObject: $0)) }
    }

    /// Plan and reserve potential holders in one writer transaction, before network delivery.
    /// Failed deliveries may overcount holders; undercounting would make rotation unsound.
    func prepareSenderKey(_ db: Database, conversationId: String, groupId: Data, current: Set<SenderKeyInfo.Device>,
                          targets: Set<String>) throws -> (SenderKeyInfo, Set<SenderKeyInfo.Device>) {
        let members = try MessageSender.currentMembers(db, groupId: groupId)
        for target in targets where !members.contains(target) { throw SendError.notAMember(target) }
        let stored = try Self.storedInfo(db, conversationId)
        var info: SenderKeyInfo
        if let stored, stored.generation != nil, stored.needsReset != true,
           MessageStore.now() - stored.createdAtDate < Self.senderKeyExpiry {
            info = stored
        } else {
            info = try resetSenderKey(db, conversationId: conversationId, previous: stored)
        }
        let rotation = SenderKeyInfo.rotation(distributed: info.memberDevices, current: current, targets: targets)
        if rotation.reset { info = try resetSenderKey(db, conversationId: conversationId, previous: info) }
        info.memberDevices = SenderKeyInfo.recording(info.memberDevices, adding: current)
        try Self.saveInfo(db, conversationId, info)
        return (info, current.subtracting(Set(info.deliveredDevices ?? [])))
    }

    /// A completion can add only to its own generation, and merges with the latest database row.
    static func recordSenderKeyDelivery(_ db: Database, conversationId: String, generation: String,
                                        devices: Set<SenderKeyInfo.Device>) throws {
        guard var info = try storedInfo(db, conversationId), info.generation == generation else {
            throw SendError.notAMember("sender key changed")
        }
        info.deliveredDevices = SenderKeyInfo.recording(info.deliveredDevices ?? [], adding: devices)
        try saveInfo(db, conversationId, info)
    }

    /// Check the key actually used, not merely this send's addressed recipients. Called in the
    /// encryption transaction and again by the transport immediately before submission.
    static func authorizeSenderKey(_ db: Database, conversationId: String, generation: String, groupId: Data) throws {
        guard let info = try storedInfo(db, conversationId), info.generation == generation, info.needsReset != true else {
            throw SendError.notAMember("sender key changed")
        }
        let members = try MessageSender.currentMembers(db, groupId: groupId)
        for device in info.memberDevices where !members.contains(device.serviceId) {
            throw SendError.notAMember(device.serviceId)
        }
    }

    /// Upstream `resetSenderKey`: our key for this distribution is deleted, so the next
    /// distribution message carries a new one that only the current members receive. The
    /// distribution id is kept (as upstream does), which lets receivers replace our old key.
    @discardableResult
    func resetSenderKey(_ db: Database, conversationId: String, previous: SenderKeyInfo?) throws -> SenderKeyInfo {
        let fresh = SenderKeyInfo(createdAtDate: MessageStore.now(), distributionId: previous?.distributionId ?? UUID().uuidString.lowercased(),
                                  memberDevices: [], generation: UUID().uuidString.lowercased(), deliveredDevices: [])
        if let previous, let id = UUID(uuidString: previous.distributionId) {
            try sender.store.removeSenderKey(db, from: try ProtocolAddress(name: account.aci, deviceId: account.deviceId), distributionId: id)
        }
        try Self.saveInfo(db, conversationId, fresh)
        return fresh
    }

    static func saveInfo(_ db: Database, _ conversationId: String, _ info: SenderKeyInfo) throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(info))
        try MessageStore.updateConversationJSON(db, conversationId: conversationId) { $0["senderKeyInfo"] = object }
    }

    func sendViaSenderKey(_ payload: OutgoingPayload, keys: GroupKeys, conversationId: String, devices: [(String, [UInt32])],
                          endorsements: GroupSendEndorsements.State, messageIds: [String]) async throws -> ([String], [String]) {
        let current = try await database.pool.read { db -> Set<SenderKeyInfo.Device> in
            let ctx = DatabaseStoreContext(db)
            var out = Set<SenderKeyInfo.Device>()
            for (id, ds) in devices {
                for d in ds {
                    let reg = try sender.store.loadSession(for: ProtocolAddress(name: id, deviceId: d), context: ctx)?.remoteRegistrationId() ?? 0
                    out.insert(.init(id: d, serviceId: id, registrationId: reg))
                }
            }
            return out
        }
        let (info, newDevices, skdm) = try await database.pool.write { db in
            let (info, newDevices) = try prepareSenderKey(db, conversationId: conversationId, groupId: keys.groupId, current: current,
                                                       targets: Set(devices.map(\.0)))
            guard let distributionId = UUID(uuidString: info.distributionId) else { throw SendError.invalidKeysResponse("distribution id") }
            let local = try ProtocolAddress(name: account.aci, deviceId: account.deviceId)
            let skdm = try SenderKeyDistributionMessage(from: local, distributionId: distributionId, store: sender.store,
                                                        context: DatabaseStoreContext(db)).serialize()
            return (info, newDevices, skdm)
        }
        guard let distributionId = UUID(uuidString: info.distributionId), let generation = info.generation else {
            throw SendError.invalidKeysResponse("sender key generation")
        }
        let local = try ProtocolAddress(name: account.aci, deviceId: account.deviceId)
        if !newDevices.isEmpty {
            var content = Signalservice_Content()
            content.senderKeyDistributionMessage = skdm
            var distribution = OutgoingPayload(content: content, timestamp: payload.timestamp, contentHint: .resendable, urgent: payload.urgent)
            distribution.groupId = keys.groupId
            for id in Set(newDevices.map(\.serviceId)).sorted() {
                _ = try await sender.send(distribution, to: id)
                try await database.pool.write { db in
                    try Self.recordSenderKeyDelivery(db, conversationId: conversationId, generation: generation,
                                                     devices: Set(newDevices.filter { $0.serviceId == id }))
                }
            }
        }

        let recipients = Set(devices.map(\.0))
        let token = try endorsements.token(for: recipients, ourAci: account.aci, keys: keys)
        let certificate = try await sender.certificates.current()
        let proto = try payload.content.serializedBytes() as Data
        let padded = MessageSender.pad(proto)
        let addresses = try devices.flatMap { id, ds in try ds.map { try ProtocolAddress(name: id, deviceId: $0) } }
        let multi = try await database.pool.write { db in
            try Self.authorizeSenderKey(db, conversationId: conversationId, generation: generation, groupId: keys.groupId)
            let ctx = DatabaseStoreContext(db)
            let message = try groupEncrypt(padded, from: local, distributionId: distributionId, store: sender.store, context: ctx)
            let usmc = try UnidentifiedSenderMessageContent(message, from: certificate, contentHint: payload.contentHint, groupId: keys.groupId)
            return try sealedSenderMultiRecipientEncrypt(usmc, for: addresses, identityStore: sender.store, sessionStore: sender.store, context: ctx)
        }
        let authorize = sender.authorization(to: nil, groupId: keys.groupId, messageIds: messageIds,
                                             retracting: payload.onlyRetracts, recipients: devices.map(\.0),
                                             senderKey: .init(conversationId: conversationId, generation: generation))
        let gone = try await socket.sendMultiRecipient(multi, timestamp: payload.timestamp, token: token, online: payload.online, urgent: payload.urgent,
                                                       authorize: authorize)
            .map { $0.serviceIdString.lowercased() }
        let delivered = devices.filter { !gone.contains($0.0) }
        try await database.pool.write { db in
            for (id, ds) in delivered {
                try SendLog.record(db, timestamp: payload.timestamp, contentHint: payload.contentHint.rawValue, proto: proto, urgent: payload.urgent,
                                   recipient: id, devices: ds, messageIds: messageIds)
            }
        }
        return (delivered.map(\.0), gone)
    }
}
