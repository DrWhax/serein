#if os(Linux)
import Foundation
import FoundationNetworking
import LinuxHTTP

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
            let transfer = try LinuxHTTPRequest(request, roots: roots, invalidResponse: HTTPError.invalidResponse)
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
