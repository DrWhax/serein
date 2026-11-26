#if os(Linux)
import CLinuxHTTP
import Foundation
import FoundationNetworking

/// A request owns one SoupSession and one cancellable. GIO performs certificate
/// chain and hostname verification before handing back response headers.
public final class LinuxHTTPRequest: Sendable {
    private let id: UInt64

    // SoupSession and its stream may be used by one I/O operation at a time.
    // Cancellation uses the separately thread-safe GCancellable.
    private let lock = NSLock()
    private let invalidResponse: any Error

    public init(_ request: URLRequest, roots: [Data], invalidResponse: any Error) throws {
        self.invalidResponse = invalidResponse
        guard let address = request.url?.absoluteString else { throw URLError(.badURL) }
        let url = Array(address.utf8), method = Array((request.httpMethod ?? "GET").utf8)
        let timeout = request.timeoutInterval
        guard timeout.isFinite, timeout > 0 else { throw URLError(.timedOut) }
        let seconds = UInt32(min(Double(UInt32.max), timeout.rounded(.up)))
        id = serein_http_new(url.span, method.span, seconds)
        guard id != 0 else { throw URLError(.badURL) }
        for root in roots { try self.check(serein_http_add_root(id, Array(root).span)) }
        if let body = request.httpBody { try self.check(serein_http_set_body(id, Array(body).span)) }
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            try self.check(serein_http_add_header(id, Array(key.utf8).span, Array(value.utf8).span))
        }
    }

    deinit { serein_http_release(id) }
    public func cancel() { serein_http_cancel(id) }

    private func check(_ status: SereinHTTPError) throws {
        switch status {
        case SereinHTTPOK: return
        case SereinHTTPTLS: throw URLError(.serverCertificateUntrusted)
        case SereinHTTPTimeout: throw URLError(.timedOut)
        case SereinHTTPCancelled: throw CancellationError()
        case SereinHTTPInvalid: throw self.invalidResponse
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
                    continuation.resume(with: Swift.Result { try self.lock.withLock { try work(self.id) } })
                }
            }
        } onCancel: { cancel() }
    }

    public func send(url: URL) async throws -> HTTPURLResponse {
        let (status, fields) = try await io { id in
            let reply = serein_http_send(id)
            try self.check(reply.error)
            var bytes = [UInt8](repeating: 0, count: reply.headers_size)
            var buffer = bytes.mutableSpan
            try self.check(serein_http_headers(id, &buffer))
            var fields = [String: String]()
            for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { throw self.invalidResponse }
                let name = line[..<colon].lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if let previous = fields[name] { fields[name] = previous + ", " + value }
                else { fields[name] = value }
            }
            return (Int(reply.status), fields)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: fields) else {
            throw self.invalidResponse
        }
        return response
    }

    /// An empty proxy selects a direct connection, regardless of the process environment.
    public func setProxy(_ proxy: String) throws {
        try lock.withLock { try check(serein_http_set_proxy(id, Array(proxy.utf8).span)) }
    }

    /// Every peer observed while connecting, including connection retries.
    public func peerAddresses() -> [String] {
        lock.withLock {
            let size = serein_http_peers_size(id)
            guard size > 0 else { return [] }
            var bytes = [UInt8](repeating: 0, count: size)
            var buffer = bytes.mutableSpan
            guard serein_http_peers(id, &buffer) == SereinHTTPOK else { return [] }
            return String(decoding: bytes, as: UTF8.self).split(separator: "\n").map(String.init)
        }
    }

    public func read(upTo count: Int = 64 << 10) async throws -> [UInt8] {
        guard count > 0 else { return [] }
        return try await io { id in
            var bytes = [UInt8](repeating: 0, count: min(count, 64 << 10))
            var buffer = bytes.mutableSpan
            let result = serein_http_read(id, &buffer)
            try self.check(result.error)
            bytes.removeLast(bytes.count - result.count)
            return bytes
        }
    }
}
#endif
