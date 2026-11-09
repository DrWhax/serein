// Periodic housekeeping that upstream runs as services: expiring messages
// (expiringMessagesDeletionService), expired pins (pinnedMessagesCleanupService), orphaned
// attachment files (cleanupOrphanedAttachments) and the weekly key-transparency self check
// (CheckScheduler, `lastKeyTransparencySelfCheck`).

import Foundation
import GRDB

public actor Maintenance {
    public static let keyTransparencyInterval: Int64 = 7 * 86_400_000
    let database: SignalDatabase
    let store: AttachmentStore?
    let keyTransparency: KeyTransparencyService?
    var loop: Task<Void, Never>?

    public init(database: SignalDatabase, store: AttachmentStore?, keyTransparency: KeyTransparencyService?) {
        self.database = database
        self.store = store
        self.keyTransparency = keyTransparency
    }

    public struct Report: Sendable, Equatable {
        public var expiredMessages: Int
        public var orphanedFiles: Int
        public var ranKeyTransparency: Bool
    }

    /// `cleanupOrphanedAttachments`. Like upstream, only at startup, before anything downloads
    /// or sends: a file is written a moment before the row that refers to it, and must not be
    /// taken for an orphan in between.
    @discardableResult
    public func cleanOrphans() async throws -> Int {
        guard let store else { return 0 }
        return try await database.pool.write { db in try store.deleteOrphans(db) }
    }

    /// One pass; `now` for tests. `cleanOrphans` only where nothing else is writing files.
    @discardableResult
    public func runOnce(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000), cleanOrphans: Bool = true) async throws -> Report {
        let store = cleanOrphans ? self.store : nil
        let (expired, orphans) = try await database.pool.write { db -> (Int, Int) in
            let e = try ConversationState.deleteExpired(db, now: now).count
            try MessageModifiers.expirePins(db, now: now)
            // Messages we asked to be resent and that did not come within the hour.
            try RetryPlaceholders.expire(db, now: now)
            return (e, try store?.deleteOrphans(db) ?? 0)
        }
        var ranKT = false
        if let kt = keyTransparency, try await kt.isAvailable() {
            let last = try await database.pool.read { try Items.get($0, "lastKeyTransparencySelfCheck", as: Int64.self) } ?? 0
            if now - last >= Self.keyTransparencyInterval {
                _ = try? await kt.selfCheck()
                ranKT = true
            }
        }
        return Report(expiredMessages: expired, orphanedFiles: orphans, ranKeyTransparency: ranKT)
    }

    /// Runs `runOnce` (without the orphan pass) every `interval` until `stop`.
    public func start(interval: Duration = .seconds(60)) {
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                _ = try? await self.runOnce(cleanOrphans: false)
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// `stop`, and waits for a pass that is under way to finish (nothing of ours writes to the
    /// database afterwards).
    public func stopAndWait() async {
        let running = loop
        stop()
        await running?.value
    }

    /// Whether the periodic pass is scheduled.
    public var isRunning: Bool { loop != nil }
}
