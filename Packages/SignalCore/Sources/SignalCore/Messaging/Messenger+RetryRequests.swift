// What happens after a message could not be decrypted (upstream jobs/helpers/
// sendResendRequest and util/handleRetry): the sender is asked to send it again with a
// DecryptionErrorMessage, which travels unencrypted (PlaintextContent) because the session
// may be what is broken. If asking is not possible, the session with that device is reset
// locally instead.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos

extension Messenger {
    /// `sendResendRequest`
    func sendResendRequest(_ job: ConversationJob) async throws {
        guard let from = job.requester, let device = job.requesterDevice, let timestamp = job.timestamp,
              let plaintext = job.plaintext.flatMap({ Data(base64Encoded: $0) }) else { throw JobError.permanent("malformed job") }
        let groupId = job.groupId.flatMap { Data(base64Encoded: $0) }
        var payload = OutgoingPayload(content: Signalservice_Content(), timestamp: timestamp, contentHint: .default, urgent: false)
        payload.plaintextContent = plaintext
        payload.groupId = groupId ?? Data()
        do {
            try await sender.send(payload, to: from, logged: false)
        } catch is SendError {
            // Unregistered, untrusted identity, devices that cannot be resolved: nobody to ask.
            try await automaticSessionReset(sender: from, device: device)
            return
        }
        let hint = ContentHint(rawValue: job.contentHint ?? ContentHint.default.rawValue)
        if hint == .implicit { return }   // never shown
        let receivedAt = job.receivedAt ?? MessageStore.now()
        let counter = job.receivedAtCounter
        try await database.pool.write { db in
            // In the group the message was for, when we know it.
            let conversationId = try RetryPlaceholders.conversation(db, sender: from, groupId: groupId)
            if hint == .resendable {
                // Nothing is shown while we wait: the resent message takes this place in the
                // timeline, or a delivery issue does if it has not come within the hour.
                try RetryPlaceholders.add(db, .init(conversationId: conversationId, sentAt: timestamp, receivedAt: receivedAt,
                                                    receivedAtCounter: try counter ?? MessageStore.nextReceivedAt(db), senderAci: from, wasOpened: nil))
            } else {
                try RetryPlaceholders.insertDeliveryIssue(db, conversationId: conversationId, sender: from, receivedAt: receivedAt)
            }
        }
    }

    /// The user opened a conversation: a resent message arriving later keeps its own, later
    /// place instead of appearing above what they have already read (upstream
    /// `findByConversationAndMarkOpened`).
    public func conversationOpened(_ conversationId: String) async throws {
        try await database.pool.write { db in try RetryPlaceholders.markOpened(db, conversationId: conversationId) }
    }

    /// `startAutomaticSessionReset`: the session with that device is archived (at most once an
    /// hour, `lightSessionReset`), a NullMessage starts a new one, and the chat says so.
    func automaticSessionReset(sender from: String, device: UInt32) async throws {
        let id = "\(account.aci):\(from).\(device)"
        let now = MessageStore.now()
        let reset = try await database.pool.write { db -> Bool in
            let conversationId = try MessageStore.privateConversation(db, serviceId: from)
            try MessageStore.insert(db, .init(conversationId: conversationId, type: "chat-session-refreshed", body: "", sentAt: UInt64(now), source: nil,
                                              sourceDevice: nil, serverGuid: nil, serverTimestamp: nil, unidentified: false,
                                              extra: ["readStatus": ReadStatus.unread.rawValue, "seenStatus": SeenStatus.unseen.rawValue]))
            var resets = try Items.get(db, Self.sessionResetsKey, as: [String: Int64].self) ?? [:]
            if let last = resets[id], last > now - Self.sessionResetInterval { return false }
            resets[id] = now
            try Items.set(db, Self.sessionResetsKey, resets)
            try self.sender.archive(db, serviceId: from, devices: [device])
            return true
        }
        guard reset else { return }
        do {
            var content = Signalservice_Content()
            content.nullMessage = Signalservice_NullMessage()
            try await sender.send(OutgoingPayload(content: content, timestamp: UInt64(MessageStore.now()), contentHint: .implicit, urgent: false),
                                  to: from, logged: false)
        } catch {
            // Upstream: a reset that did not go through may be tried again sooner.
            try? await database.pool.write { db in
                var resets = try Items.get(db, Self.sessionResetsKey, as: [String: Int64].self) ?? [:]
                resets[id] = nil
                try Items.set(db, Self.sessionResetsKey, resets)
            }
        }
    }

    static let sessionResetsKey = "sessionResets"
    static let sessionResetInterval: Int64 = 60 * 60 * 1000
}

/// Messages we could not decrypt, asked to be sent again, and are waiting for (upstream
/// services/retryPlaceholders): kept in `items` under upstream's key and shape.
enum RetryPlaceholders {
    struct Item: Codable, Equatable {
        var conversationId: String
        var sentAt: UInt64
        var receivedAt: Int64
        var receivedAtCounter: Int64
        var senderAci: String
        var wasOpened: Bool?
    }

    static let storageKey = "retryPlaceholders"
    /// Upstream retryReceiptLifespan: how long we wait for the resend.
    static let lifespan: Int64 = 60 * 60 * 1000

    static func items(_ db: Database) throws -> [Item] { try Items.get(db, storageKey, as: [Item].self) ?? [] }

    static func add(_ db: Database, _ item: Item) throws {
        try Items.set(db, storageKey, (try items(db) + [item]).sorted { $0.receivedAt < $1.receivedAt })
    }

    /// `findByMessageAndRemove`: the message we were waiting for has arrived.
    static func take(_ db: Database, conversationId: String, sentAt: UInt64) throws -> Item? {
        var all = try items(db)
        guard let index = all.firstIndex(where: { $0.conversationId == conversationId && $0.sentAt == sentAt }) else { return nil }
        let item = all.remove(at: index)
        try Items.set(db, storageKey, all)
        return item
    }

    static func markOpened(_ db: Database, conversationId: String) throws {
        var all = try items(db)
        guard all.contains(where: { $0.conversationId == conversationId && $0.wasOpened != true }) else { return }
        for i in all.indices where all[i].conversationId == conversationId { all[i].wasOpened = true }
        try Items.set(db, storageKey, all)
    }

    /// `getExpiredAndRemove` and what upstream does with the result: a delivery issue for
    /// every message that was not resent in time. Returns how many.
    @discardableResult
    static func expire(_ db: Database, now: Int64) throws -> Int {
        let all = try items(db)
        let expired = all.filter { $0.receivedAt <= now - lifespan }
        guard !expired.isEmpty else { return 0 }
        try Items.set(db, storageKey, all.filter { $0.receivedAt > now - lifespan })
        for item in expired where try Bool.fetchOne(db, sql: "SELECT 1 FROM conversations WHERE id = ?", arguments: [item.conversationId]) == true {
            try insertDeliveryIssue(db, conversationId: item.conversationId, sender: item.senderAci, receivedAt: now)
        }
        return expired.count
    }

    /// The conversation a message from `sender` belongs to: the group when its id is known.
    static func conversation(_ db: Database, sender: String, groupId: Data?) throws -> String {
        let group = try groupId.flatMap { $0.isEmpty ? nil : $0 }.flatMap {
            try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE type = 'group' AND groupId = ?", arguments: [$0.base64EncodedString()])
        }
        return try group ?? MessageStore.privateConversation(db, serviceId: sender)
    }

    /// `addDeliveryIssue`
    static func insertDeliveryIssue(_ db: Database, conversationId: String, sender: String, receivedAt: Int64) throws {
        try MessageStore.insert(db, .init(conversationId: conversationId, type: "delivery-issue", body: "", sentAt: UInt64(receivedAt), source: sender,
                                          sourceDevice: nil, serverGuid: nil, serverTimestamp: nil, unidentified: false,
                                          extra: ["readStatus": ReadStatus.unread.rawValue, "seenStatus": SeenStatus.unseen.rawValue]))
    }
}
