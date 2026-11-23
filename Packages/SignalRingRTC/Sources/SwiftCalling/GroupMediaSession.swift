import CodecCore
import CryptoKit
import Foundation
import Security
import Network
import Synchronization

package protocol GroupMediaProtection: Sendable {
    func seal(_ plaintext: Data) throws -> Data
    func open(_ ciphertext: Data, from demuxID: UInt32) throws -> Data
}

/// One negotiated ICE/SRTP association to Signal's SFU. Participant media and
/// broadcasts have independent, end-to-end frame protection inside that association.
package actor GroupMediaSession {
    package enum Event: Sendable {
        case connected, sfu(Data,UInt32), device(UInt32,Data,UInt32), audioLevels(UInt16,[UInt32:UInt16]), failed(String)
        case reconnecting, route(Int), speech(Int), bandwidth(recovered: Bool), rtcStats(String)
    }
    private struct Keys {
        let tx, rx, txControl, rxControl: SRTPKeys
        init(client: Curve25519.KeyAgreement.PrivateKey, server: Data, extra: Data) throws {
            guard server.count == 32, extra.count <= 4096 else { throw CallingWireError.malformed }
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: server)
            let secret = try client.sharedSecretFromKeyAgreement(with: peer)
            guard !(secret == Data(repeating: 0, count: 32)) else { throw CallingWireError.malformed }
            let label = Data("Signal_Group_Call_20211105_SignallingDH_SRTPKey_KDF".utf8) + extra
            let material = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(repeating: 0,count: 32),
                                                          sharedInfo: label, outputByteCount: 56)
            let bytes = material.bytes
            let send = try SRTPKeyDerivation(key: .init(copying: bytes.extracting(0..<16)), salt: .init(copying: bytes.extracting(16..<28)))
            let receive = try SRTPKeyDerivation(key: .init(copying: bytes.extracting(28..<44)), salt: .init(copying: bytes.extracting(44..<56)))
            tx = send.sessionKeys(rtcp: false)
            txControl = send.sessionKeys(rtcp: true)
            rx = receive.sessionKeys(rtcp: false)
            rxControl = receive.sessionKeys(rtcp: true)
        }
    }

    private final class Wire {
        let keys: Keys
        let id: UInt32
        let audio, video, sfu, devices: SRTPSender
        let simulcast: [SRTPSender]
        var videoSenders: [SRTPSender] { [video] + simulcast }
        let senderControls: [UInt32: SRTCPSender]
        let cname = UUID().uuidString
        var nextSenderReport = ContinuousClock.now
        let feedback: SRTCPSender
        var remoteFeedback: VideoFeedback
        let transportNumbers = TransportPacketNumbers()
        var arrivals = TransportFeedback()
        var sendRate = GroupSendRate()
        var reports: [UInt32:RTCPReport] = [:]
        var nacksReceived = [UInt32:UInt64](), plisReceived = [UInt32:UInt64](), firsReceived = [UInt32:UInt64]()
        var receivers: [UInt32:SRTPReceiver] = [:]
        var sfuClock: UInt32 = 1, deviceClock: UInt32 = 1
        init(keys: Keys, id: UInt32, svc: Bool) {
            let videoSSRC = id + (svc ? 8 : 2)
            self.keys = keys
            self.id = id
            let transportNumbers = self.transportNumbers
            func sender(_ ssrc: UInt32) -> SRTPSender {
                .init(keys: keys.tx, ssrc: ssrc, startingAt: .random(in: 0...0x7fff), transportNumbers: (ssrc != 1 && ssrc != id+13) ? transportNumbers : nil)
            }
            audio = sender(id)
            video = sender(videoSSRC)
            simulcast = svc ? [] : [sender(id+4),sender(id+6)]
            sfu = sender(1)
            devices = sender(id+13)
            feedback = .init(keys: keys.txControl, ssrc: videoSSRC)
            var controls = [videoSSRC: feedback, id: SRTCPSender(keys: keys.txControl, ssrc: id)]
            for sender in simulcast { controls[sender.ssrc] = SRTCPSender(keys: keys.txControl, ssrc: sender.ssrc) }
            senderControls = controls
            remoteFeedback = .init(keys: keys.rxControl, streamLimit: 2048)
        }
    }

    private final class Participant {
        var audioStats = RTPStatsCounter()
        struct VideoStats {
            var media = RTPStatsCounter(), repair = RTPStatsCounter()
            var nacksSent: UInt64 = 0, plisSent: UInt64 = 0
        }
        var streamStats = [UInt32:VideoStats]()
        var speech = OpusJitterBuffer()
        init(dred: DREDConfiguration?) { speech.setDRED(dred) }
        let synchronization = RTPMediaSynchronization()
        var peak: UInt16 = 0
        var reorder = VideoReceiveQueue()
        var assembler = VP8Assembly()
        var vp9 = VP9Assembly()
        var videoOffset: UInt32 = 2
        var sink: DirectCallVideo?
        var lastPLI: ContinuousClock.Instant?
    }

    package nonisolated let video = GroupCallVideo()
    package nonisolated let measurements: CallMediaMeasurements
    private var nextMeasurement = ContinuousClock.now
    package nonisolated let publicKey: Data
    package nonisolated let iceUfrag: String
    package nonisolated let icePassword: String
    private let dh: Curve25519.KeyAgreement.PrivateKey
    private let devices: VoiceCallDevices
    private let crypto: any GroupMediaProtection
    private let event: @Sendable (Event) -> Void
    private var wire: Wire?
    private var connection: DirectICETransport?
    private var nomination: Task<GroupICERoutes.Nomination, any Error>?
    private var migration: Task<Void,Never>?
    private var routeVersion = UUID()
    private var routes: GroupICERoutes?
    private var selectedAddress: GroupICERoutes.Address?
    private var remoteICE: DirectICETransport.Credentials?
    private var trustAnchor: SecCertificate?
    private var incoming: AsyncStream<Data>.Continuation?
    private var pathMonitor: NWPathMonitor?
    private var networkPath: CallNetworkPath?
    private var receiveTask: Task<Void,Never>?
    private var capture: Task<Void,Never>?
    private var stoppingMic: Task<Void,Never>?
    private var mix: Task<Void,Never>?
    private var monitor: Task<Void,Never>?
    private var ids: Set<UInt32> = []
    private var peers: [UInt32:Participant] = [:]
    private var admitted = false, audioEnabled = false, videoEnabled = false, ended = false
    private var videoRevision: UInt64 = 0, microphoneRevision: UInt64 = 0
    private var speakerStarted = false
    private var capturedPeak: UInt16 = 0, speechPeak: UInt16 = 0
    private var speech = GroupSpeechDetector()
    private var nextSpeechPoll = ContinuousClock.now
    private var lastAdapter: Int?
    private var bitrateLimit = LiveVoiceSession.maxBitrate(lowDataMode: false)
    private let groupVideo: GroupVideoConfiguration?
    private let dred: DREDConfiguration?
    private let levelsInterval: Duration?
    private var statsInterval: Duration?
    private var nextStats = ContinuousClock.now, nextLevels = ContinuousClock.now
    private var encoder = CallOpusEncoder()
    private let audioClockOrigin = ContinuousClock.now
    private let audioClockOffset = UInt32.random(in: .min ... .max)
    private var nextAudioTimestamp: UInt32?
    private let lifetime = Mutex(true)

    package init(devices: VoiceCallDevices, crypto: any GroupMediaProtection, audioLevelsIntervalMillis: UInt64? = nil, groupVideo: GroupVideoConfiguration? = nil, dred: DREDConfiguration? = nil, measurements: CallMediaMeasurements = .init(), event: @escaping @Sendable (Event) -> Void) {
        self.measurements = measurements
        self.dred = dred
        encoder.setDRED(dred)
        dh = Curve25519.KeyAgreement.PrivateKey()
        publicKey = dh.publicKey.rawRepresentation
        iceUfrag = String(UUID().uuidString.prefix(8))
        icePassword = ICEHostPair.randomPassword()
        self.groupVideo = groupVideo
        self.levelsInterval = audioLevelsIntervalMillis.flatMap(Self.interval)
        self.devices = devices
        self.crypto = crypto
        self.event = event
    }

    package func connect(demuxID: UInt32, serverKey: Data, hkdfExtraInfo: Data, remoteUfrag: String, remotePassword: String,
                         udpAddresses: [String], tcpAddresses: [String], tlsAddresses: [String], hostname: String?, trustAnchor: SecCertificate? = nil) async throws {
        guard !ended, wire == nil, demuxID != 0, demuxID & 15 == 0 else { throw CallingWireError.malformed }
        let keys = try Keys(client: dh, server: serverKey, extra: hkdfExtraInfo)
        let wire = Wire(keys: keys, id: demuxID, svc: groupVideo != nil)
        self.wire = wire
        let routes = GroupICERoutes(udp: udpAddresses, tcp: tcpAddresses, tls: tlsAddresses, hostname: hostname)
        let local = DirectICETransport.Credentials(ufrag: iceUfrag, password: icePassword)
        let remote = DirectICETransport.Credentials(ufrag: remoteUfrag, password: remotePassword)
        let packets = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.routes = routes
        self.remoteICE = remote
        self.trustAnchor = trustAnchor
        incoming = packets.continuation
        let task = Task { try await routes.connect(local: local, remote: remote, trustAnchor: trustAnchor) { packets.continuation.yield($0) } }
        nomination = task
        let winner = try await task.value
        let selected = winner.transport
        selectedAddress = winner.address
        nomination = nil
        guard !ended, lifetime.withLock({ $0 }) else { selected.close(); throw CancellationError() }
        connection = selected
        receiveTask = Task { [weak self] in
            for await bytes in packets.stream {
                if Task.isCancelled { return }
                await self?.read(bytes)
            }
        }
        let crypto = self.crypto
        video.local.startSending(sender: wire.video, transport: selected, groupVideo: groupVideo, simulcast: wire.simulcast, protect: { try crypto.seal($0) })
        updateMedia()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                await self?.check()
            }
        }
        event(.connected)
        let path = NWPathMonitor()
        path.pathUpdateHandler = { [weak self] path in
            let current = CallNetworkPath(path)
            Task { await self?.pathChanged(current) }
        }
        pathMonitor = path
        path.start(queue: DispatchQueue(label: "org.serein.groupsfu.path"))
    }

    package func setServerAddress(_ address: GroupSFUUpdate.ServerAddress) {
        guard !ended, remoteICE != nil else { return }
        let next = GroupICERoutes(udp: address.udp, tcp: address.tcp, tls: address.tls, hostname: address.tlsHostname)
        guard !next.routes.isEmpty else { return }
        let addresses = Set(next.routes.map { $0.0 })
        let same = routes.map { Set($0.routes.map { $0.0 }) == addresses } ?? false
        routes = next
        if same || selectedAddress.map(addresses.contains) == true { return }
        recover()
    }

    private func pathChanged(_ current: CallNetworkPath) {
        guard !ended else { return }
        let old = networkPath
        networkPath = current
        if let old, old != current { recover() }
    }

    /// Re-nominate ICE only. Preserve the media keys, packet indices, replay
    /// windows, codecs, and endpoint-to-endpoint frame counters across migration.
    private func recover() {
        guard !ended, let routes, let remoteICE, let incoming, wire != nil else { return }
        if migration == nil { event(.reconnecting) }
        else { migration?.cancel() }
        let revision = UUID()
        routeVersion = revision
        connection?.close()
        connection = nil
        selectedAddress = nil
        video.local.replaceTransport(nil)
        updateMedia()
        let local = DirectICETransport.Credentials(ufrag: iceUfrag, password: icePassword)
        let anchor = trustAnchor
        migration = Task { [weak self] in
            let until = ContinuousClock.now + .seconds(30)
            while !Task.isCancelled && ContinuousClock.now < until {
                do {
                    let winner = try await routes.connect(local: local, remote: remoteICE, trustAnchor: anchor) {
                        incoming.yield($0)
                    }
                    guard let self else { winner.transport.close(); return }
                    await self.recovered(winner, revision: revision)
                    return
                } catch {
                    do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                }
            }
            guard !Task.isCancelled else { return }
            await self?.recoveryFailed(revision)
        }
    }

    private func recovered(_ winner: GroupICERoutes.Nomination, revision: UUID) {
        guard !ended, lifetime.withLock({ $0 }), routeVersion == revision else { winner.transport.close(); return }
        connection = winner.transport
        selectedAddress = winner.address
        video.local.replaceTransport(winner.transport)
        migration = nil
        updateMedia()
        event(.connected)
    }

    private func recoveryFailed(_ revision: UUID) async {
        guard routeVersion == revision else { return }
        await fail("Group call ICE reconnection failed.")
    }

    package func setJoined(_ joined: Bool) {
        guard !ended else { return }
        admitted = joined
        updateMedia()
    }

    package func setRemoteDevices(_ ids: Set<UInt32>) {
        guard !ended else { return }
        self.ids = Set(ids.filter { $0 != 0 && $0 & 15 == 0 && $0 != wire?.id }.sorted().prefix(256))
        if peers.keys.contains(where: { !self.ids.contains($0) }), let wire, let connection {
            measurements.sample(rtt: connection.lastRoundTrip, media: observations(wire), relayed: connection.relayed)
        }
        for id in peers.keys where !self.ids.contains(id) {
            peers[id] = nil
            video.remove(id)
        }
        updateMedia()
    }

    package func setAudioEnabled(_ enabled: Bool) {
        guard !ended else { return }
        audioEnabled = enabled
        updateMedia()
    }

    package func setVideoEnabled(_ enabled: Bool) {
        guard !ended else { return }
        videoEnabled = enabled
        videoRevision = video.local.request(enabled)
        updateMedia()
    }

    package func setLowDataMode(_ low: Bool) {
        encoder.setLowDataMode(low)
        bitrateLimit = LiveVoiceSession.maxBitrate(lowDataMode: low)
        applyBudget(wire?.sendRate.estimate ?? bitrateLimit)
    }

    package nonisolated func setScreenSharing(_ enabled: Bool) { video.local.setScreenSharing(enabled) }

    package func setMaxSendHeight(_ height: UInt32) { video.local.setMaxHeight(height) }

    private func applyBudget(_ bps: UInt64) {
        let total = min(bps, bitrateLimit, groupVideo?.maximumBitrate ?? .max)
        video.local.setBudget(total > 40_000 ? total - 40_000 : 0)
    }

    private static func interval(_ millis: UInt64) -> Duration? {
        millis == 0 ? nil : .milliseconds(Int64(clamping: millis))
    }

    package func setStatsInterval(_ millis: UInt64) {
        let previous = statsInterval ?? .seconds(10)
        statsInterval = Self.interval(millis)
        nextMeasurement = min(.now + (statsInterval ?? .seconds(10)), nextMeasurement - previous + (statsInterval ?? .seconds(10)))
        nextStats = .now
    }

    private func updateMedia() {
        let active = admitted && !ids.isEmpty && connection != nil && !ended && lifetime.withLock { $0 }
        video.local.setSending(active && videoEnabled, revision: videoRevision)
        if active && audioEnabled && capture == nil { startCapture() }
        else if !(active && audioEnabled), capture != nil { stopCapture() }
    }

    package func sendToSFU(_ data: Data) throws {
        guard !ended, let wire, let connection, data.count <= 1300 else { throw CallingWireError.malformed }
        defer { wire.sfuClock &+= 1 }
        try connection.send(wire.sfu.seal(data, type: 101, timestamp: wire.sfuClock))
    }

    package func sendToDevices(_ data: Data) throws {
        guard !ended, admitted, let wire, let connection, data.count <= 1250 else { throw CallingWireError.malformed }
        defer { wire.deviceClock &+= 1 }
        try connection.send(wire.devices.seal(crypto.seal(data), type: 101, timestamp: wire.deviceClock))
    }

    private func read(_ bytes: Data) async {
        guard !ended, let wire, bytes.count >= 12 else { return }
        let type = bytes[bytes.startIndex+1]
        if (192...223).contains(type) {
            guard let plain = try? wire.remoteFeedback.open(bytes) else { return }
            for sender in wire.videoSenders {
                if let requested = try? VideoRepair.requests(plain, for: sender.ssrc), requested.messages != 0 {
                    wire.nacksReceived[sender.ssrc,default:0] += requested.messages
                    video.local.repair(requested.sequences, for: sender.ssrc)
                }
                if let requests = try? VideoFeedback.refreshRequests(plain, for: sender.ssrc), requests.pli + requests.fir > 0 {
                    wire.plisReceived[sender.ssrc,default:0] += requests.pli
                    wire.firsReceived[sender.ssrc,default:0] += requests.fir
                    video.local.requestKeyframe()
                }
            }
            _ = try? wire.sendRate.receive(plain, sent: wire.transportNumbers)
            if let reports = try? RTCPReport.compound(plain) {
                for report in reports.senders {
                    let id = report.ssrc & ~15, offset = report.ssrc & 15
                    guard admitted, ids.contains(id), [0, 2, 8].contains(offset) else { continue }
                    let peer = peers[id] ?? Participant(dred: dred)
                    peers[id] = peer
                    measurements.receivedSenderReport(report)
                    peer.synchronization.observe(report, audio: offset == 0)
                }
                for report in reports.receivers where report.stream == wire.id || wire.videoSenders.contains(where: { $0.ssrc == report.stream }) {
                    wire.reports[report.stream] = report
                    measurements.report(report, clock: report.stream == wire.id ? 48_000 : 90_000)
                    if report.stream == wire.id { encoder.setPacketLoss(report.fractionLost) }
                }
            }
            return
        }
        var header = ByteCursor(Array(bytes.prefix(12)))
        guard (try? header.skip(8)) != nil, let ssrc = try? header.u32be() else { return }
        let id = ssrc & ~15, wireOffset = ssrc & 15
        let repair = wireOffset == 3 || wireOffset == 9
        let offset = repair ? wireOffset-1 : wireOffset
        guard ssrc == 1 || (admitted && ids.contains(id) && [0,2,8,13].contains(offset)) else { return }
        guard wire.receivers[ssrc] != nil || wire.receivers.count < 2048 else { return }
        let mediaStream = ssrc != 1 && offset != 13
        let receiver = wire.receivers[ssrc] ?? SRTPReceiver(keys: wire.keys.rx, ssrc: ssrc,
            measurements: mediaStream && !repair ? measurements : nil, clock: offset == 0 ? 48_000 : 90_000)
        guard let authenticated = try? receiver.open(bytes) else { return }
        wire.receivers[ssrc] = receiver
        if let number = authenticated.transportNumber { wire.arrivals.observe(number, at: .now) }
        let packet: RTPPayload
        if repair {
            guard let original = try? VideoRepair.unpack(authenticated) else { return }
            packet = original
        } else { packet = authenticated }
        if ssrc == 1 {
            if packet.type == 101 { event(.sfu(packet.bytes,packet.timestamp)) }
            return
        }
        if offset == 13, packet.type == 101 {
            if let data = try? crypto.open(packet.bytes, from: id) { event(.device(id,data,packet.timestamp)) }
            return
        }
        let peer = peers[id] ?? Participant(dred: dred)
        peers[id] = peer
        if offset == 0, packet.type == 102 { peer.audioStats.record(packet.bytes.count) }
        let vp8 = offset == 2 && packet.type == DirectVideoStream.vp8
        let vp9 = (offset == 8 || offset == 2) && packet.type == VP9Assembly.payloadType
        if vp8 || vp9 {
            peer.streamStats[offset,default: Participant.VideoStats()].media.record(packet.bytes.count)
            if repair { peer.streamStats[offset,default: Participant.VideoStats()].repair.record(authenticated.bytes.count) }
            if peer.videoOffset != offset {
                peer.videoOffset = offset
                peer.reorder = VideoReceiveQueue()
                peer.assembler = VP8Assembly()
                peer.vp9 = VP9Assembly()
            }
        }
        if offset == 0, packet.type == 102,
           let data = try? crypto.open(packet.bytes, from: id), let opus = try? OpusPacket(data) {
            peer.speech.insert(opus, timestamp: packet.timestamp, sequence: packet.sequence, marker: packet.marker)
            if mix == nil { startMix() }
        } else if vp8 || vp9 {
            if peer.sink == nil {
                let sink = DirectCallVideo(synchronization: peer.synchronization), crypto = self.crypto
                sink.startReceiving(open: { try crypto.open($0, from: id) }) { [weak self] in await self?.refresh(id) }
                peer.sink = sink
                video.install(id,sink)
            }
            let output = peer.reorder.insert(packet)
            deliver(output, to: peer, id: id, wire: wire)
        }
    }

    private func deliver(_ output: VideoReceiveQueue.Output, to peer: Participant, id: UInt32, wire: Wire) {
        for packet in output.ready {
            if packet.type == DirectVideoStream.vp8, let encoded = try? peer.assembler.assemble(packet) { peer.sink?.decode(encoded, ssrc: id + peer.videoOffset) }
            if packet.type == VP9Assembly.payloadType, let layers = try? peer.vp9.assemble(packet) {
                for layer in layers { peer.sink?.decode(layer, ssrc: id + peer.videoOffset) }
            }
        }
        if let nack = VideoRepair.nack(output.missing, from: wire.feedback.ssrc, for: id+peer.videoOffset),
           let protected = try? wire.feedback.seal(nack), let connection, (try? connection.send(protected)) != nil { peer.streamStats[peer.videoOffset,default: Participant.VideoStats()].nacksSent += 1 }
    }

    private func startCapture() {
        let microphone = devices.microphone, previous = stoppingMic
        let origin = audioClockOrigin, offset = audioClockOffset
        microphoneRevision &+= 1
        let revision = microphoneRevision
        encoder.beginTalkspurt()
        capture = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let frames = try await microphone.start()
                var first = true
                for await samples in frames {
                    guard !Task.isCancelled else { return }
                    guard samples.count == 960 else { throw CallingWireError.malformed }
                    let clock = offset &+ UInt32(truncatingIfNeeded: Int64(origin.duration(to: .now) / .seconds(1) * 48_000))
                    try await self?.sendAudio(samples, clock: clock, first: first, revision: revision)
                    first = false
                }
            } catch { }
            if !Task.isCancelled { await self?.fail("Group call microphone stopped.") }
        }
    }

    private func sendAudio(_ samples: [Int16], clock: UInt32, first: Bool, revision: UInt64) throws {
        guard !ended, admitted, audioEnabled, revision == microphoneRevision, let wire, let connection else { return }
        // The SSRC survives microphone starts, mute, and ICE migration. A new
        // random RTP timestamp would look like stale speech to the remote jitter buffer.
        let next = nextAudioTimestamp ?? clock
        let timestamp = first && Int32(bitPattern: clock &- next) > 0 ? clock : next
        nextAudioTimestamp = timestamp &+ UInt32(samples.count)
        let level = samples.reduce(UInt16(0)) { max($0,$1.magnitude) }
        capturedPeak = max(capturedPeak,level)
        speechPeak = max(speechPeak,level)
        let db = UInt8(clamping: min(127,Int(-20 * log10(max(1,Double(level))/32768))))
        guard let frame = try encoder.transmission(samples) else { return }
        let captured = ContinuousClock.now - .milliseconds(20)
        let opus = try crypto.seal(frame.payload)
        let packet = try wire.audio.seal(opus, type: 102, timestamp: timestamp, marker: first || frame.marker, extensions: [(5,[db])])
        do {
            try lifetime.withLock { active in
                guard active else { return }
                try connection.send(packet)
                wire.audio.didSend(payloadBytes: opus.count, timestamp: timestamp, captured: captured)
            }
        } catch { recover() }
    }

    private func stopCapture() {
        microphoneRevision &+= 1
        capture?.cancel()
        capture = nil
        let mic = devices.microphone, previous = stoppingMic
        stoppingMic = Task { await previous?.value; await mic.stop() }
    }

    private func startMix() {
        mix = Task { [weak self] in
            var stamp = UInt32.random(in: .min ... .max), deadline = ContinuousClock.now
            while !Task.isCancelled {
                await self?.play(timestamp: stamp)
                stamp &+= 960
                deadline += .milliseconds(20)
                if deadline < .now { deadline = .now }
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            }
        }
    }

    private func play(timestamp: UInt32) async {
        guard !ended, admitted else { return }
        var pcm = [Int32](repeating: 0, count: 960)
        var contributors: [(RTPMediaSynchronization, UInt32, UInt32)] = []
        for (id, peer) in peers {
            guard let rendered = peer.speech.render() else { continue }
            peer.peak = rendered.pcm.reduce(peer.peak) { max($0, $1.magnitude) }
            for i in pcm.indices { pcm[i] += Int32(rendered.pcm[i]) }
            contributors.append((peer.synchronization, id, rendered.timestamp))
        }
        guard !contributors.isEmpty else { return }
        do {
            if !speakerStarted { try await devices.speaker.start(); speakerStarted = true }
            guard !ended, admitted else { return }
            if let time = try await devices.speaker.enqueueForPresentation(pcm.map { Int16(clamping: $0) }, timestamp: timestamp) {
                for (source, id, stamp) in contributors { source.played(stamp, ssrc: id, at: time) }
            }
        } catch { await fail("Group call speaker is unavailable.") }
    }

    private func refresh(_ id: UInt32) {
        guard let peer = peers[id], let wire, let connection else { return }
        if let previous = peer.lastPLI, previous.duration(to: .now) < .milliseconds(300) { return }
        peer.lastPLI = .now
        var pli = Data([0x81,206,0,2])
        for value in [wire.video.ssrc,id+peer.videoOffset] { for shift in [24,16,8,0] { pli.append(UInt8(truncatingIfNeeded: value >> shift)) } }
        if (try? connection.send(wire.feedback.seal(pli))) != nil { peer.streamStats[peer.videoOffset,default: Participant.VideoStats()].plisSent += 1 }
    }

    private func check() async {
        guard !ended, let connection, let wire else { return }
        if !connection.consented { recover(); return }
        let now = ContinuousClock.now
        for (id,peer) in peers where peer.reorder.waiting { deliver(peer.reorder.poll(now: now), to: peer, id: id, wire: wire) }
        if admitted, now >= wire.nextSenderReport {
            wire.nextSenderReport = now + .seconds(1)
            for sender in [wire.audio] + wire.videoSenders {
                let rate = sender.ssrc == wire.id ? 48_000.0 : 90_000.0
                if let control = wire.senderControls[sender.ssrc], let report = sender.senderReport(rate: rate, cname: wire.cname),
                   let packet = try? control.seal(report), (try? connection.send(packet)) != nil {
                    measurements.sentSenderReport(report)
                }
            }
            for report in RTCPReport.datagrams(measurements.receptionReports(), sender: wire.feedback.ssrc, cname: wire.cname) {
                if let packet = try? wire.feedback.seal(report) { try? connection.send(packet) }
            }
        }
        if now >= nextMeasurement {
            measurements.sample(rtt: connection.lastRoundTrip, media: observations(wire), relayed: connection.relayed)
            nextMeasurement = now + (statsInterval ?? .seconds(10))
        }
        if let feedback = wire.arrivals.packet(sender: wire.feedback.ssrc) {
            try? connection.send(wire.feedback.seal(feedback))
        }
        let adapter = connection.adapter ?? networkPath?.adapter ?? 0
        if adapter != lastAdapter { lastAdapter = adapter; event(.route(adapter)) }
        if now >= nextSpeechPoll {
            if let value = speech.poll(peak: speechPeak, unmuted: audioEnabled && admitted, at: now) { event(.speech(value)) }
            nextSpeechPoll = now + .milliseconds(200)
            speechPeak = 0
        }
        if let levelsInterval, now >= nextLevels {
            event(.audioLevels(min(32767,capturedPeak), peers.mapValues { min(32767,$0.peak) }))
            nextLevels = now + levelsInterval
            capturedPeak = 0
            for peer in peers.values { peer.peak = 0 }
        }
        if admitted, !ids.isEmpty, let bps = wire.sendRate.update(limit: bitrateLimit, now: now) {
            applyBudget(bps)
            if let recovered = wire.sendRate.bandwidthEvent(now: now) { event(.bandwidth(recovered: recovered)) }
        }
        if let statsInterval, now >= nextStats {
            nextStats = now + statsInterval
            if let stats = statsReport(wire) { event(.rtcStats(stats)) }
        }
    }

    private func observations(_ wire: Wire) -> [RTPObservation] {
        var streams = [RTPObservation(ssrc: wire.id, outgoing: true, video: false, count: wire.audio.stats)]
        for sender in wire.videoSenders {
            streams.append(RTPObservation(ssrc: sender.ssrc, outgoing: true, video: true, count: sender.stats,
                                          frames: video.local.frameStats(ssrc: sender.ssrc, outgoing: true)))
        }
        for (id,peer) in peers {
            streams.append(RTPObservation(ssrc: id, outgoing: false, video: false, count: peer.audioStats, audio: peer.speech.statistics))
            for (offset,stats) in peer.streamStats {
                let ssrc = id + offset
                streams.append(RTPObservation(ssrc: ssrc, outgoing: false, video: true, count: stats.media,
                                              frames: peer.sink?.frameStats(ssrc: ssrc, outgoing: false)))
            }
        }
        return streams
    }

    private func statsReport(_ wire: Wire) -> String? {
        // libwebrtc's RTCStatsReport::ToJson stores timestamps in microseconds.
        let time = Date().timeIntervalSince1970 * 1_000_000
        var pair = GroupStatsRecord(id: "sfu-candidate-pair", type: "candidate-pair", timestamp: time)
        pair.state = "succeeded"
        pair.nominated = true
        pair.availableOutgoingBitrate = wire.sendRate.estimate
        pair.currentRoundTripTime = connection?.lastRoundTrip.map { $0.milliseconds / 1000 }
        let observations = observations(wire)
        var transport = GroupStatsRecord(id: "sfu-transport", type: "transport", timestamp: time)
        transport.selectedCandidatePairId = pair.id
        pair.transportId = transport.id
        var rows = [transport, pair]
        if let address = selectedAddress {
            var remote = GroupStatsRecord(id: "sfu-remote-candidate", type: "remote-candidate", timestamp: time)
            remote.transportId = transport.id
            remote.candidateType = "host"
            remote.address = address.host
            remote.port = Int(address.port)
            remote.protocol = address.transport == .udp ? "udp" : "tcp"
            rows[1].remoteCandidateId = remote.id
            rows.append(remote)
            if let endpoint = connection?.localHostEndpoint {
                var local = GroupStatsRecord(id: "sfu-local-candidate", type: "local-candidate", timestamp: time)
                local.transportId = transport.id
                local.candidateType = "host"
                local.address = endpoint.address
                local.port = endpoint.port
                local.protocol = remote.protocol
                rows[1].localCandidateId = local.id
                rows.append(local)
            }
        }
        var codecs = Set<Int>()
        for (sender, kind) in [(wire.audio, "audio")] + wire.videoSenders.map({ ($0,"video") }) {
            let count = sender.stats
            var outbound = GroupStatsRecord.rtp(ssrc: sender.ssrc, kind: kind, outgoing: true, count: count, timestamp: time)
            if kind == "video" {
                outbound.firCount = wire.firsReceived[sender.ssrc] ?? 0
                outbound.nackCount = wire.nacksReceived[sender.ssrc] ?? 0
                outbound.pliCount = wire.plisReceived[sender.ssrc] ?? 0
                let repairs = video.local.repaired(for: sender.ssrc)
                outbound.retransmittedPacketsSent = repairs.packets
                outbound.retransmittedBytesSent = repairs.bytes
                outbound.packetsSent = count.packets &+ repairs.packets
                outbound.bytesSent = count.bytes &+ repairs.bytes
            }
            rows.append(outbound)
            if let report = wire.reports[sender.ssrc] {
                var remote = GroupStatsRecord(id: "remote-inbound-rtp-\(sender.ssrc)", type: "remote-inbound-rtp", timestamp: time)
                remote.kind = kind
                remote.ssrc = sender.ssrc
                remote.packetsLost = report.cumulativeLoss
                remote.fractionLost = Double(report.fractionLost)/256
                remote.jitter = Double(report.jitter)/(kind == "audio" ? 48_000 : 90_000)
                rows.append(remote)
            }
        }
        for (id, peer) in peers.sorted(by: { $0.key < $1.key }) {
            var audio = GroupStatsRecord.rtp(ssrc: id, kind: "audio", outgoing: false, count: peer.audioStats, timestamp: time)
            if let reception = measurements.inboundStats(for: id) {
                audio.packetsLost = reception.lost
                audio.jitter = reception.jitterSeconds
            }
            rows.append(audio)
            for (offset,stats) in peer.streamStats.sorted(by: { $0.key < $1.key }) {
                var inbound = GroupStatsRecord.rtp(ssrc: id+offset, kind: "video", outgoing: false, count: stats.media, timestamp: time)
                if let reception = measurements.inboundStats(for: id+offset) {
                    inbound.packetsLost = reception.lost
                    inbound.jitter = reception.jitterSeconds
                }
                inbound.nackCount = stats.nacksSent
                inbound.pliCount = stats.plisSent
                inbound.retransmittedPacketsReceived = stats.repair.packets
                inbound.retransmittedBytesReceived = stats.repair.bytes
                rows.append(inbound)
            }
        }
        let streams = Dictionary(uniqueKeysWithValues: observations.map { ($0.key,$0) })
        for index in rows.indices {
            guard let ssrc = rows[index].ssrc else { continue }
            let type = rows[index].type
            if type == "remote-inbound-rtp" {
                rows[index].localId = "outbound-rtp-\(ssrc)"
                rows[index].transportId = transport.id
                rows[index].roundTripTime = measurements.remoteRTT(for: ssrc).map { $0/1000 }
            } else if let source = streams[(UInt64(ssrc) << 1) | (type == "outbound-rtp" ? 1 : 0)] {
                rows[index].media(source)
                if type == "outbound-rtp", wire.reports[ssrc] != nil { rows[index].remoteId = "remote-inbound-rtp-\(ssrc)" }
                if let codec = rows[index].codecId, let pt = Int(codec.dropFirst(6)) { codecs.insert(pt) }
            }
        }
        rows += codecs.sorted().map { GroupStatsRecord.codec($0, timestamp: time) }
        guard let data = try? JSONEncoder().encode(rows) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func fail(_ text: String) async {
        guard !ended else { return }
        await close()
        event(.failed(text))
    }

    package nonisolated func revokeCapture() {
        lifetime.withLock { $0 = false }
        video.close()
    }

    package func close() async {
        revokeCapture()
        guard !ended else { await stoppingMic?.value; return }
        ended = true
        if let wire, let connection {
            measurements.sample(rtt: connection.lastRoundTrip, media: observations(wire), relayed: connection.relayed)
        }
        nomination?.cancel()
        migration?.cancel()
        pathMonitor?.cancel()
        incoming?.finish()
        receiveTask?.cancel()
        mix?.cancel()
        monitor?.cancel()
        if capture != nil { stopCapture() }
        connection?.close()
        connection = nil
        peers.removeAll()
        await devices.speaker.stop()
        await stoppingMic?.value
    }

    deinit {
        video.close()
        nomination?.cancel()
        migration?.cancel()
        pathMonitor?.cancel()
        incoming?.finish()
        receiveTask?.cancel()
        mix?.cancel()
        monitor?.cancel()
        capture?.cancel()
        connection?.close()
    }
}
