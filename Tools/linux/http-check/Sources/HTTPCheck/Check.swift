import Foundation
import FoundationNetworking

@main struct Check {
    enum Failure: Error { case unexpected(String) }
    static func require(_ condition: Bool, _ name: String) throws {
        if !condition { throw Failure.unexpected(name) }
    }

    static func main() async throws {
        let args = CommandLine.arguments
        let base = URL(string: args[1])!, files = URL(fileURLWithPath: args[2], isDirectory: true)
        let root = try Data(contentsOf: files.appendingPathComponent("root.der"))
        let other = try Data(contentsOf: files.appendingPathComponent("other.der"))
        func url(_ route: String) -> URL { base.appendingPathComponent(route) }
        let client = HTTPClient(rootCertificatesDER: [root])
        _ = try await client.send("GET", url("bytes"))
        // Reuse the hostname immediately with different trust settings.
        for roots in [[], [other], [root, Data([0])]] as [[Data]] {
            do {
                _ = try await HTTPClient(rootCertificatesDER: roots).send("GET", url("bytes"))
                throw Failure.unexpected("accepted incorrect trust store containing \(roots.count) roots")
            } catch let error as URLError { try require(error.code == .serverCertificateUntrusted, "unexpected TLS error") }
        }
        let result = try await client.sendWithHeaders("POST", url("echo"), body: Data("Færge".utf8), headers: ["X-Test": "crew"])
        try require(result.status == 200 && result.body == Data("Færge".utf8) && result.headers["x-test"] == "crew", "POST body or headers")
        let wrongHost = URL(string: base.absoluteString.replacingOccurrences(of: "localhost", with: "127.0.0.1"))!
        do {
            _ = try await client.send("GET", wrongHost)
            throw Failure.unexpected("accepted incorrect hostname")
        } catch let error as URLError { try require(error.code == .serverCertificateUntrusted, "hostname TLS error") }
        try require(try await client.send("GET", url("redirect")).body == Data("abcdef".utf8), "HTTPS redirect")
        do {
            _ = try await client.send("GET", url("downgrade"))
            throw Failure.unexpected("followed HTTP downgrade")
        } catch HTTPError.insecureURL {}
        var limited = client
        limited.maxResponseBytes = 3
        for path in ["bytes", "chunked"] {
            do {
                _ = try await limited.send("GET", url(path))
                throw Failure.unexpected("exceeded response limit")
            } catch HTTPError.tooLarge(let size) { try require(size > 3, "limit size") }
        }
        let file = files.appendingPathComponent("download")
        try Data("abc".utf8).write(to: file)
        try await client.download(url("bytes"), to: file, maxBytes: 6)
        try require(try Data(contentsOf: file) == Data("abcdef".utf8), "ranged download")
        try Data("old content".utf8).write(to: file)
        try await client.download(url("whole"), to: file, maxBytes: 6)
        try require(try Data(contentsOf: file) == Data("abcdef".utf8), "server ignores range")
        let short = URLRequest(url: url("slow"), timeoutInterval: 1)
        let start = ContinuousClock.now
        do {
            _ = try await LinuxHTTPSession(roots: [root]).bytes(for: short)
            throw Failure.unexpected("ignored request timeout")
        } catch let error as URLError { try require(error.code == .timedOut, "wrong timeout error") }
        try require(start.duration(to: .now) < .seconds(4), "request timeout duration")
        let hanging = Task { try await client.send("GET", url("slow")) }
        try await Task.sleep(for: .milliseconds(200))
        hanging.cancel()
        do {
            _ = try await hanging.value
            throw Failure.unexpected("ignored cancellation")
        } catch is CancellationError {}
        print("Pinned TLS, hostname, redirects, POST, declared and streamed limits, resumed downloads and cancellation passed.")
    }
}
