// The job queue: production `JobQueue` (start, stop, stopAndWait, poke, its run loop and
// `execute`) against the Lean model in Verification/Queue, on a real database. Handlers are held
// at a gate until the trace says how they end (return, permanent failure, retry, cancellation).
// After each event the rig waits until the actor is quiet (no loop, or the loop waiting, or a
// handler held) and compares with the model's state after all its pending work ran: the
// conformance is for that ("settled") schedule; the proofs are for any schedule.
//
// Run through Tools/verify-queue.sh, or set SEREIN_QUEUE_ORACLE to the oracle executable.

import Foundation
import GRDB
import Synchronization
import Testing
@testable import SignalCore

enum QueueOracle {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Verification/Queue").standardized
    static var path: String {
        ProcessInfo.processInfo.environment["SEREIN_QUEUE_ORACLE"] ?? root.appendingPathComponent(".lake/build/bin/oracle").path
    }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: path) }

    static func call(_ args: [String], input: String = "") throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serein-queue-\(UUID().uuidString)")
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
        guard p.terminationStatus == 0 else { throw IdentityOracle.Failed() }
        return String(decoding: try Data(contentsOf: outURL), as: UTF8.self)
    }

    static func replay(_ traces: [[String]]) throws -> [[String]] {
        var out: [[String]] = []
        for line in try call(["replay"], input: traces.map { $0.joined(separator: " ") }.joined(separator: "\n") + "\n").split(separator: "\n") {
            if line.hasPrefix("T ") { out.append([]) } else { out[out.count - 1].append(String(line.split(separator: " ", maxSplits: 1)[1])) }
        }
        return out
    }
}

struct RigJob: Codable, Sendable { var j: Int }
struct RigRetry: Error {}

enum RigOutcome: Sendable { case ok, permanent, retry, cancelled }

/// What the handlers and the rig share.
final class RigShared: Sendable {
    /// The handler held at its gate: its job, and how to let it go.
    let held = Mutex<(job: Int, release: CheckedContinuation<RigOutcome, Never>)?>(nil)
    /// Handlers running at once (must never exceed one), and the most seen.
    let running = Mutex(0)
    let maxRunning = Mutex(0)
    let returned = Mutex(0)
}

final class QueueRig: @unchecked Sendable {   // driven by one serialized test
    typealias Outcome = RigOutcome
    let db: SignalDatabase
    let queue: JobQueue
    let shared = RigShared()
    var done: [Int] = []
    /// Released to finish (success, permanent failure): done once the queue deleted the row.
    var finishing: [Int] = []
    var stops: [Task<Void, Never>] = []

    init() async throws {
        (db, _) = try LinkedClient.temporaryDatabase()
        queue = JobQueue(database: db, policy: RetryPolicy(maxAttempts: 1_000_000, baseDelay: .zero, maxDelay: .zero))
        let shared = shared
        await queue.register("rig", handler: { job in
            let j = try job.decode(RigJob.self).j
            let now = shared.running.withLock { $0 += 1; return $0 }
            shared.maxRunning.withLock { $0 = max($0, now) }
            let outcome = await withCheckedContinuation { c in shared.held.withLock { $0 = (j, c) } }
            shared.running.withLock { $0 -= 1 }
            switch outcome {
            case .ok: return
            case .permanent: throw JobError.permanent("rig")
            case .retry: throw RigRetry()
            case .cancelled: throw CancellationError()
            }
        })
    }

    func dbJobs() throws -> [Int] {
        try db.pool.read { db in
            try String.fetchAll(db, sql: "SELECT data FROM jobs ORDER BY timestamp, id").compactMap {
                try? JSONDecoder().decode(RigJob.self, from: Data($0.utf8)).j
            }
        }
    }

    struct Snapshot: Equatable {
        var loop: Bool, busy: Bool, waiting: Bool, draining: Int, wants: Bool, held: Int?, returned: Int, db: [Int], stopsLeft: Int
    }

    func snapshot() async throws -> Snapshot {
        let loop = await queue.loop != nil, busy = await queue.busy, waiting = await queue.waiter != nil
        let draining = await queue.draining, wants = await queue.wantsRunning
        return Snapshot(loop: loop, busy: busy, waiting: waiting, draining: draining, wants: wants, held: shared.held.withLock { $0?.job },
                        returned: shared.returned.withLock { $0 }, db: try dbJobs(), stopsLeft: stops.count - shared.returned.withLock { $0 })
    }

    /// Waits until the actor is quiet: no loop, or the loop waiting, or a handler held; every
    /// `stopAndWait` either returned or still has a loop to wait for; unchanged for a while.
    func settle() async throws -> Snapshot {
        var last: Snapshot? = nil, stable = 0
        for _ in 0..<4000 {
            let s = try await snapshot()
            let quiet = (!s.loop || (s.waiting && !s.busy) || (s.busy && s.held != nil)) && (s.loop || s.stopsLeft == 0)
            if quiet, s == last { stable += 1 } else { stable = 0 }
            if stable >= 8 {
                // A finish the queue performed deleted the row; one it did not (a failure while
                // stopping counts as the cancellation) left it.
                for j in finishing where !s.db.contains(j) { done.append(j) }
                finishing = []
                return s
            }
            last = s
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("the queue did not settle: \(String(describing: last))")
        return last!
    }

    func step(_ event: String) async throws {
        let f = event.split(separator: ".").map(String.init)
        switch f[0] {
        case "start": await queue.start()
        case "stop": await queue.stop()
        case "stopwait":
            let queue = queue, shared = shared
            stops.append(Task { await queue.stopAndWait(); shared.returned.withLock { $0 += 1 } })
        case "enqueue":
            let j = Int(f[1])!
            try await db.pool.write { db in _ = try JobQueue.insert(db, queueType: "rig", payload: RigJob(j: j)) }
            queue.poke()
        case "ret":
            let outcome: Outcome = switch f[1] { case "ok": .ok; case "perm": .permanent; case "retry": .retry; default: .cancelled }
            if let h = shared.held.withLock({ h -> (job: Int, release: CheckedContinuation<RigOutcome, Never>)? in let x = h; h = nil; return x }) {
                if outcome == .ok || outcome == .permanent { finishing.append(h.job) }
                h.release.resume(returning: outcome)
            }
        default: Issue.record("unknown event \(event)")
        }
    }

    func observation(_ s: Snapshot) -> String {
        let l = !s.loop ? "none" : s.held.map { "exec.\($0)" } ?? (s.waiting ? "wait" : "busy")
        return "L=\(l) W=\(s.wants ? 1 : 0) D=\(s.draining) DB=[\(s.db.map(String.init).joined(separator: ","))] " +
            "DONE=[\(done.map(String.init).joined(separator: ","))] R=\(s.returned)"
    }

    /// Lets every held handler go and stops the queue (the next trace gets a new rig).
    func finish() async {
        for _ in 0..<100 {
            if let h = shared.held.withLock({ h -> (job: Int, release: CheckedContinuation<RigOutcome, Never>)? in let x = h; h = nil; return x }) {
                h.release.resume(returning: .cancelled)
            }
            await queue.stop()
            if await queue.loop == nil { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        for t in stops { await t.value }
    }
}

@Suite(.serialized, .enabled(if: QueueOracle.available, "build the oracle: Tools/verify-queue.sh, or lake build in Verification/Queue"))
struct QueueConformanceTests {
    func check(_ traces: [[String]], names: [String]) async throws {
        let model = try QueueOracle.replay(traces)
        var reported = 0
        for (k, (t, m)) in zip(traces, model).enumerated() {
            let rig = try await QueueRig()
            var swift: [String] = []
            for e in t {
                try await rig.step(e)
                swift.append(rig.observation(try await rig.settle()))
            }
            let concurrent = rig.shared.maxRunning.withLock { $0 }
            await rig.finish()
            let name = names.count > k && !names[k].isEmpty ? " (\(names[k]))" : ""
            if concurrent > 1 {
                reported += 1
                Issue.record("disagree\(name) at step 0 (two handlers ran at once)\n  trace: \(t.joined(separator: " "))")
                continue
            }
            guard let i = zip(m, swift).enumerated().first(where: { $1.0 != $1.1 })?.offset else { continue }
            reported += 1
            if reported <= 3 {
                Issue.record("disagree\(name) at step \(i) (\(t[i]))\n  model \(m[i])\n  swift \(swift[i])\n  trace: \(t.joined(separator: " "))")
            }
        }
        #expect(reported == 0, "\(reported) of \(traces.count) traces disagree")
    }

    @Test func regressionTraces() async throws {
        let text = try String(contentsOf: QueueOracle.root.appendingPathComponent("traces/regressions.txt"), encoding: .utf8)
        var traces: [[String]] = [], names: [String] = [], name = ""
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { name = String(line.dropFirst().split(separator: ":").first ?? "").trimmingCharacters(in: .whitespaces); continue }
            if line.isEmpty { continue }
            traces.append(line.split(separator: " ").map(String.init)); names.append(name); name = ""
        }
        #expect(traces.count >= 8)
        try await check(traces, names: names)
    }

    @Test func randomTraces() async throws {
        let count = ProcessInfo.processInfo.environment["SEREIN_QUEUE_TRACES"].flatMap { Int($0) } ?? 150
        let traces = try QueueOracle.call(["gen", "1111", "\(count)", "16"]).split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        try await check(traces, names: [])
    }
}
