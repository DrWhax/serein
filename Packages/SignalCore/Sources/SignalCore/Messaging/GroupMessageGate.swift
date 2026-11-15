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
