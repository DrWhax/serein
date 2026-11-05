// Runs Tests/MockServer/harness.mjs (Signal's @signalapp/mock-server) under Node
// and talks to it over JSON lines.

import Foundation
import LibSignalClient

struct HarnessError: Error, CustomStringConvertible {
    var description: String
}

struct MockServerReady: Decodable, Sendable {
    struct Account: Decodable, Sendable { var aci: String; var pni: String?; var number: String? }
    struct MockServerInfo: Decodable, Sendable { var version: String; var path: String; var libsignal: String }
    var port: Int
    var mockServer: MockServerInfo
    var certificateAuthority: String
    var serverTrustRoots: [String]
    var serverPublicParams: String
    var phone: Account
    var alice: Account

    /// DER bytes of the CA certificate (PEM body).
    var certificateAuthorityDER: Data {
        let body = certificateAuthority.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body)!
    }
    var trustRoots: [PublicKey] { serverTrustRoots.map { try! PublicKey(Data(base64Encoded: $0)!) } }
}

actor MockServerHarness {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let harnessDir = repoRoot.appendingPathComponent("Tests/MockServer")

    let process: Process
    let stdin: FileHandle
    nonisolated let ready: MockServerReady
    var nextId = 1
    var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    var readerTask: Task<Void, Never>?
    /// Yields once when node exits. (Process.waitUntilExit can miss the exit when called from a
    /// Swift-concurrency thread other than the launching one, so it is not used.)
    let exited: AsyncStream<Int32>

    init(process: Process, stdin: FileHandle, ready: MockServerReady, exited: AsyncStream<Int32>) {
        self.process = process
        self.stdin = stdin
        self.ready = ready
        self.exited = exited
    }

    static func start() async throws -> MockServerHarness {
        guard FileManager.default.fileExists(atPath: harnessDir.appendingPathComponent("node_modules/@signalapp/mock-server/src/index.js").path) else {
            throw HarnessError(description: "build Signal-Desktop/packages/mock-server first: Tools/build-mock-server.sh")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["node", "harness.mjs"]
        p.currentDirectoryURL = harnessDir
        if ProcessInfo.processInfo.environment["SIGNALSAFE_TRACE"] != nil {
            var env = ProcessInfo.processInfo.environment
            env["DEBUG"] = "mock:*"
            p.environment = env
        }
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.standardError
        let (exited, exitSink) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
        p.terminationHandler = { process in
            exitSink.yield(process.terminationStatus)
            exitSink.finish()
        }
        try p.run()

        var lines = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
        trace("harness: launched node pid \(p.processIdentifier)")
        guard let first = try await lines.next() else { throw HarnessError(description: "harness exited before ready") }
        let ready = try JSONDecoder().decode(MockServerReady.self, from: Data(first.utf8))
        trace("harness: ready on port \(ready.port)")
        let harness = MockServerHarness(process: p, stdin: input.fileHandleForWriting, ready: ready, exited: exited)
        // The same iterator keeps reading, so nothing buffered after the ready line is lost.
        let reader = Task { [lines] in
            var lines = lines
            while let line = try? await lines.next() { await harness.deliver(line) }
            await harness.failAll("harness stdout closed")
        }
        await harness.setReader(reader)
        return harness
    }

    func setReader(_ t: Task<Void, Never>) { readerTask = t }

    func deliver(_ line: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = obj["id"] as? Int,
              let continuation = pending.removeValue(forKey: id) else { return }
        if obj["ok"] as? Bool == true {
            let result = obj["result"] ?? [String: Any]()
            continuation.resume(returning: (try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])) ?? Data("{}".utf8))
        } else {
            continuation.resume(throwing: HarnessError(description: "\(obj["error"] ?? "unknown error")"))
        }
    }

    func failAll(_ reason: String) {
        for (_, c) in pending { c.resume(throwing: HarnessError(description: reason)) }
        pending.removeAll()
    }

    /// Sends one command; returns the JSON `result`.
    @discardableResult
    func call(_ cmd: String, _ args: [String: any Sendable] = [:]) async throws -> Data {
        let id = nextId
        nextId += 1
        var message: [String: Any] = args
        message["id"] = id
        message["cmd"] = cmd
        let line = try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try stdin.write(contentsOf: line) } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    nonisolated func decode<T: Decodable>(_ type: T.Type, _ cmd: String, _ args: [String: any Sendable] = [:]) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await call(cmd, args))
    }

    nonisolated func json(_ cmd: String, _ args: [String: any Sendable] = [:]) async throws -> [String: Any] {
        let data = try await call(cmd, args)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Closes node's stdin (the harness then closes the server and exits); kills it after 5 s.
    func stop() async {
        try? stdin.close()
        readerTask?.cancel()
        if await !waitForExit(.seconds(5)) {
            process.terminate()
            _ = await waitForExit(.seconds(5))
        }
    }

    func waitForExit(_ timeout: Duration) async -> Bool {
        let exited = self.exited
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in exited { return true }
                return true   // stream finished: already exited
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
