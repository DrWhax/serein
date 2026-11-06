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
    /// DER root certificates to trust exclusively; empty means the system trust store.
    public var rootCertificatesDER: [Data]

    public init(storageURL: URL, cdnURLs: [Int: URL], rootCertificatesDER: [Data]) {
        self.storageURL = storageURL
        self.cdnURLs = cdnURLs
        self.rootCertificatesDER = rootCertificatesDER
    }

    /// The layout Desktop's mock-server tests use: everything on one HTTPS port.
    public static func mockServer(port: Int, rootCertificateDER: Data) -> ServiceEndpoints {
        let base = URL(string: "https://localhost:\(port)")!
        return ServiceEndpoints(storageURL: base.appendingPathComponent("storageService"),
                                cdnURLs: [0: base, 2: base, 3: base.appendingPathComponent("cdn3")],
                                rootCertificatesDER: [rootCertificateDER])
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

    /// `send`, also returning the response headers (lower-cased names).
    public func sendWithHeaders(_ method: String, _ url: URL, body: Data? = nil, headers: [String: String] = [:],
                                accept: Set<Int> = []) async throws -> (status: Int, body: Data, headers: [String: String]) {
        guard url.scheme?.lowercased() == "https" else { throw HTTPError.insecureURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        guard data.count <= maxResponseBytes else { throw HTTPError.tooLarge(data.count) }
        guard (200..<300).contains(http.statusCode) || accept.contains(http.statusCode) else {
            throw HTTPError.status(http.statusCode, body: data)
        }
        var out: [String: String] = [:]
        for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { out[k.lowercased()] = v } }
        return (http.statusCode, data, out)
    }

    /// Performs a request; non-2xx statuses other than those in `accept` throw `HTTPError.status`.
    public func send(_ method: String, _ url: URL, body: Data? = nil, headers: [String: String] = [:],
                     accept: Set<Int> = []) async throws -> (status: Int, body: Data) {
        guard url.scheme?.lowercased() == "https" else { throw HTTPError.insecureURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        guard data.count <= maxResponseBytes else { throw HTTPError.tooLarge(data.count) }
        guard (200..<300).contains(http.statusCode) || accept.contains(http.statusCode) else {
            throw HTTPError.status(http.statusCode, body: data)
        }
        return (http.statusCode, data)
    }
}
