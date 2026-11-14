// Link and sync in the client: after the link, before the session starts (upstream sets the
// backup download path first so storage sync and the receiver wait), wait for the primary's
// transfer archive, download, decrypt and import it. Meanwhile the connection holds incoming
// messages without acknowledging them, so the server delivers them again to the receiver.

import Foundation
import GRDB
import LibSignalClient
import MessageParsing
import SignalProtos

public enum LinkAndSyncProgress: Sendable, Equatable {
    /// Waiting for the primary to upload.
    case waiting
    case downloading
    /// Runs of frames (about a megabyte each) imported of the total.
    case importing(done: Int, total: Int)
    case finished(BackupImportResult)
    /// The primary chose not to send history (or there was none).
    case skipped
    /// The transfer failed; the device continues without history.
    case failed(String)
}

/// Leaves every message on the server (no ack) while history is imported.
final class HoldingListener: ChatConnectionListener, Sendable {
    func chatConnection(_ chat: AuthenticatedChatConnection, didReceiveIncomingMessage envelope: Data, serverDeliveryTimestamp: UInt64,
                        sendAck: sending @escaping () throws -> Void) {}
    func chatConnectionDidReceiveQueueEmpty(_ chat: AuthenticatedChatConnection) {}
    func chatConnection(_ chat: AuthenticatedChatConnection, didReceiveAlerts alerts: [String]) {}
    func connectionWasInterrupted(_ service: AuthenticatedChatConnection, error: Error?) {}
}

extension SignalClient {
    /// How long the device waits for the primary's archive (upstream's getTransferArchive: an hour).
    static let transferArchiveTimeout: Duration = .seconds(3600)

    /// Whether the provision message carried an ephemeral backup key.
    func hasLinkAndSync() async throws -> Bool {
        let key: String? = try await database.pool.read { try Items.get($0, LinkAndSync.ephemeralKeyItem) }
        return key != nil
    }

    /// Runs link and sync (the connection is up with a HoldingListener; it is closed after).
    /// Throws only `LinkAndSyncError.relinkRequested` (the link must be redone); other failures
    /// are reported and the device continues without history.
    func linkAndSync(_ account: Account, progress: @escaping @Sendable (LinkAndSyncProgress) -> Void) async throws {
        guard let keyB64: String = try await database.pool.read({ try Items.get($0, LinkAndSync.ephemeralKeyItem) }),
              let ephemeralKey = Data(base64Encoded: keyB64) else {
            await socket.disconnect()
            return
        }
        do {
            progress(.waiting)
            let stored: [String: String]? = try await database.pool.read { try Items.get($0, LinkAndSync.archiveItem) }
            let archive: TransferArchive
            if let stored, let cdn = stored["cdn"].flatMap(Int.init), let key = stored["key"] {
                archive = .archive(cdn: cdn, key: key)
            } else {
                archive = try await LinkAndSync.waitForArchive(socket: socket, deadline: .now + Self.transferArchiveTimeout)
            }
            guard case .archive(let cdn, let key) = archive else {
                await socket.disconnect()
                try await clearLinkAndSync()
                progress(.skipped)
                return
            }
            try await database.pool.write { try Items.set($0, LinkAndSync.archiveItem, ["cdn": String(cdn), "key": key]) }
            progress(.downloading)
            let http = HTTPClient(rootCertificatesDER: endpoints.rootCertificatesDER)
            let blob = try await LinkAndSync.download(http: http, endpoints: endpoints, cdn: cdn, key: key)
            let result = try await importArchive(blob, ephemeralKey: ephemeralKey, account: account, progress: progress)
            await socket.disconnect()
            progress(.finished(result))
        } catch LinkAndSyncError.relinkRequested {
            await socket.disconnect()
            try? await clearLinkAndSync()
            throw LinkAndSyncError.relinkRequested
        } catch {
            await socket.disconnect()
            try? await clearLinkAndSync()
            Self.diagnose("link and sync failed: \(String(describing: error).prefix(160))")
            progress(.failed(String(describing: error)))
        }
    }

    func clearLinkAndSync() async throws {
        try await database.pool.write { db in
            try Items.remove(db, LinkAndSync.ephemeralKeyItem)
            try Items.remove(db, LinkAndSync.archiveItem)
        }
    }

    func importArchive(_ blob: Data, ephemeralKey: Data, account: Account,
                       progress: @escaping @Sendable (LinkAndSyncProgress) -> Void = { _ in }) async throws -> BackupImportResult {
        try await LinkAndSync.importArchive(blob, ephemeralKey: ephemeralKey, account: account, database: database, parser: parser, progress: progress)
    }
}

extension LinkAndSync {
    /// Decrypts and imports an archive (the frames parsed by the keyless parser, one source).
    static func importArchive(_ blob: Data, ephemeralKey: Data, account: Account, database: SignalDatabase, parser: any StructuredMessageParser,
                              progress: @escaping @Sendable (LinkAndSyncProgress) -> Void = { _ in }) async throws -> BackupImportResult {
        let keys = try LinkAndSync.keys(ephemeralKey: ephemeralKey, aci: account.aci)
        let gzip = try LinkAndSync.decrypt(blob, mac: keys.mac, aes: keys.aes)
        // The parser inflates it and hands its frames out run by run (one source, one session).
        let source = "backup:\(account.aci)"
        let (info, runs) = try parser.backupArchive(gzip, source: source)
        guard info.version == 1 else { throw LinkAndSyncError.malformed("backup version \(info.version)") }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return try await database.pool.write { db in
            var importer = try BackupImporter(db: db, account: account, now: now)
            for run in 0..<runs {
                for frame in try parser.backupRun(run, source: source) { try importer.process(frame) }
                progress(.importing(done: run + 1, total: runs))
            }
            try importer.finish()
            try Items.remove(db, LinkAndSync.ephemeralKeyItem)
            try Items.remove(db, LinkAndSync.archiveItem)
            return importer.result
        }
    }
}
