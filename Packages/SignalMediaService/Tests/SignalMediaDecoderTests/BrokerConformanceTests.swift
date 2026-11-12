// The broker: production MediaXPCClient and XPCChannel (MediaXPCInterface) against the Lean
// model in Verification/Broker, with a hostile helper on each channel (the decoder's, the
// voice-note encoder's): in-process listeners on raw XPC that keep every message and do
// whatever the run says (answer any message with anything, again, on an ended session; end
// their sessions; send messages nobody asked for), while the run also times requests out and
// cancels callers. After every event production must reach the model's state: each call's
// result, the sessions and messages each helper saw (releases included), the quarantine.
// Then the flows that turn one helper's answer into a request to another (GIF URLs, the
// parser's endpoint), against the model's definitions.
//
// Run through Tools/verify-broker.sh, or set SEREIN_BROKER_ORACLE to the oracle executable.

import Foundation
@testable import MediaXPCInterface
import Synchronization
import Testing
import XPC

enum BrokerOracle {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Verification/Broker").standardized
    static var path: String {
        ProcessInfo.processInfo.environment["SEREIN_BROKER_ORACLE"] ?? root.appendingPathComponent(".lake/build/bin/oracle").path
    }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: path) }
    struct Failed: Error {}

    /// The oracle in `step` mode: one event in, the model's state out.
    final class Stepper {
        let process = Process()
        let input = Pipe(), output = Pipe()
        var buffer = Data()

        init() throws {
            process.executableURL = URL(fileURLWithPath: BrokerOracle.path)
            process.arguments = ["step"]
            process.standardInput = input
            process.standardOutput = output
            try process.run()
        }

        deinit {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }

        func send(_ line: String) throws -> String {
            input.fileHandleForWriting.write(Data((line + "\n").utf8))
            while true {
                if let nl = buffer.firstIndex(of: 0x0A) {
                    let out = String(decoding: buffer[buffer.startIndex ..< nl], as: UTF8.self)
                    buffer = Data(buffer[(nl + 1)...])
                    return out
                }
                let more = output.fileHandleForReading.availableData
                guard !more.isEmpty else { throw Failed() }
                buffer.append(more)
            }
        }
    }

    static func batch(_ mode: String, _ lines: [String]) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serein-broker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inURL = dir.appendingPathComponent("in.txt"), outURL = dir.appendingPathComponent("out.txt")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [mode]
        p.standardInput = try FileHandle(forReadingFrom: inURL)
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failed() }
        return String(decoding: try Data(contentsOf: outURL), as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

/// Session names in the model are numbers; on the wire, UUIDs.
enum Names {
    static func uuid(_ u: Int) -> UUID {
        let digits = String(u)
        return UUID(uuidString: "00000000-0000-4000-8000-" + String(repeating: "0", count: 12 - digits.count) + digits)!
    }
    static func number(_ id: UUID) -> Int { Int(id.uuidString.suffix(12)) ?? -1 }
    static func input(_ i: Int) -> Data { Data([0xC0 + UInt8(i), 0x5E, 0x1E, 0x17]) }
    static func inputNumber(_ d: Data) -> Int { Int(d.first ?? 0) - 0xC0 }
}

/// A hostile helper: keeps every message (one dropped unanswered fails its request at once) and
/// every session, and answers only when told to.
final class HostileHelper: Sendable {
    struct Held: @unchecked Sendable {
        let message: XPCDictionary
        let request: MediaRequest?
    }
    struct State {
        var sessions: [XPCSession] = []
        var held: [Held] = []
    }
    final class Box: Sendable { let state = Mutex(State()) }
    let box = Box()
    let listener: XPCListener

    struct Peer: XPCPeerHandler {
        let box: Box
        func handleIncomingRequest(_ message: XPCDictionary) -> XPCDictionary? {
            let request = (try? XPCMessage(message, maxPayload: 1 << 30)).flatMap { m in
                m.payload.flatMap { try? MediaXPCWire.decode(MediaRequest.self, $0, maxBytes: 1 << 30) }
            }
            box.state.withLock { $0.held.append(Held(message: message, request: request)) }
            return nil
        }
    }

    init() {
        let box = box
        listener = XPCListener { $0.accept { session in
            box.state.withLock { $0.sessions.append(session) }
            return Peer(box: box)
        } }
    }

    func stop() {
        listener.cancel()
        for s in box.state.withLock({ $0.sessions }) { s.cancel(reason: "run over") }
    }

    var held: [Held] { box.state.withLock { $0.held } }
    var sessionCount: Int { box.state.withLock { $0.sessions.count } }

    func crash() { for s in box.state.withLock({ $0.sessions }) { s.cancel(reason: "crashed") } }

    func unsolicited() {
        var d = XPCDictionary()
        d[XPCMessage.payloadKey] = Data("unasked".utf8).base64EncodedString()
        for s in box.state.withLock({ $0.sessions }) { try? s.send(message: d) }
    }

    func answer(_ p: Int, _ reply: XPCDictionary) { held[p].message.reply(reply) }

    /// What the helper got, as the model writes it.
    static func code(_ r: MediaRequest?) -> String {
        switch r {
        case .thumbnail(let b, let size)?: return "t:\(size):\(Names.inputNumber(b))"
        case .openVideo(let b)?: return "o:\(Names.inputNumber(b))"
        case .startVoiceNote?: return "s"
        case .recordVoiceNote?: return "m"
        case .closeVideo(let u)?, .cancelVoiceNote(let u)?: return "r:\(Names.number(u))"
        default: return "?"
        }
    }

    func line(_ name: String) -> String {
        let codes = held.map { Self.code($0.request) }
        return "\(name) \(sessionCount) \(codes.isEmpty ? "-" : codes.joined(separator: ","))"
    }
}

/// The watchdogs' waits: each opens when the run times its request out, or when the request
/// ends first (its watchdog is cancelled).
final class Timers: Sendable {
    final class Gate: Sendable {
        struct State {
            var open = false
            var waited = false
            var waiters: [CheckedContinuation<Void, Never>] = []
        }
        let state = Mutex(State())

        func wait() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                    let now = state.withLock { s -> Bool in
                        s.waited = true
                        if s.open { return true }
                        s.waiters.append(k)
                        return false
                    }
                    if now { k.resume() }
                }
            } onCancel: { open() }
        }

        func open() {
            let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.open = true
                defer { s.waiters = [] }
                return s.waiters
            }
            for k in waiters { k.resume() }
        }

        var waited: Bool { state.withLock { $0.waited } }
    }
    let gates = Mutex<[String: Gate]>([:])

    func gate(_ key: String) -> Gate {
        gates.withLock { g in
            if let x = g[key] { return x }
            let x = Gate()
            g[key] = x
            return x
        }
    }

    func openAll() { for g in gates.withLock({ Array($0.values) }) { g.open() } }
}

/// The calls' results, as the model writes them (nil while pending).
final class Results: Sendable {
    let codes = Mutex<[String?]>([])
    func add() -> Int { codes.withLock { $0.append(nil); return $0.count - 1 } }
    func set(_ n: Int, _ code: String) { codes.withLock { $0[n] = code } }
    var line: String {
        let c = codes.withLock { $0 }
        return c.isEmpty ? "-" : c.map { $0 ?? "p" }.joined(separator: " ")
    }

    static func code(_ error: any Error) -> String {
        switch error {
        case XPCServiceError.timedOut: return "T"
        case XPCServiceError.lost: return "L"
        case is CancellationError: return "C"
        case MediaProcessingError.invalidResult: return "R"
        case MediaProcessingError.undecodable(let why): return why == MediaXPCClient.quarantined ? "Q" : "H"
        default: return "?(\(error))"
        }
    }
}

@Suite(.serialized, .enabled(if: BrokerOracle.available, "build the oracle: Tools/verify-broker.sh, or lake build in Verification/Broker"))
struct BrokerConformanceTests {
    static var count: Int { ProcessInfo.processInfo.environment["SEREIN_BROKER_CASES"].flatMap { Int($0) } ?? 3000 }
    static let sizes = [16, 32, 64]
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])

    /// A run's world: the two helpers, the watchdogs, the client and its calls.
    final class World: @unchecked Sendable {
        let dec = HostileHelper(), voice = HostileHelper()
        let timers = Timers()
        let results = Results()
        let client: MediaXPCClient
        var tasks: [Task<Void, Never>] = []
        let null = FileHandle(forReadingAtPath: "/dev/null")!

        init() {
            let timers = timers
            client = MediaXPCClient(
                channel: XPCChannel(.endpoint(dec.listener.endpoint), peer: nil, timeout: .seconds(3600)) { n, _ in await timers.gate("d:\(n)").wait() },
                voice: XPCChannel(.endpoint(voice.listener.endpoint), peer: nil, timeout: .seconds(3600)) { n, _ in await timers.gate("v:\(n)").wait() })
        }

        func helper(_ c: String) -> HostileHelper { c == "d" ? dec : voice }
        func channel(_ c: String) -> XPCChannel { c == "d" ? client.channel : client.voice }

        func call(_ body: @escaping @Sendable (MediaXPCClient) async throws -> String) {
            let n = results.add(), results = results, client = client
            tasks.append(Task {
                let code: String
                do { code = try await body(client) } catch { code = Results.code(error) }
                results.set(n, code)
            })
        }

        /// Production's state, as the model writes it.
        var line: String {
            let strikes = (0..<4).map { i in String(client.quarantine.state.withLock { $0.strikes[MediaQuarantine.key(Names.input(i))] ?? 0 }) }
            return "\(results.line) | \(dec.line("d")) | \(voice.line("v")) | \(strikes.joined(separator: ","))"
        }

        /// Every request a helper got has its watchdog waiting (or done), so a timeout can be fired.
        var settled: Bool {
            for (c, h) in [("d", dec), ("v", voice)] {
                for n in 0..<h.held.count where !timers.gate("\(c):\(n)").waited { return false }
            }
            return true
        }

        func reply(_ words: [String], _ r: inout SplitMix) -> XPCDictionary {
            var m: XPCMessage
            switch words[0] {
            case "t": m = XPCMessage(payload: try! Wire.encode(Thumbnail(png: BrokerConformanceTests.png, width: Int(words[1])!, height: Int(words[2])!)))
            case "o":
                let info = words[2] == "1" ? VideoInfo(width: 16, height: 16, rotation: 0, duration: 1, hasAudio: false, goodForStories: false)
                    : VideoInfo(width: 0, height: 16, rotation: 0, duration: 1, hasAudio: false, goodForStories: false)
                m = XPCMessage(payload: try! Wire.encode(OpenedVideo(session: Names.uuid(Int(words[1])!), info: info)))
            case "v": m = XPCMessage(payload: try! Wire.encode(Names.uuid(Int(words[1])!)))
            case "e": m = XPCMessage(payload: try! Wire.encode(MediaEmpty()))
            case "g": m = XPCMessage(payload: r.below(3) == 0 ? Data(count: (64 << 10) + 1) : Data("not the wire format".utf8))
            default: m = XPCMessage(error: "the helper says no")
            }
            var d = m.dictionary
            if words[0] == "x" && r.below(2) == 0 {
                // No payload: a file descriptor where it should be.
                d = XPCDictionary()
                d[XPCMessage.payloadKey] = xpc_fd_create(null.fileDescriptor)
            }
            if r.below(3) == 0 {
                // Entries nobody reads: a file descriptor, an endpoint, more data.
                d["fd"] = xpc_fd_create(null.fileDescriptor)
                d[XPCMessage.endpointKey] = dec.listener.endpoint
                d["w2"] = Data([1, 2, 3]).base64EncodedString()
            }
            return d
        }

        func stop() {
            timers.openAll()
            for t in tasks { t.cancel() }
            dec.stop()
            voice.stop()
        }
    }

    /// The next event of a run, from what production's helpers hold.
    static func event(_ w: World, _ r: inout SplitMix, _ names: inout Int) -> String {
        let calls = w.results.codes.withLock { $0.count }
        let held = ["d": w.dec.held, "v": w.voice.held]
        let k = r.below(100)
        if k < 14 { return "ct \(sizes[r.below(3)]) \(r.below(4))" }
        if k < 22 { return "co \(r.below(4))" }
        if k < 29 { return r.below(2) == 0 ? "cs" : "cm" }
        if k < 66 {
            let c = r.below(3) < 2 ? "d" : "v"
            guard let hs = held[c], !hs.isEmpty else { return "u \(c)" }
            let p = r.below(hs.count)
            // Mostly the reply the request expects; any other kind as often.
            let fit = r.below(3) != 0
            names += 1
            switch (fit, hs[p].request) {
            case (true, .thumbnail(_, let size)?):
                return r.below(4) == 0 ? "r \(c) \(p) t \(sizes[r.below(3)]) \(size)" : "r \(c) \(p) t \(size) \(size)"
            case (true, .openVideo?): return "r \(c) \(p) o \(names) \(r.below(4) == 0 ? 0 : 1)"
            case (true, .startVoiceNote?), (true, .recordVoiceNote?): return "r \(c) \(p) v \(names)"
            case (true, .closeVideo?), (true, .cancelVoiceNote?): return "r \(c) \(p) e"
            default:
                switch r.below(6) {
                case 0: return "r \(c) \(p) t \(sizes[r.below(3)]) \(sizes[r.below(3)])"
                case 1: return "r \(c) \(p) o \(names) \(r.below(2))"
                case 2: return "r \(c) \(p) v \(names)"
                case 3: return "r \(c) \(p) e"
                case 4: return "r \(c) \(p) g"
                default: return "r \(c) \(p) x"
                }
            }
        }
        if k < 72 { return "k \(r.below(3) < 2 ? "d" : "v")" }
        if k < 75 { return "u \(r.below(2) == 0 ? "d" : "v")" }
        if k < 89 {
            let c = r.below(3) < 2 ? "d" : "v"
            guard let hs = held[c], !hs.isEmpty else { return "u \(c)" }
            return "w \(c) \(r.below(hs.count))"
        }
        guard calls > 0 else { return "cs" }
        return "z \(r.below(calls))"
    }

    /// Applies one event to production.
    static func apply(_ w: World, _ e: String, _ r: inout SplitMix) {
        let words = e.split(separator: " ").map(String.init)
        switch words[0] {
        case "ct":
            let size = Int(words[1])!, input = Names.input(Int(words[2])!)
            w.call { c in let t = try await c.thumbnail(input, size: size); return "t:\(t.width):\(t.height)" }
        case "co":
            let input = Names.input(Int(words[1])!)
            w.call { c in "s:\(Names.number(try await c.openVideo(input).session))" }
        case "cs": w.call { c in "s:\(Names.number(try await c.startVoiceNote(sampleRate: 48000)))" }
        case "cm": w.call { c in "s:\(Names.number(try await c.recordVoiceNote()))" }
        case "r": w.helper(words[1]).answer(Int(words[2])!, w.reply(Array(words[3...]), &r))
        case "k": w.helper(words[1]).crash()
        case "u": w.helper(words[1]).unsolicited()
        case "w": w.timers.gate("\(words[1]):\(words[2])").open()
        case "z": w.tasks[Int(words[1])!].cancel()
        default: break
        }
    }

    /// Runs of calls, replies, crashes, unsolicited messages, timeouts and cancellations:
    /// production must reach the model's state after every event.
    @Test func randomRuns() async throws {
        let oracle = try BrokerOracle.Stepper()
        var r = SplitMix(seed: 0xB20CE2)
        let runs = max(1, Self.count / 10)
        var steps = 0
        for run in 0..<runs {
            #expect(try oracle.send("reset") == "ok")
            let w = World()
            defer { w.stop() }
            var events: [String] = [], names = 0
            for k in 0..<30 {
                let e = Self.event(w, &r, &names)
                events.append(e)
                let expected = try oracle.send(e)
                Self.apply(w, e, &r)
                var got = w.line
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while ContinuousClock.now < deadline {
                    let crashed = e.hasPrefix("k ") ? w.channel(String(e.dropFirst(2))).state.withLock { $0.live == nil } : true
                    got = w.line
                    if got == expected && w.settled && crashed { break }
                    try await Task.sleep(for: .microseconds(200))
                }
                if got != expected {
                    Issue.record("""
                        model and production disagree at step \(k) of run \(run): production \(got), model \(expected)
                        events: \(events.joined(separator: " ; "))
                        """)
                    return
                }
                steps += 1
                if ProcessInfo.processInfo.environment["SEREIN_BROKER_TRACE"] != nil { print("TRACE \(e) => \(expected)") }
            }
            // Anything late shows now.
            try await Task.sleep(for: .milliseconds(5))
            let last = w.line, expected = try oracle.send("u d")
            if last != expected {
                Issue.record("model and production disagree at step 30 of run \(run): production \(last), model \(expected); events: \(events.joined(separator: " ; "))")
                return
            }
        }
        #expect(steps == runs * 30)
    }

    static func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .microseconds(200)) }
    }

    /// A late notice about an ended session (its cancellation handler, or a failed reply on it,
    /// delivered after the next session opened) does not end the session that replaced it. In
    /// process such notices come before the next event, so the runs never show this; here the
    /// notice is delivered by hand.
    @Test func aLateNoticeAboutAnOldSessionLeavesTheLiveOne() async throws {
        let w = World()
        defer { w.stop() }
        var r = SplitMix(seed: 1)
        Self.apply(w, "cs", &r)
        try await Self.waitFor { w.voice.held.count == 1 }
        let first = w.client.voice.state.withLock { $0.live?.id }
        w.voice.crash()
        try await Self.waitFor { w.client.voice.state.withLock { $0.live == nil } }
        Self.apply(w, "cs", &r)
        try await Self.waitFor { w.voice.held.count == 2 }
        let second = w.client.voice.state.withLock { $0.live?.id }
        #expect(first != nil && second != nil && first != second)
        if let first { w.client.voice.drop(first) }
        if w.client.voice.state.withLock({ $0.live?.id }) != second { Issue.record("an old session's notice dropped the live one") }
    }

    // MARK: - From one helper's answer to another helper

    /// The URLs a GIF service may answer with: whether `file` asks for them and whether a page
    /// with them is accepted, against `cdn`.
    @Test func gifURLsAreChecked() async throws {
        final class Asked: Sendable { let urls = Mutex<[URL]>([]) }
        struct GifHelper: XPCMessageHandler {
            let asked: Asked
            var maxRequestBytes: Int { GifSearchRequest.maxBytes }
            func reply(to request: XPCMessage) async throws -> XPCMessage {
                if case .file(let url) = try MediaXPCWire.decode(GifSearchRequest.self, try request.requirePayload(), maxBytes: GifSearchRequest.maxBytes) {
                    asked.urls.withLock { $0.append(url) }
                }
                return XPCMessage(payload: try MediaXPCWire.encode(Data([0x00, 0x00, 0x00, 0x18])))
            }
        }
        let asked = Asked()
        let listener = XPCServer.anonymous(requirement: nil, GifHelper(asked: asked))
        defer { listener.cancel() }
        let client = GifSearchClient(timeout: .seconds(10), target: .endpoint(listener.endpoint), peer: nil)
        let hosts = ["media0.giphy.com", "media1.giphy.com", "media2.giphy.com", "media3.giphy.com", "media4.giphy.com",
                     "giphy.com", "media5.giphy.com", "media1.giphy.com.evil.example"]
        var r = SplitMix(seed: 0x61F)
        var lines: [String] = [], production: [String] = []
        for n in 0..<max(1, Self.count / 10) {
            func url() -> (String, URL) {
                let https = r.below(4) != 0, host = r.below(hosts.count), port = r.below(4) == 0, user = r.below(5) == 0
                let s = "\(https ? "https" : "http")://\(user ? "u:p@" : "")\(hosts[host])\(port ? (r.below(2) == 0 ? ":443" : ":8443") : "")/media/\(n)/giphy.mp4"
                return ("\(https ? 1 : 0):\(host):\(port ? 1 : 0):\(user ? 1 : 0)", URL(string: s)!)
            }
            let (code, u) = url()
            let before = asked.urls.withLock { $0.count }
            _ = try? await client.file(u)
            let sent = asked.urls.withLock { $0.count > before && $0.last == u }
            lines.append("g \(code)")
            production.append(sent ? "1" : "0")
            let page = (0..<(1 + r.below(3))).map { _ in url() }
            let gifs = page.enumerated().map { i, p in
                GifResult(id: "g\(i)", title: "", description: "", previewMedia: GifMedia(url: p.1, width: 200, height: 100),
                          attachmentMedia: GifMedia(url: page[0].1, width: 480, height: 240))
            }
            lines.append("p \(page.map(\.0).joined(separator: ";"))")
            production.append((try? PaginatedGifResults(next: nil, gifs: gifs).validated()) != nil ? "1" : "0")
        }
        let model = try BrokerOracle.batch("deputy", lines)
        if ProcessInfo.processInfo.environment["SEREIN_BROKER_TRACE"] != nil { print("DEPUTY \(zip(lines, production).map { "\($0) -> \($1)" })") }
        for (i, line) in lines.enumerated() where model[i] != production[i] {
            Issue.record("model and production disagree at step \(i): \(line): production \(production[i]), model \(model[i])")
            return
        }
    }

    /// The parser service's answer to the app's empty message: what the fetcher is handed with
    /// the fetch (nothing: no fetch), against `handed`.
    @Test func onlyTheParsersEndpointReachesTheFetcher() async throws {
        final class Got: Sendable { let endpoints = Mutex<[XPCEndpoint?]>([]) }
        struct Fetcher: XPCMessageHandler {
            let got: Got
            var maxRequestBytes: Int { LinkPreviewFetchRequest.maxBytes }
            func reply(to request: XPCMessage) async throws -> XPCMessage {
                got.endpoints.withLock { $0.append(request.endpoint) }
                return XPCMessage(payload: try MediaXPCWire.encode(FetchedLinkPreview?.none))
            }
        }
        let parser = HostileHelper(), got = Got()
        let fetcher = XPCServer.anonymous(requirement: nil, Fetcher(got: got))
        let one = HostileHelper(), two = HostileHelper()
        defer {
            parser.stop()
            fetcher.cancel()
            one.stop()
            two.stop()
        }
        let client = LinkPreviewFetcherClient(timeout: .seconds(10), fetcher: .endpoint(fetcher.endpoint), fetcherPeer: nil,
                                              parser: .endpoint(parser.listener.endpoint), parserPeer: nil)
        var r = SplitMix(seed: 0xE9D)
        var lines: [String] = [], production: [String] = []
        for _ in 0..<max(1, Self.count / 20) {
            let page = Task { try await client.page("https://site.signalsafe.app") }
            while parser.held.count <= lines.count { try await Task.sleep(for: .microseconds(200)) }
            // The answer: an endpoint (one of two listeners), another XPC type there, or none;
            // no payload, an empty one, or a byte; an error string or not.
            var d = XPCDictionary()
            let which = r.below(4), bytes = r.below(3)
            switch which {
            case 1: d[XPCMessage.endpointKey] = one.listener.endpoint
            case 2: d[XPCMessage.endpointKey] = two.listener.endpoint
            case 3: d[XPCMessage.endpointKey] = "an endpoint"
            default: break
            }
            if bytes > 0 { d[XPCMessage.payloadKey] = Data(repeating: 7, count: bytes - 1).base64EncodedString() }
            if r.below(2) == 0 { d[XPCMessage.errorKey] = "e" }
            parser.answer(lines.count, d)
            let before = got.endpoints.withLock { $0.count }
            _ = try? await page.value
            let received = got.endpoints.withLock { $0.count > before ? $0.last : nil }
            lines.append("e \(which == 1 || which == 2 ? String(which) : "-") \(max(0, bytes - 1))")
            switch received {
            case .some(.some(let e)) where e == one.listener.endpoint: production.append("1")
            case .some(.some(let e)) where e == two.listener.endpoint: production.append("2")
            case .some: production.append("?")
            case .none: production.append("-")
            }
        }
        let model = try BrokerOracle.batch("deputy", lines)
        if ProcessInfo.processInfo.environment["SEREIN_BROKER_TRACE"] != nil { print("DEPUTY \(zip(lines, production).map { "\($0) -> \($1)" })") }
        for (i, line) in lines.enumerated() where model[i] != production[i] {
            Issue.record("model and production disagree at step \(i): \(line): production \(production[i]), model \(model[i])")
            return
        }
    }
}

extension SplitMix {
    mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
}
