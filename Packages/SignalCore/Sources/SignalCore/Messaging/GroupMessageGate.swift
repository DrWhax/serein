// Who may post into a group (upstream handleDataMessage, after `maybeUpdateGroup`): an
// incoming group message or group story is judged on the group as the group server has it
// once the message's change is applied. It is dropped unless we and the sender are members,
// when the group is terminated, and in an announcement-only group unless the sender is an
// admin. The receive path never creates a group's conversation: a group with no stored state,
// or one behind the message's revision, is refreshed first, and the envelope waits for that.

import Foundation
import GRDB
import SignalProtos

/// What refreshing a group before judging one of its messages came to.
public enum GroupRefreshOutcome: Sendable, Equatable {
    /// The group server answered: with the group's state, or that we are not a member.
    case done
    /// It could not be asked (network, server error): the message waits and is tried again.
    case retry
}

/// Brings the group of `masterKey` up to `revision` (with the message's signed change, when it
/// carries one), as `GroupsService.update` does.
public typealias GroupRefresher = @Sendable (_ masterKey: Data, _ revision: Int, _ groupChange: Data?, _ timestamp: UInt64) async -> GroupRefreshOutcome

/// Thrown out of the receive transaction (which rolls back) for a message whose group has to
/// be refreshed first.
struct GroupRefreshNeeded: Error {
    var masterKey: Data
    var revision: Int
    var groupChange: Data?
    var timestamp: UInt64
}

extension MessageReceiver {
    /// The group conversation an incoming message or story from `sender` goes into, or nil when
    /// it is dropped. Throws GroupRefreshNeeded when the group must be refreshed first.
    func groupDestination(_ db: Database, _ g: Signalservice_GroupContextV2, sender: String, timestamp: UInt64,
                          groupRefreshed: Bool) throws -> (conversationId: String, groupId: Data)? {
        guard g.masterKey.count == 32 else { throw ReceiveError.invalidEnvelope("bad group master key") }
        let keys = try GroupKeys(masterKey: g.masterKey)
        // A blocked group is dropped before anything else (upstream `isGroupBlocked` in
        // MessageReceiver): it is not refreshed, nor its change applied, for its messages.
        if try BlockedList.groups.blockedAt(db, keys.groupId.base64EncodedString()).blocked { return nil }
        let stored = try GroupStore.find(db, groupId: keys.groupId)
        // `isFirstUpdate || revision > existingRevision`
        let behind = stored?.state.map { Int(g.revision) > $0.revision } ?? true
        if behind, !groupRefreshed, groupRefresher != nil {
            throw GroupRefreshNeeded(masterKey: g.masterKey, revision: Int(g.revision), groupChange: g.hasGroupChange ? g.groupChange : nil,
                                     timestamp: timestamp)
        }
        guard let stored, let state = stored.state, Self.mayPost(sender, in: state, ourAci: account.aci) else { return nil }
        return (stored.conversationId, keys.groupId)
    }

    /// Upstream's drops: "which we or the sender are not a part of", announcement-only groups
    /// where the sender is not an admin, terminated groups.
    static func mayPost(_ sender: String, in state: GroupV2State, ourAci: String) -> Bool {
        guard state.isMember(ourAci), state.isMember(sender), !state.terminated else { return false }
        return !state.announcementsOnly || state.isAdmin(sender)
    }
}

// What upstream drops before a message reaches its handler, and the limits processDataMessage
// puts on what it carries (MessageReceiver #decryptAndProcess, #handleDataMessage,
// #handleEditMessage, #handleStoryMessage; textsecure/processDataMessage.preload.ts).
enum InboundLimits {
    /// `MAX_MESSAGE_BODY_BYTE_LENGTH`: a longer body travels as a long-text attachment, so a
    /// message, edit or story reply with one is dropped ("Dropping too-long message").
    static let maxBodyBytes = 2 << 10
    /// `ATTACHMENT_MAX`: the attachments past these are ignored.
    static let maxAttachments = 32
    /// `DataMessage.Flags` that processDataMessage knows; any other bit drops the message
    /// ("Unknown flags in message").
    static let knownFlags: UInt32 = 1 | ConversationState.expirationTimerUpdateFlag | ConversationState.profileKeyUpdateFlag
    static let endSessionFlag: UInt32 = 1

    static func bodyTooLong(_ body: String) -> Bool { body.utf8.count > maxBodyBytes }

    /// `getStoriesBlocked`: stories are off on this account.
    static func storiesDisabled(_ db: Database) throws -> Bool { try Items.get(db, "hasStoriesDisabled", as: Bool.self) == true }

    /// The sender's private conversation shares our profile (`profileSharing`): 1:1 stories and
    /// story replies come only from them ("Dropping story message - !profileSharing for sender").
    static func sharesProfile(_ db: Database, sender: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT json ->> '$.profileSharing' FROM conversations WHERE type = 'private' AND serviceId = ?",
                          arguments: [sender]) ?? false
    }

    /// `isMessageEmpty` for an incoming chat message as it is stored: nothing to show.
    static func isEmpty(_ m: Signalservice_DataMessage) -> Bool {
        m.body.isEmpty && m.attachments.isEmpty && m.contact.isEmpty && !m.hasSticker && !m.hasPollCreate && !m.isViewOnce
    }
}
