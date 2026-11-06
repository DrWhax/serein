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

    /// One pass; `now` for tests.
    @discardableResult
    public func runOnce(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws -> Report {
        let store = self.store
        let (expired, orphans) = try await database.pool.write { db -> (Int, Int) in
            let e = try ConversationState.deleteExpired(db, now: now).count
            try MessageModifiers.expirePins(db, now: now)
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

    /// Runs `runOnce` every `interval` until `stop`.
    public func start(interval: Duration = .seconds(60)) {
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                _ = try? await self.runOnce()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }
}
