// Events emitted by MessageReceiver (subset of Desktop messageReceiverEvents.std.ts
// needed by Phase 2a; each case is emitted only after its database commit).

import Foundation
import SignalProtos

public enum ReceiptKind: String, Sendable { case delivery, read, viewed }

public enum ReceiveEvent: Sendable, Equatable {
    /// An incoming DataMessage was stored as `messageId`.
    case message(messageId: String, conversationId: String, sender: String, senderDevice: UInt32, timestamp: UInt64, body: String,
                 sealed: Bool, groupId: Data?)
    /// A SyncMessage.Sent transcript from one of our own devices was stored.
    case sentTranscript(messageId: String, conversationId: String, destination: String, timestamp: UInt64, body: String)
    /// Other sync-message kinds (read, viewed, contacts, …): handled in later phases.
    case sync(kind: String, senderDevice: UInt32)
    case receipt(kind: ReceiptKind, sender: String, timestamps: [UInt64], updatedMessages: Int)
    case typing(sender: String, started: Bool, timestamp: UInt64, groupId: Data?)
    /// An EditMessage replaced the body of `messageId` (history kept in edited_messages / json.editHistory).
    case edit(messageId: String, sender: String, targetTimestamp: UInt64, body: String)
    /// A peer reports it failed to decrypt our message sent at `timestamp`.
    case decryptionErrorReported(sender: String, senderDevice: UInt32, timestamp: UInt64, deviceId: UInt32)
    case senderKeyDistribution(sender: String, senderDevice: UInt32, distributionId: UUID)
    case serverDeliveryReceipt(timestamp: UInt64)
    case other(kind: String, sender: String)
    /// A story arrived (or our other device sent one).
    case story(storyId: String, conversationId: String, sender: String, timestamp: UInt64)
    /// A reply or reaction to a story.
    case storyReply(messageId: String, storyId: String, conversationId: String, sender: String)
    /// A CallMessage (calling signalling) for CallingService; never stored.
    case callMessage(CallMessageEnvelope)
    /// Call history, call log or call link changes from a sync message were stored.
    case callHistoryChanged
    /// A message carried a Groups v2 context: bring the group up to `revision` (GroupsService.update).
    case groupContext(masterKey: Data, revision: Int, groupChange: Data?, sender: String, timestamp: UInt64)
    /// Envelope dropped (decryption or validation failed); state changes were rolled back.
    case failed(serverGuid: String, reason: String)
    case queueEmpty
}

/// A received CallMessage with what `RingRTC.handleCallingMessage` needs.
public struct CallMessageEnvelope: Sendable, Equatable {
    public var sender: String
    public var senderDevice: UInt32
    public var destinationIsPni: Bool
    public var timestamp: UInt64
    public var serverTimestamp: UInt64
    public var receivedAt: Int64
    public var serverGuid: String
    public var message: Signalservice_CallMessage
}
