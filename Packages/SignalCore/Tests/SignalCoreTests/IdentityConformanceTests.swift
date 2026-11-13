// Identity approval: production SignalCore against the Lean model in Verification/Identity, step
// by step, on a real (temporary, encrypted) database. Driven through the APIs the app and the
// receive path use: `Messenger.safetyNumber(with:)` (the review the UI shows),
// `approveIdentities`, `setVerified`, `ProtocolStore.saveIdentity`, `StorageRecords.mergeContact`,
// and the VerifiedSync job's `verifiedSyncMessage`. Nothing is sent: queued syncs are run through
// the job's message builder, which is what the job sends.
//
// Run through Tools/verify-identity.sh (it builds the oracle first), or set
// SEREIN_IDENTITY_ORACLE to the oracle executable.

import Foundation
import GRDB
import LibSignalClient
import SignalProtos
import Synchronization
import Testing
@testable import SignalCore

enum IdentityOracle {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Verification/Identity").standardized
    static var path: String {
        ProcessInfo.processInfo.environment["SEREIN_IDENTITY_ORACLE"] ?? root.appendingPathComponent(".lake/build/bin/oracle").path
    }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: path) }

    struct Failed: Error {}

    static func call(_ args: [String], input: String = "") throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serein-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inURL = dir.appendingPathComponent("in.txt"), outURL = dir.appendingPathComponent("out.txt")
        try Data(input.utf8).write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = try FileHandle(forReadingFrom: inURL)
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failed() }
        return String(decoding: try Data(contentsOf: outURL), as: UTF8.self)
    }

    /// The model's observations, per trace.
    static func replay(_ traces: [IdentityTrace]) throws -> [[String]] {
        var out: [[String]] = []
        for line in try call(["replay"], input: traces.map(\.line).joined(separator: "\n") + "\n").split(separator: "\n") {
            if line.hasPrefix("T ") { out.append([]) } else { out[out.count - 1].append(String(line.split(separator: " ", maxSplits: 1)[1])) }
        }
        return out
    }
}

struct IdentityTrace {
    var name: String
    var events: [String]
    var line: String { events.joined(separator: " ") }

    /// `# name: …` comments followed by trace lines.
    static func parse(_ text: String) -> [IdentityTrace] {
        var out: [IdentityTrace] = []
        var name = ""
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                name = String(line.dropFirst().split(separator: ":").first ?? "").trimmingCharacters(in: .whitespaces)
            } else {
                out.append(IdentityTrace(name: name, events: line.split(separator: " ").map(String.init)))
                name = ""
            }
        }
        return out
    }
}

/// The environment the model's numbers stand for: three contacts, four identity keys they may
/// have, and our accounts (two ACIs × two identity keys), each with its own `Messenger` over the
/// same database.
final class IdentityRig: @unchecked Sendable {   // used by one serialized test at a time
    let db: SignalDatabase
    let jobs: JobQueue
    let socket: SocketManager
    let peers = (0..<3).map { _ in UUID().uuidString.lowercased() }
    let peerKeys = (0..<4).map { _ in IdentityKeyPair.generate() }
    let ourAcis = (0..<2).map { _ in UUID().uuidString.lowercased() }
    let ourKeys = (0..<2).map { _ in IdentityKeyPair.generate() }
    var messengers: [Int: Messenger] = [:]
    var current = (0, 0)
    var held: [ReviewedIdentity] = []
    var pending: [[ReviewedIdentity]] = []
    var sent: [String] = []
    var last = "-"

    init() throws {
        (db, _) = try LinkedClient.temporaryDatabase()
        jobs = JobQueue(database: db)
        socket = SocketManager(net: Net(env: .staging, userAgent: "SignalSafe-Tests", buildVariant: .production))
        let peers = self.peers
        try db.pool.write { db in for p in peers { _ = try MessageStore.privateConversation(db, serviceId: p) } }
    }

    func account(_ a: Int, _ k: Int) -> Account {
        Account(aci: ourAcis[a], pni: nil, number: "+14155550100", deviceId: 2, password: "pw", deviceName: "rig",
                aciIdentity: ourKeys[k], pniIdentity: nil, aciRegistrationId: 1, pniRegistrationId: nil, profileKey: nil,
                masterKey: nil, accountEntropyPool: nil, readReceipts: false)
    }

    var messenger: Messenger {
        let key = current.0 * 2 + current.1
        if let m = messengers[key] { return m }
        let m = Messenger(account: account(current.0, current.1), database: db, socket: socket, trustRoots: [], jobs: jobs)
        messengers[key] = m
        return m
    }

    func reset() throws {
        try db.pool.write { db in
            try account(0, 0).save(db)
            try db.execute(sql: "DELETE FROM identityKeys")
            try db.execute(sql: "DELETE FROM messages")
            try db.execute(sql: "DELETE FROM jobs")
        }
        current = (0, 0)
        held = []; pending = []; sent = []; last = "-"
    }

    func saveKey(_ db: Database, _ p: Int, _ k: Int) throws {
        try account(current.0, current.1).aciStore().saveIdentity(db, peerKeys[k].identityKey, for: try ProtocolAddress(name: peers[p], deviceId: 1))
    }

    func approve(_ xs: [ReviewedIdentity]) async -> String {
        do { try await messenger.approveIdentities(xs); return "ok" } catch IdentityReviewError.identityChanged { return "stale" } catch {
            return "error(\(error))"
        }
    }

    /// The queued VerifiedSync jobs, in run order.
    func syncJobs() throws -> [(String, ConversationJob)] {
        try db.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, data FROM jobs WHERE queueType = ? ORDER BY timestamp", arguments: [ConversationJob.queueType])
                .compactMap { row -> (String, ConversationJob)? in
                    guard let data = (row["data"] as String?)?.data(using: .utf8),
                          let job = try? JSONDecoder().decode(ConversationJob.self, from: data), job.type == .verifiedSync else { return nil }
                    return (row["id"], job)
                }
        }
    }

    func peerIndex(_ serviceId: String?) -> String { serviceId.flatMap { s in peers.firstIndex(of: s.lowercased()) }.map(String.init) ?? "?" }
    func keyIndex(_ key: Data?) -> String { key.flatMap { k in peerKeys.firstIndex { $0.identityKey.serialize() == k } }.map(String.init) ?? "?" }

    func step(_ event: String) async throws {
        last = "-"
        let f = event.split(separator: ".").map(String.init)
        let n = { (i: Int) in Int(f[i])! }
        switch f[0] {
        case "show":
            if let number = try? await messenger.safetyNumber(with: peers[n(1)]) { held.append(number.identity) }
        case "confirm":
            pending.append(f.dropFirst().compactMap { Int($0) }.compactMap { $0 < held.count ? held[$0] : nil })
        case "commit":
            last = await approve(pending.remove(at: n(1)))
        case "race":
            // The key change holds the database's writer; the commit starts while it waits. A
            // commit that validates outside its transaction reads the old key meanwhile.
            let xs = pending.remove(at: n(1))
            let (p, k) = (n(2), n(3))
            let started = Mutex(false)
            let release = DispatchSemaphore(value: 0)
            let writer = Task.detached { [self] in
                try await db.pool.write { db in
                    started.withLock { $0 = true }
                    release.wait()
                    try self.saveKey(db, p, k)
                }
            }
            while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
            let commit = Task { await self.approve(xs) }
            try await Task.sleep(for: .milliseconds(40))
            release.signal()
            try await writer.value
            last = await commit.value
        case "verify":
            do {
                try await messenger.setVerified(held[n(1)], f[2] == "1")
                last = "ok"
            } catch IdentityReviewError.identityChanged { last = "stale" } catch { last = "error(\(error))" }
        case "key":
            let (p, k) = (n(1), n(2))
            try await db.pool.write { db in try self.saveKey(db, p, k) }
        case "acct":
            current = (n(1), n(2))
            let active = account(current.0, current.1)
            try await db.pool.write { try active.save($0) }
        case "win":
            let id = peers[n(1)]
            try await db.pool.write { db in
                try db.execute(sql: "UPDATE identityKeys SET json = json_set(json, '$.timestamp', json_extract(json, '$.timestamp') - ?) WHERE id = ?",
                               arguments: [ProtocolStore.approvalWindow + 60_000, id])
            }
        case "store":
            var c = Signalservice_ContactRecord()
            c.aci = peers[n(1)]
            c.identityKey = peerKeys[n(2)].identityKey.serialize()
            c.identityState = f[3] == "V" ? .verified : f[3] == "U" ? .unverified : .default
            let ctx = StorageMergeContext(account: account(current.0, current.1), version: 1, isFirstSync: f[4] == "1", now: MessageStore.now(),
                                          messageQueueTime: 0, binaryServiceIds: false, sender: messenger.sender)
            let record = c, storageID = "rig-\(f[1])"
            try await db.pool.write { db in _ = try StorageRecords.mergeContact(db, record, storageID: storageID, ctx: ctx) }
        case "sync":
            let (id, job) = try syncJobs()[n(1)]
            let message = try await messenger.verifiedSyncMessage(job)
            let v = message.verified
            sent.append("\(peerIndex(StorageLocal.uuidString(v.destinationAciBinary)))." +
                        "\(keyIndex(v.identityKey)).\(v.state == .verified ? "1" : "0")")
            try await db.pool.write { db in try db.execute(sql: "DELETE FROM jobs WHERE id = ?", arguments: [id]) }
        default:
            Issue.record("unknown event \(event)")
        }
    }

    func observation() throws -> String {
        let queued = try syncJobs().map { (_, j) in
            "\(peerIndex(j.requester)).\(keyIndex(j.identityKey.flatMap { Data(base64Encoded: $0) })).\(j.verified == true ? "1" : "0")"
        }
        let rows = try db.pool.read { db -> [String] in
            try peers.map { p in
                let row: String
                if let r = try ProtocolStore.identityRow(db, serviceId: p) {
                    let recent = r.timestamp > MessageStore.now() - ProtocolStore.approvalWindow
                    let v = r.verifiedStatus == .verified ? "V" : r.verifiedStatus == .unverified ? "U" : "D"
                    row = "\(keyIndex(r.key)).\(r.firstUse ? 1 : 0).\(recent ? 1 : 0).\(v).\(r.nonblockingApproval ? 1 : 0)"
                } else {
                    row = "-"
                }
                let conversation = try MessageStore.privateConversation(db, serviceId: p)
                let keyChanges = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages WHERE type = 'keychange' AND json ->> '$.key_changed' = ?",
                                                  arguments: [p]) ?? 0
                let notices = { (local: Int) in
                    try Int.fetchOne(db, sql: """
                        SELECT count(*) FROM messages WHERE type = 'verified-change' AND conversationId = ? AND json_extract(json, '$.local') = ?
                        """, arguments: [conversation, local]) ?? 0
                }
                return "\(row)/\(keyChanges).\(try notices(1)).\(try notices(0))"
            }
        }
        return "A=\(current.0).\(current.1) R=\(rows.joined(separator: ",")) H=\(held.count) P=\(pending.count) " +
            "J=[\(queued.joined(separator: ","))] T=[\(sent.joined(separator: ","))] L=\(last)"
    }

    func run(_ t: IdentityTrace) async throws -> [String] {
        try reset()
        var out: [String] = []
        for e in t.events {
            try await step(e)
            out.append(try observation())
        }
        return out
    }
}

@Suite(.serialized, .enabled(if: IdentityOracle.available, "build the oracle: Tools/verify-identity.sh, or lake build in Verification/Identity"))
struct IdentityConformanceTests {
    func check(_ traces: [IdentityTrace]) async throws {
        let rig = try IdentityRig()
        let model = try IdentityOracle.replay(traces)
        var reported = 0
        for (t, m) in zip(traces, model) {
            let swift = try await rig.run(t)
            guard let k = zip(m, swift).enumerated().first(where: { $1.0 != $1.1 })?.offset ?? (m.count == swift.count ? nil : min(m.count, swift.count))
            else { continue }
            reported += 1
            if reported <= 3 {
                let mf = k < m.count ? m[k].split(separator: " ") : [], sf = k < swift.count ? swift[k].split(separator: " ") : []
                let diff = zip(mf, sf).filter { $0 != $1 }.map { "model \($0) | swift \($1)" }
                Issue.record("""
                    disagree\(t.name.isEmpty ? "" : " (\(t.name))") at step \(k) (\(k < t.events.count ? t.events[k] : "?"))
                      \(diff.joined(separator: "\n  "))
                      trace: \(t.line)
                    """)
            }
        }
        #expect(reported == 0, "\(reported) of \(traces.count) traces disagree")
    }

    @Test func regressionTraces() async throws {
        let traces = IdentityTrace.parse(try String(contentsOf: IdentityOracle.root.appendingPathComponent("traces/regressions.txt"), encoding: .utf8))
        #expect(traces.count >= 20)
        try await check(traces)
    }

    @Test func randomTraces() async throws {
        let count = ProcessInfo.processInfo.environment["SEREIN_IDENTITY_TRACES"].flatMap { Int($0) } ?? 300
        let traces = IdentityTrace.parse(try IdentityOracle.call(["gen", "20261111", "\(count)", "40"]))
        try await check(traces)
    }
}
