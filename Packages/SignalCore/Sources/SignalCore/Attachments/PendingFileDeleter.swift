// Deletes the files of deleted attachment rows right after the transaction that deleted them
// commits (upstream cleanupMessages → cleanupAllMessageAttachmentFiles): an expired
// disappearing message, delete for me / for everyone, an opened view-once message, a deleted
// chat. The rows' paths are queued by a trigger (serein_pendingFileDeletes); Maintenance also
// drains the queue, for files left when the app quit in between.

import Foundation
import GRDB

final class PendingFileDeleter: TransactionObserver {
    let pool: DatabasePool
    let store: AttachmentStore
    /// Set while a transaction queues paths; read on commit (both on the writer's queue).
    private var queued = false

    init(pool: DatabasePool, store: AttachmentStore) {
        self.pool = pool
        self.store = store
    }

    /// Starts deleting queued files after each commit that queues some.
    static func install(pool: DatabasePool, store: AttachmentStore) {
        pool.add(transactionObserver: PendingFileDeleter(pool: pool, store: store), extent: .databaseLifetime)
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        if case .insert(let table) = eventKind { return table == "serein_pendingFileDeletes" }
        return false
    }

    func databaseDidChange(with event: DatabaseEvent) {
        queued = true
        stopObservingDatabaseChangesUntilNextTransaction()
    }

    func databaseDidCommit(_ db: Database) {
        guard queued else { return }
        queued = false
        let pool = pool, store = store
        Task.detached { _ = try? await pool.write { try store.deletePendingFiles($0) } }
    }

    func databaseDidRollback(_ db: Database) { queued = false }
}
