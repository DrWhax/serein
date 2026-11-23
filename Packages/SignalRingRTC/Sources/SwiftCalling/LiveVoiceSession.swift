import CryptoKit
import Foundation
import Network
import Synchronization

/// Owns the ICE, SRTP and audio devices for one V4 signaling leg.
package actor LiveVoiceSession {
    package enum Event: Sendable {
        case candidate(IceCandidateUpdate), ringing, accepted, remoteAudio(Bool), remoteHangup, failed(String)
        case remoteVideo(Bool), remoteScreen(Bool), reconnecting, reconnected, networkRoute(Int)
        case lowBandwidthForVideo(recovered: Bool)
        /// A diagnostic line for the app's log: pair kinds, counts and times, never addresses.
        case log(String)
        case audioLevels(captured: UInt16, received: UInt16)
    }

    private final class Media {
        var control: DirectControlStream
        var send: DirectSpeechSender
        var receive: DirectSpeechReceiver
        var video: DirectVideoStream
        let arrivals = TransportArrivals()
        let sentNumbers = TransportPacketNumbers()
        var sendRate = GroupSendRate()
        let audioControl: SRTCPSender
        let cname = UUID().uuidString
        var feedback: VideoFeedback

        init(callID: UInt64, role: DirectCallRole, keys: DirectCallKeys, measurements: CallMediaMeasurements) throws {
            let local = role == .caller ? keys.offer : keys.answer
            let remote = role == .caller ? keys.answer : keys.offer
            let tx = try SRTPKeyDerivation(key: local.key, salt: local.salt).sessionKeys(rtcp: false)
            let rx = try SRTPKeyDerivation(key: remote.key, salt: remote.salt).sessionKeys(rtcp: false)
            let rtcp = try SRTPKeyDerivation(key: local.key, salt: local.salt).sessionKeys(rtcp: true)
            feedback = .init(keys: try SRTPKeyDerivation(key: remote.key, salt: remote.salt).sessionKeys(rtcp: true))
            audioControl = SRTCPSender(keys: rtcp, ssrc: role.audioSSRC)
            video = DirectVideoStream(tx: tx, rx: rx, rtcp: rtcp, role: role, measurements: measurements, transportNumbers: sentNumbers, arrivals: arrivals)
            control = .init(callID: callID, role: role, outgoing: tx, incoming: rx)
            send = .init(transport: DirectOpusSender(keys: tx, role: role, transportNumbers: sentNumbers))
            receive = .init(keys: rx, remoteRole: role == .caller ? .callee : .caller, measurements: measurements, arrivals: arrivals)
        }
    }

    package nonisolated let video = DirectCallVideo()
    package nonisolated let measurements = CallMediaMeasurements()
    private var measurementInterval = Duration.seconds(10)
    private var nextMeasurement = ContinuousClock.now

    package func setStatsInterval(seconds: UInt64) { measurementInterval = .seconds(min(65_535, max(1, seconds))) }
    private var peerReceivesVP8 = false
    private var peerSendsVP8 = false
    private var peerSendsVP9 = false, peerReceivesVP9 = false
    private var vp9Encode = false, vp9Decode = false
    private var sendsVP9: Bool { vp9Encode && peerReceivesVP9 }
    private var sendsVideo: Bool { sendsVP9 || peerReceivesVP8 }

    package func configureVP9(encode: Bool, decode: Bool) { vp9Encode = encode; vp9Decode = decode }
    private var remoteEstimate: (bitrate: UInt64, expires: ContinuousClock.Instant)?
    private var peerBitrate: UInt64 = 2_000_000
    private var localBitrate: UInt64 = 2_000_000
    private var videoRevision: UInt64 = 0
    private var videoEnabled = false
    private var bandwidthNotifications = DirectVideoBandwidthNotifications()
    private var screenSharing = false
    private var remoteVideo: Bool?
    private var remoteScreen: Bool?
    package nonisolated let localParameters: DirectCallParameters
    private let localKey: Curve25519.KeyAgreement.PrivateKey
    private let callID: UInt64
    private let role: DirectCallRole
    private let devices: VoiceCallDevices
    private let event: @Sendable (Event) -> Void
    private let tieBreaker = UInt64.random(in: .min ... .max)
    private var media: Media?
    private var dred: DREDConfiguration?
    package func setDRED(_ configuration: DREDConfiguration?) {
        dred = configuration
        media?.send.setDRED(configuration)
        media?.receive.setDRED(configuration)
    }
    private var remoteICE: DirectICETransport.Credentials?
    private var relayOnly: Bool?
    private var allocation: TURNAllocation?
    private var gather: Task<Void, Never>?
    private var hostGather: Task<Void, Never>?
    private var reflexiveGather: Task<Void, Never>?
    private var reflexiveAddresses: [ICEBinding.Address] = []
    private var listen: Task<Void, Never>?
    private var incoming: [UUID: Task<Void, Never>] = [:]
    private var hostPort: VoiceHostPort?
    private var servers: [VoiceTURNServer] = []
    private var deadline: Task<Void, Never>?
    private var knownCandidates: [Candidate] = []
    private var candidates: [Candidate] = []
    private var iceGeneration = UUID()
    private var nomination = ICENomination()
    private var recovering = false
    private var pathMonitor: NWPathMonitor?
    private var networkPath: CallNetworkPath?
    private var reportedAdapter: Int?
    private typealias GatherHosts = @Sendable (@escaping @Sendable (NWConnection) -> Void) async throws -> VoiceHostPort
    private var gatherHosts: GatherHosts?
    private var allocateRelay: @Sendable ([VoiceTURNServer]) async -> TURNAllocation? = VoiceTURNServer.allocateFirst

    /// The nominated pair.
    private var active: Candidate?
    /// RFC 8445 §6.1.4: pairs are checked in parallel, a new one every `checkPacing` (WebRTC
    /// starts one about every 50 ms), so an address that never answers delays no other.
    private var attempts: [UUID: (candidate: Candidate, task: Task<Void, Never>)] = [:]
    private var nextCheckStart = ContinuousClock.now
    private var iceStarted: ContinuousClock.Instant?
    private var checksStarted = 0, checksFailed = 0
    /// Video repair requests we sent, and the totals at the last quality line.
    private var nacksSent = 0, refreshesSent = 0
    private var qualityTotals: (at: ContinuousClock.Instant, videoIn: UInt64, videoOut: UInt64, audioIn: UInt64,
                                rendered: UInt64, nacks: Int, refreshes: Int)?
    private static let checkPacing: Duration = .milliseconds(50)
    private static let maxParallelChecks = 16
    private var transport: DirectICETransport?
    private var receive: Task<Void, Never>?
    private let audioClockOrigin = ContinuousClock.now
    private var audioPlayout: Task<Void,Never>?
    private var repairTimer: Task<Void,Never>?
    private var heartbeat: Task<Void, Never>?
    private var meter: Task<Void, Never>?
    private var levelInterval: Duration?
    private var capturedPeak: UInt16 = 0
    private var receivedPeak: UInt16 = 0
    private var accepted = false
    private var acceptRequested = false
    private var microphoneEnabled = false
    private struct CapturePermission {
        var revision: UInt64 = 0
        var enabled = false
        var closed = false
    }
    private let permission = Mutex(CapturePermission())
    private var appliedRevision: UInt64 = 0
    private var lastSpeech: ContinuousClock.Instant?
    private var microphoneGeneration: UInt64 = 0
    private var capture: Task<Void, Never>?
    private var stoppingMicrophone: Task<Void, Never>?
    private var speakerStarted = false
    private var ended = false
    private var shutdown: Task<Void, Never>?
    private var remoteAudio: Bool?

    /// The case records our socket. The peer's advertised type influences priority,
    /// but both local UDP and local TURN can reach a publicly routable peer.
    enum Candidate: Sendable {
        case host(ICEHostCandidate), relay(ICERelayCandidate)

        static func pairs(for sdp: String, relayOnly: Bool) -> [Self] {
            if let host = ICEHostCandidate(sdp) {
                var pairs: [Self] = relayOnly ? [] : [.host(host)]
                if let peer = ICERelayCandidate(address: host.address) { pairs.append(.relay(peer)) }
                return pairs
            }
            guard let host = ICEHostCandidate(sdp, relay: true) else { return [] }
            var pairs: [Self] = []
            if let peer = ICERelayCandidate(address: host.address) { pairs.append(.relay(peer)) }
            if !relayOnly { pairs.append(.host(host)) }
            return pairs
        }

        var address: ICEBinding.Address {
            switch self {
            case .host(let host): host.address
            case .relay(let relay): relay.address
            }
        }
    }

    /// All linked devices answer the same broadcast offer. Each leg uses the
    /// offer's identity and ICE credentials with its own peer key and SRTP state.
    package struct Identity: Sendable {
        fileprivate let key = Curve25519.KeyAgreement.PrivateKey()
        fileprivate let parameters: DirectCallParameters

        package init() {
            var parameters = DirectCallParameters()
            parameters.publicKey = key.publicKey.rawRepresentation
            parameters.iceUfrag = String(UUID().uuidString.prefix(8))
            parameters.icePassword = ICEHostPair.randomPassword()
            parameters.encoders = [8]
            parameters.decoders = [8]
            self.parameters = parameters
        }
    }

    private let claimMedia: @Sendable () -> Bool

    package init(callID: UInt64, outgoing: Bool, devices: VoiceCallDevices, identity: Identity = .init(),
                 claimMedia: @escaping @Sendable () -> Bool = { true }, event: @escaping @Sendable (Event) -> Void) {
        self.callID = callID
        role = outgoing ? .caller : .callee
        self.devices = devices
        self.claimMedia = claimMedia
        self.event = event
        localKey = identity.key
        localParameters = identity.parameters
    }

    package func configure(relayOnly: Bool, servers: [VoiceTURNServer], audioLevelsIntervalMs: UInt64? = nil) {
        let discoverMapping = !relayOnly && servers.prefix(16).contains { server in
            server.urls.prefix(16).contains { TURNServerEndpoint(stunURI: $0) != nil }
        }
        configure(relayOnly: relayOnly, servers: servers, audioLevelsIntervalMs: audioLevelsIntervalMs) { inbound in
            try await VoiceHostPort.gather(timeoutAfter: discoverMapping ? .seconds(1) : .seconds(10),
                                          keepPortOnLookupTimeout: discoverMapping, inbound: inbound)
        }
    }

    func configure(relayOnly: Bool, servers: [VoiceTURNServer], audioLevelsIntervalMs: UInt64? = nil,
                   allocateRelay: @escaping @Sendable ([VoiceTURNServer]) async -> TURNAllocation? = VoiceTURNServer.allocateFirst,
                   gatherHosts: @escaping @Sendable (@escaping @Sendable (NWConnection) -> Void) async throws -> VoiceHostPort) {
        guard !ended, self.relayOnly == nil else { return }
        if let ms = audioLevelsIntervalMs, ms > 0 {
            levelInterval = .milliseconds(min(60_000, max(50, ms)))
        }
        self.relayOnly = relayOnly
        iceStarted = .now
        event(.log("ICE: \(role == .caller ? "caller" : "callee"), \(relayOnly ? "relay only" : "direct and relay"), \(servers.count) relay servers"))
        self.servers = servers
        self.gatherHosts = gatherHosts
        self.allocateRelay = allocateRelay
        if relayOnly {
            knownCandidates.removeAll { if case .host = $0 { true } else { false } }
            candidates = knownCandidates
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let value = CallNetworkPath(path)
            Task { await self?.pathChanged(value) }
        }
        pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "org.serein.call.path"))
        gatherCandidates()
    }

    private func pathChanged(_ path: CallNetworkPath) {
        guard !ended else { return }
        let previous = networkPath
        networkPath = path
        guard let previous, previous != path else { return }
        if transport != nil { restartICE() }
        else if recovering, path.usable { restartICE() }
    }

    private func gatherCandidates() {
        let generation = iceGeneration
        if relayOnly == false, let gatherHosts {
            let connections = AsyncStream<NWConnection>.makeStream(bufferingPolicy: .bufferingOldest(4))
            listen = Task { [weak self] in
                for await connection in connections.stream { await self?.incomingCheck(connection) }
            }
            hostGather = Task { [weak self] in
                let local = try? await gatherHosts { connection in
                    if case .enqueued = connections.continuation.yield(connection) { return }
                    connection.cancel()
                }
                if Task.isCancelled { local?.close(); return }
                await self?.didGatherHost(local, generation: generation)
            }
        }
        gatherRelay()
        checkCandidates()
    }

    private func didGatherHost(_ local: VoiceHostPort?, generation: UUID) {
        guard generation == iceGeneration else { local?.close(); return }
        hostGather = nil
        guard !ended, transport == nil else { local?.close(); return }
        hostPort = local
        if let local {
            // An in-flight check keeps its source tuple when a local address trickles.
            // The peer can learn that tuple as a peer-reflexive candidate.
            for update in local.candidates { event(.candidate(update)) }
            let servers = servers
            reflexiveGather = Task { [weak self] in
                await STUNDiscovery.gather(servers: servers, port: local.port) { [weak self] mapping in
                    await self?.didGatherReflexive(mapping, generation: generation)
                }
            }
        }
        checkCandidates()
    }

    private func didGatherReflexive(_ mapping: STUNDiscovery.Mapping, generation: UUID) {
        guard !ended, relayOnly == false, transport == nil, generation == iceGeneration,
              let hostPort, !reflexiveAddresses.contains(mapping.address),
              !hostPort.candidates.contains(where: { $0.addedSDP.flatMap(ICEHostCandidate.init)?.address == mapping.address })
        else { return }
        reflexiveAddresses.append(mapping.address)
        event(.candidate(mapping.candidate))
    }

    private func incomingCheck(_ socket: NWConnection) {
        guard !ended, transport == nil, relayOnly == false, let remoteICE,
              let ufrag = localParameters.iceUfrag, let password = localParameters.icePassword,
              incoming.count < 4, let candidate = ICEHostCandidate(observed: socket.endpoint) else { socket.cancel(); return }
        let token = UUID()
        let iceRole: ICEBinding.Role = role == .caller ? .controlling(tieBreaker) : .controlled(tieBreaker)
        let election = role == .caller ? nomination : nil
        incoming[token] = Task { [weak self] in
            let packets = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(64))
            do {
                let selected = try await DirectICETransport.accept(socket, candidate: candidate, local: .init(ufrag: ufrag, password: password),
                                                                   remote: remoteICE, role: iceRole, nomination: election) { packets.continuation.yield($0) }
                guard !Task.isCancelled, let self else { selected.close(); return }
                await self.inboundNominated(selected, packets: packets.stream, candidate: candidate, token: token)
            } catch {
                socket.cancel()
                packets.continuation.finish()
                await self?.removeIncoming(token)
            }
        }
    }

    private func removeIncoming(_ token: UUID) { incoming[token] = nil }

    private func inboundNominated(_ selected: DirectICETransport, packets: AsyncStream<Data>, candidate: ICEHostCandidate, token: UUID) async {
        guard incoming.removeValue(forKey: token) != nil, !ended, transport == nil else { selected.close(); return }
        cancelAttempts()
        await connected(selected, packets: packets, candidate: .host(candidate), generation: iceGeneration)
    }

    private func gatherRelay() {
        let servers = self.servers
        let required = relayOnly == true
        let allocate = allocateRelay
        let generation = iceGeneration
        gather = Task { [weak self] in
            if let allocation = await allocate(servers) {
                guard !Task.isCancelled, let self else { allocation.close(); return }
                await self.didGather(allocation, generation: generation)
            } else if required, !Task.isCancelled { await self?.gatherFailed(generation: generation) }
        }
    }

    private func gatherFailed(generation: UUID) async {
        guard !ended, generation == iceGeneration, transport == nil else { return }
        guard recovering else { event(.log("ICE: no relay allocation from \(servers.count) servers")); await fail("No TURN allocation is available."); return }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        if !ended, generation == iceGeneration, transport == nil { gatherRelay() }
    }

    private func didGather(_ allocation: TURNAllocation, generation: UUID) {
        guard !ended, generation == iceGeneration, transport == nil else { allocation.close(); return }
        self.allocation = allocation
        event(.log("ICE: relay allocation ready"))
        event(.candidate(.init(addedSDP: allocation.localCandidate.sdp)))
        checkCandidates()
    }

    package func setRemote(_ parameters: DirectCallParameters, callerIdentity: Data, calleeIdentity: Data) throws {
        guard !ended, media == nil, let peer = parameters.publicKey, let user = parameters.iceUfrag,
              let password = parameters.icePassword else { throw CallingWireError.malformed }
        let keys = try DirectCallKeys(local: localKey, remote: peer, callerIdentity: callerIdentity, calleeIdentity: calleeIdentity)
        peerReceivesVP8 = parameters.decoders.contains(8)
        peerSendsVP8 = parameters.encoders.contains(8)
        peerSendsVP9 = parameters.encoders.contains(9)
        peerReceivesVP9 = parameters.decoders.contains(9)
        peerBitrate = parameters.maxBitrateBps ?? 2_000_000
        media = try Media(callID: callID, role: role, keys: keys, measurements: measurements)
        setDRED(dred)
        updateVideoBudget()
        remoteICE = .init(ufrag: user, password: password)
        checkCandidates()
    }

    package func addCandidate(_ update: IceCandidateUpdate) async {
        guard !ended else { return }
        if let removed = update.removed {
            let address = ICEBinding.Address(ip: Array(removed.ip), port: removed.port)
            knownCandidates.removeAll { $0.address == address }
            candidates.removeAll { $0.address == address }
            if active?.address == address, transport != nil { restartICE(); return }
            if cancelAttempts(where: { $0.address == address }), transport == nil { replaceAllocation() }
            checkCandidates()
            return
        }
        guard let sdp = update.addedSDP else { return }
        let pairs = Candidate.pairs(for: sdp, relayOnly: relayOnly == true)
        guard let first = pairs.first, knownCandidates.count + pairs.count <= 128,
              !knownCandidates.contains(where: { $0.address == first.address }) else { return }
        knownCandidates.append(contentsOf: pairs)
        candidates.append(contentsOf: pairs)
        checkCandidates()
    }

    /// Re-nominate a new tuple with the same ICE credentials and SRTP state. Withdrawing
    /// old local candidates lets the other endpoint run its checklist for the new pair.
    private func restartICE() {
        guard !ended, relayOnly != nil, transport != nil || recovering else { return }
        if !recovering, accepted { event(.reconnecting) }
        recovering = true
        iceGeneration = UUID()
        nomination = ICENomination()
        cancelAttempts()
        receive?.cancel(); receive = nil
        heartbeat?.cancel(); heartbeat = nil
        listen?.cancel(); listen = nil
        hostGather?.cancel(); hostGather = nil
        reflexiveGather?.cancel(); reflexiveGather = nil
        gather?.cancel(); gather = nil
        for task in incoming.values { task.cancel() }
        incoming.removeAll()
        video.replaceTransport(nil)
        let old = transport
        transport = nil
        active = nil
        if let address = allocation?.localCandidate.address { withdraw(address) }
        if let hostPort {
            for local in hostPort.candidates {
                if let sdp = local.addedSDP, let host = ICEHostCandidate(sdp) { withdraw(host.address) }
            }
        }
        for address in reflexiveAddresses { withdraw(address) }
        reflexiveAddresses.removeAll()
        hostPort?.close(); hostPort = nil
        old?.close()
        allocation?.close(); allocation = nil
        candidates = knownCandidates
        gatherCandidates()
    }

    private func withdraw(_ address: ICEBinding.Address) {
        if let update = try? IceCandidateUpdate(removingIP: Data(address.ip), port: address.port) { event(.candidate(update)) }
    }

    private func checkCandidates() {
        guard !ended, transport == nil, let relayOnly, let remoteICE,
              let ufrag = localParameters.iceUfrag, let password = localParameters.icePassword else { return }
        if deadline == nil {
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(40)) } catch { return }
                await self?.iceTimedOut()
            }
        }
        let local = DirectICETransport.Credentials(ufrag: ufrag, password: password)
        let iceRole: ICEBinding.Role = role == .caller ? .controlling(tieBreaker) : .controlled(tieBreaker)
        // Both roles check from the advertised port, as WebRTC does. Behind a NAT only that
        // socket's own sends open the mapping the peer's checks need (a callee checking from
        // another port was unreachable). A check arriving on a pair's socket is answered and
        // its nomination recorded there (ICEHostPair.receive), not lost to the listener.
        let port = hostPort?.port
        let generation = iceGeneration
        // Only one pair of this generation can carry USE-CANDIDATE (ICENomination).
        let election = role == .caller ? nomination : nil
        // Host pairs run in parallel. A relay pair needs the allocation to itself
        // (TURNAllocation.connect serves one peer), so relay pairs go one at a time.
        while attempts.count < Self.maxParallelChecks, let index = candidates.firstIndex(where: { candidate in
            switch candidate {
            case .host: !relayOnly
            case .relay: allocation != nil && !attempts.values.contains { Self.relayed($0.candidate) }
            }
        }) {
            let candidate = candidates.remove(at: index)
            let allocation = self.allocation
            let now = ContinuousClock.now
            let start = max(now, nextCheckStart)
            nextCheckStart = start + Self.checkPacing
            let delay = now.duration(to: start)
            let id = UUID()
            let task = Task { [weak self] in
                let packets = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(64))
                do {
                    if delay > .zero { try await Task.sleep(for: delay) }
                    let route: DirectICETransport.Route
                    switch candidate {
                    case .host(let host): route = .host(host)
                    case .relay(let relay):
                        guard let allocation else { throw DirectICETransport.Failure.noConsent }
                        route = .relay(try await allocation.connect(to: relay))
                    }
                    let connection = try await DirectICETransport.connect(route: route, relayOnly: relayOnly,
                        local: local, remote: remoteICE, role: iceRole, hostPort: port, nomination: election) { packets.continuation.yield($0) }
                    guard let self else { connection.close(); return }
                    if Task.isCancelled {
                        connection.close()
                        await self.candidateFailed(candidate, attempt: id, generation: generation)
                    } else {
                        await self.connected(connection, packets: packets.stream, candidate: candidate, attempt: id, generation: generation)
                    }
                } catch {
                    packets.continuation.finish()
                    await self?.candidateFailed(candidate, attempt: id, generation: generation)
                }
            }
            attempts[id] = (candidate, task)
            checksStarted += 1
        }
    }

    /// Cancelled checks are dropped here; their tasks then find themselves unregistered.
    /// Returns whether a relay check was among them: its allocation can serve no other peer.
    @discardableResult
    private func cancelAttempts(where matches: (Candidate) -> Bool = { _ in true }) -> Bool {
        var relay = false
        for (id, attempt) in attempts where matches(attempt.candidate) {
            attempt.task.cancel()
            attempts[id] = nil
            relay = relay || Self.relayed(attempt.candidate)
        }
        return relay
    }

    private static func relayed(_ candidate: Candidate) -> Bool { if case .relay = candidate { true } else { false } }

    /// After a relay check ends without winning, a fresh allocation serves the next relay pair.
    private func replaceAllocation() {
        if let address = allocation?.localCandidate.address,
           let update = try? IceCandidateUpdate(removingIP: Data(address.ip), port: address.port) {
            event(.candidate(update))
        }
        allocation?.close()
        allocation = nil
        gatherRelay()
    }

    private func candidateFailed(_ candidate: Candidate, attempt id: UUID, generation: UUID) {
        guard attempts.removeValue(forKey: id) != nil, !ended, generation == iceGeneration, transport == nil else { return }
        checksFailed += 1
        if Self.relayed(candidate) { replaceAllocation() }
        checkCandidates()
    }

    private func connected(_ connection: DirectICETransport, packets: AsyncStream<Data>, candidate: Candidate, attempt id: UUID? = nil,
                           generation: UUID) async {
        guard !ended, generation == iceGeneration, transport == nil, let media else { connection.close(); return }
        guard !Task.isCancelled else {
            connection.close()
            if let id { candidateFailed(candidate, attempt: id, generation: generation) } else { checkCandidates() }
            return
        }
        transport = connection
        active = candidate
        // The winner's own task is finishing this call; every other check stops.
        if let id { attempts[id] = nil }
        cancelAttempts()
        reflexiveGather?.cancel(); reflexiveGather = nil
        listen?.cancel()
        for check in incoming.values { check.cancel() }
        incoming.removeAll()
        deadline?.cancel()
        deadline = nil
        gather?.cancel()
        gather = nil
        if case .host = candidate { allocation?.close(); allocation = nil }
        receive = Task { [weak self] in
            for await packet in packets {
                guard !Task.isCancelled else { return }
                await self?.read(packet)
            }
        }
        let resumed = recovering && accepted
        recovering = false
        let adapter = connection.adapter ?? networkPath?.adapter ?? 0
        measurements.nominated(relayed: connection.relayed)
        let elapsed = iceStarted.map { Int($0.duration(to: .now) / .milliseconds(1)) } ?? -1
        event(.log("ICE: connected over \(Self.describe(candidate))\(id == nil ? " (peer's check)" : "") after \(elapsed) ms; "
                   + "\(checksStarted) checks started, \(checksFailed) failed"))
        if reportedAdapter != adapter || resumed { event(.networkRoute(adapter)); reportedAdapter = adapter }
        if resumed { video.replaceTransport(connection); video.requestKeyframe(); event(.reconnected) }
        else { event(.ringing) }
        do {
            try media.control.setAudio(enabled: accepted && microphoneEnabled)
            try media.control.setReceiveBitrate(localBitrate)
            try media.control.setVideo(enabled: videoEnabled && sendsVideo, screen: screenSharing && videoEnabled && sendsVideo)
            try sendControl()
        } catch { restartICE(); return }
        guard transport === connection else { return }
        heartbeat = Task { [weak self] in
            var nextConsent = ContinuousClock.now + .seconds(1)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                    await self?.sendTransportFeedback(connection)
                    guard ContinuousClock.now >= nextConsent else { continue }
                    nextConsent = .now + .seconds(1)
                    guard connection.consented else { await self?.recoverIfSelected(connection); return }
                    await self?.sendSenderReports(connection)
                    await self?.sampleQuality(connection)
                    try await self?.sendControl()
                } catch {
                    if !Task.isCancelled { await self?.recoverIfSelected(connection) }
                    return
                }
            }
        }
        if acceptRequested { await accept() }
    }

    private func recoverIfSelected(_ connection: DirectICETransport) {
        if transport === connection { restartICE() }
    }

    private func sendSenderReports(_ connection: DirectICETransport) {
        guard accepted, !ended, transport === connection, let media else { return }
        let streams = [(media.send.transport.sender, media.audioControl, 48_000.0),
                       (media.video.sender, media.video.feedback, 90_000.0)]
        for (sender, control, rate) in streams {
            if let report = sender.senderReport(rate: rate, cname: media.cname),
               let packet = try? control.seal(report), (try? connection.send(packet)) != nil {
                measurements.sentSenderReport(report)
            }
        }
        for report in RTCPReport.datagrams(measurements.receptionReports(), sender: role.audioSSRC, cname: media.cname) {
            if let packet = try? media.audioControl.seal(report) { try? connection.send(packet) }
        }
    }

    private func sampleQuality(_ connection: DirectICETransport) {
        guard transport === connection, ContinuousClock.now >= nextMeasurement else { return }
        guard let media else { return }
        let remoteRole: DirectCallRole = role == .caller ? .callee : .caller
        let streams = [
            RTPObservation(ssrc: role.audioSSRC, outgoing: true, video: false, count: media.send.transport.sender.stats),
            RTPObservation(ssrc: role.videoSSRC, outgoing: true, video: true, count: media.video.sender.stats,
                           frames: video.frameStats(ssrc: role.videoSSRC, outgoing: true)),
            measurements.inbound(remoteRole.audioSSRC, video: false, audio: media.receive.statistics),
            measurements.inbound(remoteRole.videoSSRC, video: true, frames: video.frameStats(ssrc: remoteRole.videoSSRC, outgoing: false))
        ]
        measurements.sample(rtt: connection.lastRoundTrip, media: streams, relayed: connection.relayed)
        logQuality(connection, outAudio: streams[0], outVideo: streams[1], inAudio: streams[2], inVideo: streams[3])
        nextMeasurement = .now + (streams.contains(where: { $0.count.packets > 0 }) ? measurementInterval : .seconds(1))
    }

    /// One line per measurement interval: what we receive and request, what we send, and the
    /// bitrate limits each side applies. Video quality from the peer follows our feedback.
    private func logQuality(_ connection: DirectICETransport, outAudio: RTPObservation, outVideo: RTPObservation,
                            inAudio: RTPObservation, inVideo: RTPObservation) {
        let now = ContinuousClock.now
        let rendered = inVideo.frames?.rendered ?? 0
        defer {
            qualityTotals = (now, inVideo.count.bytes, outVideo.count.bytes, inAudio.count.bytes, rendered, nacksSent, refreshesSent)
        }
        guard let last = qualityTotals, accepted else { return }
        let seconds = max(0.001, last.at.duration(to: now) / .seconds(1))
        func kbps(_ total: UInt64, _ before: UInt64) -> Int { Int(Double(total &- before) * 8 / seconds / 1000) }
        func size(_ frames: VideoFrameCounters?) -> String {
            guard let width = frames?.width, let height = frames?.height else { return "none" }
            return "\(width)x\(height)"
        }
        let remoteRole: DirectCallRole = role == .caller ? .callee : .caller
        let inbound = measurements.inboundStats(for: remoteRole.videoSSRC)
        let rtt = connection.lastRoundTrip.map { "\(Int($0.milliseconds)) ms" } ?? "?"
        let tenths = Int((Double(rendered &- last.rendered) / seconds * 10).rounded())
        let sendEstimate = media?.sendRate.estimate.map { "\($0 / 1000)" } ?? "?"
        let peerEstimate = remoteEstimate.map { "\($0.bitrate / 1000)" } ?? "none"
        event(.log("media: rtt \(rtt)\(connection.relayed ? " relayed" : ""); "
            + "video in \(size(inVideo.frames)) \(tenths / 10).\(tenths % 10) fps \(kbps(inVideo.count.bytes, last.videoIn)) kbps, "
            + "lost \(inbound?.lost ?? 0) total, jitter \(Int((inbound?.jitterSeconds ?? 0) * 1000)) ms, "
            + "\(inVideo.frames?.freezes ?? 0) freezes, \(inVideo.frames?.dropped ?? 0) dropped, "
            + "\(nacksSent - last.nacks) NACKs, \(refreshesSent - last.refreshes) keyframe requests, "
            + "codec \(inVideo.frames?.codec.map { "VP\($0)" } ?? "none"), \(video.receiveDiagnostics().summary) (since start); "
            + "audio in \(kbps(inAudio.count.bytes, last.audioIn)) kbps; "
            + "video out \(size(outVideo.frames)) \(kbps(outVideo.count.bytes, last.videoOut)) kbps; "
            + "we accept \(localBitrate / 1000) kbps, peer accepts \(peerBitrate / 1000) kbps, "
            + "send estimate \(sendEstimate) kbps, peer's estimate \(peerEstimate) kbps"))
    }

    private func sendTransportFeedback(_ connection: DirectICETransport) {
        guard accepted, !ended, let media, transport === connection else { return }
        if let packet = try? media.video.transportFeedback(media.arrivals) { try? connection.send(packet) }
        let changed = media.sendRate.update(limit: min(localBitrate,peerBitrate), now: .now) != nil
        if let estimate = remoteEstimate, estimate.expires <= .now {
            remoteEstimate = nil
            updateVideoBudget()
        } else if changed { updateVideoBudget() }
        let estimate = [media.sendRate.estimate,remoteEstimate?.bitrate].compactMap { $0 }.min()
        if let recovered = bandwidthNotifications.poll(estimate: estimate, sending: videoEnabled && sendsVideo, at: .now) {
            event(.lowBandwidthForVideo(recovered: recovered))
        }
    }

    private func sendControl() throws {
        guard let packet = try media?.control.packet(), let transport else { return }
        do { try transport.send(packet) }
        catch { recoverIfSelected(transport) }
    }

    package func accept() async {
        guard !ended, role == .callee, !accepted else { return }
        acceptRequested = true
        guard transport != nil, let media else { return }
        do {
            try media.control.accept()
            try sendControl()
            didAccept()
        } catch { await fail("Could not send call acceptance.") }
    }

    private func didAccept() {
        guard !accepted, !ended, claimMedia() else { return }
        accepted = true
        if let media, let transport {
            video.start(sender: sendsVideo ? media.video.sender : nil, transport: transport, vp9: sendsVP9) { [weak self] in
                await self?.requestVideoRefresh()
            }
            video.setSending(videoEnabled && sendsVideo, revision: videoRevision)
        }
        event(.accepted)
        if let levelInterval {
            meter = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: levelInterval) } catch { return }
                    await self?.emitLevels()
                }
            }
        }
        startCaptureIfEnabled()
    }

    private func emitLevels() {
        guard !ended else { return }
        event(.audioLevels(captured: min(32767, capturedPeak), received: min(32767, receivedPeak)))
        capturedPeak = 0
        receivedPeak = 0
    }

    private func read(_ packet: Data) async {
        guard !ended, let media, packet.count >= 12 else { return }
        let type = packet[packet.startIndex + 1]
        if (192...223).contains(type) {
            guard accepted, let plain = try? media.feedback.open(packet) else { return }
            _ = try? media.sendRate.receive(plain, sent: media.sentNumbers)
            if let cap = try? VideoFeedback.maximumBitrate(plain,for:role.videoSSRC) {
                remoteEstimate = (cap,.now + .seconds(5))
                updateVideoBudget()
            }
            if let requested = try? VideoRepair.requested(plain, for: role.videoSSRC) { video.repair(requested, for: role.videoSSRC) }
            if (try? VideoFeedback.requestsKeyframe(plain, for: role.videoSSRC)) == true { video.requestKeyframe() }
            if let reports = try? RTCPReport.compound(plain) {
                let remote: DirectCallRole = role == .caller ? .callee : .caller
                for report in reports.senders where report.ssrc == remote.audioSSRC || report.ssrc == remote.videoSSRC {
                    measurements.receivedSenderReport(report)
                    video.synchronization.observe(report, audio: report.ssrc == remote.audioSSRC)
                }
                for report in reports.receivers where report.stream == role.audioSSRC || report.stream == role.videoSSRC {
                    let audio = report.stream == role.audioSSRC
                    measurements.report(report, clock: audio ? 48_000 : 90_000)
                    if audio { media.send.setPacketLoss(report.fractionLost) }
                    else { video.setLoss(report.fractionLost) }
                }
            }
            return
        }
        let payloadType = type & 0x7f
        if payloadType == DirectCallControl.payloadType {
            guard let control = try? media.control.receive(packet) else { return }
            if control.hangup != nil {
                await end(sendHangup: false)
                event(.remoteHangup)
                return
            }
            if control.acceptedID == callID { didAccept() }
            if let maximum = control.receiver?.bitrate {
                peerBitrate = maximum
                updateVideoBudget()
            }
            if let enabled = control.sender?.video, remoteVideo != enabled {
                remoteVideo = enabled
                event(.remoteVideo(enabled))
            }
            if let sharing = control.sender?.screen, remoteScreen != sharing {
                remoteScreen = sharing
                event(.remoteScreen(sharing))
            }
            if let enabled = control.sender?.audio, remoteAudio != enabled {
                remoteAudio = enabled
                if !enabled { video.synchronization.audioMuted() }
                event(.remoteAudio(enabled))
            }
        } else if accepted, VideoRepair.primaryType(payloadType) != nil || [DirectVideoStream.vp8, VP9Assembly.payloadType, DirectVideoStream.red, 122].contains(payloadType) {
            if let nack = try? media.video.receive(packet, vp8Enabled: peerSendsVP8, vp9Enabled: vp9Decode && peerSendsVP9, sink: video) {
                if (try? transport?.send(nack)) != nil { nacksSent += 1 }
            }
            if media.video.waitingForRepair && repairTimer == nil { scheduleVideoRepair() }
        } else if accepted, payloadType == DirectOpusSender.payloadType {
            guard (try? media.receive.insert(packet)) != nil else { return }
            if audioPlayout == nil { startAudioPlayout() }
        }
    }

    private func startAudioPlayout() {
        let stamp = UInt32(truncatingIfNeeded: Int64((audioClockOrigin.duration(to: .now) / .seconds(1)) * 48_000))
        audioPlayout = Task { [weak self] in
            var deadline = ContinuousClock.now
            var outputStamp = stamp
            while !Task.isCancelled {
                guard await self?.playAudio(timestamp: outputStamp) == true else { return }
                outputStamp &+= 960
                deadline += .milliseconds(20)
                if deadline < .now { deadline = .now }
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            }
        }
    }

    private func playAudio(timestamp: UInt32) async -> Bool {
        guard !ended, let media else { return false }
        guard let frame = media.receive.render() else {
            if media.receive.active { return true }
            audioPlayout = nil
            return false
        }
        do {
            if !speakerStarted {
                try await devices.speaker.start()
                guard !ended else { return false }
                speakerStarted = true
            }
            if let time = try await devices.speaker.enqueueForPresentation(frame.pcm, timestamp: timestamp) {
                let remote: DirectCallRole = role == .caller ? .callee : .caller
                video.synchronization.played(frame.timestamp, ssrc: remote.audioSSRC, at: time)
            }
            if levelInterval != nil { receivedPeak = frame.pcm.reduce(receivedPeak) { max($0, $1.magnitude) } }
            return true
        } catch {
            await fail("The audio output device is unavailable.")
            return false
        }
    }

    private func scheduleVideoRepair() {
        repairTimer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(55)) } catch { return }
            await self?.pollVideoRepair()
        }
    }

    private func pollVideoRepair() {
        repairTimer = nil
        guard accepted, !ended, let media, let transport, media.video.waitingForRepair else { return }
        if let nack = try? media.video.pollRepair(vp8: peerSendsVP8, vp9: vp9Decode && peerSendsVP9, sink: video),
           (try? transport.send(nack)) != nil { nacksSent += 1 }
        if media.video.waitingForRepair { scheduleVideoRepair() }
    }

    private func requestVideoRefresh() {
        guard accepted, !ended, let media, let refresh = try? media.video.refresh() else { return }
        if (try? transport?.send(refresh)) != nil { refreshesSent += 1 }
    }

    package static func maxBitrate(lowDataMode: Bool) -> UInt64 { lowDataMode ? 300_000 : 2_000_000 }

    package func setLowDataMode(_ low: Bool) async {
        guard !ended else { return }
        localBitrate = Self.maxBitrate(lowDataMode: low)
        updateVideoBudget()
        do {
            try media?.control.setReceiveBitrate(localBitrate)
            try sendControl()
        } catch { await fail("Could not update data mode.") }
    }

    private func updateVideoBudget() {
        // Reserve bandwidth for speech and control when both media are active.
        let total = min(peerBitrate, localBitrate, media?.sendRate.estimate ?? UInt64.max, remoteEstimate?.bitrate ?? UInt64.max)
        media?.send.setLowDataMode(total <= Self.maxBitrate(lowDataMode: true))
        video.setBudget(total > 40_000 ? total - 40_000 : 0)
    }

    package nonisolated func requestVideo(_ enabled: Bool) -> UInt64 { video.request(enabled) }

    package func setVideoEnabled(_ enabled: Bool, revision: UInt64) async {
        guard !ended, video.current(enabled, revision: revision) else { return }
        videoRevision = revision
        if !accepted && enabled { bandwidthNotifications.waitForAcceptance() }
        videoEnabled = enabled
        video.setSending(enabled && accepted && sendsVideo, revision: revision)
        await sendVideoStatus()
    }

    package func setScreenSharing(_ enabled: Bool) async {
        guard !ended else { return }
        screenSharing = enabled
        video.setScreenSharing(enabled)
        await sendVideoStatus()
    }

    private func sendVideoStatus() async {
        let enabled = videoEnabled && sendsVideo
        do {
            try media?.control.setVideo(enabled: enabled, screen: enabled && screenSharing)
            try sendControl()
        } catch { await fail("Could not update video status.") }
    }

    /// XPC commands arrive synchronously. Revoke the old stream before queueing the
    /// device work on this actor so a backlog cannot transmit frames after mute.
    package nonisolated func requestMicrophone(_ enabled: Bool) -> UInt64 {
        permission.withLock {
            if !$0.closed, $0.enabled != enabled {
                $0.revision &+= 1
                $0.enabled = enabled
            }
            return $0.revision
        }
    }

    package nonisolated func revokeCapture() {
        video.close()
        permission.withLock {
            $0.closed = true
            $0.enabled = false
        }
    }

    package func setMicrophoneEnabled(_ enabled: Bool) async {
        await setMicrophoneEnabled(enabled, revision: requestMicrophone(enabled))
    }

    package func setMicrophoneEnabled(_ enabled: Bool, revision: UInt64) async {
        guard !ended, appliedRevision != revision || microphoneEnabled != enabled else { return }
        if enabled, !permission.withLock({ !$0.closed && $0.enabled && $0.revision == revision }) { return }
        if enabled, microphoneEnabled { stopCapture() }
        appliedRevision = revision
        microphoneEnabled = enabled
        if !enabled {
            stopCapture()
            do {
                try media?.control.setAudio(enabled: false)
                try sendControl()
            } catch { await fail("Could not update microphone status."); return }
            await stoppingMicrophone?.value
        } else { startCaptureIfEnabled() }
    }

    private func startCaptureIfEnabled() {
        guard !ended, accepted, microphoneEnabled, capture == nil, transport != nil else { return }
        guard permission.withLock({ !$0.closed && $0.enabled && $0.revision == appliedRevision }) else { return }
        microphoneGeneration &+= 1
        let generation = microphoneGeneration
        let microphone = devices.microphone
        let revision = appliedRevision
        let stop = stoppingMicrophone
        capture = Task { [weak self] in
            await stop?.value
            guard !Task.isCancelled else { return }
            do {
                let frames = try await microphone.start()
                guard !Task.isCancelled else { return }
                try await self?.captureStarted(generation)
                var samples: [Int16] = []
                samples.reserveCapacity(2880)
                var talkspurt = true
                for await frame in frames {
                    guard !Task.isCancelled else { return }
                    guard frame.count == 960 else { throw CallingWireError.malformed }
                    samples.append(contentsOf: frame)
                    if samples.count == 2880 {
                        try await self?.sendSpeech(samples, generation: generation, revision: revision, talkspurt: talkspurt)
                        samples.removeAll(keepingCapacity: true)
                        talkspurt = false
                    }
                }
            } catch { }
            await self?.captureEnded(generation)
        }
    }

    private func captureStarted(_ generation: UInt64) throws {
        guard !ended, microphoneEnabled, generation == microphoneGeneration,
              permission.withLock({ !$0.closed && $0.enabled && $0.revision == appliedRevision }) else { return }
        media?.send.beginTalkspurt()
        try media?.control.setAudio(enabled: true)
        try sendControl()
    }

    private func sendSpeech(_ samples: [Int16], generation: UInt64, revision: UInt64, talkspurt: Bool) throws {
        guard !ended, accepted, microphoneEnabled, generation == microphoneGeneration, let media, let transport else { return }
        guard permission.withLock({ !$0.closed && $0.enabled && $0.revision == revision }) else { return }
        let now = ContinuousClock.now
        var skipped: UInt32 = 0
        if talkspurt, let lastSpeech {
            let gap = lastSpeech.duration(to: now) / .seconds(1) * 48_000 - Double(samples.count)
            skipped = UInt32(max(0, min(Double(Int32.max), gap)))
        }
        guard let packet = try media.send.seal(samples, talkspurt: talkspurt, skippedSamples: skipped) else { return }
        let sent = permission.withLock {
            guard !$0.closed, $0.enabled, $0.revision == revision else { return false }
            return (try? transport.send(packet)) != nil
        }
        if !sent, !transport.consented { restartICE() }
        guard sent else { return }
        media.send.transport.didSend(captured: now - .seconds(Double(samples.count) / 48_000))
        lastSpeech = now
        if levelInterval != nil { capturedPeak = samples.reduce(capturedPeak) { max($0, $1.magnitude) } }
    }

    private func captureEnded(_ generation: UInt64) async {
        if !ended, microphoneEnabled, microphoneGeneration == generation {
            await fail("Microphone capture stopped unexpectedly.")
        }
    }

    private func stopCapture() {
        microphoneGeneration &+= 1
        capturedPeak = 0
        capture?.cancel()
        capture = nil
        let previous = stoppingMicrophone
        let microphone = devices.microphone
        stoppingMicrophone = Task {
            await previous?.value
            await microphone.stop()
        }
    }

    private func iceTimedOut() async {
        event(.log("ICE: no pair after 40 s; \(checksStarted) checks started, \(checksFailed) failed, \(candidates.count) waiting, "
                   + "relay allocation \(allocation == nil ? "none" : "ready"), \(knownCandidates.count) remote pairs"))
        await fail("ICE nomination timed out.")
    }

    private static func describe(_ candidate: Candidate) -> String {
        let family = candidate.address.ip.count == 16 ? "IPv6" : "IPv4"
        switch candidate {
        case .host: return "direct " + family
        case .relay: return "relay to " + family
        }
    }

    private func fail(_ reason: String) async {
        guard !ended else { return }
        await end(sendHangup: true)
        event(.failed(reason))
    }

    package func end(sendHangup: Bool) async {
        revokeCapture()
        if let shutdown { await shutdown.value; return }
        guard !ended else { return }
        ended = true
        microphoneEnabled = false
        stopCapture()
        var finalPackets: [Data] = []
        if sendHangup, let media, transport != nil {
            try? media.control.hangup()
            for _ in 0..<3 {
                if let packet = try? media.control.packet() { finalPackets.append(packet) }
            }
        }
        pathMonitor?.cancel()
        pathMonitor = nil
        cancelAttempts()
        deadline?.cancel()
        gather?.cancel()
        heartbeat?.cancel()
        meter?.cancel()
        audioPlayout?.cancel()
        receive?.cancel()
        hostGather?.cancel()
        reflexiveGather?.cancel()
        listen?.cancel()
        for check in incoming.values { check.cancel() }
        incoming.removeAll()
        let socket = transport
        let turn = allocation
        let port = hostPort
        transport = nil
        allocation = nil
        hostPort = nil
        media = nil
        let microphoneStop = stoppingMicrophone
        let speaker = devices.speaker
        let cleanup = Task {
            async let speakerStop: Void = speaker.stop()
            // Give the UDP socket time to transmit the cumulative hangup before cancel.
            // Repetitions have fresh SRTP indices and the peer treats them idempotently.
            for packet in finalPackets {
                try? socket?.send(packet)
                try? await Task.sleep(for: .milliseconds(40))
            }
            socket?.close()
            turn?.close()
            port?.close()
            await speakerStop
            await microphoneStop?.value
        }
        shutdown = cleanup
        await cleanup.value
        shutdown = nil
    }

    deinit {
        video.close()
        capture?.cancel()
        receive?.cancel()
        heartbeat?.cancel()
        meter?.cancel()
        audioPlayout?.cancel()
        gather?.cancel()
        deadline?.cancel()
        for attempt in attempts.values { attempt.task.cancel() }
        hostGather?.cancel()
        reflexiveGather?.cancel()
        listen?.cancel()
        for check in incoming.values { check.cancel() }
        hostPort?.close()
        transport?.close()
        allocation?.close()
    }
}
