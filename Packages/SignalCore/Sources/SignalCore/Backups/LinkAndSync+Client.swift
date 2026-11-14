// Link and sync in the client: after the link, before the session starts (upstream sets the
// backup download path first so storage sync and the receiver wait), wait for the primary's
// transfer archive, download it to a file, check, decrypt and import it. Meanwhile the
// connection holds incoming messages without acknowledging them, so the server delivers them
// again to the receiver. An app that quits on the way picks up where it stopped on its next
// start (`resume`): the download goes on from what the file holds, and an import, being one
// transaction, starts again from the beginning.
//
// As upstream (backups downloadAndImport): a failure while waiting or downloading can be tried
// again; one while importing is fatal, as is the primary asking to link again; cancelling, or
// giving up after a failure, unlinks the device and deletes its data (the app does that on
// `LinkAndSyncError.canceled` / `.relinkRequested`). No archive on the server (404), or the
// primary continuing without one, links without history.

import Foundation
import GRDB
import LibSignalClient
import MessageParsing
import SignalProtos

public enum LinkAndSyncProgress: Sendable, Equatable {
    /// Waiting for the primary to upload.
    case waiting
    /// Bytes of the archive downloaded, of its size (0 while not known).
    case downloading(done: Int64, total: Int64)
    /// Bytes of the archive imported, of its size.
    case importing(done: Int64, total: Int64)
    case finished(BackupImportResult)
    /// The primary chose not to send history (or there was none).
    case skipped
    /// Stopped; `LinkAndSyncControl` says what follows: retry or cancel after a retriable
    /// failure, cancel after any other.
    case failed(LinkAndSyncFailure)
    /// Cancelled: the device is unlinked and its data deleted next.
    case canceled
}

/// upstream InstallScreenBackupError.
public enum LinkAndSyncFailure: Sendable, Equatable {
    /// Waiting for the archive or downloading it failed: it can be tried again.
    case retriable
    /// The archive could not be imported, or the primary asked to link again.
    case fatal
    /// The backup is of a version this client does not read.
    case unsupportedVersion
}

/// Leaves every message on the server (no ack) while history is imported.
final class HoldingListener: ChatConnectionListener, Sendable {
    func chatConnection(_ chat: AuthenticatedChatConnection, didReceiveIncomingMessage envelope: Data, serverDeliveryTimestamp: UInt64,
                        sendAck: sending @escaping () throws -> Void) {}
    func chatConnectionDidReceiveQueueEmpty(_ chat: AuthenticatedChatConnection) {}
    func chatConnection(_ chat: AuthenticatedChatConnection, didReceiveAlerts alerts: [String]) {}
    func connectionWasInterrupted(_ service: AuthenticatedChatConnection, error: Error?) {}
}

/// A failure before the import (waiting for the archive, downloading it): retriable.
struct ArchiveDownloadFailure: Error { let underlying: Error }

extension SignalClient {
    /// How long the device waits for the primary's archive (upstream's getTransferArchive: an hour).
    static let transferArchiveTimeout: Duration = .seconds(3600)

    /// The archive as it downloads (upstream's backupDownloadPath), removed after the import.
    var transferArchiveFile: URL { directory.appendingPathComponent("transfer-archive") }

    /// Whether the provision message carried an ephemeral backup key (and its history has not
    /// been imported yet).
    func hasLinkAndSync() async throws -> Bool {
        let key: String? = try await database.pool.read { try Items.get($0, LinkAndSync.ephemeralKeyItem) }
        return key != nil
    }

    /// Runs link and sync (the connection is up with a HoldingListener; it is closed after).
    /// Throws `LinkAndSyncError.canceled` or `.relinkRequested` when the device must be unlinked
    /// (and its data deleted); returns once history was imported, or there was none to import.
    func linkAndSync(_ account: Account, control: LinkAndSyncControl, progress: @escaping @Sendable (LinkAndSyncProgress) -> Void) async throws {
        guard let keyB64: String = try await database.pool.read({ try Items.get($0, LinkAndSync.ephemeralKeyItem) }),
              let ephemeralKey = Data(base64Encoded: keyB64) else {
            await socket.disconnect()
            return
        }
        let file = transferArchiveFile
        while true {
            do {
                let result = try await transfer(account, ephemeralKey: ephemeralKey, file: file, control: control, progress: progress)
                await socket.disconnect()
                try? FileManager.default.removeItem(at: file)
                progress(result.map { .finished($0) } ?? .skipped)
                return
            } catch {
                let failure: LinkAndSyncFailure
                switch error {
                case _ where control.isCanceled, LinkAndSyncError.canceled:
                    Self.diagnose("link and sync: canceled")
                    try await giveUp(file, progress, throwing: .canceled)
                case LinkAndSyncError.unsupportedVersion: failure = .unsupportedVersion
                case is ArchiveDownloadFailure: failure = .retriable
                default: failure = .fatal
                }
                Self.diagnose("link and sync failed (\(failure)): \(String(describing: error).prefix(160))")
                progress(.failed(failure))
                let choice = await control.choice()
                if failure == .retriable, choice == .retry { continue }
                try await giveUp(file, progress, throwing: error as? LinkAndSyncError == .relinkRequested ? .relinkRequested : .canceled)
            }
        }
    }

    func giveUp(_ file: URL, _ progress: @Sendable (LinkAndSyncProgress) -> Void, throwing error: LinkAndSyncError) async throws -> Never {
        progress(.canceled)
        await socket.disconnect()
        try? FileManager.default.removeItem(at: file)
        throw error
    }

    /// One attempt: the archive's location (waiting for the primary unless it is known), its
    /// download (unless it is all in the file), its import. nil: the primary sent no history.
    func transfer(_ account: Account, ephemeralKey: Data, file: URL, control: LinkAndSyncControl,
                  progress: @escaping @Sendable (LinkAndSyncProgress) -> Void) async throws -> BackupImportResult? {
        progress(.waiting)
        let stored: [String: String]? = try await database.pool.read { try Items.get($0, LinkAndSync.archiveItem) }
        let archive: TransferArchive
        if let stored, let cdn = stored["cdn"].flatMap(Int.init), let key = stored["key"] {
            archive = .archive(cdn: cdn, key: key)
        } else {
            do {
                archive = try await LinkAndSync.waitForArchive(socket: socket, deadline: .now + Self.transferArchiveTimeout)
            } catch LinkAndSyncError.relinkRequested {
                throw LinkAndSyncError.relinkRequested
            } catch {
                throw ArchiveDownloadFailure(underlying: error)
            }
        }
        guard case .archive(let cdn, let key) = archive else {
            try await clearLinkAndSync()
            return nil
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        if stored?["size"].flatMap(Int64.init) == nil || stored?["size"].flatMap(Int64.init) != size {
            try await database.pool.write { try Items.set($0, LinkAndSync.archiveItem, ["cdn": String(cdn), "key": key]) }
            progress(.downloading(done: 0, total: 0))
            let http = HTTPClient(rootCertificatesDER: endpoints.rootCertificatesDER), endpoints = endpoints
            do {
                try await control.cancellable {
                    try await LinkAndSync.download(http: http, endpoints: endpoints, cdn: cdn, key: key, to: file) { done, total in
                        progress(.downloading(done: done, total: total ?? 0))
                    }
                }
            } catch LinkAndSyncError.canceled {
                throw LinkAndSyncError.canceled
            } catch HTTPError.status(404, _) {
                // No backup on the server: link without history.
                try await clearLinkAndSync()
                return nil
            } catch {
                throw ArchiveDownloadFailure(underlying: error)
            }
            let downloaded = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            try await database.pool.write { try Items.set($0, LinkAndSync.archiveItem, ["cdn": String(cdn), "key": key, "size": String(downloaded)]) }
        }
        return try await LinkAndSync.importArchive(file: file, ephemeralKey: ephemeralKey, account: account, database: database, parser: parser,
                                                   isCanceled: { control.isCanceled }, progress: progress)
    }

    func clearLinkAndSync() async throws {
        try await database.pool.write { db in
            try Items.remove(db, LinkAndSync.ephemeralKeyItem)
            try Items.remove(db, LinkAndSync.archiveItem)
        }
    }
}

extension LinkAndSync {
    /// Imports an archive file: its MAC checked, then decrypted piece by piece and parsed by the
    /// keyless parser (one source, so one parser process, for the whole backup), the frames
    /// written as they come, all in one transaction.
    static func importArchive(file: URL, ephemeralKey: Data, account: Account, database: SignalDatabase, parser: any StructuredMessageParser,
                              isCanceled: @escaping @Sendable () -> Bool = { false },
                              progress: @escaping @Sendable (LinkAndSyncProgress) -> Void = { _ in }) async throws -> BackupImportResult {
        let keys = try LinkAndSync.keys(ephemeralKey: ephemeralKey, aci: account.aci)
        let total = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        progress(.importing(done: 0, total: total))
        let verified = try verify(file, mac: keys.mac)
        let source = "backup:\(account.aci)"
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return try await database.pool.write { db in
            var importer = try BackupImporter(db: db, account: account, now: now)
            var infoRead = false
            try decrypt(verified, mac: keys.mac, aes: keys.aes) { piece, done, total in
                if isCanceled() { throw LinkAndSyncError.canceled }
                // The whole import is one block on the database's queue: what Foundation and XPC
                // autorelease must go piece by piece, or it is all held until the end.
                try autoreleasepool {
                    var next = piece
                    while true {
                        let records = try parser.backupRecords(next, infoRead: infoRead, source: source)
                        next = Data()
                        if let info = records.info {
                            guard info.version == 1 else { throw LinkAndSyncError.unsupportedVersion(info.version) }
                            try checkMediaRootKey(db, info)
                            infoRead = true
                        } else if records.frames.isEmpty {
                            break
                        }
                        for frame in records.frames { try importer.process(frame) }
                    }
                }
                progress(.importing(done: done, total: total))
            }
            try parser.backupEnd(source: source)
            guard infoRead else { throw LinkAndSyncError.malformed("no backup info") }
            try importer.finish()
            try Items.remove(db, LinkAndSync.ephemeralKeyItem)
            try Items.remove(db, LinkAndSync.archiveItem)
            return importer.result
        }
    }

    /// upstream: the backup's media root key must be there, and be the one the link gave (a
    /// device that got none then takes it: the archive is authenticated by the same link).
    static func checkMediaRootKey(_ db: Database, _ info: BackupProto_BackupInfo) throws {
        guard info.mediaRootBackupKey.count == 32 else { throw LinkAndSyncError.malformed("missing mediaRootBackupKey") }
        if let ours: String = try Items.get(db, "backupMediaRootKey"), let key = Data(base64Encoded: ours) {
            guard SignalCrypto.constantTimeEqual(key, info.mediaRootBackupKey) else { throw LinkAndSyncError.malformed("incorrect mediaRootBackupKey") }
        } else {
            try Items.set(db, "backupMediaRootKey", info.mediaRootBackupKey.base64EncodedString())
        }
    }
}
