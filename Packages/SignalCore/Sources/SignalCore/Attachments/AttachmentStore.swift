// Attachments at rest (ts/util/attachmentPath.node.ts, ts/windows/attachments.ts): every file
// under the attachments directory is a locally encrypted v2 blob named
// `<2 hex>/<64 hex>` (createName + getRelativePath). Saving one out decrypts it and marks the
// copy as downloaded from the internet (com.apple.quarantine, set through URL resource values).

import Foundation
import GRDB

public enum AttachmentStoreError: Error, Equatable {
    case invalidPath(String)
}

public struct AttachmentStore: Sendable {
    public let root: URL

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// `createName` + `getRelativePath`
    public static func newRelativePath() -> String {
        let name = SignalCrypto.randomBytes(32).hexString
        return "\(name.prefix(2))/\(name)"
    }

    /// Only paths of our own shape resolve, so a stored path can never escape the root.
    public func url(_ relativePath: String) throws -> URL {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        let hex = Set("0123456789abcdef")
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 64, parts[1].hasPrefix(parts[0]),
              parts[1].allSatisfy({ hex.contains($0) }) else { throw AttachmentStoreError.invalidPath(relativePath) }
        return root.appendingPathComponent(String(parts[0]), isDirectory: true).appendingPathComponent(String(parts[1]))
    }

    /// Writes a blob under a fresh name; returns the relative path.
    public func write(_ blob: Data) throws -> String {
        let path = Self.newRelativePath()
        let u = try url(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Class C (until first unlock), as Signal-iOS: class A (.completeFileProtection) refuses
        // writes while the Mac is locked, so attachments arriving then could not be saved. The
        // blob is already encrypted under its own local key.
        try blob.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return path
    }

    public func read(_ relativePath: String) throws -> Data { try Data(contentsOf: try url(relativePath)) }

    /// Every stored file's relative path (`xx/<64 hex>`).
    func allPaths() throws -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for dir in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where dir.count == 2 {
            for name in (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)) ?? [] {
                let p = dir + "/" + name
                if (try? url(p)) != nil { out.append(p) }
            }
        }
        return out
    }

    /// `cleanupOrphanedAttachments`: files no message attachment, sticker or avatar refers to
    /// (left by erased messages, replaced stickers, failed writes). Returns how many went.
    @discardableResult
    public func deleteOrphans(_ db: Database) throws -> Int {
        var referenced = Set(try String.fetchAll(db, sql: """
            SELECT path FROM message_attachments WHERE path IS NOT NULL
            UNION SELECT thumbnailPath FROM message_attachments WHERE thumbnailPath IS NOT NULL
            UNION SELECT screenshotPath FROM message_attachments WHERE screenshotPath IS NOT NULL
            UNION SELECT downloadPath FROM message_attachments WHERE downloadPath IS NOT NULL
            UNION SELECT path FROM stickers WHERE path IS NOT NULL
            UNION SELECT json ->> '$.avatar.path' FROM conversations WHERE json ->> '$.avatar.path' IS NOT NULL
            UNION SELECT json ->> '$.profileAvatar.path' FROM conversations WHERE json ->> '$.profileAvatar.path' IS NOT NULL
            """))
        // Files a pending download is about to replace stay too.
        referenced.formUnion(try String.fetchAll(db, sql: "SELECT attachmentJson ->> '$.path' FROM attachment_downloads WHERE attachmentJson ->> '$.path' IS NOT NULL"))
        var removed = 0
        for p in try allPaths() where !referenced.contains(p) {
            try delete(p)
            removed += 1
        }
        return removed
    }

    public func delete(_ relativePath: String) throws {
        let u = try url(relativePath)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
    }

    /// Encrypts `plaintext` at rest under a fresh local key.
    public func storeLocally(_ plaintext: Data) throws -> (path: String, localKey: Data, plaintextHash: String) {
        let keys = AttachmentCipher.generateKeys()
        let e = try AttachmentCipher.encrypt(plaintext, keys: keys)
        return (try write(e.blob), keys, e.plaintextHash)
    }

    /// The plaintext of a downloaded attachment.
    public func plaintext(of a: MessageAttachment) throws -> Data? {
        guard let path = a.path, let key = a.localKey, let k = Data(base64Encoded: key) else { return nil }
        return try AttachmentCipher.decryptLocal(read(path), localKey: k, size: a.size)
    }

    /// "Save as…": writes the plaintext to `destination` and sets its quarantine properties
    /// (the agent is the app; LSQuarantineType = web download), as browsers and Electron do.
    public func export(_ a: MessageAttachment, to destination: URL, agentName: String = "Signal") throws {
        guard let data = try plaintext(of: a) else { throw AttachmentStoreError.invalidPath(a.path ?? "") }
        try data.write(to: destination, options: .atomic)
        try Self.quarantine(destination, agentName: agentName)
    }

    public static func quarantine(_ url: URL, agentName: String) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [
            "LSQuarantineAgentName": agentName,
            "LSQuarantineType": "LSQuarantineTypeWebDownload",
            "LSQuarantineTimeStamp": Date(),
        ]
        var u = url
        try u.setResourceValues(values)
    }
}
