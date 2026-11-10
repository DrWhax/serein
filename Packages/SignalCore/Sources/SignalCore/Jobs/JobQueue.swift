// Persistent job queue over the upstream `jobs` table (ts/jobs/JobQueue.std.ts +
// JobQueueDatabaseStore): a job row is inserted in the same transaction as the state
// change that needs it (an outgoing message, a received message that owes a receipt),
// so a crash can never lose a send. Jobs run one at a time in insertion order; a
// failed job is retried with exponential backoff until it succeeds, throws
// `JobError.permanent`, or runs out of attempts. Rows are deleted only after the job
// finished (success or final failure).

import Foundation
import GRDB

public struct Job: Sendable {
    public let id: String
    public let queueType: String
    public let timestamp: Int64
    public let data: Data          // JSON payload

    public func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(T.self, from: data) }
}

public enum JobError: Error, Equatable {
    /// Retrying cannot help (unregistered recipient, malformed job, …).
    case permanent(String)
}

public enum JobEvent: Sendable {
    case succeeded(Job)
    case failed(Job, error: String, final: Bool)
}

public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration
    public init(maxAttempts: Int = 8, baseDelay: Duration = .seconds(1), maxDelay: Duration = .seconds(300)) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }
    func delay(afterAttempt n: Int) -> Duration { min(baseDelay * (1 << min(n - 1, 20)), maxDelay) }
}

public actor JobQueue {
    public typealias Handler = @Sendable (Job) async throws -> Void
    /// Called after a job's final failure (e.g. to mark a message as failed).
    public typealias FailureHandler = @Sendable (Job, any Error) async -> Void

    let database: SignalDatabase
    let policy: RetryPolicy
    var handlers: [String: Handler] = [:]
    var failureHandlers: [String: FailureHandler] = [:]
    var attempts: [String: Int] = [:]
    var notBefore: [String: ContinuousClock.Instant] = [:]
    var waiter: CheckedContinuation<Void, Never>?
    var loop: Task<Void, Never>?
    var wantsRunning = false
    var draining = 0
    var busy = false

    public nonisolated let events: AsyncStream<JobEvent>
    let sink: AsyncStream<JobEvent>.Continuation

    public init(database: SignalDatabase, policy: RetryPolicy = RetryPolicy()) {
        self.database = database
        self.policy = policy
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: enqueue

    /// Inserts a job inside the caller's write transaction. Call `poke()` after the commit.
    @discardableResult
    public static func insert(_ db: Database, queueType: String, payload: some Encodable) throws -> String {
        let id = UUID().uuidString.lowercased()
        let data = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        // Monotonic per database so the run order is the insertion order even within one millisecond.
        let last = try Int64.fetchOne(db, sql: "SELECT max(timestamp) FROM jobs") ?? 0
        try db.execute(sql: "INSERT INTO jobs (id, queueType, timestamp, data) VALUES (?, ?, ?, ?)",
                       arguments: [id, queueType, max(last + 1, MessageStore.now()), data])
        return id
    }

    @discardableResult
    public func enqueue(queueType: String, payload: some Encodable & Sendable) throws -> String {
        let id = try database.pool.write { db in try Self.insert(db, queueType: queueType, payload: payload) }
        poke()
        return id
    }

    // MARK: handlers and run loop

    public func register(_ queueType: String, handler: @escaping Handler, onFailure: FailureHandler? = nil) {
        handlers[queueType] = handler
        failureHandlers[queueType] = onFailure
        poke()
    }

    /// Starts processing (including jobs persisted by a previous run).
    public func start() {
        guard draining == 0 else { return }
        wantsRunning = true
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    public func stop() {
        wantsRunning = false
        loop?.cancel()
        poke()
    }

    /// Returns only after the active handler and its database work have finished.
    public func stopAndWait() async {
        draining += 1
        let running = loop
        stop()
        await running?.value
        draining -= 1
    }

    /// Wakes the run loop (new job committed).
    public nonisolated func poke() { Task { await self.wake() } }

    func wake() {
        waiter?.resume()
        waiter = nil
    }

    func nextJob() throws -> (Job?, ContinuousClock.Instant?) {
        let now = ContinuousClock.now
        let rows = try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, queueType, timestamp, data FROM jobs ORDER BY timestamp, id")
        }
        var earliest: ContinuousClock.Instant?
        for row in rows {
            let job = Job(id: row["id"], queueType: row["queueType"], timestamp: row["timestamp"], data: Data((row["data"] as String? ?? "").utf8))
            guard handlers[job.queueType] != nil else { continue }
            if let t = notBefore[job.id], t > now {
                earliest = min(earliest ?? t, t)
                continue
            }
            return (job, nil)
        }
        return (nil, earliest)
    }

    func run() async {
        defer {
            loop = nil
            if wantsRunning { start() }
        }
        while !Task.isCancelled {
            let next: (Job?, ContinuousClock.Instant?)
            do { next = try nextJob() } catch { next = (nil, ContinuousClock.now + .seconds(1)) }
            guard let job = next.0 else {
                if let deadline = next.1 {
                    Task { [weak self] in
                        try? await Task.sleep(until: deadline)
                        await self?.wake()
                    }
                }
                await withCheckedContinuation { waiter = $0 }
                continue
            }
            busy = true
            await execute(job)
            busy = false
        }
    }

    func execute(_ job: Job) async {
        guard let handler = handlers[job.queueType] else { return }
        do {
            try await handler(job)
            finish(job)
            sink.yield(.succeeded(job))
        } catch {
            // Cancellation does not consume retry attempts or discard persisted work.
            if Task.isCancelled || error is CancellationError { return }
            let n = (attempts[job.id] ?? 0) + 1
            attempts[job.id] = n
            let permanent = (error as? JobError) != nil
            if permanent || n >= policy.maxAttempts {
                finish(job)
                sink.yield(.failed(job, error: "\(error)", final: true))
                await failureHandlers[job.queueType]?(job, error)
            } else {
                notBefore[job.id] = ContinuousClock.now + policy.delay(afterAttempt: n)
                sink.yield(.failed(job, error: "\(error)", final: false))
            }
        }
    }

    func finish(_ job: Job) {
        attempts[job.id] = nil
        notBefore[job.id] = nil
        _ = try? database.pool.write { db in try db.execute(sql: "DELETE FROM jobs WHERE id = ?", arguments: [job.id]) }
    }

    /// Number of persisted jobs (all queue types).
    public func pendingCount() throws -> Int {
        try database.pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM jobs") ?? 0 }
    }

    /// Waits until no runnable job is pending and none is executing.
    public func waitUntilIdle(timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let (job, _) = try nextJob()
            if job == nil && !busy { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw JobError.permanent("job queue not idle after \(timeout)")
    }
}
