import Foundation
import Network
import Synchronization
import Testing
@testable import SwiftCalling

struct LiveVoicePairTests {
    private actor Microphone: VoiceCallMicrophone {
        var inputs: [AsyncStream<[Int16]>.Continuation] = []
        var running = false

        func start() async throws -> AsyncStream<[Int16]> {
            let pair = AsyncStream<[Int16]>.makeStream()
            inputs.append(pair.continuation)
            running = true
            return pair.stream
        }
        // Retain each continuation to simulate old callbacks racing mute.
        func stop() { running = false }
        func speak(_ generation: Int, _ frames: Int) {
            guard inputs.indices.contains(generation) else { return }
            let frame = (0..<960).map { Int16(8000 * sin(Double($0) * 0.13)) }
            for _ in 0..<frames { inputs[generation].yield(frame) }
        }
    }

    private actor Speaker: VoiceCallSpeaker {
        var running = false
        var audibleBlocks = 0
        func start() throws { running = true }
        func enqueue(_ samples: [Int16], timestamp: UInt32) throws {
            try #require(running && samples.count == 960)
            if samples.contains(where: { $0 != 0 }) { audibleBlocks += 1 }
        }
        func stop() { running = false }
    }

    private final class Observer: Sendable {
        let candidates = AsyncStream<IceCandidateUpdate>.makeStream()
        let ringing = Mutex(false)
        let accepted = Mutex(false)
        let hungUp = Mutex(false)
        let audible = Mutex(false)
        let error = Mutex<String?>(nil)
        let hostCandidates = Mutex(0)
        let reflexiveCandidates = Mutex(0)
        let relayedOnly = Mutex(true)
        private let relayAddresses = Mutex<[ICEBinding.Address]>([])
        let routes = Mutex<[Int]>([])
        let recovered = Mutex(0)
        let reconnecting = Mutex(0)

        func observe(_ event: LiveVoiceSession.Event) {
            switch event {
            case .candidate(let update):
                hostCandidates.withLock { $0 += 1 }
                if update.addedSDP?.contains(" typ srflx ") == true { reflexiveCandidates.withLock { $0 += 1 } }
                if let removed = update.removed {
                    // The pinned wire format attaches a fixed non-routable compatibility
                    // placeholder. The only real address withdrawn must be a prior relay.
                    let address = ICEBinding.Address(ip: Array(removed.ip), port: removed.port)
                    if update.addedSDP != "candidate:FAKE 1 tcp 0 127.0.0.1 0 typ host" || !relayAddresses.withLock({ $0.contains(address) }) {
                        relayedOnly.withLock { $0 = false }
                    }
                } else if let sdp = update.addedSDP, let relay = ICERelayCandidate(sdp) {
                    relayAddresses.withLock { $0.append(relay.address) }
                } else { relayedOnly.withLock { $0 = false } }
                candidates.continuation.yield(update)
            case .ringing: ringing.withLock { $0 = true }
            case .accepted: accepted.withLock { $0 = true }
            case .remoteHangup: hungUp.withLock { $0 = true }
            case .failed(let reason): error.withLock { $0 = reason }
            case .networkRoute(let adapter): routes.withLock { $0.append(adapter) }
            case .reconnecting: reconnecting.withLock { $0 += 1 }
            case .reconnected: recovered.withLock { $0 += 1 }
            case .remoteAudio, .remoteVideo, .remoteScreen, .lowBandwidthForVideo: break
            case .audioLevels(let captured, let received):
                if captured > 0 || received > 0 { audible.withLock { $0 = true } }
            }
        }
    }

    private func wait(seconds: Int = 4, sourceLocation: SourceLocation = #_sourceLocation,
                      for condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await condition(), sourceLocation: sourceLocation)
    }

    @Test(arguments: [false, true]) func slowLocalAddressLookupIsBounded(keepPort: Bool) async throws {
        let lookingUp = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let start = ContinuousClock.now
        let local = try? await VoiceHostPort.gather(timeoutAfter: .milliseconds(750), keepPortOnLookupTimeout: keepPort, localAddresses: {
            lookingUp.withLock { $0 = true }
            _ = release.wait(timeout: .now() + 4)
            return ["192.0.2.1"]
        })
        #expect(lookingUp.withLock { $0 })
        #expect((local != nil) == keepPort)
        if let local { #expect(local.candidates.isEmpty); local.close() }
        #expect(start.duration(to: .now) < .seconds(3))
    }

    @Test func remoteCheckStartsWhileLocalDiscoveryIsPending() async throws {
        let peer = try NWListener(using: .udp)
        let ready = Mutex(false), received = Mutex(false)
        peer.stateUpdateHandler = { state in
            if case .ready = state { ready.withLock { $0 = true } }
        }
        peer.newConnectionHandler = { connection in
            received.withLock { $0 = true }
            connection.cancel()
        }
        peer.start(queue: .global())
        defer { peer.cancel() }
        try await wait { ready.withLock { $0 } }
        let port = try #require(peer.port)
        let devices = VoiceCallDevices(microphone: Microphone(), speaker: Speaker())
        let session = LiveVoiceSession(callID: 1, outgoing: true, devices: devices) { _ in }
        let remote = LiveVoiceSession(callID: 1, outgoing: false, devices: devices) { _ in }
        try await session.setRemote(remote.localParameters, callerIdentity: Data(repeating: 1, count: 32),
                                    calleeIdentity: Data(repeating: 2, count: 32))
        await session.configure(relayOnly: false, servers: []) { _ in
            try await Task.sleep(for: .seconds(10))
            return try await VoiceHostPort.gather()
        }
        await session.addCandidate(.init(addedSDP: "candidate:peer 1 udp 123 127.0.0.1 \(port.rawValue) typ host"))
        do { try await wait(seconds: 3) { received.withLock { $0 } } }
        catch { await session.end(sendHangup: false); throw error }
        await session.end(sendHangup: false)
    }

    @Test func acceptsOnlyUDPDiscoveryURIs() {
        #expect(TURNServerEndpoint(stunURI: "stun:example.org")?.port.rawValue == 3478)
        #expect(TURNServerEndpoint(stunURI: "stun:[2001:db8::1]:9900")?.host == "2001:db8::1")
        #expect(TURNServerEndpoint(stunURI: "turn:127.0.0.1?transport=udp")?.transport == .udp)
        for uri in ["stuns:example.org", "stun:host?transport=udp", "stun:host/path", "turns:host", "turn:host?transport=tcp"] {
            #expect(TURNServerEndpoint(stunURI: uri) == nil)
        }
        #expect(TURNServerEndpoint("stun:example.org") == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_TEST_STUN_ONLY"] == "1"))
    func twoWaySpeechWithServerReflexiveCandidates() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["SEREIN_TEST_TURN_PORT"])
        let stun = VoiceTURNServer(urls: ["stun:127.0.0.1:" + port], username: "", password: "")
        let a = Observer(), b = Observer(), micA = Microphone(), micB = Microphone()
        let outA = Speaker(), outB = Speaker()
        let alice = LiveVoiceSession(callID: 99, outgoing: true, devices: .init(microphone: micA, speaker: outA), event: a.observe)
        let bob = LiveVoiceSession(callID: 99, outgoing: false, devices: .init(microphone: micB, speaker: outB), event: b.observe)
        let forward = Task { for await candidate in a.candidates.stream { await bob.addCandidate(candidate) } }
        let back = Task { for await candidate in b.candidates.stream { await alice.addCandidate(candidate) } }
        defer { forward.cancel(); back.cancel() }
        let idA = Data(repeating: 0x21, count: 33), idB = Data(repeating: 0x22, count: 33)
        do {
            try await alice.setRemote(bob.localParameters, callerIdentity: idA, calleeIdentity: idB)
            try await bob.setRemote(alice.localParameters, callerIdentity: idA, calleeIdentity: idB)
            for endpoint in [alice, bob] {
                await endpoint.configure(relayOnly: false, servers: [stun]) { inbound in
                    try await VoiceHostPort.gather(inbound: inbound, localAddresses: { [] })
                }
            }
            try await wait(seconds: 12) { a.ringing.withLock { $0 } && b.ringing.withLock { $0 } }
            #expect(a.reflexiveCandidates.withLock { $0 > 0 } || b.reflexiveCandidates.withLock { $0 > 0 })
            await alice.setMicrophoneEnabled(true)
            await bob.setMicrophoneEnabled(true)
            await bob.accept()
            try await wait { await micA.running }
            try await wait { await micB.running }
            await micA.speak(0, 3)
            await micB.speak(0, 3)
            try await wait { await outA.audibleBlocks >= 3 }
            try await wait { await outB.audibleBlocks >= 3 }
        } catch {
            await alice.end(sendHangup: false)
            await bob.end(sendHangup: false)
            throw error
        }
        await alice.end(sendHangup: false)
        await bob.end(sendHangup: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_TEST_TURN_PORT"] != nil
                      && ProcessInfo.processInfo.environment["SEREIN_TEST_STUN_ONLY"] != "1"), arguments: [false, true])
    func asymmetricRelayCarriesTwoWaySpeech(relayIsCaller: Bool) async throws {
        let a = Observer(), b = Observer(), micA = Microphone(), micB = Microphone()
        let outA = Speaker(), outB = Speaker()
        let relay = LiveVoiceSession(callID: 101, outgoing: relayIsCaller, devices: .init(microphone: micA, speaker: outA), event: a.observe)
        let direct = LiveVoiceSession(callID: 101, outgoing: !relayIsCaller, devices: .init(microphone: micB, speaker: outB), event: b.observe)
        // Coturn's one-to-one NAT maps 192.0.2.1 to loopback for TURN permissions.
        // Model the view on each side of that NAT without changing candidate types.
        let forward = Task {
            for await update in a.candidates.stream {
                if let sdp = update.addedSDP {
                    await direct.addCandidate(.init(addedSDP: sdp.replacingOccurrences(of: " 192.0.2.1 ", with: " 127.0.0.1 ")))
                }
            }
        }
        let back = Task {
            for await update in b.candidates.stream {
                if let sdp = update.addedSDP {
                    await relay.addCandidate(.init(addedSDP: sdp.replacingOccurrences(of: " typ host", with: " typ srflx")))
                }
            }
        }
        defer { forward.cancel(); back.cancel() }
        let idA = Data(repeating: 1, count: 33), idB = Data(repeating: 2, count: 33)
        let server = VoiceTURNServer(urls: [TURNTestRelay.peerURI], username: "serein", password: "serein-test-relay")
        do {
            try await relay.setRemote(direct.localParameters, callerIdentity: idA, calleeIdentity: idB)
            try await direct.setRemote(relay.localParameters, callerIdentity: idA, calleeIdentity: idB)
            await direct.configure(relayOnly: false, servers: []) { inbound in
                try await VoiceHostPort.gather(inbound: inbound, localAddresses: { ["192.0.2.1"] })
            }
            await relay.configure(relayOnly: true, servers: [server]) { _ in
                Issue.record("Relay-only endpoint gathered a host address")
                throw DirectICETransport.Failure.noConsent
            }
            try await wait(seconds: 14) { a.ringing.withLock { $0 } && b.ringing.withLock { $0 } }
            await relay.setMicrophoneEnabled(true)
            await direct.setMicrophoneEnabled(true)
            await (relayIsCaller ? direct : relay).accept()
            try await wait { await micA.running }
            try await wait { await micB.running }
            await micA.speak(0, 3)
            await micB.speak(0, 3)
            try await wait { await outA.audibleBlocks >= 3 }
            try await wait { await outB.audibleBlocks >= 3 }
            #expect(a.relayedOnly.withLock { $0 } && a.hostCandidates.withLock { $0 > 0 })
        } catch {
            await relay.end(sendHangup: false); await direct.end(sendHangup: false)
            throw error
        }
        await relay.end(sendHangup: false); await direct.end(sendHangup: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_TEST_TURN_PORT"] != nil))
    func recoversForcedRelayWithoutRevealingHostCandidates() async throws {
        let a = Observer(), b = Observer()
        let micA = Microphone(), micB = Microphone()
        let outA = Speaker(), outB = Speaker()
        let alice = LiveVoiceSession(callID: 98, outgoing: true, devices: .init(microphone: micA, speaker: outA), event: a.observe)
        let bob = LiveVoiceSession(callID: 98, outgoing: false, devices: .init(microphone: micB, speaker: outB), event: b.observe)
        let forward = Task { for await c in a.candidates.stream { await bob.addCandidate(c) } }
        let back = Task { for await c in b.candidates.stream { await alice.addCandidate(c) } }
        defer { forward.cancel(); back.cancel() }
        let idA = Data(repeating: 0x41, count: 33), idB = Data(repeating: 0x42, count: 33)
        let server = VoiceTURNServer(urls: [TURNTestRelay.peerURI, "stun:127.0.0.1:" + (ProcessInfo.processInfo.environment["SEREIN_TEST_TURN_PORT"] ?? "")], username: "serein", password: "serein-test-relay")
        do {
            try await alice.setRemote(bob.localParameters, callerIdentity: idA, calleeIdentity: idB)
            try await bob.setRemote(alice.localParameters, callerIdentity: idA, calleeIdentity: idB)
            let firstAllocation = Mutex<TURNAllocation?>(nil)
            await alice.configure(relayOnly: true, servers: [server], allocateRelay: { servers in
                let allocated = await VoiceTURNServer.allocateFirst(servers)
                firstAllocation.withLock { if $0 == nil { $0 = allocated } }
                return allocated
            }, gatherHosts: { _ in
                Issue.record("A relay-only call attempted host discovery")
                throw DirectICETransport.Failure.noConsent
            })
            await bob.configure(relayOnly: true, servers: [server])
            try await wait(seconds: 14) { a.ringing.withLock { $0 } && b.ringing.withLock { $0 } }
            await alice.setMicrophoneEnabled(true)
            await bob.setMicrophoneEnabled(true)
            await bob.accept()
            try await wait { await micA.running }
            try await wait { await micB.running }
            await micA.speak(0, 3)
            await micB.speak(0, 3)
            try await wait { await outA.audibleBlocks >= 3 }
            try await wait { await outB.audibleBlocks >= 3 }
            // Delete the real coturn allocation without notifying the session. Consent and
            // heartbeat processing must detect the loss, signal new candidates and recover.
            let lost = try #require(firstAllocation.withLock { $0 })
            lost.close()
            try await wait(seconds: 18) { a.recovered.withLock { $0 > 0 } && b.recovered.withLock { $0 > 0 } }
            #expect(await micA.inputs.count == 1)
            #expect(await micB.inputs.count == 1)
            let beforeA = await outA.audibleBlocks, beforeB = await outB.audibleBlocks
            await micA.speak(0, 3)
            await micB.speak(0, 3)
            try await wait { await outA.audibleBlocks >= beforeA + 3 }
            try await wait { await outB.audibleBlocks >= beforeB + 3 }
            #expect(a.reconnecting.withLock { $0 >= 1 } && b.reconnecting.withLock { $0 >= 1 })
            #expect(a.relayedOnly.withLock { $0 } && b.relayedOnly.withLock { $0 })
            #expect(a.routes.withLock { $0.count >= 2 } && b.routes.withLock { $0.count >= 2 })
        } catch {
            await alice.end(sendHangup: false); await bob.end(sendHangup: false)
            throw error
        }
        await alice.end(sendHangup: false); await bob.end(sendHangup: false)
    }

    @Test(arguments: [false, true]) func directCaptureConsentMuteAndTeardown(peerReflexive: Bool) async throws {
        let first = Observer(), second = Observer()
        let micA = Microphone(), micB = Microphone()
        let speakerA = Speaker(), speakerB = Speaker()
        let caller = LiveVoiceSession(callID: 71, outgoing: true,
            devices: .init(microphone: micA, speaker: speakerA), event: first.observe)
        let callee = LiveVoiceSession(callID: 71, outgoing: false,
            devices: .init(microphone: micB, speaker: speakerB), event: second.observe)
        let a = Task { for await candidate in first.candidates.stream { await callee.addCandidate(candidate) } }
        let b = Task { for await candidate in second.candidates.stream { await caller.addCandidate(candidate) } }
        defer { a.cancel(); b.cancel() }
        do {
            let callerIdentity = Data(repeating: 0x11, count: 33), calleeIdentity = Data(repeating: 0x22, count: 33)
            try await caller.setRemote(callee.localParameters, callerIdentity: callerIdentity, calleeIdentity: calleeIdentity)
            try await callee.setRemote(caller.localParameters, callerIdentity: callerIdentity, calleeIdentity: calleeIdentity)
            await caller.setMicrophoneEnabled(true)
            await callee.setMicrophoneEnabled(true)
            await callee.configure(relayOnly: false, servers: [], audioLevelsIntervalMs: 100)
            if peerReflexive {
                // No caller host candidate or reserved port: the callee must authenticate
                // the first inbound STUN check and learn its peer's actual source tuple.
                await caller.configure(relayOnly: false, servers: [], audioLevelsIntervalMs: 100) { _ in
                    throw DirectICETransport.Failure.noConsent
                }
            } else { await caller.configure(relayOnly: false, servers: [], audioLevelsIntervalMs: 100) }
            try await wait(seconds: 14) { first.ringing.withLock { $0 } && second.ringing.withLock { $0 } }
            #expect(await micA.inputs.isEmpty)
            #expect(await micB.inputs.isEmpty)
            #expect(await !speakerA.running)
            #expect(await !speakerB.running)

            await callee.accept()
            try await wait { await micA.running }
            try await wait { await micB.running }
            await micA.speak(0, 3)
            await micB.speak(0, 3)
            try await wait { await speakerA.audibleBlocks >= 3 }
            try await wait { await speakerB.audibleBlocks >= 3 }
            try await wait { first.audible.withLock { $0 } && second.audible.withLock { $0 } }

            // Let the prior 60 ms packet and its bounded concealment tail finish.
            try await Task.sleep(for: .milliseconds(200))
            let beforeMute = await speakerB.audibleBlocks
            await micA.speak(0, 2)
            let mute = caller.requestMicrophone(false)
            await micA.speak(0, 12)
            // The XPC command already returned, but its actor-side device stop is queued.
            try await Task.sleep(for: .milliseconds(100))
            #expect(await micA.running)
            #expect(await speakerB.audibleBlocks == beforeMute)
            await caller.setMicrophoneEnabled(false, revision: mute)
            #expect(await !micA.running)
            await micA.speak(0, 12)
            await caller.setMicrophoneEnabled(true)
            try await wait { await micA.inputs.count == 2 }
            await micA.speak(0, 12)
            await micA.speak(1, 2)
            try await Task.sleep(for: .milliseconds(150))
            #expect(await speakerB.audibleBlocks == beforeMute)
            await micA.speak(1, 1)
            try await wait { await speakerB.audibleBlocks >= beforeMute + 3 }

            await caller.end(sendHangup: true)
            try await wait { second.hungUp.withLock { $0 } }
            #expect(await !micA.running)
            #expect(await !micB.running)
            #expect(await !speakerA.running)
            #expect(await !speakerB.running)
        } catch {
            await caller.end(sendHangup: false)
            await callee.end(sendHangup: false)
            if !peerReflexive { #expect(first.hostCandidates.withLock { $0 } > 0) }
            #expect(second.hostCandidates.withLock { $0 } > 0)
            #expect(first.error.withLock { $0 } == nil)
            #expect(second.error.withLock { $0 } == nil)
            throw error
        }
    }
}
