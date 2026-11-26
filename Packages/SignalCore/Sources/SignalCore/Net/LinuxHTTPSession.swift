#if os(Linux)
import CLinuxHTTP
import Foundation
import FoundationNetworking

/// A request owns one SoupSession and one cancellable. GIO performs certificate
/// chain and hostname verification before handing back response headers.
private final class LinuxHTTPRequest: Sendable {
    let id: UInt64

    init(_ request: URLRequest, roots: [Data]) throws {
        guard let address = request.url?.absoluteString else { throw URLError(.badURL) }
        let url = Array(address.utf8), method = Array((request.httpMethod ?? "GET").utf8)
        let timeout = request.timeoutInterval
        guard timeout.isFinite, timeout > 0 else { throw URLError(.timedOut) }
        let seconds = UInt32(min(Double(UInt32.max), timeout.rounded(.up)))
        id = serein_http_new(url.span, method.span, seconds)
        guard id != 0 else { throw URLError(.badURL) }
        for root in roots { try Self.check(serein_http_add_root(id, Array(root).span)) }
        if let body = request.httpBody { try Self.check(serein_http_set_body(id, Array(body).span)) }
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            try Self.check(serein_http_add_header(id, Array(key.utf8).span, Array(value.utf8).span))
        }
    }

    deinit { serein_http_release(id) }
    func cancel() { serein_http_cancel(id) }

    private static func check(_ status: SereinHTTPError) throws {
        switch status {
        case SereinHTTPOK: return
        case SereinHTTPTLS: throw URLError(.serverCertificateUntrusted)
        case SereinHTTPTimeout: throw URLError(.timedOut)
        case SereinHTTPCancelled: throw CancellationError()
        case SereinHTTPInvalid: throw HTTPError.invalidResponse
        default: throw URLError(.networkConnectionLost)
        }
    }

    // GIO's blocking calls run on the dispatch I/O worker pool. Task cancellation
    // interrupts the native connect, TLS handshake, header wait or stream read.
    private func io<Result: Sendable>(_ work: @escaping @Sendable (UInt64) throws -> Result) async throws -> Result {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Swift.Result { try work(self.id) })
                }
            }
        } onCancel: { cancel() }
    }

    func send(url: URL) async throws -> HTTPURLResponse {
        let (status, fields) = try await io { id in
            let reply = serein_http_send(id)
            try Self.check(reply.error)
            var bytes = [UInt8](repeating: 0, count: reply.headers_size)
            var buffer = bytes.mutableSpan
            try Self.check(serein_http_headers(id, &buffer))
            var fields = [String: String]()
            for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { throw HTTPError.invalidResponse }
                let name = line[..<colon].lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if let previous = fields[name] { fields[name] = previous + ", " + value }
                else { fields[name] = value }
            }
            return (Int(reply.status), fields)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: fields) else {
            throw HTTPError.invalidResponse
        }
        return response
    }

    func read() async throws -> [UInt8] {
        try await io { id in
            var bytes = [UInt8](repeating: 0, count: 64 << 10)
            var buffer = bytes.mutableSpan
            let result = serein_http_read(id, &buffer)
            try Self.check(result.error)
            bytes.removeLast(bytes.count - result.count)
            return bytes
        }
    }
}

struct LinuxHTTPBytes: AsyncSequence {
    typealias Element = UInt8
    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let transfer: LinuxHTTPRequest
        private var bytes: [UInt8] = []
        private var index = 0
        fileprivate init(_ transfer: LinuxHTTPRequest) { self.transfer = transfer }
        mutating func next() async throws -> UInt8? {
            if index == bytes.count {
                bytes = try await transfer.read()
                index = 0
                if bytes.isEmpty { return nil }
            }
            defer { index += 1 }
            return bytes[index]
        }
    }
    fileprivate let transfer: LinuxHTTPRequest
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(transfer) }
    func cancel() { transfer.cancel() }
    var task: Self { self }
}

struct LinuxHTTPSession: Sendable {
    let roots: [Data]

    func bytes(for original: URLRequest) async throws -> (LinuxHTTPBytes, URLResponse) {
        var request = original
        for redirect in 0...10 {
            guard let url = request.url, url.scheme?.lowercased() == "https" else { throw HTTPError.insecureURL }
            let transfer = try LinuxHTTPRequest(request, roots: roots)
            let response = try await transfer.send(url: url)
            guard [301, 302, 303, 307, 308].contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location")
            else { return (LinuxHTTPBytes(transfer: transfer), response) }
            transfer.cancel()
            guard redirect < 10 else { throw URLError(.httpTooManyRedirects) }
            guard let next = URL(string: location, relativeTo: url)?.absoluteURL else { throw URLError(.badURL) }
            guard next.scheme?.lowercased() == "https" else { throw HTTPError.insecureURL }
            let method = request.httpMethod ?? "GET"
            let changeToGet = (response.statusCode == 303 && method != "HEAD") || ([301, 302].contains(response.statusCode) && method == "POST")
            let crossOrigin = url.host?.lowercased() != next.host?.lowercased() || (url.port ?? 443) != (next.port ?? 443)
            // A replayed body or custom authentication header can carry an account
            // credential. Only bodyless GET/HEAD requests can cross origins.
            if crossOrigin {
                guard changeToGet || ((method == "GET" || method == "HEAD") && request.httpBody == nil) else { throw URLError(.redirectToNonExistentLocation) }
                request.allHTTPHeaderFields = [:]
            }
            if changeToGet {
                request.httpMethod = "GET"
                request.httpBody = nil
                request.setValue(nil, forHTTPHeaderField: "Content-Type")
                request.setValue(nil, forHTTPHeaderField: "Content-Length")
            }
            request.url = next
        }
        throw URLError(.httpTooManyRedirects)
    }
}
#endif
