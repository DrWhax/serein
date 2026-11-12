// The calling boundary: production RingRTC over production RemoteCallEndpoint (CallXPC), against
// the Lean model in Verification/CallBoundary, with a hostile calling service: an in-process XPC
// listener that speaks the service's requests, answers commands with the ids the run chooses,
// hands the client's event wait whatever events the run makes up (incoming calls, signalling,
// call and group messages, rings, ended calls and group calls, remote devices), and loses the
// client's endpoint when the run says so. After every event production must reach the model's
// state: the endpoint and its generation, the losses reported, the call, the group calls, what
// the app did for the service, and which endpoint every command reached, from whom.
//
// Run through Tools/verify-callboundary.sh, or set SEREIN_CALLBOUNDARY_ORACLE to the oracle.

@testable import CallXPC
import Foundation
import MediaXPCInterface
import Synchronization
import Testing
import XPC
@testable import CallService
@testable import SignalRingRTC

enum CallBoundaryOracle {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Verification/CallBoundary").standardized
    static var path: String {
        ProcessInfo.processInfo.environment["SEREIN_CALLBOUNDARY_ORACLE"] ?? root.appendingPathComponent(".lake/build/bin/oracle").path
    }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: path) }
    struct Failed: Error {}

    final class Stepper {
        let process = Process()
        let input = Pipe(), output = Pipe()
        var buffer = Data()

        init() throws {
            process.executableURL = URL(fileURLWithPath: CallBoundaryOracle.path)
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
}

/// The model's names as bytes: users (16-byte uuids, user 0 is ourselves), groups (32 bytes).
enum Names {
    static func uuid(_ n: Int) -> Data { Data(repeating: 0xA0, count: 15) + [UInt8(n)] }
    static func user(_ d: Data) -> String { d.count == 16 && d.prefix(15) == Data(repeating: 0xA0, count: 15) ? String(d[d.startIndex + 15]) : "?" }
    static func group(_ n: Int) -> Data { Data(repeating: UInt8(0x40 + n), count: 32) }
    static func groupNumber(_ d: Data) -> String { d.count == 32 && Set(d).count == 1 && d.first! >= 0x40 ? String(Int(d.first!) - 0x40) : "?" }
    static func peer(_ n: Int) -> String { "p\(n)" }
    static func peerNumber(_ s: String) -> String { s.hasPrefix("p") ? String(s.dropFirst()) : "?" }
    static func list(_ us: [Int]) -> String { us.isEmpty ? "-" : us.map(String.init).joined(separator: ",") }
}

/// The hostile calling service: the service's request handler, as the run directs it.
final class HostileCallService: XPCMessageHandler, Sendable {
    struct State {
        /// Endpoint ids, in the order made (their index is the model's endpoint number).
        var endpoints: [UInt64] = []
        var gone: Set<UInt64> = []
        var queued: [UInt64: [JSONValue]] = [:]
        /// The commands run: "endpoint:origin".
        var log: [String] = []
        var nextCallId = 1
        var nextClientId = 1
    }
    let state = Mutex(State())
    static let callCommands: Set<String> = ["updateDataMode", "setOutgoingAudioEnabled", "setOutgoingVideoEnabled", "setMicrophoneWarmupEnabled"]

    var maxRequestBytes: Int { CallXPCLimits.maxRequestBytes }

    func index(_ id: UInt64) -> Int? { state.withLock { $0.endpoints.firstIndex(of: id) } }

    func reply(to request: XPCMessage) async throws -> XPCMessage {
        let r = try Wire.decode(CallRequest.self, try request.requirePayload(), maxBytes: maxRequestBytes)
        switch r {
        case .create:
            let id = state.withLock { s -> UInt64 in
                let id = UInt64(100 + s.endpoints.count)
                s.endpoints.append(id)
                return id
            }
            return XPCMessage(payload: try Wire.encode(id))
        case .destroy:
            return XPCMessage(payload: try Wire.encode(true))
        case .command(let id, let json):
            let cmd = try JSONDecoder().decode(JSONValue.self, from: json)
            let name = cmd["cmd"].string ?? ""
            let answer = try state.withLock { s -> JSONValue in
                guard let i = s.endpoints.firstIndex(of: id), !s.gone.contains(id) else { throw CallServiceError.unknownEndpoint }
                let origin = !cmd["clientId"].isNull ? "g" : Self.callCommands.contains(name) ? "c" : "r"
                s.log.append("\(i):\(origin)")
                switch name {
                case "createOutgoingCall": return .string(String(s.nextCallId))
                case "createGroupCallClient", "createCallLinkCallClient": return .int(Int64(s.nextClientId))
                default: return .null
                }
            }
            return XPCMessage(payload: try Wire.encode(try JSONEncoder().encode(answer)))
        case .waitEvents(let id, let ms):
            let end = ContinuousClock.now + .milliseconds(ms)
            while true {
                let found = try state.withLock { s -> [JSONValue]? in
                    guard s.endpoints.contains(id), !s.gone.contains(id) else { throw CallServiceError.unknownEndpoint }
                    guard let q = s.queued[id], !q.isEmpty else { return nil }
                    s.queued[id] = []
                    return q
                }
                if let found { return XPCMessage(payload: try Wire.encode(try JSONEncoder().encode(found))) }
                if ContinuousClock.now >= end { return XPCMessage(payload: try Wire.encode(Data("[]".utf8))) }
                try await Task.sleep(for: .milliseconds(3))
            }
        case .sendFrame:
            return XPCMessage(payload: try Wire.encode(true))
        case .receiveFrames:
            return XPCMessage(payload: try Wire.encode([ReceivedFrame]()))
        }
    }
}

@MainActor final class BoundaryObserver: GroupCallObserver {
    let ended: (GroupCall) -> Void
    init(ended: @escaping (GroupCall) -> Void) { self.ended = ended }
    func requestMembershipProof(_ groupCall: GroupCall) {}
    func requestGroupMembers(_ groupCall: GroupCall) {}
    func onLocalDeviceStateChanged(_ groupCall: GroupCall) {}
    func onRemoteDeviceStatesChanged(_ groupCall: GroupCall) {}
    func onAudioLevels(_ groupCall: GroupCall) {}
    func onLowBandwidthForVideo(_ groupCall: GroupCall, recovered: Bool) {}
    func onReactions(_ groupCall: GroupCall, reactions: [Reaction]) {}
    func onRaisedHands(_ groupCall: GroupCall, raisedHands: [UInt32]) {}
    func onPeekChanged(_ groupCall: GroupCall) {}
    func onEnded(_ groupCall: GroupCall, reason: CallEndReason, summary: CallSummary) { ended(groupCall) }
    func onSpeechEvent(_ groupCall: GroupCall, event: SpeechEvent) {}
    func onRemoteMute(_ groupCall: GroupCall, demuxId: UInt32) {}
    func onObservedRemoteMute(_ groupCall: GroupCall, sourceDemuxId: UInt32, targetDemuxId: UInt32) {}
}

/// One run: RingRTC over RemoteCallEndpoint over the hostile service.
@MainActor final class BoundaryWorld {
    let service = HostileCallService()
    let listener: XPCListener
    let channel: XPCChannel
    let rtc: RingRTC
    let remote: RemoteCallEndpoint
    var out: [String] = []
    var observers: [BoundaryObserver] = []
    /// Every group call object made, the latest per client id: the app may hold one after it
    /// ended, and its commands must not reach a later endpoint.
    var held: [UInt32: GroupCall] = [:]
    /// Sentinels pushed after each batch of service events, and the last one RingRTC handled:
    /// the pump delivers in order, so once it has, so has everything pushed before it.
    var sentinels = 0
    var sentinelSeen = 0
    let key = Data(repeating: 5, count: 33)

    init() throws {
        listener = XPCServer.anonymous(requirement: nil, service)
        let channel = XPCChannel(.endpoint(listener.endpoint), peer: nil, timeout: .seconds(20))
        self.channel = channel
        rtc = try RingRTC(endpoint: { trials in try RemoteCallEndpoint(fieldTrials: trials, channel: channel) })
        remote = rtc.endpoint as! RemoteCallEndpoint
        rtc.handleOutgoingSignaling = { [weak self] peer, message in
            let id = message.busy?.callId ?? message.hangup?.callId ?? message.offer?.callId ?? 0
            self?.out.append("s:\(Names.peerNumber(peer)):\(id)")
            return true
        }
        rtc.handleIncomingCall = { [weak self] call in
            self?.out.append("i:\(Names.peerNumber(call.remoteUserId)):\(call.callId)")
            return true
        }
        rtc.handleStartCall = { _ in true }
        rtc.handleSendCallMessage = { [weak self] to, _, _ in self?.out.append("m:\(Names.user(to))") }
        rtc.handleSendCallMessageToGroup = { [weak self] gid, _, _, to in
            self?.out.append("g:\(Names.groupNumber(gid)):\(to.isEmpty ? "-" : to.map(Names.user).joined(separator: ","))")
        }
        rtc.handleGroupCallRingUpdate = { [weak self] gid, _, sender, _ in self?.out.append("r:\(Names.user(sender)):\(Names.groupNumber(gid))") }
        rtc.handleLogMessage = { [weak self] _, _, _, message in
            if message.hasPrefix("sentinel "), let n = Int(message.dropFirst(9)) { self?.sentinelSeen = n }
        }
    }

    /// Waits until RingRTC has handled every event pushed so far.
    func drained() async {
        let end = Date().addingTimeInterval(4)
        while sentinelSeen < sentinels && Date() < end { try? await Task.sleep(for: .milliseconds(2)) }
        // Then the tasks those events started.
        try? await Task.sleep(for: .milliseconds(4))
    }

    func close() { listener.cancel() }

    /// The client's endpoint, as the model numbers it.
    var endpointIndex: Int? { remote.state.withLock { $0.id }.flatMap(service.index) }

    var line: String {
        let ep = endpointIndex.map(String.init) ?? "-"
        let reported = remote.state.withLock { $0.reported }
        let call = rtc.call.map { "\(Names.peerNumber($0.remoteUserId)):\($0.callId):\($0.state == .ended ? 1 : 0)" } ?? "-"
        let groups = rtc.groupCallByClientId.keys.sorted().compactMap { id -> String? in
            guard let g = rtc.groupCallByClientId[id] else { return nil }
            return "\(id):\(g.kind == .callLink ? "-" : Names.groupNumber(g.groupId ?? Data())):\(g.generation)"
        }
        let cmds = service.state.withLock { $0.log }
        func list(_ xs: [String]) -> String { xs.isEmpty ? "-" : xs.joined(separator: ";") }
        return "ep \(ep) gen \(remote.generation) rep \(reported) | call \(call) | groups \(list(groups)) | out \(list(out)) | cmds \(list(cmds))"
    }

    /// Queues events for the client's live endpoint (none: the service cannot reach it).
    func push(_ events: [JSONValue]) {
        guard let id = remote.state.withLock({ $0.id }) else { return }
        let n = sentinels + 1
        let sentinel = event("onLogMessage", ["level": .int(3), "file": .string(""), "line": .int(0), "message": .string("sentinel \(n)")])
        let pushed = service.state.withLock { s -> Bool in
            guard !s.gone.contains(id) else { return false }
            s.queued[id, default: []] += events + [sentinel]
            return true
        }
        if pushed { sentinels = n }
    }

    func event(_ type: String, _ fields: [String: JSONValue]) -> JSONValue { .object(fields.merging(["type": .string(type)]) { $1 }) }

    func options(_ peer: Int, uuid: Data? = nil) -> RingRTC.CallingMessageOptions {
        .init(remoteUserId: Names.peer(peer), remoteUuid: uuid, remoteDeviceId: 2, localDeviceId: 1, ageSec: 0, receivedAtCounter: 0,
              receivedAtDate: 0, senderIdentityKey: key, receiverIdentityKey: key)
    }

    /// Applies one event; the oracle lines it stands for.
    func apply(_ e: String) throws -> [String] {
        let w = e.split(separator: " ").map(String.init)
        let n = w.dropFirst().map { Int($0) ?? 0 }
        func users(_ i: Int) -> [Int] { w[i] == "-" ? [] : w[i].split(separator: ",").map { Int($0) ?? 0 } }
        switch w[0] {
        case "self": try? rtc.setSelfUuid(Names.uuid(0))
        case "start":
            service.state.withLock { $0.nextCallId = n[1] }
            _ = try? rtc.startOutgoingCall(remoteUserId: Names.peer(n[0]), isVideoCall: false, localDeviceId: 1)
        case "offer":
            var m = CallingMessage()
            m.offer = OfferMessage(callId: CallId(n[1]), type: .audioCall, opaque: Data([1]))
            rtc.handleCallingMessage(m, options(n[0]))
        case "msg":
            var m = CallingMessage()
            m.opaque = OpaqueMessage(data: Data([1]))
            rtc.handleCallingMessage(m, options(9, uuid: Names.uuid(n[0])))
        case "group":
            service.state.withLock { $0.nextClientId = n[1] }
            let observer = BoundaryObserver { [weak self] g in self?.out.append("e:\(g.clientId)") }
            observers.append(observer)
            let made: GroupCall?
            if n[2] == 1 {
                made = rtc.getCallLinkCall(sfuUrl: "https://sfu.example", endorsementPublicKey: Data(), authCredentialPresentation: Data(),
                                        rootKey: try CallLinkRootKey.generate(), adminPasskey: nil, hkdfExtraInfo: Data(), audioLevelsIntervalMillis: nil,
                                        dredDuration: nil, svcConfig: nil, observer: observer)
            } else {
                made = rtc.getGroupCall(groupId: Names.group(n[0]), sfuUrl: "https://sfu.example", hkdfExtraInfo: Data(), audioLevelsIntervalMillis: nil,
                                        dredDuration: nil, svcConfig: nil, observer: observer)
            }
            if let made { held[made.clientId] = made }
        case "members":
            rtc.groupCallByClientId[UInt32(n[0])]?.setGroupMembers(users(2).map { GroupMemberInfo(userId: Names.uuid($0), userIdCipherText: Data([1])) })
        case "ccmd": rtc.call?.updateDataMode(.normal)
        case "gcmd": held[UInt32(n[0])]?.react("x")
        case "cancel": rtc.cancelGroupRing(groupId: Names.group(n[0]), ringId: 1, reason: nil)
        case "in": push([event("onStartIncomingCall", ["remoteUserId": .string(Names.peer(n[0])), "callId": .id(UInt64(n[1])), "isVideoCall": .bool(false)])])
        case "sig": push([event("onSendBusy", ["remoteUserId": .string(Names.peer(n[0])), "callId": .id(UInt64(n[1])), "remoteDeviceId": .int(2)])])
        case "cm": push([event("sendCallMessage", ["recipientUuid": .bytes(Names.uuid(n[0])), "message": .bytes(Data([1])), "urgency": .int(0)])])
        case "gm":
            push([event("sendCallMessageToGroup", ["groupId": .bytes(Names.group(n[0])), "message": .bytes(Data([1])), "urgency": .int(0),
                                                   "overrideRecipients": .array(users(2).map { .bytes(Names.uuid($0)) })])])
        case "ring":
            push([event("groupCallRingUpdate", ["groupId": .bytes(Names.group(n[1])), "ringId": .string("1"), "sender": .bytes(Names.uuid(n[0])),
                                                "update": .int(0)])])
        case "end": push([event("onCallEnded", ["remoteUserId": .string(Names.peer(0)), "callId": .id(UInt64(n[0])), "reason": .int(0)])])
        case "dev":
            push([event("handleRemoteDevicesChanged", ["clientId": .int(Int64(n[0])), "remoteDeviceStates": .array(users(2).enumerated().map { i, u in
                .object(["demuxId": .int(Int64(i + 1)), "userId": .bytes(Names.uuid(u))])
            })])])
        case "gend": push([event("handleEnded", ["clientId": .int(Int64(n[0])), "reason": .int(0), "summary": .null])])
        case "crash":
            if let id = remote.state.withLock({ $0.id }) { service.state.withLock { _ = $0.gone.insert(id) } }
            // The pump finds the loss, then reports it.
            return ["crash", "wait", "wait"]
        default: throw CallBoundaryOracle.Failed()
        }
        return [e]
    }
}

@MainActor @Suite(.serialized, .enabled(if: CallBoundaryOracle.available,
                                        "build the oracle: Tools/verify-callboundary.sh, or lake build in Verification/CallBoundary"))
struct CallBoundaryConformanceTests {
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    static func users(_ r: inout Rng) -> String {
        let k = r.below(3)
        return k == 0 ? "-" : (0..<k).map { _ in String(r.below(4)) }.joined(separator: ",")
    }

    /// A random event: the app's calls and the service's events on three peers (ids 1…3),
    /// four users (0 is ourselves), two groups and three clients; now and then a crash.
    static func randomEvent(_ r: inout Rng) -> String {
        let p = r.below(3), c = r.below(3) + 1, u = r.below(4), g = r.below(2), cl = r.below(3) + 1
        switch r.below(22) {
        case 0: return "self"
        case 1: return "start \(p) \(c)"
        case 2, 3: return "offer \(p) \(c)"
        case 4: return "msg \(u)"
        case 5: return "group \(g) \(cl) \(r.below(2))"
        case 6: return "members \(cl) \(users(&r))"
        case 7: return "ccmd"
        case 8: return "gcmd \(cl)"
        case 9: return "cancel \(g)"
        case 10, 11: return "in \(p) \(c)"
        case 12: return "sig \(p) \(c)"
        case 13: return "cm \(u)"
        case 14: return "gm \(g) \(users(&r))"
        case 15: return "ring \(u) \(g)"
        case 16: return "end \(c)"
        case 17: return "dev \(cl) \(users(&r))"
        case 18: return "gend \(cl)"
        case 19: return "crash"
        default: return r.below(2) == 0 ? "in \(p) \(c)" : "cm \(u)"
        }
    }

    /// Production reaches `expected` (its events and acknowledgements arrive asynchronously).
    static func converge(_ w: BoundaryWorld, _ expected: String) async -> String {
        let end = Date().addingTimeInterval(4)
        var last = w.line
        while last != expected && Date() < end {
            try? await Task.sleep(for: .milliseconds(5))
            last = w.line
        }
        return last
    }

    @Test func randomRuns() async throws {
        let runs = Int(ProcessInfo.processInfo.environment["SEREIN_CALLBOUNDARY_CASES"] ?? "") ?? 200
        let oracle = try CallBoundaryOracle.Stepper()
        var r = Rng(state: 2026)
        var seen = Set<String>()
        for run in 0..<runs {
            _ = try oracle.send("reset")
            let w = try BoundaryWorld()
            defer { w.close() }
            var events: [String] = []
            var expected = ""
            for _ in 0..<25 {
                let e = Self.randomEvent(&r)
                events.append(e)
                for line in try w.apply(e) { expected = try oracle.send(line) }
                await w.drained()
                let got = await Self.converge(w, expected)
                if got != expected {
                    Issue.record("model and production disagree in run \(run) after \(events.count) events:\nproduction \(got)\nmodel      \(expected)\nevents: \(events.joined(separator: " ; "))")
                    return
                }
                for part in expected.split(separator: "|") where part.contains("out ") {
                    for o in part.dropFirst(5).split(separator: ";") { seen.insert(String(o.prefix(1))) }
                }
            }
        }
        // Every kind of output the boundary lets through occurred.
        #expect(seen.isSuperset(of: ["s", "i", "m", "g", "r", "e"]), "outputs seen: \(seen.sorted())")
    }
}
