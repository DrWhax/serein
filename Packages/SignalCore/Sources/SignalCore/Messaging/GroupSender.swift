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
}

public struct GroupSendResult: Sendable, Equatable {
    public var senderKeyRecipients: [String]
    public var normalRecipients: [String]
    public var unregistered: [String]
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

    public func send(_ payload: OutgoingPayload, keys: GroupKeys, recipients: [String], messageIds: [String] = [], attempt: Int = 0)
        async throws -> GroupSendResult
    {
        let ourAci = account.aci
        let targets = Array(Set(recipients.filter { $0 != ourAci })).sorted()
        guard !targets.isEmpty else { return GroupSendResult(senderKeyRecipients: [], normalRecipients: [], unregistered: []) }
        let conversationId = try await database.pool.write { db in try GroupStore.conversation(db, keys: keys).conversationId }
        // Sessions for every recipient (fetchKeysForServiceIds).
        for t in targets where try await database.pool.read({ db in try sender.activeDevices(db, serviceId: t) }).isEmpty {
            try? await sender.fetchKeys(t, deviceId: nil)
        }
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
        if senderKeyTargets.count >= 2, let endorsements {
            do {
                (viaSenderKey, unregistered) = try await sendViaSenderKey(payload, keys: keys, conversationId: conversationId,
                                                                          devices: senderKeyTargets, endorsements: endorsements, messageIds: messageIds)
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
        for t in normal {
            do { _ = try await sender.send(payload, to: t, messageIds: messageIds) } catch SendError.unregistered { unregistered.append(t) }
        }
        return GroupSendResult(senderKeyRecipients: viaSenderKey, normalRecipients: normal, unregistered: unregistered)
    }

    func loadInfo(_ conversationId: String) async throws -> SenderKeyInfo {
        let now = MessageStore.now()
        return try await database.pool.write { db in
            let json = try String.fetchOne(db, sql: "SELECT json FROM conversations WHERE id = ?", arguments: [conversationId]).map(MessageStore.jsonObject) ?? [:]
            if let raw = json["senderKeyInfo"], let data = try? JSONSerialization.data(withJSONObject: raw),
               let info = try? JSONDecoder().decode(SenderKeyInfo.self, from: data), now - info.createdAtDate < Self.senderKeyExpiry {
                return info
            }
            let info = SenderKeyInfo(createdAtDate: now, distributionId: UUID().uuidString.lowercased(), memberDevices: [])
            try Self.saveInfo(db, conversationId, info)
            return info
        }
    }

    static func saveInfo(_ db: Database, _ conversationId: String, _ info: SenderKeyInfo) throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(info))
        try MessageStore.updateConversationJSON(db, conversationId: conversationId) { $0["senderKeyInfo"] = object }
    }

    func sendViaSenderKey(_ payload: OutgoingPayload, keys: GroupKeys, conversationId: String, devices: [(String, [UInt32])],
                          endorsements: GroupSendEndorsements.State, messageIds: [String]) async throws -> ([String], [String]) {
        var info = try await loadInfo(conversationId)
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
        let known = Set(info.memberDevices)
        let removed = known.subtracting(current)
        let memberSet = Set(devices.map(\.0))
        // A device of someone no longer in the send target saw our key: start a new one.
        if removed.contains(where: { !memberSet.contains($0.serviceId) }) {
            info = SenderKeyInfo(createdAtDate: MessageStore.now(), distributionId: UUID().uuidString.lowercased(), memberDevices: [])
            let fresh = info
            try await database.pool.write { db in try Self.saveInfo(db, conversationId, fresh) }
        }
        guard let distributionId = UUID(uuidString: info.distributionId) else { throw SendError.invalidKeysResponse("distribution id") }
        let local = try ProtocolAddress(name: account.aci, deviceId: account.deviceId)
        let newDevices = current.subtracting(Set(info.memberDevices))
        if !newDevices.isEmpty {
            let skdm = try await database.pool.write { db in
                try SenderKeyDistributionMessage(from: local, distributionId: distributionId, store: sender.store, context: DatabaseStoreContext(db))
                    .serialize()
            }
            var content = Signalservice_Content()
            content.senderKeyDistributionMessage = skdm
            for id in Set(newDevices.map(\.serviceId)).sorted() {
                _ = try await sender.send(OutgoingPayload(content: content, timestamp: payload.timestamp, contentHint: .resendable, urgent: payload.urgent),
                                          to: id)
            }
        }
        info.memberDevices = Array(current).sorted { ($0.serviceId, $0.id) < ($1.serviceId, $1.id) }
        let saved = info
        try await database.pool.write { db in try Self.saveInfo(db, conversationId, saved) }

        let recipients = Set(devices.map(\.0))
        let token = try endorsements.token(for: recipients, ourAci: account.aci, keys: keys)
        let certificate = try await sender.certificates.current()
        let proto = try payload.content.serializedBytes() as Data
        let padded = MessageSender.pad(proto)
        let addresses = try devices.flatMap { id, ds in try ds.map { try ProtocolAddress(name: id, deviceId: $0) } }
        let multi = try await database.pool.write { db in
            let ctx = DatabaseStoreContext(db)
            let message = try groupEncrypt(padded, from: local, distributionId: distributionId, store: sender.store, context: ctx)
            let usmc = try UnidentifiedSenderMessageContent(message, from: certificate, contentHint: payload.contentHint, groupId: keys.groupId)
            return try sealedSenderMultiRecipientEncrypt(usmc, for: addresses, identityStore: sender.store, sessionStore: sender.store, context: ctx)
        }
        let gone = try await socket.sendMultiRecipient(multi, timestamp: payload.timestamp, token: token, online: payload.online, urgent: payload.urgent)
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
