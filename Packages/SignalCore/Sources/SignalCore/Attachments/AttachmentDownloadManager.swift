// ts/jobs/AttachmentDownloadManager.preload.ts + JobManager.std.ts over the upstream
// attachment_downloads table: jobs for currently visible messages first (oldest first), then
// everything else newest first; at most 6 at once; failures retry with exponential backoff
// (30 s, ×10, at most 6 h, 5 attempts); a download is verified, re-encrypted at rest, and its
// message_attachments row updated (plus a 150 px thumbnail for images, via the media service).

import Foundation
import GRDB
import MediaXPCInterface

public struct AttachmentDownloadJob: Sendable, Equatable {
    public var messageId: String
    public var attachmentType: MessageAttachmentType
    public var signature: String
    public var receivedAt: Int64
    public var sentAt: Int64
    public var attachment: MessageAttachment
    public var attempts: Int = 0
    public var retryAfter: Int64?
    public var lastAttemptTimestamp: Int64?
    public var source = "standard"

    var ciphertextSize: Int {
        AttachmentCipher.ivLength + AttachmentCipher.aesCBCCiphertextSize(AttachmentCipher.logPadSize(attachment.size)) + AttachmentCipher.macLength
    }
}

public enum AttachmentDownloads {
    /// `addJob` (insert or replace on the same message/type/signature).
    public static func add(_ db: Database, _ job: AttachmentDownloadJob) throws {
        try db.execute(sql: """
            INSERT INTO attachment_downloads (messageId, attachmentType, attachmentSignature, receivedAt, sentAt, contentType, size,
                attachmentJson, active, attempts, retryAfter, lastAttemptTimestamp, source, ciphertextSize, originalSource)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (messageId, attachmentType, attachmentSignature) DO UPDATE SET
                attachmentJson = excluded.attachmentJson, active = 0, attempts = excluded.attempts, retryAfter = excluded.retryAfter
            """, arguments: [job.messageId, job.attachmentType.rawValue, job.signature, job.receivedAt, job.sentAt, job.attachment.contentType,
                             job.attachment.size, String(decoding: try JSONEncoder().encode(job.attachment), as: UTF8.self), job.attempts,
                             job.retryAfter, job.lastAttemptTimestamp, job.source, job.ciphertextSize, job.source])
    }

    static func job(_ row: Row) throws -> AttachmentDownloadJob? {
        guard let type = MessageAttachmentType(rawValue: row["attachmentType"]) else { return nil }
        let json: String = row["attachmentJson"]
        return AttachmentDownloadJob(messageId: row["messageId"], attachmentType: type, signature: row["attachmentSignature"],
                                     receivedAt: row["receivedAt"], sentAt: row["sentAt"],
                                     attachment: try JSONDecoder().decode(MessageAttachment.self, from: Data(json.utf8)),
                                     attempts: row["attempts"], retryAfter: row["retryAfter"], lastAttemptTimestamp: row["lastAttemptTimestamp"],
                                     source: row["source"])
    }

    /// `getNextAttachmentDownloadJobs`
    public static func next(_ db: Database, limit: Int, prioritize: [String], now: Int64) throws -> [AttachmentDownloadJob] {
        var rows: [Row] = []
        if !prioritize.isEmpty {
            let marks = Array(repeating: "?", count: prioritize.count).joined(separator: ",")
            rows = try Row.fetchAll(db, sql: """
                SELECT * FROM attachment_downloads WHERE active = 0
                  AND (lastAttemptTimestamp IS NULL OR lastAttemptTimestamp <= ?) AND messageId IN (\(marks))
                ORDER BY receivedAt ASC LIMIT ?
                """, arguments: StatementArguments([now - 3_600_000] as [Int64]) + StatementArguments(prioritize) + [limit])
        }
        if rows.count < limit {
            rows += try Row.fetchAll(db, sql: """
                SELECT * FROM attachment_downloads WHERE active = 0 AND (retryAfter IS NULL OR retryAfter <= ?)
                ORDER BY receivedAt DESC LIMIT ?
                """, arguments: [now, limit - rows.count])
        }
        var seen = Set<String>()
        return try rows.compactMap { row -> AttachmentDownloadJob? in
            guard let j = try job(row), seen.insert("\(j.messageId)|\(j.attachmentType.rawValue)|\(j.signature)").inserted else { return nil }
            return j
        }
    }

    static func key(_ j: AttachmentDownloadJob) -> StatementArguments { [j.messageId, j.attachmentType.rawValue, j.signature] }

    static func setActive(_ db: Database, _ j: AttachmentDownloadJob, _ active: Bool) throws {
        try db.execute(sql: "UPDATE attachment_downloads SET active = ? WHERE messageId = ? AND attachmentType = ? AND attachmentSignature = ?",
                       arguments: [active ? 1 : 0] + key(j))
    }

    static func remove(_ db: Database, _ j: AttachmentDownloadJob) throws {
        try db.execute(sql: "DELETE FROM attachment_downloads WHERE messageId = ? AND attachmentType = ? AND attachmentSignature = ?",
                       arguments: key(j))
    }

    static func retryLater(_ db: Database, _ j: AttachmentDownloadJob, now: Int64) throws {
        try db.execute(sql: """
            UPDATE attachment_downloads SET active = 0, attempts = ?, retryAfter = ?, lastAttemptTimestamp = ?
            WHERE messageId = ? AND attachmentType = ? AND attachmentSignature = ?
            """, arguments: [j.attempts + 1, now + AttachmentDownloadManager.backoff(attempt: j.attempts + 1), now] + key(j))
    }

    /// Startup: jobs left active by a crash become runnable again.
    public static func resetActive(_ db: Database) throws { try db.execute(sql: "UPDATE attachment_downloads SET active = 0 WHERE active = 1") }

    public static func count(_ db: Database) throws -> Int { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attachment_downloads") ?? 0 }
}

public enum AttachmentDownloadError: Error, Equatable {
    case tooBig(Int)
    case missingPointer
    case permanent(Int)
}

public actor AttachmentDownloadManager {
    public static let maxConcurrentJobs = 6
    public static let maxAttempts = 5

    /// `exponentialBackoffSleepTime` with DEFAULT_RETRY_CONFIG (ms).
    public static func backoff(attempt: Int) -> Int64 {
        let first: [Int64] = [30_000], multiplier = 10.0, maxBackoff = 6 * 3_600_000.0
        if attempt - 1 < first.count { return first[attempt - 1] }
        let last = Double(first.last!)
        return Int64(min(maxBackoff, (last / multiplier) * pow(multiplier, Double(attempt - first.count + 1))))
    }

    let db: DatabaseWriter
    let http: HTTPClient
    let endpoints: ServiceEndpoints
    let store: AttachmentStore
    let media: (any MediaProcessing)?
    var active: [String: Task<Void, Never>] = [:]
    var visibleMessages: [String] = []
    var running = false
    var starting = false
    var generation: UInt64 = 0
    var selecting = false
    var draining = 0
    var stateWaiters: [CheckedContinuation<Void, Never>] = []
    var wake: Task<Void, Never>?
    /// Test hook: the clock.
    var clock: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    var onUpdate: (@Sendable (String) -> Void)?

    public init(db: DatabaseWriter, http: HTTPClient, endpoints: ServiceEndpoints, store: AttachmentStore, media: (any MediaProcessing)?) {
        self.db = db
        self.http = http
        self.endpoints = endpoints
        self.store = store
        self.media = media
    }

    /// Called with a message id whenever one of its attachments changes.
    public func setOnUpdate(_ f: @escaping @Sendable (String) -> Void) { onUpdate = f }
    public func setClock(_ f: @escaping @Sendable () -> Int64) { clock = f }

    public func start() async throws {
        guard !running, !starting, draining == 0 else { return }
        starting = true
        defer { starting = false; stateChanged() }
        stop()
        let generation = self.generation
        while selecting { await withCheckedContinuation { stateWaiters.append($0) } }
        for task in Array(active.values) { await task.value }
        guard generation == self.generation else { return }
        try await db.write { try AttachmentDownloads.resetActive($0) }
        guard generation == self.generation else { return }
        running = true
        await tick()
    }

    public func stop() {
        generation &+= 1
        running = false
        wake?.cancel()
        for t in active.values { t.cancel() }
    }

    public func stopAndWait() async {
        draining += 1
        defer { draining -= 1 }
        stop()
        // Pending startup/selection writes must finish before a replacement can use the DB.
        while starting || selecting { await withCheckedContinuation { stateWaiters.append($0) } }
        let tasks = Array(active.values)
        for task in tasks { await task.value }
    }

    func stateChanged() {
        let waiters = stateWaiters
        stateWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// `updateVisibleTimelineMessages`: these messages' jobs run first.
    public func setVisible(_ ids: [String]) async {
        visibleMessages = ids
        await tick()
    }

    /// A manual download ("Download" in the timeline): queues these attachments whatever the
    /// auto-download settings, and starts them if there is room.
    public func requestDownload(_ locations: [MessageAttachments.Location]) async throws {
        try await db.write { db in for loc in locations { try MessageStore.queueDownload(db, loc) } }
        await tick()
    }

    /// `cancelAttachmentDownload`: the message's downloads stop (running ones are cancelled),
    /// leave the queue, and its attachments are no longer pending (they can be started again).
    public func cancelDownloads(messageId: String) async throws {
        for (id, task) in active where id.hasPrefix(messageId + "|") { task.cancel() }
        try await db.write { db in
            try db.execute(sql: "DELETE FROM attachment_downloads WHERE messageId = ?", arguments: [messageId])
            guard let row = try Row.fetchOne(db, sql: "SELECT conversationId, sent_at, received_at, type FROM messages WHERE id = ?", arguments: [messageId])
            else { return }
            for (loc, a) in try MessageAttachments.fetch(db, messageId: messageId) where a.pending == true && !a.isDownloaded {
                var a = a
                a.pending = false
                try MessageAttachments.upsert(db, loc, conversationId: row["conversationId"], sentAt: row["sent_at"], receivedAt: row["received_at"],
                                              messageType: row["type"] ?? "incoming", a)
            }
        }
        onUpdate?(messageId)
    }

    /// Queues a job (and runs it if there is room).
    public func add(_ job: AttachmentDownloadJob) async throws {
        try await db.write { try AttachmentDownloads.add($0, job) }
        await tick()
    }

    /// Starts as many jobs as there is room for; schedules a wake-up for the next retry.
    public func tick() async {
        guard running, !selecting else { return }
        selecting = true
        defer { selecting = false; stateChanged() }
        let generation = self.generation
        let room = Self.maxConcurrentJobs - active.count
        guard room > 0 else { return }
        let now = clock(), prioritize = visibleMessages
        let jobs = (try? await db.write { db -> [AttachmentDownloadJob] in
            let jobs = try AttachmentDownloads.next(db, limit: room, prioritize: prioritize, now: now)
            for j in jobs { try AttachmentDownloads.setActive(db, j, true) }
            return jobs
        }) ?? []
        guard running, generation == self.generation else {
            try? await db.write { db in
                for job in jobs { try AttachmentDownloads.setActive(db, job, false) }
            }
            return
        }
        for job in jobs {
            let id = "\(job.messageId)|\(job.attachmentType.rawValue)|\(job.signature)"
            active[id] = Task { [weak self] in
                await self?.run(job)
                await self?.finished(id)
            }
        }
        if jobs.isEmpty { await scheduleWake() }
    }

    func finished(_ id: String) async {
        active[id] = nil
        await tick()
    }

    func scheduleWake() async {
        wake?.cancel()
        let generation = self.generation
        let next = try? await db.read { try Int64.fetchOne($0, sql: "SELECT MIN(retryAfter) FROM attachment_downloads WHERE active = 0 AND retryAfter IS NOT NULL") }
        guard running, generation == self.generation else { return }
        guard let next = next ?? nil else { return }
        let delay = max(0, next - clock())
        wake = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            if !Task.isCancelled { await self?.tick() }
        }
    }

    func run(_ job: AttachmentDownloadJob) async {
        let now = clock()
        do {
            let updated = try await download(job)
            // Cancelled (`cancelDownloads`) while finishing: the user stopped it; keep nothing.
            if Task.isCancelled { return }
            try await db.write { db in
                try Self.replace(db, job: job) { _ in updated }
                try AttachmentDownloads.remove(db, job)
            }
            onUpdate?(job.messageId)
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            let permanent: Bool
            switch error {
            case AttachmentDownloadError.tooBig, AttachmentDownloadError.missingPointer, AttachmentDownloadError.permanent: permanent = true
            case HTTPError.status(let s, _) where s == 403 || s == 404: permanent = true
            case is AttachmentError: permanent = true
            default: permanent = job.attempts + 1 >= Self.maxAttempts
            }
            try? await db.write { db in
                if permanent {
                    try Self.replace(db, job: job) { a in
                        var a = a
                        a.pending = false
                        if case AttachmentDownloadError.tooBig = error { a.wasTooBig = true } else { a.error = true }
                        return a
                    }
                    try AttachmentDownloads.remove(db, job)
                } else {
                    try AttachmentDownloads.retryLater(db, job, now: now)
                }
            }
            if permanent { onUpdate?(job.messageId) }
        }
    }

    /// Finds the job's attachment on its message (by type and signature) and rewrites it.
    static func replace(_ db: Database, job: AttachmentDownloadJob, _ change: (MessageAttachment) -> MessageAttachment) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT conversationId, sent_at, received_at, type FROM messages WHERE id = ?", arguments: [job.messageId])
        else { return }
        for (loc, a) in try MessageAttachments.fetch(db, messageId: job.messageId) where loc.type == job.attachmentType && a.signature == job.signature {
            try MessageAttachments.upsert(db, loc, conversationId: row["conversationId"], sentAt: row["sent_at"], receivedAt: row["received_at"],
                                          messageType: row["type"] ?? "incoming", change(a))
        }
    }

    /// `downloadAttachment` + `decryptAndReencryptLocally` (+ a thumbnail for images, a screenshot for videos).
    func download(_ job: AttachmentDownloadJob) async throws -> MessageAttachment {
        var a = job.attachment
        guard let cdnKey = a.cdnKey, let keyB64 = a.key, let keys = Data(base64Encoded: keyB64) else { throw AttachmentDownloadError.missingPointer }
        let maxSize = try await db.read { try AttachmentPolicy.maximumIncomingSize($0) }
        guard a.size <= maxSize else { throw AttachmentDownloadError.tooBig(a.size) }
        let base = endpoints.cdnURLs[a.cdnNumber ?? 0] ?? endpoints.cdnURLs[0]!
        var client = http
        client.maxResponseBytes = job.ciphertextSize + 64 << 10
        let blob = try await client.send("GET", base.appendingPathComponent("attachments").appendingPathComponent(cdnKey)).body
        let integrity: AttachmentIntegrity
        if let d = a.digest.flatMap({ Data(base64Encoded: $0) }) { integrity = .encrypted(digest: d) }
        else if let h = a.plaintextHash.flatMap(Data.init(hex:)) { integrity = .plaintext(hash: h) }
        else { throw AttachmentError.missingDigest }
        let local = try AttachmentCipher.reencryptLocally(blob, keys: keys, size: a.size, integrity: integrity,
                                                          incrementalMac: a.incrementalMac.flatMap { Data(base64Encoded: $0) }, chunkSize: a.chunkSize)
        a.path = try store.write(local.blob)
        a.localKey = local.localKey.base64EncodedString()
        a.version = 2
        a.plaintextHash = local.plaintextHash
        a.pending = false
        a.error = nil
        if AttachmentPolicy.isImage(a.contentType), let media, let plaintext = try? store.plaintext(of: a) {
            if let t = try? await media.thumbnail(plaintext, size: MediaConstants.thumbnailSize).validated(size: MediaConstants.thumbnailSize) {
                let stored = try store.storeLocally(t.png)
                a.thumbnail = .init(path: stored.path, localKey: stored.localKey.base64EncodedString(), size: t.png.count, contentType: t.contentType,
                                    width: t.width, height: t.height)
            }
            if a.width == nil || a.blurHash == nil, let info = try? await media.imageInfo(plaintext).validated() {
                a.width = a.width ?? info.width
                a.height = a.height ?? info.height
                a.blurHash = a.blurHash ?? info.blurHash
            }
        }
        // captureDimensionsAndScreenshot
        if AttachmentPolicy.isVideo(a.contentType), a.screenshot == nil, let media, let plaintext = try? store.plaintext(of: a) {
            try await VideoAttachments.addScreenshot(&a, data: plaintext, media: media, store: store)
        }
        return a
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var it = hex.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let hi = a.hexDigitValue, let lo = b.hexDigitValue else { return nil }
            out.append(UInt8(hi << 4 | lo))
        }
        self = out
    }
}
