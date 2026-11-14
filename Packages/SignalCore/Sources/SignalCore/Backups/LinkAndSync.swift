// Link and sync (services/backups index.preload.ts #doDownloadAndImport / importBackup, WebAPI
// getTransferArchive / getEphemeralBackupStream): a newly linked device offers `backup5` in its
// QR code; the primary then sends an ephemeral backup key in the provision message and uploads
// its message history as a transfer archive, which the device waits for, downloads from the
// CDN and imports before it starts receiving.
//
//   archive  := IV:16  AES-256-CBC(gzip(backupInfo frame*), PKCS#7)  HMAC-SHA256:32
//   record   := varint length, that many bytes (protobuf encodeDelimited)
//
// Keys: MessageBackupKey(BackupKey(ephemeral), backupId = BackupKey.deriveBackupId(our ACI)).
// As upstream, the archive goes to a file as it downloads (resumed where it stopped), its MAC
// is checked over the whole file before anything is decrypted, and it is then decrypted piece
// by piece (the MAC computed again on the way) and streamed through the parser: no part of the
// history is ever held whole. The app decrypts; inflating and parsing are
// SignalMessageParser.xpc's (the app links no codec code).

import Foundation
import LibSignalClient
import MessageParsing
import SignalProtos
import Synchronization

public enum LinkAndSyncError: Error, Equatable {
    /// The primary asked for the link to be redone (RELINK_REQUESTED).
    case relinkRequested
    /// No archive came before the deadline.
    case timedOut
    case badMAC
    case malformed(String)
    /// The user cancelled the transfer (upstream BackupImportCanceledError).
    case canceled
    /// A backup version this client does not read (upstream UnsupportedBackupVersion).
    case unsupportedVersion(UInt64)
}

/// What `GET /v1/devices/transfer_archive` gave.
public enum TransferArchive: Equatable, Sendable {
    case archive(cdn: Int, key: String)
    /// The primary chose to continue without uploading (CONTINUE_WITHOUT_UPLOAD).
    case continueWithoutUpload
}

public enum LinkAndSync {
    /// `isLinkAndSyncEnabled`: offered only on a clean start (it cannot merge into history).
    public static let capability = "backup5"
    /// Items key of the provision message's key until the import has run (upstream's).
    static let ephemeralKeyItem = "backupEphemeralKey"
    /// The archive's CDN location once known, so an interrupted download need not wait again
    /// (and, once downloaded, its size).
    static let archiveItem = "backupTransitArchive"
    /// The largest archive downloaded. Nothing of it is held in memory; this only bounds the disk
    /// a server could make it fill.
    public static let maxArchiveBytes: Int64 = 16 << 30
    /// The archive is read and decrypted in pieces of this many bytes (a multiple of 16).
    static let pieceBytes = 1 << 20

    /// (HMAC key, AES key) of a transfer archive.
    public static func keys(ephemeralKey: Data, aci: String) throws -> (mac: Data, aes: Data) {
        let backupKey = try BackupKey(contents: ephemeralKey)
        let id = backupKey.deriveBackupId(aci: try Aci.parseFrom(serviceIdString: aci))
        let key = try MessageBackupKey(backupKey: backupKey, backupId: id)
        return (key.hmacKey, key.aesKey)
    }

    /// The archive for a backup (tests; what a primary uploads).
    public static func encrypt(_ plaintext: Data, mac: Data, aes: Data, iv: Data = Data(SignalCrypto.randomBytes(16))) throws -> Data {
        let body = iv + (try SignalCrypto.aes256CBCEncrypt(key: aes, iv: iv, plaintext))
        return body + SignalCrypto.hmacSHA256(key: mac, body)
    }

    // MARK: the archive file

    /// The file's size, checked against the layout.
    static func archiveSize(_ handle: FileHandle) throws -> Int64 {
        let size = Int64(try handle.seekToEnd())
        guard size >= 16 + 16 + 32, (size - 16 - 32) % 16 == 0 else { throw LinkAndSyncError.malformed("archive of \(size) bytes") }
        try handle.seek(toOffset: 0)
        return size
    }

    static func read(_ handle: FileHandle, _ count: Int) throws -> Data {
        guard let data = try handle.read(upToCount: count), data.count == count else { throw LinkAndSyncError.malformed("archive read short") }
        return data
    }

    /// An archive file whose MAC was checked over all of it: what `decrypt` takes.
    public struct VerifiedArchive: Sendable {
        public let file: URL
        public let size: Int64
        /// The MAC the file ends with, as the check computed it.
        let mac: Data
    }

    /// First pass (upstream's): the MAC over the IV and ciphertext, before anything is decrypted.
    public static func verify(_ file: URL, mac: Data) throws -> VerifiedArchive {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try archiveSize(handle)
        var hmac = SignalCrypto.StreamingHMAC(key: mac)
        var left = size - 32
        while left > 0 {
            let n = Int(min(left, Int64(pieceBytes)))
            hmac.update(try read(handle, n))
            left -= Int64(n)
        }
        let computed = hmac.finalize()
        guard SignalCrypto.constantTimeEqual(computed, try read(handle, 32)) else { throw LinkAndSyncError.badMAC }
        return VerifiedArchive(file: file, size: size, mac: computed)
    }

    /// Second pass: the plaintext (gzip) in pieces of about a megabyte, with how much of the file
    /// they cover. The file must still be the one checked: its size, the MAC it ends with, and
    /// the MAC computed again on the way, checked after the last piece (a file changed between
    /// the passes is refused, and whatever `body` did is undone by the error: the import is one
    /// transaction).
    public static func decrypt(_ archive: VerifiedArchive, mac: Data, aes: Data, _ body: (Data, _ done: Int64, _ total: Int64) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: archive.file)
        defer { try? handle.close() }
        let size = try archiveSize(handle)
        guard size == archive.size else { throw LinkAndSyncError.badMAC }
        try handle.seek(toOffset: UInt64(size - 32))
        guard SignalCrypto.constantTimeEqual(try read(handle, 32), archive.mac) else { throw LinkAndSyncError.badMAC }
        try handle.seek(toOffset: 0)
        var hmac = SignalCrypto.StreamingHMAC(key: mac)
        var iv = try read(handle, 16)
        hmac.update(iv)
        var left = size - 16 - 32
        var done: Int64 = 16
        while left > 0 {
            let n = Int(min(left, Int64(pieceBytes)))
            let piece = try read(handle, n)
            hmac.update(piece)
            left -= Int64(n)
            done += Int64(n)
            let plain: Data
            do {
                plain = left == 0 ? try SignalCrypto.aes256CBCDecrypt(key: aes, iv: iv, piece) : try SignalCrypto.aes256CBCDecryptBlocks(key: aes, iv: iv, piece)
            } catch {
                throw LinkAndSyncError.malformed("decryption")
            }
            iv = Data(piece.suffix(16))
            try body(plain, done, size)
        }
        guard SignalCrypto.constantTimeEqual(hmac.finalize(), archive.mac) else { throw LinkAndSyncError.badMAC }
    }

    // MARK: server

    /// `getTransferArchive`: long polls of up to five minutes (204: none yet) until `deadline`.
    public static func waitForArchive(socket: SocketManager, deadline: ContinuousClock.Instant) async throws -> TransferArchive {
        while true {
            try Task.checkCancellation()
            let remaining = deadline - .now
            guard remaining > .zero else { throw LinkAndSyncError.timedOut }
            let seconds = max(1, min(300, Int(remaining.components.seconds)))
            let r = try await socket.authenticatedResponse("GET", "/v1/devices/transfer_archive?timeout=\(seconds)", timeout: TimeInterval(seconds + 15))
            switch r.status {
            case 200:
                return try parseArchive(r.body)
            case 204:
                continue
            default:
                throw ChatRequestError.http(status: r.status, message: r.message, body: r.body)
            }
        }
    }

    static func parseArchive(_ body: Data) throws -> TransferArchive {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw LinkAndSyncError.malformed("archive response") }
        if let error = json["error"] as? String {
            switch error {
            case "RELINK_REQUESTED": throw LinkAndSyncError.relinkRequested
            case "CONTINUE_WITHOUT_UPLOAD": return .continueWithoutUpload
            default: throw LinkAndSyncError.malformed("archive error \(error)")
            }
        }
        guard let cdn = (json["cdn"] as? NSNumber)?.intValue, let key = json["key"] as? String, !key.isEmpty else {
            throw LinkAndSyncError.malformed("archive response")
        }
        return .archive(cdn: cdn, key: key)
    }

    /// `getEphemeralBackupStream`: the archive from `cdn<n>/attachments/<key>` into `file`,
    /// resumed from what the file holds.
    public static func download(http: HTTPClient, endpoints: ServiceEndpoints, cdn: Int, key: String, to file: URL,
                                progress: @Sendable (Int64, Int64?) -> Void = { _, _ in }) async throws {
        guard let base = endpoints.cdnURLs[cdn] ?? endpoints.cdnURLs[0] else { throw LinkAndSyncError.malformed("cdn \(cdn)") }
        try await http.download(try base.cdnAttachment(key), to: file, maxBytes: maxArchiveBytes, progress: progress)
    }
}

/// The user's say in a running link and sync (upstream's installer actions): cancel at any time
/// once the download has begun, retry or cancel after a failure.
public final class LinkAndSyncControl: Sendable {
    public enum Choice: Sendable { case retry, cancel }
    struct State {
        var canceled = false
        var waiting: CheckedContinuation<Choice, Never>?
        var cancelCurrent: (@Sendable () -> Void)?
    }
    let state = Mutex(State())

    public init() {}

    /// Cancels the transfer: the device is then unlinked and its data deleted.
    public func cancel() {
        let (waiting, current) = state.withLock { s in
            s.canceled = true
            defer { s.waiting = nil }
            return (s.waiting, s.cancelCurrent)
        }
        waiting?.resume(returning: .cancel)
        current?()
    }

    /// After a retriable failure: try again.
    public func retry() {
        state.withLock { s in
            defer { s.waiting = nil }
            return s.waiting
        }?.resume(returning: .retry)
    }

    public var isCanceled: Bool { state.withLock { $0.canceled } }

    /// What the user chose after a failure.
    func choice() async -> Choice {
        await withCheckedContinuation { c in
            let canceled = state.withLock { s in
                if s.canceled { return true }
                s.waiting = c
                return false
            }
            if canceled { c.resume(returning: .cancel) }
        }
    }

    /// `body` in a task of its own, which `cancel()` cancels.
    func cancellable<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await body() }
        let canceled = state.withLock { s in
            s.cancelCurrent = { task.cancel() }
            return s.canceled
        }
        if canceled { task.cancel() }
        defer { state.withLock { $0.cancelCurrent = nil } }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if isCanceled { throw LinkAndSyncError.canceled }
            throw error
        }
    }
}
