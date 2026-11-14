// The paid media tier (upstream services/backups credentials.preload.ts, downloadAttachment's
// MediaTier.BACKUP, crypto.preload.ts deriveBackupMediaKeyMaterial): an attachment the primary
// backed up is kept at cdn<n>/backups/<backupDir>/<mediaDir>/<mediaId> under a second layer of
// encryption keyed from the media root key. What is under that layer is the attachment as it
// was sent; it is then decrypted and checked like any download, and what the app shows of it
// comes from the media service (AttachmentDownloadManager), never from the app's own parsing.
//
// Access: the backup key (derived from the account entropy pool) asks for the day's backup
// credentials (GET /v1/archives/auth). The media one, presented and signed with the backup's EC
// key, gets the media folder (getMediaBackupInfo) and the CDN's read headers
// (getBackupCdnCredentials) over the unauthenticated connection.
//
//   mediaName := hex(plaintextHash ‖ key)       mediaId := mediaRootKey.deriveMediaId(mediaName)
//   (mac ‖ aes) := mediaRootKey.deriveMediaEncryptionKey(mediaId)
//   object := IV:16 AES-256-CBC(transit blob, PKCS#7) HMAC-SHA256(IV ‖ ciphertext):32

import Foundation
import GRDB
import LibSignalClient

public enum BackupMediaTierError: Error, Equatable {
    /// No backup key, media root key or paid tier: the media tier is not for this account.
    case unavailable(String)
    case badCredentials(String)
}

actor BackupMediaTier {
    let database: SignalDatabase
    let socket: SocketManager
    let http: HTTPClient
    let endpoints: ServiceEndpoints
    let aci: String
    /// `backupServerPublicParams`: what backup credentials are issued under.
    let serverParams: Data

    /// The day's media credential, the media folder and each CDN's read headers (upstream keeps
    /// them in storage; here for the session).
    var auth: (day: Int64, auth: BackupAuth)?
    var folder: MediaBackupInfo?
    var cdnHeaders: [Int: [String: String]] = [:]

    init(database: SignalDatabase, socket: SocketManager, http: HTTPClient, endpoints: ServiceEndpoints, aci: String, backupServerPublicParams: Data) {
        self.database = database
        self.socket = socket
        self.http = http
        self.endpoints = endpoints
        self.aci = aci
        self.serverParams = backupServerPublicParams
    }

    /// `BackupLevel.Paid`
    static let paidTier: UInt64 = 200

    /// upstream hasMediaBackups: the account's backup tier is the paid one.
    static func isEnabled(_ db: Database) throws -> Bool { try Items.get(db, "backupTier", as: UInt64.self) == paidTier }

    /// upstream isDownloadableFromBackupTier.
    static func canDownload(_ a: MessageAttachment) -> Bool { a.backupCdnNumber != nil && a.key != nil && a.plaintextHash != nil }

    /// `getMediaName`: hex(plaintextHash ‖ key).
    static func mediaName(_ a: MessageAttachment) throws -> String {
        guard let hash = a.plaintextHash.flatMap(Data.init(hex:)), hash.count == 32, let key = a.key.flatMap({ Data(base64Encoded: $0) }), key.count == 64
        else { throw AttachmentDownloadError.missingPointer }
        return (hash + key).hexString
    }

    /// The object's location and its layer's keys (aes ‖ mac, as AttachmentCipher takes them).
    static func object(_ a: MessageAttachment, mediaRootKey: Data) throws -> (mediaId: Data, keys: Data) {
        let root = try BackupKey(contents: mediaRootKey)
        let mediaId = try root.deriveMediaId(try mediaName(a))
        let material = try root.deriveMediaEncryptionKey(mediaId)
        guard material.count == 64 else { throw BackupMediaTierError.unavailable("media key") }
        return (mediaId, material.suffix(32) + material.prefix(32))
    }

    /// The attachment's transit blob, from the media tier (at most `maxBytes` of it).
    func download(_ a: MessageAttachment, maxBytes: Int) async throws -> Data {
        guard let cdn = a.backupCdnNumber else { throw AttachmentDownloadError.missingPointer }
        guard let rootB64: String = try await database.pool.read({ try Items.get($0, "backupMediaRootKey") }), let root = Data(base64Encoded: rootB64)
        else { throw BackupMediaTierError.unavailable("no media root key") }
        let (mediaId, keys) = try Self.object(a, mediaRootKey: root)
        let auth = try await credential()
        let folder = try await mediaFolder(auth)
        let headers = try await readHeaders(auth, cdn: cdn)
        guard let base = endpoints.cdnURLs[cdn] else { throw BackupMediaTierError.unavailable("cdn \(cdn)") }
        var client = http
        // The outer layer adds an IV, up to a block of padding and a MAC.
        client.maxResponseBytes = maxBytes + 16 + 16 + 32
        let url = try base.cdnPath(["backups", folder.backupDir, folder.mediaDir, mediaId.base64URLEncodedString()])
        let object = try await client.send("GET", url, headers: headers).body
        do { return try AttachmentCipher.decryptV1(object, keys: keys) } catch {
            throw AttachmentError.badMAC
        }
    }

    // MARK: credentials

    /// The backup key and the EC key that signs presentations (upstream getBackupKey /
    /// getBackupSignatureKey).
    func keys() async throws -> (backupKey: BackupKey, signing: PrivateKey) {
        guard let aep: String = try await database.pool.read({ try Items.get($0, "accountEntropyPool") }), AccountEntropyPool.isValid(aep)
        else { throw BackupMediaTierError.unavailable("no account entropy pool") }
        let key = try AccountEntropyPool.deriveBackupKey(aep)
        return (key, key.deriveEcKey(aci: try Aci.parseFrom(serviceIdString: aci)))
    }

    /// Today's media credential (upstream BackupCredentials: credentials by day, requested for a
    /// range of days, a new day asks again).
    func credential() async throws -> BackupAuth {
        let day = Int64(Date().timeIntervalSince1970) / 86_400 * 86_400
        if let auth, auth.day == day { return auth.auth }
        let (backupKey, signing) = try await keys()
        guard let uuid = UUID(uuidString: aci) else { throw BackupMediaTierError.unavailable("aci") }
        let context = BackupAuthCredentialRequestContext.create(backupKey: backupKey.serialize(), aci: uuid)
        let r = try await socket.authenticatedResponse("GET", "/v1/archives/auth?redemptionStartSeconds=\(day)&redemptionEndSeconds=\(day + 86_400)")
        guard r.status == 200 else { throw BackupMediaTierError.unavailable("credentials: HTTP \(r.status)") }
        struct Response: Decodable {
            struct Credential: Decodable { var credential: String; var redemptionTime: Int64 }
            struct Credentials: Decodable { var media: [Credential]? }
            var credentials: Credentials
        }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: r.body) } catch { throw BackupMediaTierError.badCredentials("response") }
        guard let today = response.credentials.media?.first(where: { $0.redemptionTime == day }),
              let bytes = Data(base64Encoded: today.credential) else { throw BackupMediaTierError.badCredentials("no media credential for today") }
        let params = try GenericServerPublicParams(contents: serverParams)
        let credential: BackupAuthCredential
        do {
            credential = try context.receive(try BackupAuthCredentialResponse(contents: bytes), timestamp: Date(timeIntervalSince1970: TimeInterval(day)),
                                             params: params)
        } catch { throw BackupMediaTierError.badCredentials("credential") }
        let made = BackupAuth(credential: credential, serverKeys: params, signingKey: signing)
        auth = (day, made)
        folder = nil
        cdnHeaders = [:]
        return made
    }

    func mediaFolder(_ auth: BackupAuth) async throws -> MediaBackupInfo {
        if let folder { return folder }
        let info = try await socket.unauthenticatedConnection().getMediaBackupInfo(auth: auth)
        folder = info
        return info
    }

    func readHeaders(_ auth: BackupAuth, cdn: Int) async throws -> [String: String] {
        if let h = cdnHeaders[cdn] { return h }
        guard let n = Int32(exactly: cdn) else { throw BackupMediaTierError.unavailable("cdn \(cdn)") }
        let h = try await socket.unauthenticatedConnection().getBackupCdnCredentials(auth: auth, cdn: n).headers
        cdnHeaders[cdn] = h
        return h
    }
}

extension Data {
    /// Unpadded URL-safe base64 (upstream Bytes.toBase64url).
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

extension URL {
    /// `<base>/<segment>/…`, each segment percent-encoded as one (a folder name from the server
    /// can add no path or query of its own).
    func cdnPath(_ segments: [String]) throws -> URL {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        var s = absoluteString.hasSuffix("/") ? String(absoluteString.dropLast()) : absoluteString
        for segment in segments {
            guard !segment.isEmpty, segment != ".", segment != "..", let e = segment.addingPercentEncoding(withAllowedCharacters: unreserved) else {
                throw URLError(.badURL)
            }
            s += "/" + e
        }
        guard let url = URL(string: s) else { throw URLError(.badURL) }
        return url
    }
}
