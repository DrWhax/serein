import Foundation
import Security
import SwiftCalling
import Synchronization
import Testing

private actor SFUTestMic: VoiceCallMicrophone {
    let hz: Double
    var pump: Task<Void,Never>?
    init(_ hz: Double) { self.hz = hz }
    func start() -> AsyncStream<[Int16]> {
        let stream = AsyncStream<[Int16]>.makeStream(bufferingPolicy: .bufferingNewest(3))
        let hz = self.hz
        pump = Task {
            var offset = 0
            var deadline = ContinuousClock.now
            defer { stream.continuation.finish() }
            while !Task.isCancelled {
                stream.continuation.yield((0..<960).map { Int16(8000 * sin(2 * .pi * hz * Double(offset + $0) / 48000)) })
                offset += 960
                deadline += .milliseconds(20)
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            }
        }
        return stream.stream
    }
    func stop() { pump?.cancel(); pump = nil }
}

private actor SFUTestSpeaker: VoiceCallSpeaker {
    var samples: [Int16] = []
    func start() {}
    func enqueue(_ pcm: [Int16], timestamp: UInt32) { if samples.count < 48000 { samples += pcm } }
    func stop() {}
    func clear() { samples.removeAll() }
    func hasTone(_ hz: Double) -> Bool {
        guard samples.count >= 4800 else { return false }
        // Check frequency as well as energy. The fixtures use different tones, so local
        // sidetone or silence cannot satisfy the two-way assertion.
        let input = samples.suffix(4800)
        var real = 0.0, imag = 0.0, power = 0.0
        for (i,s) in input.enumerated() {
            let phase = 2*Double.pi*hz*Double(i)/48000
            real += Double(s)*cos(phase); imag += Double(s)*sin(phase); power += Double(s)*Double(s)
        }
        return power > 1_000_000 && (real*real + imag*imag)/(power*Double(input.count)) > 0.05
    }
}

@Suite struct GroupMediaInteropTests {
    private struct Join: Decodable {
        let demuxId: UInt32
        let udpAddresses, tcpAddresses, tlsAddresses: [String]
        let hostname: String?
        let iceUfrag, icePwd, dhePublicKey: String
    }

    private func join(_ session: GroupMediaSession, url: URL, user: String, room: String) async throws -> Join {
        var request = URLRequest(url: url.appending(path: "v2/conference/participants"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let auth = Data("test:2:\(user):\(room):1:2:3".utf8).base64EncodedString()
        request.setValue("Basic " + auth, forHTTPHeaderField: "Authorization")
        let extra = "group-media-test"
        func hex(_ data: Data) -> String { data.map { ($0 < 16 ? "0" : "") + String($0, radix:16) }.joined() }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "iceUfrag":session.iceUfrag, "icePwd":session.icePassword, "dhePublicKey":hex(session.publicKey),
            "hkdfExtraInfo":hex(Data(extra.utf8)), "requiresSvc":false])
        let (data,response) = try await URLSession.shared.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 200)
        let reply = try JSONDecoder().decode(Join.self, from: data)
        let chars = Array(reply.dhePublicKey.utf8)
        try #require(chars.count == 64)
        let key = Data(try stride(from: 0,to:64,by:2).map { try #require(UInt8(String(decoding:chars[$0..<$0+2],as:UTF8.self),radix:16)) })
        let env = ProcessInfo.processInfo.environment
        let mode = env["SEREIN_TEST_SFU_TRANSPORT"] ?? (env["SEREIN_TEST_SFU_TCP"] == "1" ? "tcp" : "udp")
        var anchor: SecCertificate?
        if mode == "tls" {
            let path = try #require(env["SEREIN_TEST_SFU_CA"])
            let der = try Data(contentsOf: URL(fileURLWithPath: path))
            anchor = try #require(SecCertificateCreateWithData(nil, der as CFData))
            try #require(!reply.tlsAddresses.isEmpty && reply.hostname == "localhost")
        }
        try await session.connect(demuxID: reply.demuxId, serverKey: key, hkdfExtraInfo: Data(extra.utf8),
            remoteUfrag: reply.iceUfrag, remotePassword: reply.icePwd, udpAddresses: mode == "udp" ? reply.udpAddresses : [],
            tcpAddresses: mode == "tcp" ? reply.tcpAddresses : [], tlsAddresses: mode == "tls" ? reply.tlsAddresses : [],
            hostname: reply.hostname, trustAnchor: anchor)
        return reply
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_TEST_SFU_URL"] != nil))
    func independentVP8SimulcastSubscriptions() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["SEREIN_TEST_SFU_URL"].flatMap(URL.init(string:)))
        let room = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let users = [UUID(), UUID(), UUID()]
        let crypto = users.map { _ in GroupFrameCrypto() }
        let sessions = crypto.map { state in
            GroupMediaSession(devices: .init(microphone: SFUTestMic(300), speaker: SFUTestSpeaker()), crypto: state) { _ in }
        }
        do {
            var ids = [UInt32]()
            for (i,session) in sessions.enumerated() {
                ids.append(try await join(session,url:url,user:"0\(i+1)",room:room).demuxId)
            }
            for (i,session) in sessions.enumerated() {
                let others = users.indices.filter { $0 != i }
                let roster = Dictionary(uniqueKeysWithValues: others.map { (ids[$0],users[$0]) })
                try crypto[i].setMembers(roster)
                for j in others {
                    let key = crypto[j].sendingKey
                    try crypto[i].install(secret:key.secret,ratchet:key.ratchet,demuxID:ids[j],sender:users[j])
                }
                await session.setRemoteDevices(Set(roster.keys))
                await session.setJoined(true)
            }
            let source = sessions[0], width = 1280, height = 720
            await source.setVideoEnabled(true)
            var buffer = [UInt8](repeating:0,count:width*height*4)
            var frame = [UInt8](repeating:128,count:width*height*3/2)
            for row in 0..<height {
                for col in 0..<width { frame[row*width+col] = col < width/2 ? 48 : 192 }
            }
            for large in [720,360] {
                var actual = [0,0]
                for (i,resolution) in [180,large].enumerated() {
                    var control = GroupSFUControl()
                    let request = GroupSFUCommand.videoRequest([.init(demuxID:ids[0],height:UInt32(resolution))],maxKbps:3000,activeSpeakerHeight:0)
                    for data in try control.send(request) { try await sessions[i+1].sendToSFU(data) }
                }
                let end = ContinuousClock.now + .seconds(15)
                var revision: UInt8 = 0
                while actual != [180,large], ContinuousClock.now < end {
                    revision &+= 3
                    for col in 0..<width { frame[height/4*width+col] = revision }
                    _ = source.video.submit(width:width,height:height,format:0,data:frame)
                    try await Task.sleep(for:.milliseconds(65))
                    for i in actual.indices {
                        if let received = sessions[i+1].video.receive(demuxID:ids[0],maxWidth:width,maxHeight:height,into:&buffer) {
                            let centre = received.width*(received.height/2)
                            let contrast = Int(buffer[4*(centre+3*received.width/4)]) - Int(buffer[4*(centre+received.width/4)])
                            if contrast > 90 { actual[i] = received.height }
                        }
                    }
                }
                #expect(actual == [180,large], "Separate SFU subscriptions must deliver the requested VP8 layers")
            }
        } catch {
            for session in sessions { await session.close() }
            throw error
        }
        for session in sessions { await session.close() }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_TEST_SFU_URL"] != nil))
    func twoWayEncryptedAudioVideoAndData() async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["SEREIN_TEST_SFU_URL"])
        let url = try #require(URL(string: raw))
        let room = UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let aSpeaker = SFUTestSpeaker(), bSpeaker = SFUTestSpeaker(), aCrypto = GroupFrameCrypto(), bCrypto = GroupFrameCrypto()
        let seenA = Mutex<[Data]>([]), seenB = Mutex<[Data]>([])
        let connections = Mutex<[String]>([]), stats = Mutex<[String]>([])
        let a = GroupMediaSession(devices: .init(microphone: SFUTestMic(300),speaker: aSpeaker),crypto:aCrypto) {
            switch $0 {
            case .device(_,let body,_): seenA.withLock { $0.append(body) }
            case .connected: connections.withLock { $0.append("connected") }
            case .reconnecting: connections.withLock { $0.append("reconnecting") }
            case .rtcStats(let json): stats.withLock { $0.append(json) }
            default: break
            }
        }
        let b = GroupMediaSession(devices: .init(microphone: SFUTestMic(500),speaker: bSpeaker),crypto:bCrypto) {
            if case .device(_,let body,_) = $0 { seenB.withLock { $0.append(body) } }
        }
        do {
            let first = try await join(a,url:url,user:"01",room:room), second = try await join(b,url:url,user:"02",room:room)
            let aID = first.demuxId, bID = second.demuxId
            await a.setStatsInterval(100)
            for (receiver,recvCrypto,senderCrypto,other) in [(a,aCrypto,bCrypto,bID),(b,bCrypto,aCrypto,aID)] {
                let member = UUID()
                try recvCrypto.setMembers([other:member])
                let key = senderCrypto.sendingKey
                try recvCrypto.install(secret:key.secret,ratchet:key.ratchet,demuxID:other,sender:member)
                await receiver.setRemoteDevices([other])
                await receiver.setJoined(true)
                await receiver.setVideoEnabled(true)
                await receiver.setAudioEnabled(true)
                var control = GroupSFUControl()
                let command = GroupSFUCommand.videoRequest([.init(demuxID:other,height:240)],maxKbps:1000,activeSpeakerHeight:nil)
                for packet in try control.send(command) { try await receiver.sendToSFU(packet) }
            }
            let w = 128, h = 96
            let aFrame = Array(repeating:UInt8(60),count:w*h) + Array(repeating:UInt8(128),count:w*h/2)
            let bFrame = Array(repeating:UInt8(185),count:w*h) + Array(repeating:UInt8(128),count:w*h/2)
            let sentA = Data("device A".utf8), sentB = Data("device B".utf8)
            var atA = false, atB = false, audioA = false, audioB = false, aData = false, bData = false
            var lastData = ContinuousClock.now - .seconds(1)
            let end = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < end, !(atA && atB && audioA && audioB && aData && bData) {
                if lastData.duration(to: .now) > .milliseconds(500) {
                    try await a.sendToDevices(sentA)
                    try await b.sendToDevices(sentB)
                    lastData = .now
                }
                _ = a.video.submit(width:w,height:h,format:0,data:aFrame)
                _ = b.video.submit(width:w,height:h,format:0,data:bFrame)
                try await Task.sleep(for:.milliseconds(60))
                var pixels = [UInt8](repeating:0,count:w*h*4)
                if b.video.receive(demuxID:aID,maxWidth:w,maxHeight:h,into:&pixels) != nil { atB = pixels[0] < 80 && pixels[3] == 255 }
                if a.video.receive(demuxID:bID,maxWidth:w,maxHeight:h,into:&pixels) != nil { atA = pixels[0] > 160 && pixels[3] == 255 }
                if !audioA { audioA = await aSpeaker.hasTone(500) }
                if !audioB { audioB = await bSpeaker.hasTone(300) }
                aData = seenA.withLock { $0.contains(sentB) }; bData = seenB.withLock { $0.contains(sentA) }
            }
            #expect(atA && atB, "Video A=\(atA) B=\(atB)")
            #expect(audioA && audioB, "Speech A=\(audioA) B=\(audioB)")
            #expect(aData && bData, "Device broadcasts A=\(aData) B=\(bData)")
            func counts() -> (sent: UInt64, received: UInt64) {
                guard let json = stats.withLock({ $0.last }), let records = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String:Any]] else { return (0,0) }
                func video(_ direction: String, _ column: String) -> UInt64 {
                    records.first { $0["type"] as? String == direction && $0["kind"] as? String == "video" }?[column] as? UInt64 ?? 0
                }
                return (video("outbound-rtp", "packetsSent"), video("inbound-rtp", "packetsReceived"))
            }
            let before = counts()
            #expect(before.sent > 0 && before.received > 0)
            if ["tcp","tls"].contains(ProcessInfo.processInfo.environment["SEREIN_TEST_SFU_TRANSPORT"] ?? "") {
                await a.setServerAddress(.init(udp:first.udpAddresses))
                let until = ContinuousClock.now + .seconds(8)
                while ContinuousClock.now < until, connections.withLock({ $0.last != "connected" || $0.count < 3 }) {
                    try await Task.sleep(for: .milliseconds(50))
                }
                try #require(connections.withLock { $0 } == ["connected","reconnecting","connected"])
                await aSpeaker.clear()
                await bSpeaker.clear()
                audioA = false; audioB = false; atA = false; atB = false
                let timeout = ContinuousClock.now + .seconds(8)
                while ContinuousClock.now < timeout, !(audioA && audioB && atA && atB) {
                    _ = a.video.submit(width:w,height:h,format:0,data:bFrame)
                    _ = b.video.submit(width:w,height:h,format:0,data:aFrame)
                    try await Task.sleep(for:.milliseconds(60))
                    var pixels = [UInt8](repeating:0,count:w*h*4)
                    if b.video.receive(demuxID:aID,maxWidth:w,maxHeight:h,into:&pixels) != nil { atB = pixels[0] > 160 && pixels[3] == 255 }
                    if a.video.receive(demuxID:bID,maxWidth:w,maxHeight:h,into:&pixels) != nil { atA = pixels[0] < 80 && pixels[3] == 255 }
                    if !audioA { audioA = await aSpeaker.hasTone(500) }
                    if !audioB { audioB = await bSpeaker.hasTone(300) }
                }
                #expect(atA && atB && audioA && audioB, "encrypted media after SFU address migration")
                let after = counts()
                #expect(after.sent > before.sent && after.received > before.received)
            }
        } catch {
            await a.close(); await b.close(); throw error
        }
        await a.close(); await b.close()
    }
}
