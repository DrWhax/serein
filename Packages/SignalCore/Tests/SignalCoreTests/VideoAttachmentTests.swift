import Foundation
import LibSignalClient
import MediaXPCInterface
import SignalMediaDecoder
import Testing
@testable import SignalCore

struct NoForms: UploadFormSource {
    func uploadForm(size: Int) async throws -> UploadForm { throw HTTPError.invalidResponse }
}

@Suite struct VideoAttachmentTests {
    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Resources/Video/\(name)"))
    }

    static func topLevel(_ d: Data) -> [String] {
        var i = d.startIndex, out: [String] = []
        while i + 8 <= d.endIndex {
            let n = d[i ..< i + 4].reduce(0) { $0 << 8 | Int($1) }
            out.append(String(decoding: d[i + 4 ..< i + 8], as: UTF8.self))
            guard n >= 8 else { break }
            i += n
        }
        return out
    }

    /// ftyp free mdat moov → ftyp moov mdat (free dropped), the same frames. (mp4san keeps
    /// moov whole: the udta title stays.)
    @Test func sanitizesMoovLast() async throws {
        let original = try Self.fixture("moov_last_with_title.mp4")
        let (out, outcome) = VideoAttachments.sanitizeMP4(original)
        #expect(outcome == .rewritten)
        #expect(Self.topLevel(original) == ["ftyp", "free", "mdat", "moov"] && Self.topLevel(out) == ["ftyp", "moov", "mdat"], "\(Self.topLevel(out))")
        let d = MediaDecoder()
        let a = try await d.posterFrame(original).validated(), b = try await d.posterFrame(out).validated()
        #expect(a == b)
        let (session, info) = try await d.openVideo(out)
        var frames = 0
        while true { let f = try await d.videoFrames(session, count: 8); if f.isEmpty { break }; frames += f.count }
        await d.closeVideo(session)
        #expect(frames == 6 && info.width == 64 && info.height == 48)
    }

    @Test func leavesOthersAlone() throws {
        let clean = try Self.fixture("faststart_clean.mp4")
        let r = VideoAttachments.sanitizeMP4(clean)
        #expect(r.outcome != .unsupported)
        #expect(Self.topLevel(r.data).prefix(2) == ["ftyp", "moov"] && Self.topLevel(r.data).last == "mdat")
        let junk = Data("definitely not an mp4".utf8)
        #expect(VideoAttachments.sanitizeMP4(junk) == (junk, .unsupported))
    }

    /// `prepare` sends the sanitized file and stores the screenshot, size and duration.
    @Test func prepareVideo() async throws {
        let store = try AttachmentStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID())"))
        let services = AttachmentServices(store: store, uploader: AttachmentUploader(http: HTTPClient(rootCertificatesDER: []), forms: NoForms()),
                                          media: MediaDecoder())
        let original = try Self.fixture("moov_last_with_title.mp4")
        let a = try await services.prepare(OutgoingAttachment(data: original, contentType: "video/mp4", fileName: "IMG_0001.mp4"))
        let sent = try #require(try store.plaintext(of: a))
        // Metadata stripped (the udta title), then mp4san's layout.
        let stripped = try await MediaDecoder().stripMetadata(original, contentType: "video/mp4")
        #expect(sent == VideoAttachments.sanitizeMP4(stripped).data && a.size == sent.count)
        #expect(original.range(of: Data("secret title".utf8)) != nil && sent.range(of: Data("secret title".utf8)) == nil)
        #expect(a.fileName == nil && a.width == 64 && a.height == 48 && abs((a.duration ?? 0) - 0.2) < 0.01)
        let shot = try #require(a.screenshot)
        #expect(shot.contentType == "image/png" && shot.width == 64)
        let png = try AttachmentCipher.decryptLocal(store.read(shot.path), localKey: Data(base64Encoded: shot.localKey)!, size: shot.size)
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    static func metadataFixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Resources/Metadata/\(name)"))
    }

    /// Nothing visual leaves with its metadata: re-encoded images have none, the rest is
    /// stripped, and what cannot be stripped is refused.
    @Test(arguments: [("photo.jpg", "image/jpeg"), ("image.png", "image/png"), ("image.webp", "image/webp"), ("anim.gif", "image/gif"),
                      ("photo.heic", "image/heic"), ("moov_last.mp4", "video/mp4"), ("faststart.mp4", "video/mp4"), ("clip.mov", "video/quicktime")])
    func noMetadataLeaves(name: String, type: String) async throws {
        let store = try AttachmentStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID())"))
        let services = AttachmentServices(store: store, uploader: AttachmentUploader(http: HTTPClient(rootCertificatesDER: []), forms: NoForms()),
                                          media: MediaDecoder())
        let original = try Self.metadataFixture(name)
        #expect(original.range(of: Data("Secret".utf8)) != nil)
        for transcode in [true, false] {
            let a = try await services.prepare(OutgoingAttachment(data: original, contentType: type), transcode: transcode)
            let sent = try #require(try store.plaintext(of: a))
            #expect(sent.range(of: Data("Secret".utf8)) == nil, "\(name) transcode \(transcode)")
        }
    }

    /// handleImageAttachment: HEIC (by type or by name) is sent as a JPEG converted at quality
    /// 0.75 and then scaled; without transcoding it stays HEIC, stripped.
    @Test func heicIsSentAsJPEG() async throws {
        let store = try AttachmentStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID())"))
        let services = AttachmentServices(store: store, uploader: AttachmentUploader(http: HTTPClient(rootCertificatesDER: []), forms: NoForms()),
                                          media: MediaDecoder())
        let heic = try Self.metadataFixture("grid.heic")
        for (type, name) in [("image/heic", "IMG_0001.HEIC"), ("application/octet-stream", "IMG_0002.heif"), ("image/heif", nil as String?)] {
            let a = try await services.prepare(OutgoingAttachment(data: heic, contentType: type, fileName: name))
            let sent = try #require(try store.plaintext(of: a))
            #expect(a.contentType == "image/jpeg" && sent.prefix(2) == Data([0xFF, 0xD8]), "\(type) \(name ?? "-")")
            #expect(a.fileName == nil && a.width == 700 && a.height == 450 && a.blurHash != nil && a.thumbnail != nil)
        }
        let kept = try await services.prepare(OutgoingAttachment(data: heic, contentType: "image/heic", fileName: "IMG_0003.HEIC"), transcode: false)
        #expect(kept.contentType == "image/heic")
        #expect(AttachmentServices.isHeic("image/jpeg", fileName: "photo.Heic") && !AttachmentServices.isHeic("image/avif", fileName: "x.avif"))
    }

    @Test func refusesWhatCannotBeStripped() async throws {
        let store = try AttachmentStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID())"))
        let services = AttachmentServices(store: store, uploader: AttachmentUploader(http: HTTPClient(rootCertificatesDER: []), forms: NoForms()),
                                          media: MediaDecoder())
        for (data, type) in [(Data("not really a jpeg".utf8), "image/jpeg"), (Data("II*\u{0}tiff".utf8), "image/tiff"), (Data("junk".utf8), "video/mp4")] {
            await #expect(throws: OutgoingAttachmentError.self, "\(type)") {
                try await services.prepare(OutgoingAttachment(data: data, contentType: type))
            }
        }
        // Not images or videos: sent as they are.
        let pdf = Data("%PDF-1.4 Author SecretAuthor".utf8)
        let a = try await services.prepare(OutgoingAttachment(data: pdf, contentType: "application/pdf", fileName: "x.pdf"))
        #expect(try store.plaintext(of: a) == pdf)
    }
}
