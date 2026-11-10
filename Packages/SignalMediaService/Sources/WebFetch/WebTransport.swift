// HTTPS for the web-facing services (SignalLinkPreviewFetcher.xpc, SignalGifSearch.xpc): one
// request at a time, never following redirects (callers check every hop), the body read up
// to a limit, ephemeral (no cookies, cache or credentials), optionally through an HTTP CONNECT
// proxy (Signal's content proxy for Giphy; the test harness's stand-in), with the system's
// trust or (tests) pinned roots.

import Foundation
import Security

public struct WebResponse: Sendable {
    public var status: Int
    /// Lower-cased names.
    public var headers: [String: String]
    /// At most `limit + 1` bytes (one more than allowed means "too large").
    public var body: Data
    public var url: URL

    public init(status: Int, headers: [String: String], body: Data, url: URL) {
        self.status = status
        self.headers = headers
        self.body = body
        self.url = url
    }
}

/// One request, never following redirects.
public protocol WebTransport: Sendable {
    func request(_ method: String, _ url: URL, headers: [String: String], limit: Int) async throws -> WebResponse
}

extension WebTransport {
    public func get(_ url: URL, headers: [String: String], limit: Int) async throws -> WebResponse {
        try await request("GET", url, headers: headers, limit: limit)
    }
}

public enum ContentProxy: Sendable, Equatable {
    /// contentproxy.signal.org:443 (lets a fixed set of hosts through, Giphy among them).
    case signal
    case custom(host: String, port: Int)
    /// Straight to the site (link previews, as upstream Desktop fetches them).
    case direct

    var dictionary: [AnyHashable: Any]? {
        switch self {
        case .signal: return ["HTTPSEnable": 1, "HTTPSProxy": "contentproxy.signal.org", "HTTPSPort": 443]
        case .custom(let host, let port): return ["HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
        case .direct: return nil
        }
    }
}

public enum WebError: Error, Equatable {
    case insecureURL
    case invalidResponse
    /// The host is not on the public internet (PublicDestinationTransport).
    case forbiddenDestination
}

/// The session's only delegate: no redirects, server trust from the system or the pinned roots.
final class WebSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let rootsDER: [Data]
    init(rootsDER: [Data]) { self.rootsDER = rootsDER }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        trust(challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) { trust(challenge) }

    func trust(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust else {
            // Client-certificate or HTTP authentication: nothing is offered (the session has no
            // credential storage), so the request goes on without.
            return (.performDefaultHandling, nil)
        }
        if rootsDER.isEmpty { return (.performDefaultHandling, nil) }
        let anchors = rootsDER.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard anchors.count == rootsDER.count, SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return (.cancelAuthenticationChallenge, nil) }
        return SecTrustEvaluateWithError(trust, nil) ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }
}

public struct URLSessionWebTransport: WebTransport {
    let session: URLSession

    public init(proxy: ContentProxy, rootCertificatesDER: [Data] = [], timeout: TimeInterval = 60) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.connectionProxyDictionary = proxy.dictionary
        session = URLSession(configuration: config, delegate: WebSessionDelegate(rootsDER: rootCertificatesDER), delegateQueue: nil)
    }

    public func request(_ method: String, _ url: URL, headers: [String: String], limit: Int) async throws -> WebResponse {
        guard url.scheme?.lowercased() == "https" else { throw WebError.insecureURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebError.invalidResponse }
        var body = Data()
        if !(300..<400).contains(http.statusCode) && method != "HEAD" {
            for try await b in bytes {
                body.append(b)
                if body.count > limit { break }
            }
        }
        bytes.task.cancel()
        var out: [String: String] = [:]
        for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { out[k.lowercased()] = v } }
        return WebResponse(status: http.statusCode, headers: out, body: body, url: http.url ?? url)
    }
}
