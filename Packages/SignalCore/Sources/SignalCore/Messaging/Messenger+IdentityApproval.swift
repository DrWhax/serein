// The user's side of identity-key trust (upstream blockSendUntilConversationsAreVerified,
// conversationStoppedByMissingVerification and verifyConversationsStoppingSend).
//
// The identity store refuses to encrypt to a key that replaced another one until the user has
// approved it (or, for a contact that was never verified, until `ProtocolStore.approvalWindow`
// has passed), and to any contact marked unverified. These are the calls a UI needs around
// that: ask before sending, hear about sends that stopped, and approve.

import Foundation
import GRDB

public enum IdentityReviewError: Error, Equatable { case identityChanged }

/// A snapshot retained by the safety-number UI, not fetched again when confirming it.
public struct ReviewedIdentity: Sendable, Equatable {
    public let ourServiceId: String
    public let ourKey: Data
    public let serviceId: String
    public let key: Data

    func validate(_ db: Database, account: Account) throws {
        guard ourServiceId == account.aci, SignalCrypto.constantTimeEqual(ourKey, account.aciIdentity.publicKey.serialize()),
              let current = try ProtocolStore.identityRow(db, serviceId: serviceId)?.key,
              SignalCrypto.constantTimeEqual(current, key) else { throw IdentityReviewError.identityChanged }
    }
}

/// A send that did not go out because of the recipients' identity keys.
public struct IdentityStop: Sendable, Equatable {
    public var conversationId: String?
    /// The failed message (nil for reactions, edits and other modifier sends).
    public var messageId: String?
    public var serviceIds: [String]
}

extension Messenger {
    /// The members of a conversation whose identity key must be approved before a send:
    /// marked unverified, or changed within `threshold` milliseconds and not approved since.
    /// Empty means a send may go ahead.
    public func identitiesNeedingApproval(conversationId: String, threshold: Int64 = ProtocolStore.approvalWindow) async throws -> [String] {
        let ourAci = account.aci
        return try await database.pool.read { db in
            let members: [String]
            if let group = try GroupStore.load(db, conversationId: conversationId) {
                members = group.state?.membersV2.map(\.aci) ?? []
            } else {
                members = [try String.fetchOne(db, sql: "SELECT serviceId FROM conversations WHERE id = ?", arguments: [conversationId])].compactMap { $0 }
            }
            return try members.filter { $0 != ourAci }.filter { try ProtocolStore.needsApproval(db, serviceId: $0, threshold: threshold) }.sorted()
        }
    }

    /// The same for a set of recipients (a story's lists and groups, `verifyStoryListMembers`):
    /// those whose key changed recently and was not approved since.
    public func identitiesNeedingApproval(serviceIds: [String], threshold: Int64 = ProtocolStore.approvalWindow) async throws -> [String] {
        let ourAci = account.aci
        return try await database.pool.read { db in
            try Set(serviceIds).filter { $0 != ourAci }.filter { try ProtocolStore.needsApproval(db, serviceId: $0, threshold: threshold) }.sorted()
        }
    }

    /// Whether we marked this contact's current identity key as verified.
    public func verifiedStatus(_ serviceId: String) async throws -> VerifiedStatus {
        try await database.pool.read { db in try ProtocolStore.verifiedStatus(db, serviceId: serviceId) }
    }

    /// The recipients a failed message is waiting on (its `OutgoingIdentityKeyError`s).
    public func identitiesBlocking(messageId: String) async throws -> [String] {
        try await database.pool.read { db in try MessageStore.untrustedRecipients(db, messageId: messageId) }
    }

    /// The user reviewed the changed safety numbers and wants to send anyway: an unverified
    /// contact goes back to the default state (with its notice and the Verified sync to our
    /// other devices, queued with the reviewed key), and the key on record is approved. One
    /// transaction: the whole review is checked first, and one stale identity (a newer key,
    /// or another account of ours) changes nothing. Retry the stopped sends afterwards.
    public func approveIdentities(_ identities: [ReviewedIdentity]) async throws {
        let account = self.account
        try await database.pool.write { db in
            // Validate the entire review before changing any trust state.
            for identity in identities { try identity.validate(db, account: account) }
            try Self.applyApproval(db, identities)
        }
        jobs.poke()
    }

    static func applyApproval(_ db: Database, _ identities: [ReviewedIdentity]) throws {
        for identity in identities {
            let id = identity.serviceId
            if try ProtocolStore.verifiedStatus(db, serviceId: id) == .unverified {
                try ProtocolStore.setVerified(db, serviceId: id, .default)
                let conversationId = try MessageStore.privateConversation(db, serviceId: id)
                try Identity.insertVerifiedChange(db, conversationId: conversationId, verified: false, local: true)
                try StorageWriteBack.conversationChanged(db, conversationId: conversationId)
                try queueVerifiedSync(db, identity, verified: false)
            }
            try ProtocolStore.setApproval(db, serviceId: id, true)
        }
    }

    /// Records the stop on the message, tells the UI, and gives the job its final error.
    func stoppedByIdentity(_ serviceIds: [String], conversationId: String?, messageId: String?) async throws -> JobError {
        if let messageId {
            try await database.pool.write { db in try MessageStore.markFailed(db, messageId: messageId, untrustedIdentities: serviceIds) }
        }
        identityStopSink.yield(IdentityStop(conversationId: conversationId, messageId: messageId, serviceIds: serviceIds))
        return .permanent("untrusted identities: \(serviceIds.joined(separator: ", "))")
    }
}
