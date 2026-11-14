// Link and sync (services/backups index.preload.ts #doDownloadAndImport, WebAPI
// getTransferArchive / getEphemeralBackupStream): a newly linked device offers `backup5` in its
// QR code; the primary then sends an ephemeral backup key in the provision message and uploads
// its message history as a transfer archive, which the device waits for, downloads from the
// CDN and imports before it starts receiving.
//
//   archive  := IV:16  AES-256-CBC(gzip(backupInfo frame*), PKCS#7)  HMAC-SHA256:32
//   record   := varint length, that many bytes (protobuf encodeDelimited)
//
// Keys: MessageBackupKey(BackupKey(ephemeral), backupId = BackupKey.deriveBackupId(our ACI)).
// The MAC covers the IV and ciphertext; it is checked before anything is decrypted. The app
// decrypts; inflating and parsing are SignalMessageParser.xpc's (the app links no codec code).

import Foundation
import LibSignalClient
import MessageParsing
import SignalProtos

public enum LinkAndSyncError: Error, Equatable {
    /// The primary asked for the link to be redone (RELINK_REQUESTED).
    case relinkRequested
    /// No archive came before the deadline.
    case timedOut
    case badMAC
    case malformed(String)
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
    /// The archive's CDN location once known, so an interrupted download need not wait again.
    static let archiveItem = "backupTransitArchive"
    /// The largest archive downloaded, and the largest decompressed backup.
    public static let maxArchiveBytes = MessageParserLimits.maxArchiveBytes

    /// (HMAC key, AES key) of a transfer archive.
    public static func keys(ephemeralKey: Data, aci: String) throws -> (mac: Data, aes: Data) {
        let backupKey = try BackupKey(contents: ephemeralKey)
        let id = backupKey.deriveBackupId(aci: try Aci.parseFrom(serviceIdString: aci))
        let key = try MessageBackupKey(backupKey: backupKey, backupId: id)
        return (key.hmacKey, key.aesKey)
    }

    /// The plaintext of an archive (still gzip): MAC first, then AES-256-CBC.
    public static func decrypt(_ archive: Data, mac: Data, aes: Data) throws -> Data {
        guard archive.count >= 16 + 16 + 32, (archive.count - 16 - 32) % 16 == 0 else { throw LinkAndSyncError.malformed("archive of \(archive.count) bytes") }
        let body = archive.prefix(archive.count - 32)
        guard SignalCrypto.constantTimeEqual(SignalCrypto.hmacSHA256(key: mac, Data(body)), Data(archive.suffix(32))) else { throw LinkAndSyncError.badMAC }
        do {
            return try SignalCrypto.aes256CBCDecrypt(key: aes, iv: Data(body.prefix(16)), Data(body.dropFirst(16)))
        } catch {
            throw LinkAndSyncError.malformed("decryption")
        }
    }

    /// The archive for a backup (tests; what a primary uploads).
    public static func encrypt(_ plaintext: Data, mac: Data, aes: Data, iv: Data = Data(SignalCrypto.randomBytes(16))) throws -> Data {
        let body = iv + (try SignalCrypto.aes256CBCEncrypt(key: aes, iv: iv, plaintext))
        return body + SignalCrypto.hmacSHA256(key: mac, body)
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

    /// `getEphemeralBackupStream`: the archive's bytes from `cdn<n>/attachments/<key>`.
    public static func download(http: HTTPClient, endpoints: ServiceEndpoints, cdn: Int, key: String) async throws -> Data {
        guard let base = endpoints.cdnURLs[cdn] ?? endpoints.cdnURLs[0] else { throw LinkAndSyncError.malformed("cdn \(cdn)") }
        var client = http
        client.maxResponseBytes = maxArchiveBytes
        return try await client.send("GET", try base.cdnAttachment(key)).body
    }
}
