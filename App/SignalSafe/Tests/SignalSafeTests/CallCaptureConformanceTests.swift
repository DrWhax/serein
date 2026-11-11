// Conformance of the production call/capture lifecycle with the Lean model in
// Verification/CallCapture (the oracle). Each trace drives the real SignalSession (Calls.swift,
// CallLinksAndPresenting.swift), CaptureReconciler, ScreenShareCapture and ScreenStreamOutput,
// including the frame and stop callbacks production gives them. Only the environment is faked:
// the camera device, ScreenCaptureKit's streams and sources, and CallingService/RingRTC (one
// direct-call slot, and its messages to the session).
//
// The trace is the scheduler. Production starts its main-actor tasks through `MainTasks`; here
// each is held until the trace's `run.k` releases it, and so is the continuation of every await
// on a fake after the trace completes it, and every service message. `run.k` then waits until
// that task is suspended in a fake again or has ended (the fakes and the task wrapper report
// it), so no yield counting is involved. After each event the rig prints the observation the
// oracle prints for the same step; any difference is minimised to a short trace and reported.
//
// Run through Tools/verify-calls.sh (it builds the oracle first), or set SEREIN_CALL_ORACLE.

import AppKit
import Foundation
import Testing
@testable import SignalCore
import SignalRingRTC
@testable import SignalUI
@testable import SignalSafe

// MARK: traces

struct CallTrace: Equatable {
    var cfg: [UInt64]          // callGeneration, lastScreenShareToken, setupGeneration, capture generation
    var events: [String]
    var name = ""

    var line: String { "cfg \(cfg.map(String.init).joined(separator: " ")) | \(events.joined(separator: " "))" }

    init(cfg: [UInt64], events: [String], name: String = "") {
        self.cfg = cfg
        self.events = events
        self.name = name
    }

    init?(line: String, name: String = "") {
        let halves = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard halves.count == 2 else { return nil }
        let nums = halves[0].split(separator: " ").dropFirst().compactMap { UInt64($0) }
        guard nums.count == 4 else { return nil }
        self.init(cfg: nums, events: halves[1].split(separator: " ").map(String.init), name: name)
    }

    /// `# name: …` comments followed by trace lines (regressions.txt, `oracle counterexamples`).
    static func parse(_ text: String) -> [CallTrace] {
        var out: [CallTrace] = []
        var name = ""
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                name = String(line.dropFirst().split(separator: ":").first ?? "").trimmingCharacters(in: .whitespaces)
            } else if let t = CallTrace(line: line, name: name) {
                out.append(t)
                name = ""
            }
        }
        return out
    }
}

// MARK: the main actor's queue, as the trace schedules it

struct RigFailure: Error {}

func b01(_ b: Bool) -> String { b ? "1" : "0" }

/// The main-actor work production made runnable, in the order it was made (the model's `jobs`):
/// tasks spawned through `MainTasks` (held at a gate until run), continuations of awaits whose
/// fake has been completed (held until run), and the calling service's messages. `run(k)`
/// starts the `k`-th and waits until that task is suspended in a fake again or has finished:
/// every fake reports when a task waits on it, and every task reports when it ends, so the
/// barrier is exact. No other task can run meanwhile: all others are at their gate or in a fake.
@MainActor final class RigJobs {
    @MainActor final class Gate {
        var open = false
        var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() {
            open = true
            waiter?.resume()
            waiter = nil
        }
    }

    enum Entry {
        case task(code: String, gate: Gate)
        case resume(code: String, resume: () -> Void)
        case msg(RigService.Msg)

        var code: String {
            switch self {
            case .task(let c, _), .resume(let c, _): c
            case .msg(let m): m.code
            }
        }
    }

    /// Spawn-site labels, as the model names the tasks (`Job.code`).
    static let codes = ["camera.reconcile": "rec", "screen.stop": "capstop", "call.setup": "setup", "screen.sources": "sources",
                        "screen.present": "present", "camera.frame": "cframe", "screen.frame": "sframe", "screen.stopped": "serr"]

    var entries: [Entry] = []
    var deliver: (RigService.Msg) -> Void = { _ in }
    var busy = false
    var waiting: CheckedContinuation<Void, Never>?
    var ticket = 0
    var unknown: [String] = []

    /// What production spawns with. `screen.repeat` (the capture's once-a-second repeat of a
    /// stale frame) is not modelled and never runs here.
    var tasks: MainTasks {
        MainTasks { [weak self] label, work in
            MainActor.assumeIsolated {
                guard let self, label != "screen.repeat" else { return Task {} }
                if Self.codes[label] == nil { self.unknown.append(label) }
                let gate = Gate()
                self.entries.append(.task(code: Self.codes[label] ?? label, gate: gate))
                return Task { @MainActor [weak self] in
                    await gate.wait()
                    await work()
                    self?.settled()
                }
            }
        }
    }

    func resume(_ code: String, _ f: @escaping () -> Void) { entries.append(.resume(code: code, resume: f)) }

    /// The running task waits on a fake, or has ended.
    func settled() {
        guard busy else { return }
        busy = false
        waiting?.resume()
        waiting = nil
    }

    func run(_ k: Int) async {
        guard k >= 0, k < entries.count else { return }
        switch entries.remove(at: k) {
        case .msg(let m): deliver(m)
        case .task(_, let gate): await settle { gate.release() }
        case .resume(_, let f): await settle(f)
        }
    }

    func settle(_ start: () -> Void) async {
        busy = true
        ticket += 1
        let mine = ticket
        start()
        guard busy else { return }
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, busy, ticket == mine else { return }
            Issue.record("a task neither finished nor waited on a fake within 10 s")
            settled()
        }
        await withCheckedContinuation { waiting = $0 }
        watchdog.cancel()
    }
}

// MARK: the environment's stand-ins

/// A ScreenCaptureKit stream whose start and stop wait for the trace.
@MainActor final class RigStream: ScreenStream {
    let j: Int
    let owner: Int
    unowned let rig: CallRig
    var phase = "starting"
    var startWaiter: CheckedContinuation<Bool, Never>?
    var stopWaiter: CheckedContinuation<Bool, Never>?

    init(j: Int, owner: Int, rig: CallRig) {
        self.j = j
        self.owner = owner
        self.rig = rig
    }

    func startCapture() async throws {
        rig.log.append("sb\(owner).\(j)")
        let ok = await withCheckedContinuation { startWaiter = $0; rig.jobs.settled() }
        if !ok { throw RigFailure() }
    }

    func stopCapture() async throws {
        rig.log.append("se\(j)")
        phase = "stopping"
        let ok = await withCheckedContinuation { stopWaiter = $0; rig.jobs.settled() }
        if !ok { throw RigFailure() }
    }
}

/// The camera device behind production's `cameraReconciler` (its device closures and frame
/// callback are production's).
@MainActor final class RigCamera: CallCamera {
    unowned let rig: CallRig
    init(rig: CallRig) { self.rig = rig }

    func startCapture(deviceId: String?) async throws {
        if !(await rig.camWait("start")) { throw RigFailure() }
    }

    func stopCapture() async { _ = await rig.camWait("stop") }
}

/// CallingService and RingRTC as the model's environment: one direct-call slot, the presenting
/// and camera-enabled bookkeeping of CallingService, and its messages to the session, each a
/// main-actor job the trace runs.
@MainActor final class RigService: CallControl {
    struct Native {
        var id: UInt64
        var conv: Int
        var st: CallState
        var incoming: Bool
        var acceptedHere = false
        var hungUp = false
    }
    enum Msg {
        case event(CallingEvent, String)
        case camNeeded(Bool)
        var code: String {
            switch self {
            case .event(_, let c): c
            case .camNeeded(let b): "cam.\(b01(b))"
            }
        }
    }
    struct Setup {
        var waiter: CheckedContinuation<(ok: Bool, placed: UInt64?), Never>
        var sgen: UInt64
        var setup: UInt64
        var conversationId: String
        var audio: Bool
        var video: Bool
    }

    unowned let rig: CallRig
    var ncall: Native?
    var isPresenting = false
    var camEnabled = false
    var setupGen: UInt64 = 0
    var setups: [Int: Setup] = [:]
    var nextSetup = 0
    /// RingRTC's call ids, numbered as the model numbers native calls (rejected offers too).
    var nextNative: UInt64 = 0

    func newCallId() -> UInt64 {
        defer { nextNative += 1 }
        return nextNative
    }

    init(rig: CallRig) { self.rig = rig }

    func enqueue(_ m: Msg) { rig.jobs.entries.append(.msg(m)) }

    static func conv(_ id: String) -> Int? { id.hasPrefix("c") ? Int(id.dropFirst()) : nil }
    static func code(_ s: CallState) -> String {
        switch s {
        case .prering: "P"
        case .ringing: "R"
        case .accepted: "A"
        case .reconnecting: "X"
        case .ended: "E"
        }
    }

    var activeConversationIds: Set<String> { ncall.map { ["c\($0.conv)"] } ?? [] }

    func directCallState(_ conversationId: String) -> CallState? {
        guard let n = ncall, Self.conv(conversationId) == n.conv else { return nil }
        return n.st
    }

    func markHungUp(_ c: Int?) {
        guard var n = ncall, c == nil || c == n.conv else { return }
        n.hungUp = true
        ncall = n
    }

    func startOutgoingDirectCall(conversationId: String, hasLocalAudio: Bool, hasLocalVideo: Bool, setup: UInt64) async throws -> UInt64? {
        let q = nextSetup
        nextSetup += 1
        rig.log.append("start\(Self.conv(conversationId) ?? -1).\(b01(hasLocalVideo))")
        // CallingService's first await is its recipient lookup, a GRDB read, which throws
        // CancellationError in a cancelled task (releaseCallMedia cancels callSetupTask).
        if Task.isCancelled { throw CancellationError() }
        let sgen = setupGen
        let r = await withCheckedContinuation {
            setups[q] = Setup(waiter: $0, sgen: sgen, setup: setup, conversationId: conversationId, audio: hasLocalAudio, video: hasLocalVideo)
            rig.jobs.settled()
        }
        if !r.ok { throw CallingError.cancelled }
        return r.placed
    }

    /// `setup.q.ok`: the service's side of the setup completing; the setup task continues in a job.
    func completeSetup(_ q: Int, ok: Bool) {
        guard let p = setups.removeValue(forKey: q) else { return }
        let r = setupGen == p.sgen && ok
        var placed: UInt64?
        if r && ncall == nil {
            let c = Self.conv(p.conversationId) ?? -1
            let id = newCallId()
            placed = id
            ncall = Native(id: id, conv: c, st: .prering, incoming: false)
            camEnabled = p.video
            enqueue(.event(.outgoingCall(conversationId: p.conversationId, hasLocalAudio: p.audio, hasLocalVideo: p.video, callId: id, setup: p.setup),
                           "out.\(c).\(b01(p.video)).\(id)"))
        }
        rig.jobs.resume("ret.setup\(q)") { p.waiter.resume(returning: (r, placed)) }
    }

    func joinGroupCall(conversationId: String, hasLocalAudio: Bool, hasLocalVideo: Bool, shouldRing: Bool) async throws {
        Issue.record("group calls are not in the model")
        throw RigFailure()
    }

    func joinCallLinkCall(roomId: String, rootKey: CallLinkRootKey, adminPasskey: Data?, hasLocalAudio: Bool, hasLocalVideo: Bool) async throws {
        Issue.record("call links are not in the model")
        throw RigFailure()
    }

    func acceptDirectCall(conversationId: String, asVideoCall: Bool, callId: UInt64?) {
        let c = Self.conv(conversationId) ?? -1
        rig.log.append("accept\(c).\(b01(asVideoCall))")
        guard var n = ncall, n.conv == c, callId == nil || n.id == callId else { return }
        camEnabled = asVideoCall
        n.acceptedHere = true
        ncall = n
    }

    func declineDirectCall(conversationId: String, callId: UInt64?) {
        let c = Self.conv(conversationId) ?? -1
        rig.log.append("decline\(c)")
        guard let n = ncall, callId == nil || n.id == callId else { return }
        markHungUp(c)
    }

    func hangup(excludeRinging: Bool) {
        rig.log.append("hangup\(b01(excludeRinging))")
        if let n = ncall, !(excludeRinging && n.st == .ringing && n.incoming) { markHungUp(nil) }
        setupGen &+= 1
        isPresenting = false
        enqueue(.camNeeded(false))
    }

    func endCall(conversationId: String, callId: UInt64?) {
        let c = Self.conv(conversationId) ?? -1
        rig.log.append("end\(c).\(callId.map(String.init) ?? "-")")
        guard let n = ncall, callId == nil || n.id == callId else { return }
        markHungUp(c)
    }

    func setOutgoingAudio(conversationId: String, enabled: Bool) {
        Issue.record("setOutgoingAudio is not in the model")
    }

    func setOutgoingVideo(conversationId: String, enabled: Bool) {
        let c = Self.conv(conversationId) ?? -1
        rig.log.append("video\(c).\(b01(enabled))")
        camEnabled = enabled
        enqueue(.camNeeded(enabled && ncall?.conv == c))
    }

    func setPresenting(conversationId: String, _ presenting: Bool) {
        let c = Self.conv(conversationId)
        rig.log.append("present\(c.map(String.init) ?? "-").\(b01(presenting))")
        if let n = ncall, c == n.conv {
            isPresenting = presenting
            if presenting { enqueue(.camNeeded(false)) } else if camEnabled { enqueue(.camNeeded(true)) }
        } else if !presenting {
            isPresenting = false
        }
    }

    func sendVideoFrame(width: Int, height: Int, format: VideoPixelFormat, buffer: [UInt8]) {
        rig.log.append((width == 2 ? "fc" : "fs") + "\(height / 2 - 1)")
    }
}

// MARK: the rig

/// One production SignalSession with the stand-ins, stepped by trace events.
@MainActor final class CallRig {
    let session = SignalSession()
    let jobs = RigJobs()
    var service: RigService!
    let capGen0: UInt64
    var log: [String] = []
    // camera
    var camSessions = 0
    var dev = "off"
    var camOnFrame: (@Sendable (CapturedFrame) -> Void)?
    /// The device call the reconciler waits on, and one completed whose continuation has not run.
    var camWaiting: (kind: String, waiter: CheckedContinuation<Bool, Never>)?
    var camAnswered: String?
    // screen
    var caps: [ScreenShareCapture] = []
    var capTokens: [UInt64] = []
    /// The capture's `sources()` succeeded, so `filter(for:)` would resolve a pick.
    var capContent: [Bool] = []
    var sources: [Int: CheckedContinuation<Bool, Never>] = [:]
    var streams: [RigStream] = []
    var outputs: [ScreenStreamOutput] = []

    init(cfg: [UInt64]) {
        _ = NSApplication.shared   // an incoming ring asks NSApp for the user's attention
        capGen0 = cfg[3]
        service = RigService(rig: self)
        service.setupGen = cfg[2]
        session.callGeneration = cfg[0]
        session.lastScreenShareToken = cfg[1]
        session.callControlOverride = service
        session.mainTasks = jobs.tasks
        jobs.deliver = { [unowned self] m in
            switch m {
            case .event(let ev, _): session.handleCallingEvent(ev)
            case .camNeeded(let on): session.setCameraSending(on)
            }
        }
        session.cameraBackend = .init(
            requestAccess: { [unowned self] in await camWait("access") },
            make: { [unowned self] onFrame in
                camOnFrame = onFrame
                return RigCamera(rig: self)
            })
        session.screenShareBackend = .init(
            isGranted: { true },
            sources: { [unowned self] capture in
                let i = index(capture)
                log.append("ss\(i)")
                let ok = await withCheckedContinuation { sources[i] = $0; jobs.settled() }
                if !ok { throw RigFailure() }
                capContent[i] = true
                return []
            },
            start: { [unowned self] capture, _ in
                let owner = index(capture)
                guard capContent[owner] else { throw ScreenShareError.sourceGone }   // filter(for:) without content
                try await capture.start(makeStream: { out in
                    let s = RigStream(j: streams.count, owner: owner, rig: self)
                    streams.append(s)
                    outputs.append(out)
                    return s
                })
            })
        session.callLocalVideoModel.sinks[ObjectIdentifier(self)] = { [unowned self] planes in
            if let planes { log.append("cp\(planes.height / 2 - 1)") }
        }
    }

    /// The camera device call `kind` (`access`, `start`, `stop`) waits for the trace.
    func camWait(_ kind: String) async -> Bool {
        switch kind {
        case "access": log.append("ca")
        case "start":
            log.append("cs\(camSessions)")
            dev = "starting\(camSessions)"
            camSessions += 1
        default:
            log.append("cx")
            if dev.hasPrefix("on") { dev = "stopping" + dev.dropFirst(2) }
        }
        return await withCheckedContinuation { camWaiting = (kind, $0); jobs.settled() }
    }

    /// `cacc` / `cstart` / `cstop`: the device call completes; the reconciler continues in a job.
    func completeCamera(_ kind: String, _ value: Bool) {
        guard let w = camWaiting, w.kind == kind else { return }
        camWaiting = nil
        camAnswered = kind
        if kind == "start" { dev = value ? "on\(camSessions - 1)" : "off" }
        if kind == "stop" { dev = "off" }
        jobs.resume("ret.cam") { [unowned self] in
            camAnswered = nil
            w.waiter.resume(returning: value)
        }
    }

    /// A capture's share number: captures are numbered as `togglePresenting` makes them.
    func index(_ capture: ScreenShareCapture) -> Int { caps.firstIndex { $0 === capture } ?? -1 }

    /// After the share button: a new capture is share `caps.count`, under the token it was given.
    func noteNewCapture() {
        guard let c = session.screenCapture, !caps.contains(where: { $0 === c }), let t = session.screenShareToken else { return }
        caps.append(c)
        capTokens.append(t)
        capContent.append(false)
        c.generation = capGen0
    }

    static func summary(_ c: Int) -> ConversationSummary {
        ConversationSummary(id: "c\(c)", kind: .private, title: "Contact \(c)", color: "A100", unreadCount: 0, isArchived: false,
                            isPinned: false, isAccepted: true)
    }

    /// Frames carry their source in their size: camera session `k` is 2×(2k+2), share `i` 4×(2i+2).
    static func frame(width: Int, _ n: Int) -> CapturedFrame {
        let h = 2 * (n + 1)
        return CapturedFrame(width: width, height: h, nv12: [UInt8](repeating: 0, count: width * h * 3 / 2))!
    }

    func step(_ e: String) async {
        let p = e.split(separator: ".").map(String.init)
        let n = { (k: Int) in Int(p[k]) ?? -1 }
        let flag = { (k: Int) in p[k] == "1" }
        let s = session
        switch p[0] {
        case "open":
            s.opened = Self.summary(n(1))
            s.openCallLobby("c\(n(1))", video: flag(2))
        case "start": s.startCallFromLobby()
        case "accept": s.acceptCall("c\(n(1))", video: flag(2))
        case "decline": s.declineCall("c\(n(1))")
        case "hangup": s.hangUp()
        case "close": s.endCallUI()
        case "video": s.setCallVideo(flag(1))
        case "toggle":
            s.togglePresenting()
            noteNewCapture()
        case "pick": s.startPresenting("source")
        case "cancel": s.cancelPresentingSources()
        case "run": await jobs.run(n(1))
        case "nin":
            guard service.ncall == nil else { return }
            let id = service.newCallId()
            service.ncall = .init(id: id, conv: n(1), st: .prering, incoming: true)
            service.enqueue(.event(.incomingDirectCall(conversationId: "c\(n(1))", isVideoCall: flag(2), callId: id), "in.\(n(1)).\(p[2]).\(id)"))
        case "nst":
            let st: CallState = switch p[1] { case "P": .prering; case "R": .ringing; case "A": .accepted; default: .reconnecting }
            guard var c = service.ncall, c.st != st, !c.hungUp, !(st == .accepted && c.incoming && !c.acceptedHere) else { return }
            c.st = st
            service.ncall = c
            if st == .accepted && service.camEnabled { service.enqueue(.camNeeded(true)) }
            service.enqueue(.event(.callStateChange(conversationId: "c\(c.conv)", state: st, endedReason: nil, acceptedTime: nil, callId: c.id),
                                   "st.\(c.conv).\(p[1]).\(c.id)"))
        case "nend":
            guard let c = service.ncall else { return }
            let reason: CallEndReason = switch p[1] { case "L": .localHangup; case "R": .remoteHangup; default: .remoteHangupNeedPermission }
            service.ncall = nil
            service.isPresenting = false
            service.enqueue(.camNeeded(false))
            service.enqueue(.event(.callStateChange(conversationId: "c\(c.conv)", state: .ended, endedReason: reason, acceptedTime: nil, callId: c.id),
                                   "end.\(c.conv).\(p[1]).\(c.id)"))
        case "nrej":
            let id = service.newCallId()
            service.enqueue(.event(.callStateChange(conversationId: "c\(n(1))", state: .ended, endedReason: nil, acceptedTime: nil, callId: id),
                                   "end.\(n(1)).-.\(id)"))
        case "setup": service.completeSetup(n(1), ok: flag(2))
        case "cacc": completeCamera("access", flag(1))
        case "cstart": completeCamera("start", flag(1))
        case "cstop": completeCamera("stop", true)
        case "cframe":
            // the camera's frame callback (production's, given to the device when it was made)
            if n(1) >= 0 && n(1) < camSessions, let onFrame = camOnFrame { onFrame(Self.frame(width: 2, n(1))) }
        case "src":
            guard let c = sources.removeValue(forKey: n(1)) else { return }
            jobs.resume("ret.src\(n(1))") { c.resume(returning: flag(2)) }
        case "sstart":
            guard n(1) >= 0, n(1) < streams.count, let c = streams[n(1)].startWaiter else { return }
            streams[n(1)].startWaiter = nil
            streams[n(1)].phase = flag(2) ? "running" : "failed"
            jobs.resume("ret.sstart\(n(1))") { c.resume(returning: flag(2)) }
        case "sstop":
            guard n(1) >= 0, n(1) < streams.count, let c = streams[n(1)].stopWaiter else { return }
            streams[n(1)].stopWaiter = nil
            streams[n(1)].phase = flag(2) ? "stopped" : "stopfailed"
            jobs.resume("ret.sstop\(n(1))") { c.resume(returning: flag(2)) }
        case "sframe":
            // a frame of a stream that has run (frames on their way may arrive while and after it
            // stops), through its production output and the capture's callback
            guard n(1) >= 0, n(1) < streams.count, !["starting", "failed"].contains(streams[n(1)].phase) else { return }
            outputs[n(1)].deliver(Self.frame(width: 4, streams[n(1)].owner))
        case "serr":
            // the stream's delegate error, through its production output and the capture's callback
            guard n(1) >= 0, n(1) < streams.count else { return }
            if streams[n(1)].phase == "running" { streams[n(1)].phase = "stopped" }
            outputs[n(1)].stopped(RigFailure())
        default:
            Issue.record("unknown event \(e)")
        }
    }

    /// Completes everything still waiting (failing it) and runs every job, so no task is left suspended.
    func finish() async {
        for _ in 0..<2000 {
            if !jobs.entries.isEmpty {
                await jobs.run(0)
            } else if let w = camWaiting {
                completeCamera(w.kind, w.kind == "stop")
            } else if let q = service.setups.keys.min() {
                service.completeSetup(q, ok: false)
            } else if let (k, c) = sources.first {
                sources[k] = nil
                jobs.resume("") { c.resume(returning: false) }
            } else if let st = streams.first(where: { $0.startWaiter != nil || $0.stopWaiter != nil }) {
                if let c = st.startWaiter { st.startWaiter = nil; jobs.resume("") { c.resume(returning: false) } }
                if let c = st.stopWaiter { st.stopWaiter = nil; jobs.resume("") { c.resume(returning: true) } }
            } else {
                return
            }
        }
        Issue.record("the rig did not wind down")
    }

    // MARK: observation (the same fields, in the same order, as `obs` in CallCapture/Trace.lean)

    func observe() -> String {
        let s = session
        let rec = s.cameraReconciler
        let a = s.activeCall.map { a -> String in
            let d: String = switch a.directState {
            case .prering: "P"
            case .ringing: "R"
            case .accepted: "A"
            case .reconnecting: "X"
            case .ended: "E"
            case nil: "-"
            }
            return "\(RigService.conv(a.conversationId).map(String.init) ?? "?").\(a.stage == .lobby ? "L" : "C").\(d).\(b01(a.isLive)).\(a.callId.map(String.init) ?? "-")"
        } ?? "-"
        let ringing = s.ringingCall.map { "\(RigService.conv($0.conversationId).map(String.init) ?? "?").\($0.callId)" } ?? "-"
        let share: String = if let c = s.screenCapture, let t = s.screenShareToken {
            "\(caps.firstIndex(where: { $0 === c }).map(String.init) ?? "?").\(t)"
        } else if s.screenCapture == nil && s.screenShareToken == nil { "-" } else { "unpaired" }
        let pc = camWaiting?.kind ?? camAnswered ?? (rec.pass != nil ? "sched" : "idle")
        let capList = caps.enumerated().map { i, c in
            "\(i).\(capTokens[i]).\(c.generation).\((c.stream as? RigStream).map { String($0.j) } ?? "-")"
        }
        let streamList = streams.map { st in
            "\(st.j).\(st.owner).\(st.phase)\(outputs[st.j].state.withLock { $0.running } ? "" : ".off")"
        }
        var ops = service.setups.keys.map { "setup\($0)" } + sources.keys.map { "sources\($0)" }
        for st in streams {
            if st.startWaiter != nil { ops.append("start\(st.j)") }
            if st.stopWaiter != nil { ops.append("stop\(st.j)") }
        }
        let nc = service.ncall.map { "\($0.conv).\(RigService.code($0.st)).\(b01($0.incoming)).\(b01($0.acceptedHere))" } ?? "-"
        return [
            "A=\(a)", "R=\(ringing)", "V=\(b01(s.callLocalVideo))", "S=\(b01(s.cameraSends))", "G=\(s.callGeneration)",
            "T=\(b01(s.callSetupTask != nil))", "SH=\(share)", "LT=\(s.lastScreenShareToken)", "SRC=\(b01(s.presentingSources != nil))",
            "PC=\(pc)", "RUN=\(b01(rec.isRunning))", "AG=\(b01(rec.again))", "DEV=\(dev)",
            "CAPS=\(capList.joined(separator: ","))", "ST=\(streamList.joined(separator: ","))", "OPS=\(ops.sorted().joined(separator: ","))",
            "N=\(nc)", "P=\(b01(service.isPresenting))", "CE=\(b01(service.camEnabled))", "SG=\(service.setupGen)",
            "J=\(jobs.entries.map(\.code).joined(separator: ","))", "E=\(log.joined(separator: ","))",
        ].joined(separator: " ")
    }

    /// Production's observation after each event of `t`.
    static func run(_ t: CallTrace) async -> [String] {
        let rig = CallRig(cfg: t.cfg)
        var out: [String] = []
        for (k, e) in t.events.enumerated() {
            rig.log = []
            await rig.step(e)
            out.append("\(k) \(rig.observe())")
        }
        await rig.finish()
        if !rig.jobs.unknown.isEmpty { Issue.record("tasks spawned at sites the model does not know: \(rig.jobs.unknown)") }
        return out
    }
}

// MARK: the oracle

enum CallOracle {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../Verification/CallCapture").standardized
    static var path: String {
        ProcessInfo.processInfo.environment["SEREIN_CALL_ORACLE"] ?? root.appendingPathComponent(".lake/build/bin/oracle").path
    }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: path) }

    static func call(_ args: [String], input: String = "") throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serein-oracle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inURL = dir.appendingPathComponent("in.txt"), outURL = dir.appendingPathComponent("out.txt")
        try Data(input.utf8).write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = try FileHandle(forReadingFrom: inURL)
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw RigFailure() }
        return String(decoding: try Data(contentsOf: outURL), as: UTF8.self)
    }

    /// The model's observations for each trace.
    static func replay(_ traces: [CallTrace]) throws -> [[String]] {
        var out: [[String]] = []
        for line in try call(["replay"], input: traces.map(\.line).joined(separator: "\n") + "\n").split(separator: "\n") {
            if line.hasPrefix("T ") { out.append([]) } else { out[out.count - 1].append(String(line)) }
        }
        return out
    }
}

// MARK: comparison and minimisation

struct Mismatch {
    var step: Int
    var event: String
    var fields: [String]
}

@MainActor func firstMismatch(_ t: CallTrace, model: [String], swift: [String]) -> Mismatch? {
    for (k, (m, p)) in zip(model, swift).enumerated() where m != p {
        let mf = m.split(separator: " "), pf = p.split(separator: " ")
        let diff = zip(mf, pf).filter { $0 != $1 }.map { "model \($0) | swift \($1)" }
        return Mismatch(step: k, event: t.events[k], fields: diff)
    }
    return model.count == swift.count ? nil : Mismatch(step: min(model.count, swift.count), event: "?", fields: ["step counts differ"])
}

@MainActor func mismatches(_ t: CallTrace) async throws -> Bool {
    let model = try CallOracle.replay([t])[0]
    return firstMismatch(t, model: model, swift: await CallRig.run(t)) != nil
}

/// Drops chunks of events while production and the model still disagree.
@MainActor func minimise(_ t: CallTrace) async throws -> CallTrace {
    var t = t
    var chunk = max(1, t.events.count / 2)
    while true {
        var i = 0
        while i < t.events.count {
            var c = t
            c.events.removeSubrange(i..<min(i + chunk, c.events.count))
            if try await mismatches(c) { t = c } else { i += 1 }
        }
        if chunk == 1 { break }
        chunk /= 2
    }
    return t
}

@MainActor func check(_ traces: [CallTrace]) async throws {
    let model = try CallOracle.replay(traces)
    #expect(model.count == traces.count)
    var reported = 0
    for (t, m) in zip(traces, model) {
        let swift = await CallRig.run(t)
        guard let bad = firstMismatch(t, model: m, swift: swift) else { continue }
        reported += 1
        guard reported <= 3 else { continue }
        let small = try await minimise(t)
        let model2 = try CallOracle.replay([small])[0]
        let detail = firstMismatch(small, model: model2, swift: await CallRig.run(small)) ?? bad
        Issue.record("""
            production and the model disagree\(t.name.isEmpty ? "" : " (\(t.name))") at step \(detail.step) (\(detail.event)):
              \(detail.fields.joined(separator: "\n  "))
            minimised trace:
              \(small.line)
            """)
    }
    #expect(reported == 0, "\(reported) of \(traces.count) traces disagree")
}

@MainActor @Suite(.enabled(if: CallOracle.available, "build the oracle: Tools/verify-calls.sh, or lake build in Verification/CallCapture"))
struct CallCaptureConformanceTests {
    @Test func regressionTraces() async throws {
        let text = try String(contentsOf: CallOracle.root.appendingPathComponent("traces/regressions.txt"), encoding: .utf8)
        let traces = CallTrace.parse(text)
        #expect(traces.count >= 30)
        try await check(traces)
    }

    /// The model's replayable counterexamples (none since D1–D5 were fixed: the 2^64 ones in
    /// Wrap.lean are symbolic).
    @Test func counterexampleTraces() async throws {
        let traces = CallTrace.parse(try CallOracle.call(["counterexamples"]))
        try await check(traces)
    }

    /// Random traces of any events and any job order, a third of them starting next to every
    /// counter's wrap.
    @Test func randomTraces() async throws { try await random(seed: 20261110, length: 60, mode: "any") }

    /// Random traces whose user events are only those the UI offers.
    @Test func randomUITraces() async throws { try await random(seed: 1729, length: 80, mode: "ui") }

    /// Random traces whose user events come only while no main-actor job is pending.
    @Test func randomDrainedTraces() async throws { try await random(seed: 4242, length: 80, mode: "drained") }

    /// …and whose jobs run oldest first.
    @Test func randomDrainedFIFOTraces() async throws { try await random(seed: 31337, length: 80, mode: "drained-fifo") }

    func random(seed: Int, length: Int, mode: String) async throws {
        let count = ProcessInfo.processInfo.environment["SEREIN_CALL_TRACES"].flatMap { Int($0) } ?? 400
        let traces = try CallOracle.call(["gen", String(seed), String(count), String(length), mode]).split(separator: "\n").compactMap { CallTrace(line: String($0)) }
        #expect(traces.count == count)
        try await check(traces)
    }
}
