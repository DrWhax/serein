// Payloads of the "conversation" job queue (upstream conversationJobQueue job types,
// ts/jobs/conversationJobQueue.preload.ts) plus the receipt / sync jobs that upstream
// keeps in separate queues.

import Foundation

public struct ReceiptTarget: Codable, Sendable, Equatable {
    public var messageId: String
    public var conversationId: String
    public var senderAci: String
    public var timestamp: UInt64
}

public enum ReceiptsType: String, Codable, Sendable {
    case delivery = "deliveryReceipt", read = "readReceipt", viewed = "viewedReceipt"
}

public struct ConversationJob: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case normalMessage = "NormalMessage"
        case receipts = "Receipts"
        case readSync = "ReadSync"
        case viewedSync = "ViewedSync"
        case resend = "Resend"
        case syncRequest = "SyncRequest"
        case fetchLatest = "FetchLatest"
        case stickerPackSync = "StickerPackSync"
        case modifierSend = "ModifierSend"
        case resendRequest = "ResendRequest"
        /// SyncMessage.Verified (upstream sends it through singleProtoJobQueue).
        case verifiedSync = "VerifiedSync"
    }

    /// SyncMessage.StickerPackOperation
    public struct StickerPackOperation: Codable, Sendable {
        public var packId: String
        public var packKey: String
        public var install: Bool
    }

    public var type: Kind
    public var conversationId: String?
    public var messageId: String?
    public var receiptsType: ReceiptsType?
    public var receipts: [ReceiptTarget]?
    // Resend (answer to a DecryptionErrorMessage)
    public var requester: String?
    public var requesterDevice: UInt32?
    public var timestamp: UInt64?
    public var ratchetKey: String?
    public var wasSenderKey: Bool?
    // SyncRequest; FetchLatest (SyncMessage.FetchLatest.Type raw values)
    public var requestTypes: [Int]?
    // StickerPackSync
    public var stickerPack: StickerPackOperation?
    // ModifierSend: a serialized Content
    public var content: String?
    // ResendRequest (we could not decrypt `requester`'s message at `timestamp`): the serialized
    // PlaintextContent carrying our DecryptionErrorMessage, the failed message's content hint
    // and group, and when it arrived.
    public var plaintext: String?
    public var contentHint: UInt32?
    public var groupId: String?
    public var receivedAt: Int64?
    public var receivedAtCounter: Int64?
    // VerifiedSync: the contact (`requester`), the identity key the user reviewed, and the state
    // set for it. The key is the reviewed one, never looked up again when the job runs: by then
    // the contact may have a newer key the user has not seen.
    public var identityKey: String?
    public var verified: Bool?

    public static let queueType = "conversation"

    public static func normalMessage(conversationId: String, messageId: String) -> Self {
        Self(type: .normalMessage, conversationId: conversationId, messageId: messageId)
    }
    public static func receipts(_ type: ReceiptsType, _ receipts: [ReceiptTarget]) -> Self {
        Self(type: .receipts, receiptsType: type, receipts: receipts)
    }
    public static func readSync(_ receipts: [ReceiptTarget]) -> Self { Self(type: .readSync, receipts: receipts) }
    public static func viewedSync(_ receipts: [ReceiptTarget]) -> Self { Self(type: .viewedSync, receipts: receipts) }
    public static func resend(requester: String, device: UInt32, timestamp: UInt64, ratchetKey: Data?, wasSenderKey: Bool) -> Self {
        Self(type: .resend, requester: requester, requesterDevice: device, timestamp: timestamp,
             ratchetKey: ratchetKey?.base64EncodedString(), wasSenderKey: wasSenderKey)
    }
    public static func resendRequest(sender: String, device: UInt32, timestamp: UInt64, plaintext: Data, contentHint: UInt32, groupId: Data?,
                                     receivedAt: Int64, receivedAtCounter: Int64? = nil) -> Self {
        Self(type: .resendRequest, requester: sender, requesterDevice: device, timestamp: timestamp, plaintext: plaintext.base64EncodedString(),
             contentHint: contentHint, groupId: groupId?.base64EncodedString(), receivedAt: receivedAt, receivedAtCounter: receivedAtCounter)
    }
    public static func syncRequest(_ types: [Int]) -> Self { Self(type: .syncRequest, requestTypes: types) }
    public static func verifiedSync(serviceId: String, key: Data, verified: Bool) -> Self {
        Self(type: .verifiedSync, requester: serviceId, identityKey: key.base64EncodedString(), verified: verified)
    }
    /// `getFetchManifestSyncMessage` and friends: tells our other devices to refetch.
    public static func fetchLatest(_ types: [Int]) -> Self { Self(type: .fetchLatest, requestTypes: types) }
}
