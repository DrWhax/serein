// Upload (ts/util/uploadAttachment.preload.ts, ts/util/uploads/tusProtocol.node.ts,
// WebAPI putEncryptedAttachment): encrypt with fresh keys, ask the chat server for an upload
// form sized to the ciphertext, then send the blob to the form's CDN — TUS
// creation-with-upload (resumed with HEAD/PATCH) on CDN3, a resumable PUT on CDN2.

import Foundation
import LibSignalClient

/// What a sent AttachmentPointer needs (`UploadedAttachmentType`).
public struct UploadedAttachment: Sendable, Equatable {
    public var cdnKey: String
    public var cdnNumber: Int
    public var keys: Data
    public var digest: Data
    public var plaintextHash: String
    public var incrementalMac: Data?
    public var chunkSize: Int?
    public var size: Int
    public var uploadTimestamp: UInt64
}

public enum UploadError: Error, Equatable {
    case missingLocation
    case badOffset(String?)
    case gaveUp
}

/// Where upload forms come from (SocketManager in the app; injectable for tests).
public protocol UploadFormSource: Sendable {
    func uploadForm(size: Int) async throws -> UploadForm
}

extension SocketManager: UploadFormSource {}

public struct AttachmentUploader: Sendable {
    public static let cdnsSupportingTus: Set<Int> = [3]
    /// `FIBONACCI_TIMEOUTS` (seconds), the TUS resume backoff.
    public static let backoff: [Double] = [1, 2, 3, 5, 8, 13, 21, 34, 55]
    public static let maxRetries = 10

    let http: HTTPClient
    let forms: any UploadFormSource
    /// Test hook: shortens the resume backoff.
    var backoffScale: Double = 1

    public init(http: HTTPClient, forms: any UploadFormSource) {
        self.http = http
        self.forms = forms
    }

    /// `MIME.supportsIncrementalMac`
    public static func supportsIncrementalMac(_ contentType: String) -> Bool { contentType == "video/mp4" }

    public func upload(_ plaintext: Data, contentType: String, now: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) async throws
        -> UploadedAttachment
    {
        let keys = AttachmentCipher.generateKeys()
        let encrypted = try AttachmentCipher.encrypt(plaintext, keys: keys, incrementalMac: Self.supportsIncrementalMac(contentType))
        let form = try await forms.uploadForm(size: encrypted.ciphertextSize)
        try await uploadBlob(encrypted.blob, form: form)
        return UploadedAttachment(cdnKey: form.key, cdnNumber: Int(form.cdn), keys: keys, digest: encrypted.digest,
                                  plaintextHash: encrypted.plaintextHash, incrementalMac: encrypted.incrementalMac,
                                  chunkSize: encrypted.chunkSize, size: plaintext.count, uploadTimestamp: now)
    }

    /// `uploadFile`
    public func uploadBlob(_ blob: Data, form: UploadForm) async throws {
        if Self.cdnsSupportingTus.contains(Int(form.cdn)) {
            try await tusUpload(blob, endpoint: form.signedUploadUrl, fileName: form.key, headers: form.headers)
        } else {
            try await putResumable(blob, form: form)
        }
    }

    // MARK: TUS (CDN3)

    static func metadataHeader(_ params: [(String, String)]) -> String {
        params.map { "\($0.0) \(Data($0.1.utf8).base64EncodedString())" }.joined(separator: ",")
    }

    func tusUpload(_ blob: Data, endpoint: URL, fileName: String, headers: [String: String]) async throws {
        var create = headers
        create["Tus-Resumable"] = "1.0.0"
        create["Upload-Length"] = String(blob.count)
        create["Upload-Metadata"] = Self.metadataHeader([("filename", fileName)])
        create["Content-Type"] = "application/offset+octet-stream"
        do {
            _ = try await http.sendWithHeaders("POST", endpoint, body: blob, headers: create)
            return
        } catch let error as HTTPError {
            throw error            // the server answered with an error: not resumable
        } catch {
            // Closed without a response: resume below.
        }
        let resource = endpoint.appendingPathComponent(fileName)
        for attempt in 0..<Self.maxRetries {
            try await Task.sleep(for: .seconds(Self.backoff[min(attempt, Self.backoff.count - 1)] * backoffScale))
            var head = headers
            head["Tus-Resumable"] = "1.0.0"
            let state = try await http.sendWithHeaders("HEAD", resource, headers: head)
            guard let header = state.headers["upload-offset"], let offset = Int(header), offset >= 0, offset <= blob.count else {
                throw UploadError.badOffset(state.headers["upload-offset"])
            }
            if offset == blob.count { return }
            var patch = headers
            patch["Tus-Resumable"] = "1.0.0"
            patch["Upload-Offset"] = String(offset)
            patch["Content-Type"] = "application/offset+octet-stream"
            do {
                _ = try await http.sendWithHeaders("PATCH", resource, body: Data(blob.dropFirst(offset)), headers: patch)
                return
            } catch let error as HTTPError {
                throw error
            } catch {
                continue
            }
        }
        throw UploadError.gaveUp
    }

    // MARK: Resumable PUT (CDN2)

    func putResumable(_ blob: Data, form: UploadForm) async throws {
        let start = try await http.sendWithHeaders("POST", form.signedUploadUrl, headers: form.headers)
        guard let location = start.headers["location"], let url = URL(string: location) else { throw UploadError.missingLocation }
        var offset = 0
        for attempt in 0..<Self.maxRetries {
            if attempt > 0 {
                // Ask how much arrived: 308 with `Range: bytes=0-N`.
                let probe = try await http.sendWithHeaders("PUT", url, headers: ["Content-Range": "bytes */\(blob.count)"], accept: [308])
                if probe.status != 308 { return }
                if let range = probe.headers["range"], let end = range.split(separator: "-").last.flatMap({ Int($0) }) { offset = end + 1 }
            }
            do {
                _ = try await http.sendWithHeaders("PUT", url, body: Data(blob.dropFirst(offset)),
                                                  headers: ["Content-Range": "bytes \(offset)-*/\(blob.count)"])
                return
            } catch let error as HTTPError {
                throw error
            } catch {
                continue
            }
        }
        throw UploadError.gaveUp
    }
}
