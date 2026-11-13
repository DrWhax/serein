// Group authorization and sender-key rotation: production SignalCore's decisions against the
// Lean model in Verification/Group — `GroupSendPlan.make` (who a send goes to, from the membership
// when it plans), `SenderKeyInfo.rotation` and `recording` (when our key is replaced, who gets
// it, what is recorded), `MessageSender.authorization` for group payloads (the submission check
// against the local membership, on a real database) and `OutgoingPayload.isGroupUpdateOnly`.
//
// Run through Tools/verify-group.sh, or set SEREIN_GROUP_ORACLE to the oracle executable.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import Testing
@testable import SignalCore

enum GroupOracle {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Verification/Group").standardized
    static var path: String {
        ProcessInfo.processInfo.environment["SEREIN_GROUP_ORACLE"] ?? root.appendingPathComponent(".lake/build/bin/oracle").path
    }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: path) }

    static func call(_ mode: String, _ lines: [String]) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serein-group-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inURL = dir.appendingPathComponent("in.txt"), outURL = dir.appendingPathComponent("out.txt")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [mode]
        p.standardInput = try FileHandle(forReadingFrom: inURL)
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw IdentityOracle.Failed() }
        return String(decoding: try Data(contentsOf: outURL), as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

func list(_ xs: [Int]) -> String { xs.isEmpty ? "-" : xs.map(String.init).joined(separator: ",") }

func compare(_ lines: [String], model: [String], swift: [String]) {
    var reported = 0
    for (k, (m, s)) in zip(model, swift).enumerated() where m != s {
        reported += 1
        if reported <= 3 { Issue.record("disagree at step \(k) (\(lines[k]))\n  model \(m) | swift \(s)") }
    }
    #expect(model.count == lines.count && reported == 0, "\(reported) of \(lines.count) cases disagree")
}

@Suite(.serialized, .enabled(if: GroupOracle.available, "build the oracle: Tools/verify-group.sh, or lake build in Verification/Group"))
struct GroupConformanceTests {
    static var count: Int { ProcessInfo.processInfo.environment["SEREIN_GROUP_CASES"].flatMap { Int($0) } ?? 3000 }
    let accounts = (0..<6).map { _ in UUID().uuidString.lowercased() }
    let ourAci = UUID().uuidString.lowercased()

    @Test func randomPlans() throws {
        var r = SplitMix(s: 41)
        var lines: [String] = [], swift: [String] = []
        for _ in 0..<Self.count {
            let members = (0..<6).filter { _ in r.coin() }
            let rs = (0..<(r.below(6))).map { _ in r.below(6) }
            let update = r.coin(3)
            var asked = rs.map { accounts[$0] }
            if r.coin(4) { asked.append(ourAci) }   // we are never a recipient
            let plan = GroupSendPlan.make(recipients: asked, members: Set(members.map { accounts[$0] } + [ourAci]), ourAci: ourAci, update: update)
            let idx = { (xs: [String]) in xs.compactMap { accounts.firstIndex(of: $0) }.sorted() }
            lines.append("\(list(members)) | \(list(rs)) | \(update ? 1 : 0)")
            swift.append("\(list(idx(plan.members))) \(list(idx(plan.outside))) \(list(idx(plan.dropped)))")
        }
        compare(lines, model: try GroupOracle.call("plan", lines), swift: swift)
    }

    @Test func randomRotations() throws {
        var r = SplitMix(s: 43)
        var lines: [String] = [], swift: [String] = []
        func device(_ a: Int, _ d: Int) -> SenderKeyInfo.Device { .init(id: UInt32(d), serviceId: accounts[a], registrationId: 7) }
        for _ in 0..<Self.count {
            let distributed = (0..<r.below(6)).map { _ in (r.below(5), r.below(3)) }
            let targets = (0..<5).filter { _ in r.coin() }
            let current = targets.flatMap { a in (0..<3).filter { _ in r.coin() }.map { (a, $0) } }
            let rot = SenderKeyInfo.rotation(distributed: distributed.map { device($0.0, $0.1) }, current: Set(current.map { device($0.0, $0.1) }),
                                             targets: Set(targets.map { accounts[$0] }))
            // `recording` adds, never replaces.
            let recorded = SenderKeyInfo.recording(distributed.map { device($0.0, $0.1) }, adding: rot.distribute)
            let union = Set(distributed.map { device($0.0, $0.1) }).union(rot.distribute)
            if Set(recorded) != union || recorded.count != union.count { Issue.record("recording is not the union") }
            let code = { (xs: [(Int, Int)]) in
                xs.isEmpty ? "-" : Array(Set(xs.map { "\($0.0):\($0.1)" })).sorted { a, b in
                    let x = a.split(separator: ":").map { Int($0)! }, y = b.split(separator: ":").map { Int($0)! }
                    return x[0] != y[0] ? x[0] < y[0] : x[1] < y[1]
                }.joined(separator: ",")
            }
            lines.append("\(code(distributed)) | \(code(current)) | \(list(targets))")
            let given = rot.distribute.map { (accounts.firstIndex(of: $0.serviceId)!, Int($0.id)) }
            swift.append("\(rot.reset ? 1 : 0) \(code(given))")
        }
        compare(lines, model: try GroupOracle.call("rotation", lines), swift: swift)
    }

    @Test func randomBoundaries() async throws {
        let (db, _) = try LinkedClient.temporaryDatabase()
        let account = Account(aci: ourAci, pni: nil, number: "+14155550100", deviceId: 2, password: "pw", deviceName: "rig",
                              aciIdentity: .generate(), pniIdentity: nil, aciRegistrationId: 1, pniRegistrationId: nil, profileKey: nil,
                              masterKey: nil, accountEntropyPool: nil, readReceipts: false)
        let sender = MessageSender(account: account, database: db, socket: SocketManager(net: Net(env: .staging, userAgent: "SignalSafe-Tests",
                                                                                                    buildVariant: .production)), trustRoots: [])
        let keys = try GroupKeys(masterKey: Data(repeating: 4, count: 32))
        let conversation = try await db.pool.write { try GroupStore.conversation($0, keys: keys).conversationId }
        var r = SplitMix(s: 47)
        var lines: [String] = [], swift: [String] = []
        let ourAci = ourAci, accounts = accounts
        for _ in 0..<Self.count {
            let members = (0..<6).filter { _ in r.coin() }
            var state = GroupV2State()
            state.membersV2 = (members.map { accounts[$0] } + [ourAci]).map { GroupMember(aci: $0, role: 1, joinedAtVersion: 0) }
            let saved = state
            try await db.pool.write { db in try GroupStore.save(db, conversationId: conversation, state: saved, ourAci: ourAci) }
            // The payload: a DataMessage with or without a group context, with or without content.
            var data = Signalservice_DataMessage()
            data.timestamp = 1
            let group = r.coin(4) == false
            if group {
                var ctx = Signalservice_GroupContextV2()
                ctx.masterKey = keys.masterKey
                ctx.revision = 2
                if r.coin() { ctx.groupChange = Data([1, 2, 3]) }
                data.groupV2 = ctx
            }
            if r.coin() { data.profileKey = Data(repeating: 1, count: 32) }
            let extra = r.coin()
            if extra {
                switch r.below(4) {
                case 0: data.body = "hi"
                case 1: data.expireTimer = 60
                case 2:
                    var re = Signalservice_DataMessage.Reaction()
                    re.emoji = "x"
                    data.reaction = re
                default:
                    var a = Signalservice_AttachmentPointer()
                    a.cdnKey = "k"
                    data.attachments = [a]
                }
            }
            var content = Signalservice_Content()
            content.dataMessage = data
            if r.coin(6) {
                // A sender-key distribution message: never a group update.
                content = Signalservice_Content()
                content.senderKeyDistributionMessage = Data([9])
            }
            let payload = OutgoingPayload(content: content, timestamp: 1)
            let addressed = (0..<(1 + r.below(3))).map { _ in r.below(6) }
            let single = r.coin()
            let ids = (single ? [addressed[0]] : addressed)
            let isSKDM = content.senderKeyDistributionMessage.isEmpty == false
            lines.append("\(list(members)) | \(list(ids)) | \(group && !isSKDM ? 1 : 0) \(extra || isSKDM ? 1 : 0)")
            let authorize = single
                ? sender.authorization(to: accounts[addressed[0]], groupId: keys.groupId, messageIds: [], groupUpdate: payload.isGroupUpdateOnly)
                : sender.authorization(to: nil, groupId: keys.groupId, messageIds: [], groupUpdate: payload.isGroupUpdateOnly,
                                       recipients: addressed.map { accounts[$0] })
            let allowed: Bool
            do { try authorize(); allowed = true } catch SendError.notAMember { allowed = false } catch {
                Issue.record("unexpected \(error)")
                allowed = false
            }
            swift.append("\(allowed ? 1 : 0) \(payload.isGroupUpdateOnly ? 1 : 0)")
        }
        compare(lines, model: try GroupOracle.call("auth", lines), swift: swift)
    }
}

/// Exercises the database operations used around network awaits, rather than just the union helper.
@Suite(.serialized)
struct GroupReservationTests {
    private struct Rig {
        let db: SignalDatabase
        let group: GroupSender
        let keys: GroupKeys
        let conversation: String
        let members: [String]

        init() async throws {
            let (db, _) = try LinkedClient.temporaryDatabase()
            let ours = UUID().uuidString.lowercased()
            let members = (0..<3).map { _ in UUID().uuidString.lowercased() }
            let account = Account(aci: ours, pni: nil, number: "+14155550100", deviceId: 2, password: "pw", deviceName: "rig",
                                  aciIdentity: .generate(), pniIdentity: nil, aciRegistrationId: 1, pniRegistrationId: nil, profileKey: nil,
                                  masterKey: nil, accountEntropyPool: nil, readReceipts: false)
            let socket = SocketManager(net: Net(env: .staging, userAgent: "SignalSafe-Tests", buildVariant: .production))
            let sender = MessageSender(account: account, database: db, socket: socket, trustRoots: [])
            let keys = try GroupKeys(masterKey: Data(repeating: 8, count: 32))
            let conversation = try await db.pool.write { db in
                let id = try GroupStore.conversation(db, keys: keys).conversationId
                var state = GroupV2State()
                state.membersV2 = (members + [ours]).map { GroupMember(aci: $0, role: 1, joinedAtVersion: 0) }
                try GroupStore.save(db, conversationId: id, state: state, ourAci: ours)
                return id
            }
            self.db = db
            self.group = GroupSender(account: account, database: db, socket: socket, sender: sender)
            self.keys = keys
            self.conversation = conversation
            self.members = members
        }

        func device(_ member: Int, _ id: UInt32 = 1) -> SenderKeyInfo.Device {
            .init(id: id, serviceId: members[member], registrationId: 7)
        }

        func prepare(_ devices: Set<SenderKeyInfo.Device>) async throws -> SenderKeyInfo {
            try await db.pool.write { db in
                try group.prepareSenderKey(db, conversationId: conversation, groupId: keys.groupId, current: devices, targets: Set(devices.map(\.serviceId))).0
            }
        }

        func delivered(_ info: SenderKeyInfo, _ devices: Set<SenderKeyInfo.Device>) async throws {
            let generation = try #require(info.generation)
            try await db.pool.write { db in
                try GroupSender.recordSenderKeyDelivery(db, conversationId: conversation, generation: generation, devices: devices)
            }
        }

        func authorization(_ info: SenderKeyInfo, recipients: [String]) throws -> @Sendable () throws -> Void {
            let generation = try #require(info.generation)
            return group.sender.authorization(to: nil, groupId: keys.groupId, messageIds: [], recipients: recipients,
                senderKey: .init(conversationId: conversation, generation: generation))
        }

        func authorize(_ info: SenderKeyInfo, recipients: [String]) throws {
            try authorization(info, recipients: recipients)()
        }
    }

    private actor Gate {
        private var arrivals = 0
        private var blocked: [CheckedContinuation<Void, Never>] = []
        private var ready: CheckedContinuation<Void, Never>?
        func arrive() async {
            arrivals += 1
            await withCheckedContinuation { continuation in
                blocked.append(continuation)
                if arrivals == 2 { ready?.resume(); ready = nil }
            }
        }
        func waitForBoth() async {
            if arrivals == 2 { return }
            await withCheckedContinuation { ready = $0 }
        }
        func release() { for c in blocked { c.resume() }; blocked = [] }
    }

    @Test func overlappingReservationsPersistBeforeDelivery() async throws {
        let r = try await Rig()
        let gate = Gate()
        let a = Set([r.device(0), r.device(1)])
        let b = Set([r.device(0, 2), r.device(1, 2)])
        // Both sends remain suspended before delivery. Their reservations must already be durable.
        func pending(_ devices: Set<SenderKeyInfo.Device>) async throws -> SenderKeyInfo {
            let info: SenderKeyInfo
            do { info = try await r.prepare(devices) } catch { await gate.arrive(); throw error }
            await gate.arrive()
            try await r.delivered(info, devices)
            return info
        }
        let first = Task { try await pending(a) }
        let second = Task { try await pending(b) }
        await gate.waitForBoth()
        let stored = try await r.db.pool.read { try GroupSender.storedInfo($0, r.conversation) }
        await gate.release()
        let (x, y) = try await (first.value, second.value)
        #expect(x.generation == y.generation)
        #expect(Set(stored?.memberDevices ?? []) == a.union(b), "persisted reservations lost a concurrent send")
        #expect(stored?.deliveredDevices?.isEmpty == true)
        let completed = try await r.db.pool.read { try GroupSender.storedInfo($0, r.conversation) }
        #expect(Set(completed?.deliveredDevices ?? []) == a.union(b), "delivery completion lost a concurrent send")
        try r.authorize(x, recipients: r.members)
        try r.authorize(y, recipients: r.members)
    }

    @Test func removalInvalidatesEncryptionAndSubmission() async throws {
        let r = try await Rig()
        let info = try await r.prepare(Set([r.device(0), r.device(1), r.device(2)]))
        let authorize = try r.authorization(info, recipients: Array(r.members.dropFirst()))
        try authorize()
        try await r.db.pool.write { db in
            var state = GroupV2State()
            state.membersV2 = (Array(r.members.dropFirst()) + [r.group.account.aci]).map {
                GroupMember(aci: $0, role: 1, joinedAtVersion: 0)
            }
            try GroupStore.save(db, conversationId: r.conversation, state: state, ourAci: r.group.account.aci)
        }
        // All addressed recipients remain members, but another holder of the key was removed.
        #expect(throws: SendError.notAMember(r.members[0])) {
            try authorize()
        }
        let generation = try #require(info.generation)
        #expect(throws: SendError.notAMember(r.members[0])) {
            try r.db.pool.read { db in
                try GroupSender.authorizeSenderKey(db, conversationId: r.conversation, generation: generation, groupId: r.keys.groupId)
            }
        }
    }

    @Test func resetRejectsOldGenerationAndRetiresReservations() async throws {
        let r = try await Rig()
        let old = try await r.prepare(Set([r.device(0)]))
        let fresh = try await r.db.pool.write { db in
            try r.group.resetSenderKey(db, conversationId: r.conversation, previous: old)
        }
        #expect(old.distributionId == fresh.distributionId)
        #expect(old.generation != fresh.generation)
        #expect(fresh.memberDevices.isEmpty)
        #expect(throws: SendError.notAMember("sender key changed")) { try r.authorize(old, recipients: r.members) }
        do {
            try await r.delivered(old, Set([r.device(0)]))
            Issue.record("stale delivery restored a retired generation")
        } catch SendError.notAMember {} catch { throw error }
        let next = try await r.prepare(Set([r.device(1)]))
        #expect(next.generation == fresh.generation)
        #expect(next.memberDevices == [r.device(1)], "old send restored retired reservations")
        try r.authorize(next, recipients: r.members)
    }
    @Test func interruptedReservationStillDistributesOnRetry() async throws {
        let r = try await Rig()
        let devices = Set([r.device(0), r.device(1)])
        let first = try await r.prepare(devices)
        let (retry, give) = try await r.db.pool.write { db in
            try r.group.prepareSenderKey(db, conversationId: r.conversation, groupId: r.keys.groupId, current: devices, targets: Set(devices.map(\.serviceId)))
        }
        #expect(retry.generation == first.generation)
        #expect(give == devices, "reservation incorrectly counted as completed delivery")
        try await r.delivered(retry, devices)
        let (_, remaining) = try await r.db.pool.write { db in
            try r.group.prepareSenderKey(db, conversationId: r.conversation, groupId: r.keys.groupId, current: devices, targets: Set(devices.map(\.serviceId)))
        }
        #expect(remaining.isEmpty)
    }

    @Test func legacyStateGetsAFreshGeneration() async throws {
        let r = try await Rig()
        let legacy = SenderKeyInfo(createdAtDate: MessageStore.now(), distributionId: UUID().uuidString.lowercased(), memberDevices: [r.device(0)])
        try await r.db.pool.write { try GroupSender.saveInfo($0, r.conversation, legacy) }
        let info = try await r.prepare(Set([r.device(1)]))
        #expect(info.generation != nil)
        #expect(info.distributionId == legacy.distributionId)
        #expect(info.memberDevices == [r.device(1)])
        #expect(info.deliveredDevices == [])
    }

    @Test func identityChangeDuringDistributionInvalidatesTheReservedKey() async throws {
        let r = try await Rig()
        let address = try ProtocolAddress(name: r.members[0], deviceId: 1)
        try await r.db.pool.write { db in
            _ = try r.group.sender.store.saveIdentity(db, IdentityKeyPair.generate().identityKey, for: address)
        }
        let devices = Set([r.device(0), r.device(1)])
        let ticket = try await r.prepare(devices)
        // A distribution is in flight when a different identity is learned.
        try await r.db.pool.write { db in
            _ = try r.group.sender.store.saveIdentity(db, IdentityKeyPair.generate().identityKey, for: address)
        }
        try await r.delivered(ticket, devices)
        #expect(throws: SendError.notAMember("sender key changed")) { try r.authorize(ticket, recipients: r.members) }
        let next = try await r.prepare(devices)
        #expect(next.generation != ticket.generation)
        #expect(next.deliveredDevices == [])
    }

}
