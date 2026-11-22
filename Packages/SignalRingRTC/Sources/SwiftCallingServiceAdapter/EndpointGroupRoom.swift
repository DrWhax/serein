import Foundation
import SignalRingRTC
import SwiftCalling
import Synchronization

/// An ordered command mailbox per room. A slow SFU HTTP request or ICE check
/// runs independently so leaving the lobby never waits for network completion.
final class EndpointGroupRoom: Sendable {
    let id: UInt32
    let group: Data
    private let input: AsyncStream<(String, [String: JSONValue])>.Continuation
    private let worker: Task<Void, Never>
    let room: GroupRoom

    init(id: UInt32, group: Data, fields: [String: JSONValue], link: Bool, http: GroupHTTP, dred: DREDConfiguration? = nil,
         devices: @escaping @Sendable () -> VoiceCallDevices, emit: @escaping @Sendable (JSONValue) -> Void) {
        self.id = id
        self.group = group
        let room = GroupRoom(id: id, group: group, fields: fields, link: link, http: http, dred: dred, devices: devices, emit: emit)
        self.room = room
        let (stream, continuation) = AsyncStream<(String, [String: JSONValue])>.makeStream(bufferingPolicy: .bufferingOldest(256))
        input = continuation
        worker = Task {
            for await (name, fields) in stream {
                guard !Task.isCancelled else { break }
                await room.command(name, fields)
            }
            await room.close()
        }
    }

    func command(_ name: String, _ fields: [String: JSONValue]) -> Bool {
        if case .enqueued = input.yield((name, fields)) { return true }
        return false
    }

    func close() {
        room.revokeMedia()
        input.finish()
        worker.cancel()
    }
}

actor GroupRoom {
    typealias Fields = [String: JSONValue]
    let id: UInt32
    let group: Data
    let link: Bool
    var fields: Fields
    let http: GroupHTTP
    let dred: DREDConfiguration?
    let devices: @Sendable () -> VoiceCallDevices
    let emit: @Sendable (JSONValue) -> Void
    nonisolated let video = Mutex<GroupCallVideo?>(nil)
    private nonisolated let liveSession = Mutex<GroupMediaSession?>(nil)

    nonisolated func revokeMedia() {
        video.withLock { $0 = nil }
        liveSession.withLock { $0?.revokeCapture() }
    }

    var closed = false
    var connected = false
    var joinState = JoinState.notJoined
    var joinedTransport = false
    var sawLinkEndorsements = false
    var admitted = false
    var demux: UInt32?
    var era: String?
    var creator: Data?
    var me: Data?
    var media: GroupMediaSession?
    var crypto: GroupFrameCrypto?
    var version = UUID()
    var httpJoin: Task<Void, Never>?
    var poll: Task<Void, Never>?
    var tick: Task<Void, Never>?
    var pollNumber: UInt64 = 0
    var lastWirePeek: UInt32?
    var lastPoll = ContinuousClock.now - .seconds(60)
    var lastHeartbeat = ContinuousClock.now - .seconds(10)
    var lastProof = ContinuousClock.now
    var heartbeat = GroupDeviceMessage()
    var control = GroupSFUControl()
    var remotes: [UInt32: Fields] = [:]
    var waitingKeys: [(sender: Data, key: GroupDeviceMessage.Key)] = []
    var pendingDevices: [Data: Set<UInt32>] = [:]
    var resolved: [String: Data] = [:]
    var outstandingOpaque = Set<String>()
    var invalidOpaque = Set<String>()
    var lastPeek: JSONValue?
    var sentRing = false
    var cancellableRingID: Int64?
    var requestedRing = false
    var localDataMode: DataMode = .normal
    var requests: [GroupSFUVideoRequest]?
    var activeHeight: UInt32?
    var lastDeviceTime: [UInt32: UInt32] = [:]
    var seenMuteRequests: [UInt32: Set<UInt32>] = [:]
    var muteAttribution: [UInt32: UInt32] = [:]
    var statsInterval: UInt64 = 0
    var notifiedPeek: JSONValue?
    var timeline = CallTimeline()
    let measurements = CallMediaMeasurements()


    init(id: UInt32, group: Data, fields: Fields, link: Bool, http: GroupHTTP, dred: DREDConfiguration? = nil, devices: @escaping @Sendable () -> VoiceCallDevices,
         emit: @escaping @Sendable (JSONValue) -> Void) {
        self.id = id
        self.group = group
        self.fields = fields
        self.link = link
        self.http = http
        self.dred = dred
        self.devices = devices
        self.emit = emit
        heartbeat.audioMuted = true
        heartbeat.videoMuted = true
    }

    func event(_ name: String, _ fields: Fields = [:]) {
        var fields = fields
        fields["type"] = .string(name)
        fields["clientId"] = .int(Int64(id))
        emit(.object(fields))
    }

    func setJoin(_ state: JoinState) {
        guard state != joinState else { return }
        joinState = state
        event("handleJoinStateChanged", ["joinState": .int(Int64(state.rawValue)), "demuxId": demux.map { .int(Int64($0)) } ?? .null])
    }

    private func connect() {
        guard !connected else { return }
        connected = true
        timeline.record(.groupConnecting)
        event("handleConnectionStateChanged", ["connectionState": .int(Int64(ConnectionState.connecting.rawValue))])
        if !link { event("requestMembershipProof"); event("requestGroupMembers") }
        tick = Task { [weak self] in
            while !Task.isCancelled {
                await self?.update()
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }

    func peekRequest() throws -> (CallSFURequests, JSONValue) {
        var requests = CallSFURequests()
        var query = fields
        query["requestId"] = .int(1)
        let req = try requests.start(link ? "peekCallLinkCall" : "peekGroupCall", query)
        guard req["type"].string == "sendHttpRequest" else { throw RingRTCError.invalidResponse }
        return (requests, req)
    }

    func peek() {
        guard connected, poll == nil, let (requests, req) = try? peekRequest() else { return }
        lastPoll = .now
        let version = self.version
        pollNumber &+= 1
        let number = pollNumber
        poll = Task { [weak self, http, emit] in
            let reply = await http.perform(req, emit: emit)
            guard !Task.isCancelled else { return }
            var response = requests
            let result = response.complete("receivedHttpResponse", ["requestId": req["requestId"], "statusCode": .int(Int64(reply.status)), "body": .bytes(reply.body)])
            await self?.peekResult(result, version: version, number: number)
        }
    }

    private func peekResult(_ result: JSONValue?, version: UUID, number: UInt64) async {
        guard !closed, self.version == version, number == pollNumber else { return }
        poll = nil
        if let result, !result["info"].isNull { await applyPeek(result["info"]) }
    }

    private struct Joined: Decodable {
        let demuxId: UInt32
        let iceUfrag: String
        let icePwd: String
        let dhePublicKey: String
        let udpAddresses: [String]?
        let tcpAddresses: [String]?
        let tlsAddresses: [String]?
        let hostname: String?
        let conferenceId: String
        let clientStatus: String
    }

    func startJoin() {
        guard joinState == .joining, httpJoin == nil, media == nil, let (_, template) = try? peekRequest() else { return }
        let crypto = GroupFrameCrypto()
        self.crypto = crypto
        let version = self.version
        let svc = fields["svcConfig"].flatMap { config -> GroupVideoConfiguration? in
            guard let camera = config["mode"].string, let screen = config["modeForScreenshare"].string else { return nil }
            return GroupVideoConfiguration(camera: camera, screen: screen, maximumBitrate: config["maxBitrateBps"].uint64)
        }
        measurements.beginSession()
        let session = GroupMediaSession(devices: devices(), crypto: crypto, audioLevelsIntervalMillis: fields["audioLevelsIntervalMillis"]?.uint64, groupVideo: svc, dred: dred, measurements: measurements) { [weak self] update in
            Task { await self?.onMedia(update, version: version) }
        }
        media = session
        liveSession.withLock { $0 = session }
        var headers: Fields = [:]
        if case .object(let auth) = template["headers"] { headers = auth }
        headers["Content-Type"] = .string("application/json")
        var body: Fields = ["iceUfrag": .string(session.iceUfrag), "icePwd": .string(session.icePassword),
                            "dhePublicKey": .string(CallSFURequests.hex(session.publicKey)),
                            "hkdfExtraInfo": .string(CallSFURequests.hex(fields["hkdfExtraInfo"]?.data ?? Data())), "requiresSvc": .bool(svc != nil)]
        if let admin = fields["adminPasskey"]?.data { body["adminPasskey"] = .bytes(admin) }
        guard let json = try? JSONEncoder().encode(JSONValue.object(body)) else { return }
        let request = JSONValue.object(["url": template["url"], "type": .string("sendHttpRequest"), "method": .int(Int64(HttpMethod.put.rawValue)),
                                        "headers": .object(headers), "body": .bytes(json)])
        httpJoin = Task { [weak self, http, emit] in
            let reply = await http.perform(request, emit: emit)
            guard !Task.isCancelled else { return }
            await self?.joinResult(reply, session: session, version: version)
        }
    }

    private func joinResult(_ reply: GroupHTTP.Reply, session: GroupMediaSession, version: UUID) async {
        guard !closed, self.version == version else { return }
        guard (200..<300).contains(reply.status), let joined = try? JSONDecoder().decode(Joined.self, from: reply.body),
              joined.demuxId > 0, joined.demuxId & 15 == 0, let key = GroupIdentity.hex(joined.dhePublicKey), key.count == 32,
              !joined.iceUfrag.isEmpty, !joined.icePwd.isEmpty, !joined.conferenceId.isEmpty else {
            await end(reply.status == 413 ? .hasMaxDevices : .sfuClientFailedToJoin)
            return
        }
        guard ["ACTIVE", "PENDING"].contains(joined.clientStatus) else { await end(.deniedRequestToJoinCall); return }
        demux = joined.demuxId
        admitted = joined.clientStatus == "ACTIVE"
        era = joined.conferenceId
        setJoin(admitted ? .joined : .pending)
        if let lastPeek { await applyPeek(lastPeek) }
        do {
            try await session.connect(demuxID: joined.demuxId, serverKey: key, hkdfExtraInfo: fields["hkdfExtraInfo"]?.data ?? Data(),
                                      remoteUfrag: joined.iceUfrag, remotePassword: joined.icePwd, udpAddresses: joined.udpAddresses ?? [],
                                      tcpAddresses: joined.tcpAddresses ?? [], tlsAddresses: joined.tlsAddresses ?? [], hostname: joined.hostname)
        } catch { if self.version == version { await end(.iceFailedWhileConnecting) } }
    }

    func update() async {
        guard !closed else { return }
        if !link && lastProof.duration(to: .now) >= .seconds(86_400) {
            lastProof = .now
            event("requestMembershipProof")
        }
        if lastPoll.duration(to: .now) >= .seconds(3) { peek() }
        if let nextKey = crypto?.applyRotation() { sendKey(nextKey) }
        if joinedTransport {
            for bytes in control.tick() { try? await media?.sendToSFU(bytes) }
            if admitted, lastHeartbeat.duration(to: .now) >= .seconds(1) { await sendHeartbeat() }
        }
    }

    func sendHeartbeat() async {
        guard admitted && joinedTransport else { return }
        lastHeartbeat = .now
        try? await media?.sendToDevices(heartbeat.encode())
    }

    func onMedia(_ update: GroupMediaSession.Event, version: UUID) async {
        guard !closed, self.version == version else { return }
        switch update {
        case .connected:
            joinedTransport = true
            timeline.record(.groupConnected)
            timeline.didConnect()
            event("handleConnectionStateChanged", ["connectionState": .int(Int64(ConnectionState.connected.rawValue))])
            await enableMedia()
            await requestVideo()
            peek()
        case .reconnecting:
            timeline.record(.groupReconnecting)
            event("handleConnectionStateChanged", ["connectionState": .int(Int64(ConnectionState.reconnecting.rawValue))])
        case .route(let adapter):
            timeline.record(.routeChanged)
            if NetworkAdapterType(rawValue: adapter).contains(.cellular) { timeline.cellular = true }
            event("handleNetworkRouteChanged", ["localNetworkAdapterType": .int(Int64(adapter))])
        case .speech(let speech):
            event("handleSpeechEvent", ["event": .int(Int64(speech))])
        case .bandwidth(let recovered):
            event("handleLowBandwidthForVideo", ["recovered": .bool(recovered)])
        case .rtcStats(let json):
            event("handleRtcStatsReportComplete", ["reportJson": .string(json)])
        case .failed:
            await end(joinedTransport ? .iceFailedAfterConnected : .iceFailedWhileConnecting)
        case .sfu(let packet, let timestamp):
            if let messages = try? control.receive(packet, timestamp: timestamp) {
                for message in messages { await handleServer(message) }
            }
        case .device(let from, let packet, let timestamp):
            if let message = try? GroupDeviceMessage(packet) { await handleDevice(message, demux: from, timestamp: timestamp) }
        case .audioLevels(let captured, let received):
            event("handleAudioLevels", ["capturedLevel": .int(Int64(captured)), "receivedLevels": .array(received.map { demux, level in
                .object(["demuxId": .int(Int64(demux)), "level": .int(Int64(level))])
            })])
        }
    }

    func enableMedia() async {
        guard joinedTransport, let media else { return }
        await media.setLowDataMode(localDataMode == .low)
        media.setScreenSharing(heartbeat.sharingScreen == true)
        await media.setStatsInterval(statsInterval)
        await media.setJoined(admitted)
        let frames = admitted ? media.video : nil
        video.withLock { $0 = frames }
        await media.setAudioEnabled(admitted && heartbeat.audioMuted == false)
        await media.setVideoEnabled(admitted && heartbeat.videoMuted == false)
        await sendHeartbeat()
    }

    func leave() async {
        if let id = cancellableRingID {
            cancellableRingID = nil
            sendRing(.cancelled, id: id)
        }
        version = UUID()
        poll?.cancel()
        poll = nil
        httpJoin?.cancel()
        httpJoin = nil
        revokeMedia()
        liveSession.withLock { $0 = nil }
        let old = media
        media = nil
        crypto = nil
        if joinedTransport, let bytes = try? control.send(.leave) {
            for payload in bytes { try? await old?.sendToSFU(payload) }
        }
        await old?.close()
        demux = nil
        sawLinkEndorsements = false
        admitted = false
        joinedTransport = false
        remotes = [:]
        era = nil
        lastPeek = nil
        lastWirePeek = nil
        notifiedPeek = nil
        pendingDevices = [:]
        resolved = [:]
        outstandingOpaque = []
        invalidOpaque = []
        waitingKeys = []
        control = GroupSFUControl()
        lastDeviceTime.removeAll()
        muteAttribution.removeAll()
        seenMuteRequests.removeAll()
        sentRing = false
        requestedRing = false
        setJoin(.notJoined)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        tick?.cancel()
        await leave()
    }

    func end(_ reason: CallEndReason) async {
        guard !closed else { return }
        await close()
        timeline.record(.groupDisconnected)
        event("handleEnded", ["reason": .int(Int64(reason.rawValue)), "summary": timeline.summary(reason: reason, quality: measurements.summary())])
    }

    func command(_ name: String, _ fields: Fields) async {
        guard !closed else { return }
        switch name {
        case "connect": connect()
        case "join":
            guard joinState == .notJoined else { return }
            connect()
            setJoin(.joining)
            startJoin()
        case "leave": await leave()
        case "disconnect": await end(.deviceExplicitlyDisconnected)
        case "busy": await end(.callManagerIsBusy)
        case "setSelfUuid": me = fields["uuid"]?.data
        case "setMembershipProof":
            self.fields["membershipProof"] = fields["proof"]
            peek()
            startJoin()
        case "setGroupMembers":
            self.fields["members"] = fields["members"]
            if !link { await refreshMembers() }
        case "setCallLinkMembers":
            await applyResolved(fields)
        case "receivedCallMessage":
            await signaling(fields)
        default: await mediaCommand(name, fields)
        }
    }
}

enum GroupIdentity {
    static func hex(_ string: String) -> Data? {
        let bytes = Array(string.utf8)
        guard bytes.count.isMultiple(of: 2), bytes.count <= 512 else { return nil }
        func digit(_ b: UInt8) -> UInt8? {
            switch b { case 48...57: b - 48; case 65...70: b - 55; case 97...102: b - 87; default: nil }
        }
        var data = Data()
        for i in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = digit(bytes[i]), let low = digit(bytes[i + 1]) else { return nil }
            data.append(high << 4 | low)
        }
        return data
    }

    static func uuid(_ bytes: Data) -> UUID? {
        let b = Array(bytes)
        guard b.count == 16 else { return nil }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
