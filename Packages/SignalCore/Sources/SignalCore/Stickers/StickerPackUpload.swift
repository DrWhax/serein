// Uploading a pack from the sticker creator (sticker-creator util/crypto `encrypt` +
// WebAPI `putStickers`): a fresh 32-byte pack key, HKDF "Sticker Pack" keys, each distinct
// image and the StickerPack manifest encrypted as V1 attachments (IV ‖ AES-CBC ‖ HMAC), then
// `GET v1/sticker/pack/form/<count>` for the CDN upload forms and a multipart POST of each
// (manifest first, then the stickers three at a time).

import Foundation
import SignalProtos

public struct StickerPackDraft: Sendable {
    public struct Sticker: Sendable {
        public var data: Data
        public var emoji: String?
        public init(data: Data, emoji: String?) {
            self.data = data
            self.emoji = emoji
        }
    }
    public var title: String
    public var author: String
    public var stickers: [Sticker]
    public var cover: Data
    public init(title: String, author: String, stickers: [Sticker], cover: Data) {
        self.title = title
        self.author = author
        self.stickers = stickers
        self.cover = cover
    }
}

public struct EncryptedStickerPack: Sendable {
    public var manifest: Data
    public var images: [Data]
    /// hex
    public var packKey: String
}

/// `ServerV2AttachmentType`: one S3 POST form.
struct StickerUploadForm: Decodable {
    var acl: String
    var algorithm: String
    var credential: String
    var date: String
    var id: Int
    var key: String
    var policy: String
    var signature: String
}

public enum StickerPackUpload {
    public static let minStickers = 1
    public static let maxStickers = 200

    static func encryptV1(_ plaintext: Data, keys: Data) throws -> Data {
        let iv = SignalCrypto.randomBytes(16)
        let body = iv + (try SignalCrypto.aes256CBCEncrypt(key: keys.prefix(32), iv: iv, plaintext))
        return body + SignalCrypto.hmacSHA256(key: keys.suffix(32), body)
    }

    /// `encrypt`: identical images go up once; the cover reuses a sticker's id (and emoji) if
    /// it is one of them.
    public static func encrypt(_ draft: StickerPackDraft, packKey: Data = SignalCrypto.randomBytes(32)) throws -> EncryptedStickerPack {
        let keys = try Stickers.derivePackKey(packKey)
        var uploads: [Data] = []
        var idByImage: [Data: Int] = [:]
        var emojiByImage: [Data: String] = [:]
        for s in draft.stickers where idByImage[s.data] == nil {
            idByImage[s.data] = uploads.count
            if let e = s.emoji { emojiByImage[s.data] = e }
            uploads.append(s.data)
        }
        var coverId = idByImage[draft.cover]
        var coverEmoji: String?
        if coverId == nil {
            coverId = uploads.count
            uploads.append(draft.cover)
        } else {
            coverEmoji = emojiByImage[draft.cover]
        }
        var manifest = Signalservice_StickerPack()
        manifest.title = draft.title
        manifest.author = draft.author
        manifest.stickers = draft.stickers.enumerated().map { id, s in
            var sticker = Signalservice_StickerPack.Sticker()
            sticker.id = UInt32(id)
            if let e = s.emoji { sticker.emoji = e }
            return sticker
        }
        var cover = Signalservice_StickerPack.Sticker()
        cover.id = UInt32(coverId ?? 0)
        if let coverEmoji { cover.emoji = coverEmoji }
        manifest.cover = cover
        return EncryptedStickerPack(manifest: try encryptV1(try manifest.serializedBytes(), keys: keys),
                                    images: try uploads.map { try encryptV1($0, keys: keys) },
                                    packKey: packKey.hexString)
    }

    /// `makePutParams`: the S3 form fields, then the file.
    static func multipart(_ form: StickerUploadForm, _ file: Data, boundary: String = "----------------" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        -> (body: Data, contentType: String)
    {
        let crlf = "\r\n"
        func section(_ name: String, _ value: String) -> String {
            ["--\(boundary)", "Content-Disposition: form-data; name=\"\(name)\"\(crlf)", value].joined(separator: crlf)
        }
        let start = [section("key", form.key), section("x-amz-credential", form.credential), section("acl", form.acl),
                     section("x-amz-algorithm", form.algorithm), section("x-amz-date", form.date), section("policy", form.policy),
                     section("x-amz-signature", form.signature), section("Content-Type", "application/octet-stream"),
                     "--\(boundary)", "Content-Disposition: form-data; name=\"file\"", "Content-Type: application/octet-stream\(crlf)\(crlf)"]
            .joined(separator: crlf)
        let end = "\(crlf)--\(boundary)--\(crlf)"
        return (Data(start.utf8) + file + Data(end.utf8), "multipart/form-data; boundary=\(boundary)")
    }

    /// `putStickers`: returns the pack id.
    public static func upload(_ pack: EncryptedStickerPack, socket: SocketManager, http: HTTPClient, cdn: URL,
                              onProgress: @escaping @Sendable () -> Void = {}) async throws -> String {
        struct Forms: Decodable { var packId: String; var manifest: StickerUploadForm; var stickers: [StickerUploadForm] }
        let forms = try JSONDecoder().decode(Forms.self, from: try await socket.authenticatedRequest("GET", "/v1/sticker/pack/form/\(pack.images.count)"))
        guard forms.stickers.count == pack.images.count else { throw StickerError.malformedManifest("upload forms for \(forms.stickers.count) stickers") }
        func post(_ form: StickerUploadForm, _ data: Data) async throws {
            let (body, type) = multipart(form, data)
            _ = try await http.send("POST", cdn.appendingPathComponent(""), body: body, headers: ["Content-Type": type, "Content-Length": String(body.count)],
                                    accept: [200, 204])
        }
        try await post(forms.manifest, pack.manifest)
        let images = pack.images
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func start() {
                guard next < images.count else { return }
                let i = next
                next += 1
                group.addTask { try await post(forms.stickers[i], images[i]); onProgress() }
            }
            for _ in 0..<3 { start() }
            while try await group.next() != nil { start() }
        }
        return forms.packId
    }

    /// The link to share (`https://signal.art/addstickers/#pack_id=…&pack_key=…`).
    public static func shareURL(packId: String, packKey: String) -> URL {
        URL(string: "https://signal.art/addstickers/#pack_id=\(packId)&pack_key=\(packKey)")!
    }
}
