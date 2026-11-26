#if os(Linux)
import Foundation
import FoundationNetworking
import LinuxHTTP

public struct URLSessionWebTransport: WebTransport {
    let proxy: ContentProxy
    let roots: [Data]
    let timeout: TimeInterval

    public init(proxy: ContentProxy, rootCertificatesDER: [Data] = [], timeout: TimeInterval = 60) {
        self.proxy = proxy
        self.roots = rootCertificatesDER
        self.timeout = timeout
    }

    public func request(_ method: String, _ url: URL, headers: [String: String], limit: Int) async throws -> WebResponse {
        guard url.scheme?.lowercased() == "https" else { throw WebError.insecureURL }
        guard limit >= 0, limit < Int.max else { throw WebError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.allHTTPHeaderFields = headers
        let transfer = try LinuxHTTPRequest(request, roots: roots, invalidResponse: WebError.invalidResponse)
        defer { transfer.cancel() }
        switch proxy {
        case .direct: try transfer.setProxy("")
        case .signal: try transfer.setProxy("http://contentproxy.signal.org:443")
        case .custom(let host, let port):
            var components = URLComponents()
            components.scheme = "http"
            guard !host.isEmpty, (1...65535).contains(port) else { throw WebError.invalidResponse }
            components.host = host
            components.port = port
            guard let proxyURL = components.url else { throw WebError.invalidResponse }
            try transfer.setProxy(proxyURL.absoluteString)
        }
        let response = try await transfer.send(url: url)
        var data = Data()
        if method != "HEAD", !(300..<400).contains(response.statusCode) {
            while data.count <= limit {
                let next = try await transfer.read(upTo: limit + 1 - data.count)
                if next.isEmpty { break }
                data.append(contentsOf: next)
            }
        }
        var fields = [String: String]()
        for (key, value) in response.allHeaderFields {
            if let name = key as? String, let text = value as? String { fields[name.lowercased()] = text }
        }
        return WebResponse(status: response.statusCode, headers: fields, body: data, url: url, remoteAddresses: transfer.peerAddresses())
    }
}
#endif
