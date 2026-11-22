// HTTPS for the services Desktop reaches outside the chat socket (WebAPI
// STORAGE_CALLS, CDN downloads): URLSession with an ephemeral configuration, no
// cookies or cache, and — when root certificates are configured — trust limited to
// exactly those roots (Signal pins its own CA; tests pin the mock server's CA).

import Foundation
import Security

/// Base URLs of the non-chat services (Desktop config: storageUrl, cdn{0,2,3}).
public struct ServiceEndpoints: Sendable {
    public var storageURL: URL
    public var cdnURLs: [Int: URL]
    public var sfuURL: URL?
    /// DER root certificates to trust exclusively; empty means the system trust store.
    public var rootCertificatesDER: [Data]

    public init(storageURL: URL, cdnURLs: [Int: URL], rootCertificatesDER: [Data], sfuURL: URL? = nil) {
        self.storageURL = storageURL
        self.cdnURLs = cdnURLs
        self.rootCertificatesDER = rootCertificatesDER
        self.sfuURL = sfuURL
    }

    /// The layout Desktop's mock-server tests use: everything on one HTTPS port.
    public static func mockServer(port: Int, rootCertificateDER: Data) -> ServiceEndpoints {
        let base = URL(string: "https://localhost:\(port)")!
        return ServiceEndpoints(storageURL: base.appendingPathComponent("storageService"),
                                cdnURLs: [0: base, 2: base, 3: base.appendingPathComponent("cdn3")],
                                rootCertificatesDER: [rootCertificateDER], sfuURL: base.appendingPathComponent("callingService"))
    }
}

public enum HTTPError: Error, Equatable {
    case status(Int, body: Data)
    case invalidResponse
    case tooLarge(Int)
    /// Only https:// is allowed (the app's ATS exceptions would otherwise permit http to Signal hosts).
    case insecureURL
}

/// Server-trust evaluation against pinned roots only; redirects must stay on https.
final class PinnedTrustDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let rootsDER: [Data]
    init(rootsDER: [Data]) { self.rootsDER = rootsDER }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        if rootsDER.isEmpty { return (.performDefaultHandling, nil) }
        let anchors = rootsDER.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard anchors.count == rootsDER.count,
              SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess
        else { return (.cancelAuthenticationChallenge, nil) }
        // URLSession calls this off the main thread, where synchronous evaluation is allowed.
        let trusted = SecTrustEvaluateWithError(trust, nil)
        return trusted ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }

    /// The same for a task's challenge (streamed responses, `URLSession.bytes`, ask the task).
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        await urlSession(session, didReceive: challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url?.scheme?.lowercased() == "https" ? request : nil
    }
}

public struct HTTPClient: Sendable {
    let session: URLSession
    /// Responses larger than this are rejected (storage manifests/items and contact blobs are small).
    public var maxResponseBytes = 64 << 20

    public init(rootCertificatesDER: [Data]) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: PinnedTrustDelegate(rootsDER: rootCertificatesDER), delegateQueue: nil)
    }

    public static func basicAuth(_ username: String, _ password: String) -> String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    /// The response, read no further than `maxResponseBytes`: a larger declared length is refused
    /// before the body is read, and the transfer stops at the limit whatever the server declares.
    func bounded(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(maxResponseBytes) {
            bytes.task.cancel()
            throw HTTPError.tooLarge(Int(clamping: response.expectedContentLength))
        }
        do {
            return (try await Self.collect(bytes, limit: maxResponseBytes, expected: response.expectedContentLength), response)
        } catch {
            bytes.task.cancel()
            throw error
        }
    }

    /// At most `limit` bytes of `bytes`; one more is `HTTPError.tooLarge`.
    static func collect<S: AsyncSequence>(_ bytes: S, limit: Int, expected: Int64 = -1) async throws -> Data where S.Element == UInt8 {
        var data = Data()
        data.reserveCapacity(expected > 0 ? Int(min(expected, Int64(limit))) : min(limit, 1 << 16))
        for try await b in bytes {
            guard data.count < limit else { throw HTTPError.tooLarge(data.count + 1) }
            data.append(b)
        }
        return data
    }

    /// `send`, also returning the response headers (lower-cased names).
    public func sendWithHeaders(_ method: String, _ url: URL, body: Data? = nil, headers: [String: String] = [:],
                                accept: Set<Int> = []) async throws -> (status: Int, body: Data, headers: [String: String]) {
        guard url.scheme?.lowercased() == "https" else { throw HTTPError.insecureURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await bounded(request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        guard (200..<300).contains(http.statusCode) || accept.contains(http.statusCode) else {
            throw HTTPError.status(http.statusCode, body: data)
        }
        var out: [String: String] = [:]
        for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { out[k.lowercased()] = v } }
        return (http.statusCode, data, out)
    }

    /// A GET written to `file` as it arrives (nothing held in memory but a megabyte), at most
    /// `maxBytes` in all. What the file holds already is kept and the rest asked for (a Range
    /// request), unless the server answers with the whole body, which then replaces it.
    /// `progress`: bytes in the file, and the whole size when the server says it.
    public func download(_ url: URL, to file: URL, maxBytes: Int64, progress: @Sendable (Int64, Int64?) -> Void = { _, _ in }) async throws {
        guard url.scheme?.lowercased() == "https" else { throw HTTPError.insecureURL }
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        var offset = Int64(try handle.seekToEnd())
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        do {
            guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
            var total: Int64? = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
            switch http.statusCode {
            case 206 where offset > 0:
                // "bytes <first>-<last>/<size>": it must go on from where the file ends.
                let range = (http.value(forHTTPHeaderField: "Content-Range") ?? "").split(whereSeparator: { " -/".contains($0) })
                guard range.count == 4, range[0] == "bytes", Int64(range[1]) == offset else { throw HTTPError.invalidResponse }
                total = Int64(range[3])
            case 200..<300:
                offset = 0
            case 416:
                // Nothing past what the file holds: it is not the file the server has. Start over.
                try handle.truncate(atOffset: 0)
                throw HTTPError.status(416, body: Data())
            default:
                throw HTTPError.status(http.statusCode, body: Data())
            }
            if let t = total, t > maxBytes { throw HTTPError.tooLarge(Int(clamping: t)) }
            try handle.truncate(atOffset: UInt64(offset))
            try handle.seek(toOffset: UInt64(offset))
            progress(offset, total)
            var buffer = Data()
            buffer.reserveCapacity(1 << 20)
            for try await b in bytes {
                buffer.append(b)
                if buffer.count == 1 << 20 {
                    guard offset + Int64(buffer.count) <= maxBytes else { throw HTTPError.tooLarge(Int(clamping: offset + Int64(buffer.count))) }
                    try handle.write(contentsOf: buffer)
                    offset += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    progress(offset, total)
                }
            }
            guard offset + Int64(buffer.count) <= maxBytes else { throw HTTPError.tooLarge(Int(clamping: offset + Int64(buffer.count))) }
            try handle.write(contentsOf: buffer)
            offset += Int64(buffer.count)
            if let t = total, offset != t { throw HTTPError.invalidResponse }
            try handle.synchronize()
            progress(offset, offset)
        } catch {
            bytes.task.cancel()
            throw error
        }
    }

    /// Performs a request; non-2xx statuses other than those in `accept` throw `HTTPError.status`.
    public func send(_ method: String, _ url: URL, body: Data? = nil, headers: [String: String] = [:],
                     accept: Set<Int> = []) async throws -> (status: Int, body: Data) {
        guard url.scheme?.lowercased() == "https" else { throw HTTPError.insecureURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await bounded(request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        guard (200..<300).contains(http.statusCode) || accept.contains(http.statusCode) else {
            throw HTTPError.status(http.statusCode, body: data)
        }
        return (http.statusCode, data)
    }
}

extension URL {
    /// `<cdn>/attachments/<encodeURIComponent(key)>` (upstream getAttachment): a key from a
    /// sender or the server can never add path segments ("../", "/") or a query.
    func cdnAttachment(_ key: String) throws -> URL {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: unreserved), !encoded.isEmpty,
              let url = URL(string: absoluteString.hasSuffix("/") ? absoluteString + "attachments/" + encoded : absoluteString + "/attachments/" + encoded)
        else { throw URLError(.badURL) }
        return url
    }
}
