// ts/util/groupSendEndorsements.preload.ts: the endorsements a group fetch or change returns
// (one combined, one per member) in groupSendCombinedEndorsement / groupSendMemberEndorsement,
// and the GroupSendFullToken a multi-recipient send presents (GroupSendEndorsementState.buildToken).

import Foundation
import GRDB
import LibSignalClient

public enum GroupSendEndorsementError: Error, Equatable {
    case missing(String)
    case expired(String)
}

public enum GroupSendEndorsements {
    /// `decodeGroupSendEndorsementsResponse` + `replaceAllEndorsementsForGroup`.
    public static func save(_ response: Data, keys: GroupKeys, members: [String], account: Account, database: SignalDatabase,
                            serverPublicParams: Data) async throws {
        guard !response.isEmpty, !members.isEmpty else { return }
        let r = try GroupSendEndorsementsResponse(contents: response)
        let expiration = Int64(r.expiration.timeIntervalSince1970)
        let acis = try members.map { try Aci.parseFrom(serviceIdString: $0) }
        let received = try r.receive(groupMembers: acis, localUser: Aci.parseFrom(serviceIdString: account.aci), groupParams: keys.secret(),
                                     serverParams: ServerPublicParams(contents: serverPublicParams))
        guard received.endorsements.count == members.count else { throw GroupSendEndorsementError.missing("count mismatch") }
        let groupId = keys.groupIdBase64
        try await database.pool.write { db in
            try db.execute(sql: "DELETE FROM groupSendMemberEndorsement WHERE groupId = ?", arguments: [groupId])
            try db.execute(sql: "INSERT OR REPLACE INTO groupSendCombinedEndorsement (groupId, expiration, endorsement) VALUES (?, ?, ?)",
                           arguments: [groupId, expiration, received.combinedEndorsement.serialize()])
            for (aci, e) in zip(members, received.endorsements) {
                try db.execute(sql: "INSERT OR REPLACE INTO groupSendMemberEndorsement (groupId, memberAci, expiration, endorsement) VALUES (?, ?, ?, ?)",
                               arguments: [groupId, aci, expiration, e.serialize()])
            }
        }
    }

    public static func clear(_ db: Database, groupId: String) throws {
        try db.execute(sql: "DELETE FROM groupSendCombinedEndorsement WHERE groupId = ?", arguments: [groupId])
        try db.execute(sql: "DELETE FROM groupSendMemberEndorsement WHERE groupId = ?", arguments: [groupId])
    }

    /// `validateGroupSendEndorsementsExpiration`: more than 2 hours and less than 2 days left.
    public static func isValidExpiration(_ expiration: Int64, now: Int64) -> Bool {
        let distance = expiration - now
        return expiration > now && distance > 2 * 3600 && distance < 2 * 86_400
    }

    public struct State: Sendable {
        let combined: Data
        let members: [String: Data]
        let expiration: Int64

        public static func load(_ db: Database, groupId: String) throws -> State? {
            guard let row = try Row.fetchOne(db, sql: "SELECT expiration, endorsement FROM groupSendCombinedEndorsement WHERE groupId = ?",
                                             arguments: [groupId]) else { return nil }
            var members: [String: Data] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT memberAci, endorsement FROM groupSendMemberEndorsement WHERE groupId = ?", arguments: [groupId]) {
                members[r["memberAci"]] = r["endorsement"]
            }
            return State(combined: row["endorsement"], members: members, expiration: row["expiration"])
        }

        func member(_ aci: String) throws -> GroupSendEndorsement {
            guard let d = members[aci] else { throw GroupSendEndorsementError.missing(aci) }
            return try GroupSendEndorsement(contents: d)
        }

        /// `buildToken`: the cheapest way to an endorsement for exactly `recipients`.
        public func token(for recipients: Set<String>, ourAci: String, keys: GroupKeys, now: Int64 = Int64(Date().timeIntervalSince1970)) throws -> Data {
            guard GroupSendEndorsements.isValidExpiration(expiration, now: now) else { throw GroupSendEndorsementError.expired("\(expiration)") }
            let endorsement: GroupSendEndorsement
            let all = Set(members.keys)
            if recipients.count == 1, let only = recipients.first {
                endorsement = try member(only)
            } else {
                let missing = recipients.subtracting(all)
                guard missing.isEmpty else { throw GroupSendEndorsementError.missing(missing.sorted().joined(separator: ",")) }
                var others = all.subtracting(recipients)
                let includesOurs = others.remove(ourAci) == nil
                var combined = try GroupSendEndorsement(contents: self.combined)
                if includesOurs { combined = GroupSendEndorsement.combine([combined, try member(ourAci)]) }
                if others.isEmpty {
                    endorsement = combined
                } else if Double(others.count) < Double(members.count) / 2 {
                    endorsement = combined.byRemoving(GroupSendEndorsement.combine(try others.map(member)))
                } else {
                    endorsement = GroupSendEndorsement.combine(try recipients.map(member))
                }
            }
            return endorsement.toFullToken(groupParams: try keys.secret(), expiration: Date(timeIntervalSince1970: TimeInterval(expiration))).serialize()
        }
    }
}
