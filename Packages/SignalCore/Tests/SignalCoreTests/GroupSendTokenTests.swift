// Group send endorsements end to end against a zkgroup server we run ourselves (libsignal's
// issuing side): the mock server does not check group-send tokens, so this is where a token
// built for the wrong set of people would show.

import Foundation
import GRDB
import LibSignalClient
import Testing
@testable import SignalCore

@Suite struct GroupSendTokenTests {
    @Test func tokensVerifyForExactlyTheRecipientsTheyWereBuiltFor() async throws {
        try await LinkedClient.with { c in
            let server = try ServerSecretParams.generate()
            let keys = try GroupKeys.generate()
            let ours = c.account.aci
            let members = [ours] + (0..<6).map { _ in UUID().uuidString.lowercased() }
            let cipher = ClientZkGroupCipher(groupSecretParams: try keys.secret())
            // Endorsements expire on a day boundary; two days out is inside the window we accept.
            let day: TimeInterval = 86_400
            let expiration = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / day).rounded(.down) * day + 2 * day)
            let keyPair = GroupSendDerivedKeyPair.forExpiration(expiration, params: server)
            let response = GroupSendEndorsementsResponse.issue(
                groupMembers: try members.map { try cipher.encrypt(try Aci.parseFrom(serviceIdString: $0)) }, keyPair: keyPair)

            try await GroupSendEndorsements.save(response.serialize(), keys: keys, members: members, account: c.account, database: c.database,
                                                 serverPublicParams: try server.getPublicParams().serialize())
            let state = try #require(try await c.database.pool.read { db in try GroupSendEndorsements.State.load(db, groupId: keys.groupIdBase64) })
            let now = Int64(expiration.timeIntervalSince1970 - day)

            func verifies(_ token: Data, for recipients: Set<String>) -> Bool {
                (try? GroupSendFullToken(contents: token).verify(userIds: recipients.sorted().map { try Aci.parseFrom(serviceIdString: $0) },
                                                                 now: Date(timeIntervalSince1970: TimeInterval(now)), keyPair: keyPair)) != nil
            }
            let others = Set(members.dropFirst())
            let sets: [Set<String>] = [
                [members[1]],                       // one person: their own endorsement
                others,                             // everyone but us: the combined endorsement
                Set(members),                       // everyone, us included
                Set(members[1...2]),                // a few: individual endorsements combined
                others.subtracting([members[3]]),   // most: the combined one minus the rest
                Set(members).subtracting([members[4], members[5]]),
            ]
            for recipients in sets {
                let token = try state.token(for: recipients, ourAci: ours, keys: keys, now: now)
                #expect(verifies(token, for: recipients), "\(recipients.count) recipients")
                // The same token says nothing about anybody else.
                #expect(!verifies(token, for: recipients.union([UUID().uuidString.lowercased()])))
                if recipients.count > 1 { #expect(!verifies(token, for: Set(recipients.dropFirst()))) }
            }
            // Someone who is not a member has no endorsement to build on.
            #expect(throws: GroupSendEndorsementError.self) { try state.token(for: [members[1], UUID().uuidString.lowercased()], ourAci: ours, keys: keys, now: now) }
            // Too close to expiry (upstream: less than two hours left) no token is built.
            #expect(throws: GroupSendEndorsementError.self) {
                try state.token(for: others, ourAci: ours, keys: keys, now: Int64(expiration.timeIntervalSince1970) - 3600)
            }
            // A response issued by another server is not accepted in the first place.
            let stranger = try ServerSecretParams.generate()
            await #expect(throws: (any Error).self) {
                try await GroupSendEndorsements.save(response.serialize(), keys: keys, members: members, account: c.account, database: c.database,
                                                     serverPublicParams: try stranger.getPublicParams().serialize())
            }
        }
    }
}
