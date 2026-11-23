import CryptoKit
import Foundation
import SignalRingRTC
import SwiftCalling
import SwiftCallingServiceAdapter
import Testing

@MainActor private final class GroupPeerObserver: GroupCallObserver {
    let proof: Data
    let members: [GroupMemberInfo]
    var reactions: [Reaction] = []
    var hands: [UInt32] = []
    var ended: [CallEndReason] = []
    var summaries: [CallSummary] = []

    init(member: GroupMemberInfo, room: String, members: [GroupMemberInfo]) {
        let opaque = SHA256.hash(data: member.userIdCipherText).map { ($0 < 16 ? "0" : "") + String($0,radix:16) }.joined()
        proof = Data("2:\(opaque):\(room):1:2:3".utf8)
        self.members = members
    }
    func requestMembershipProof(_ call: GroupCall) { call.setMembershipProof(proof) }
    func requestGroupMembers(_ call: GroupCall) { call.setGroupMembers(members) }
    func onReactions(_ call: GroupCall,reactions: [Reaction]) { self.reactions += reactions }
    func onRaisedHands(_ call: GroupCall,raisedHands: [UInt32]) { hands = raisedHands }
    func onEnded(_ call: GroupCall,reason: CallEndReason,summary: CallSummary) { ended.append(reason); summaries.append(summary) }
    func onRemoteDeviceStatesChanged(_ call: GroupCall) {}
    func onLocalDeviceStateChanged(_ call: GroupCall) {}
    func onAudioLevels(_ call: GroupCall) {}
    func onLowBandwidthForVideo(_ call: GroupCall,recovered: Bool) {}
    func onPeekChanged(_ call: GroupCall) {}
    func onSpeechEvent(_ call: GroupCall,event: SpeechEvent) {}
    func onRemoteMute(_ call: GroupCall,demuxId: UInt32) {}
    func onObservedRemoteMute(_ call: GroupCall,sourceDemuxId: UInt32,targetDemuxId: UInt32) {}
}

@MainActor @Suite(.serialized) struct GroupCallInteropTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_TEST_SFU_URL"] != nil))
    func nativeAndSwiftGroupCall() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["SEREIN_TEST_SFU_URL"].flatMap(URL.init(string:)))
        try #require(url.host == "127.0.0.1")
        let env = ProcessInfo.processInfo.environment
        let dred = env["SEREIN_TEST_GROUP_DRED"] == "1"
        let link = dred && env["SEREIN_TEST_GROUP_KIND"] == "call-link"
        let videoLoss = env["SEREIN_TEST_VIDEO_LOSS"] == "1"
        let proxy = try dred || videoLoss ? VideoLossProxy(rtxOffset: 1, dropAudio: dred, uplinkAudioLossPeriod: 10) : nil
        if let proxy {
            await LoopbackCallTests.wait(3) { proxy.port != nil }
            try #require(proxy.port != nil)
        }
        defer { proxy?.close() }
        let phrase = try ProcessInfo.processInfo.environment["SEREIN_SPEECH_DIR"].map {
            try SpeechFixture(directory: URL(fileURLWithPath: $0, isDirectory: true))
        }
        let backend: LocalCallEndpointFactory
        if let phrase {
            let microphone = PhraseMicrophone(phrase), speaker = PhraseSpeaker(phrase)
            backend = SwiftVoiceEndpoint.factory(devices: { .init(microphone:microphone,speaker:speaker) })
        } else { backend = SwiftVoiceEndpoint.factory }
        let reference = ProcessInfo.processInfo.environment["SEREIN_TEST_REFERENCE_NATIVE"] == "1"
        let a = try reference ? LoopbackCallTests.Side("reference", .overXPC) : LoopbackCallTests.Side("swift",.overXPC,backend:backend)
        let b = try LoopbackCallTests.Side("native",.overXPC)
        if ProcessInfo.processInfo.environment["SEREIN_TEST_NATIVE_LOG"] == "1" {
            b.rtc.handleLogMessage = { _, file, _, message in print("[native \(file)] \(message)") }
        }
        if dred {
            try #require(phrase != nil && !reference)
            let model = try Data(contentsOf: URL(fileURLWithPath: try #require(env["SEREIN_DRED_WEIGHTS"])))
            try a.rtc.addAsset("opus-dred", content: model)
            try b.rtc.addAsset("opus-dred", content: model)
        }
        if phrase != nil { try #require(b.rtc.getAudioInputs()?.devices.map(\.name) == ["Serein file microphone"]) }
        let aUser = GroupMemberInfo(userId:Data(repeating:1,count:16),userIdCipherText:link ? CallLinkSFUFixture.ciphers[0] : Data(repeating:9,count:65))
        let bUser = GroupMemberInfo(userId:Data(repeating:2,count:16),userIdCipherText:link ? CallLinkSFUFixture.ciphers[1] : Data(repeating:8,count:65))
        let rootKey = try link ? CallLinkSFUFixture.rootKey() : nil
        let group = try rootKey?.deriveRoomId() ?? Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let room = group.map { ($0 < 16 ? "0" : "") + String($0,radix:16) }.joined()
        let members = [aUser,bUser]
        let oa = GroupPeerObserver(member:aUser,room:room,members:members), ob = GroupPeerObserver(member:bUser,room:room,members:members)
        var svcDevices = Set<UInt32>()
        for (side,other,user,otherUser) in [(a,b,aUser,bUser),(b,a,bUser,aUser)] {
            try side.rtc.setSelfUuid(user.userId)
            // HTTP is an app callback. Route the two synthetic accounts' requests
            // only to the local test SFU and preserve their authorization and bodies.
            side.rtc.handleSendHttpRequest = { [weak side] id, location, method, headers, body in
                guard let side, let path = URL(string:location)?.path, path == "/v2/conference/participants" else { return }
                Task {
                    var request = URLRequest(url:url.appending(path:"v2/conference/participants"))
                    request.httpMethod = ["GET","PUT","POST","DELETE"][method.rawValue]
                    request.allHTTPHeaderFields = headers
                    if link {
                        let identity = CallLinkSFUFixture.ids[side === a ? 0 : 1]
                        let token = Data(("test:2:" + identity + ":" + room + ":1:2:3").utf8).base64EncodedString()
                        request.setValue("Basic " + token, forHTTPHeaderField: "Authorization")
                    }
                    request.httpBody = body
                    do {
                        let (data,reply) = try await URLSession.shared.data(for:request)
                        var response = data
                        // The upstream development HTTP API omits requiresSvc on GET.
                        // The production frontend supplies it from the device's PUT.
                        if request.httpMethod == "PUT", let body,
                           let join = try JSONSerialization.jsonObject(with: body) as? [String:Any],
                           join["requiresSvc"] as? Bool == true,
                           let assigned = try JSONSerialization.jsonObject(with: data) as? [String:Any],
                           let id = assigned["demuxId"] as? UInt32 { svcDevices.insert(id) }
                        if request.httpMethod == "GET", !svcDevices.isEmpty,
                           var peek = try JSONSerialization.jsonObject(with: data) as? [String:Any],
                           let participants = peek["participants"] as? [[String:Any]] {
                            peek["participants"] = participants.map { device in
                                var device = device
                                if let id = device["demuxId"] as? UInt32 { device["requiresSvc"] = svcDevices.contains(id) }
                                return device
                            }
                            response = try JSONSerialization.data(withJSONObject: peek)
                        }
                        // Put speech loss on the native uplink so the SFU's receiver
                        // reports feed the real encoder's packet-loss estimator.
                        if let proxy, side === (dred ? b : a), request.httpMethod == "PUT" { response = try proxy.substituteJoin(data) }
                        side.rtc.receivedHttpResponse(requestId:id,status:(reply as? HTTPURLResponse)?.statusCode ?? 500,body:response)
                    } catch { side.rtc.httpRequestFailed(requestId:id,debugInfo:nil) }
                }
            }
            let deliver: (Data) -> Void = { [weak other] body in
                // Media keys travel over chat and can arrive after a network outage.
                let age = (try? GroupDeviceMessage.fromSignaling(body))?.key == nil ? 0 : 120
                other?.rtc.handleCallingMessage(.init(opaque:.init(data:body)),
                    .init(remoteUserId:side.name,remoteUuid:user.userId,remoteDeviceId:1,localDeviceId:1,ageSec:age,
                          receivedAtCounter:0,receivedAtDate:0,senderIdentityKey:Data(repeating:4,count:32),receiverIdentityKey:Data(repeating:5,count:32)))
            }
            side.rtc.handleSendCallMessage = { to,body,_ in
                if to == otherUser.userId { deliver(body) }
            }
            side.rtc.handleSendCallMessageToGroup = { id,body,_,overrides in
                if id == group, overrides.isEmpty || overrides.contains(otherUser.userId) { deliver(body) }
            }
        }
        defer {
            for side in [a,b] {
                side.rtc.handleSendHttpRequest = nil
                side.rtc.handleSendCallMessage = nil
                side.rtc.handleSendCallMessageToGroup = nil
                side.handler?.sessionEnded()
            }
        }
        let requestedMode = ProcessInfo.processInfo.environment["SEREIN_TEST_SWIFT_SVC"]
        let swiftSvc = requestedMode.map { GroupCallSvcConfig(mode: $0 == "1" ? "L3T3_KEY" : $0, modeForScreenshare: "L1T3") }
        let nativeSvc = env["SEREIN_TEST_NATIVE_SVC"] == "1"
            ? GroupCallSvcConfig(mode: "L3T3_KEY", modeForScreenshare: "L1T3") : nil
        func make(_ peer: LoopbackCallTests.Side, _ observer: GroupPeerObserver, _ svc: GroupCallSvcConfig?) -> GroupCall? {
            let duration: Int? = dred ? 50 : nil
            if let rootKey {
                return peer.rtc.getCallLinkCall(sfuUrl: url.absoluteString, endorsementPublicKey: CallLinkSFUFixture.publicKey,
                    authCredentialPresentation: Data([1]), rootKey: rootKey, adminPasskey: peer === a ? Data([9]) : nil,
                    hkdfExtraInfo: Data(), audioLevelsIntervalMillis: nil, dredDuration: duration, svcConfig: svc,
                    observer: observer, resolveMember: { cipher in members.first { $0.userIdCipherText == cipher }?.userId })
            }
            return peer.rtc.getGroupCall(groupId: group, sfuUrl: url.absoluteString, hkdfExtraInfo: Data(),
                audioLevelsIntervalMillis: nil, dredDuration: duration, svcConfig: svc, observer: observer)
        }
        let ga = try #require(make(a, oa, swiftSvc)), gb = try #require(make(b, ob, nativeSvc))
        for (call,observer) in [(ga,oa),(gb,ob)] {
            if !link { call.setGroupMembers(members); call.setMembershipProof(observer.proof) }
            call.setOutgoingAudioMuted(true)
            call.connect()
            call.join()
            if link && call === ga && env["SEREIN_TEST_SFU_APPROVAL"] == "1" {
                await LoopbackCallTests.wait(10) { ga.localDeviceState.joinState == .joined }
                try #require(ga.localDeviceState.joinState == .joined)
            }
        }
        if link && env["SEREIN_TEST_SFU_APPROVAL"] == "1" {
            await LoopbackCallTests.wait(12) { ga.peekInfo?.pendingUsers.contains(bUser.userId) == true }
            try #require(ga.peekInfo?.pendingUsers.contains(bUser.userId) == true)
            ga.approveUser(bUser.userId)
        }
        var swiftStats: [[String:Any]] = []
        var nativeVideoStats = [String:String]()
        let compareStats = ProcessInfo.processInfo.environment["SEREIN_TEST_MEDIA_STATISTICS"] == "1"
        var nativeStats = [[String:Any]]()
        if compareStats || ProcessInfo.processInfo.environment["SEREIN_TEST_NATIVE_LOG"] == "1" {
            b.rtc.handleRtcStatsReport = { json in
                guard let rows = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String:Any]],
                      let video = rows.first(where: { $0["kind"] as? String == "video" && $0["type"] as? String == "inbound-rtp" }) else { return }
                nativeStats = rows
                for key in ["ssrc","packetsReceived","framesReceived","framesDecoded","keyFramesDecoded","framesDropped","nackCount","pliCount"] {
                    if let value = video[key] { nativeVideoStats[key] = String(describing: value) }
                }
            }
            gb.setRtcStatsInterval(millis: 500)
        }
        a.rtc.handleRtcStatsReport = { json in
            if let rows = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String:Any]] { swiftStats = rows }
        }
        defer { a.rtc.handleRtcStatsReport = nil; b.rtc.handleRtcStatsReport = nil }
        ga.setRtcStatsInterval(millis: 120)
        func speak(_ phrase: SpeechFixture) async throws {
            ga.setOutgoingAudioMuted(false)
            gb.setOutgoingAudioMuted(false)
            try await Task.sleep(for: .seconds(Int(env["SEREIN_SPEECH_SECONDS"] ?? "") ?? 7))
            ga.setOutgoingAudioMuted(true)
            gb.setOutgoingAudioMuted(true)
            if dred, let proxy {
                await LoopbackCallTests.wait(3) { swiftStats.contains { ($0["sereinDredRecoveredSamples"] as? Int ?? 0) > 0 } }
                let recovered = swiftStats.compactMap { $0["sereinDredRecoveredSamples"] as? Int }.max() ?? 0
                print("SFU DRED recovered", recovered, "samples, dropped audio packets", proxy.audioLoss)
                #expect(recovered > 0)
                #expect(proxy.audioLoss.allSatisfy { $0 >= 2 })
            }
            try phrase.verify(route: link ? "Signal SFU call link" : "Signal SFU group")
        }
        var previousA: UInt32?
        for rejoined in reference || link ? [false] : [false,true] {
            await LoopbackCallTests.wait(16) { ga.localDeviceState.joinState == .joined && gb.localDeviceState.joinState == .joined }
            try #require(ga.localDeviceState.joinState == .joined && gb.localDeviceState.joinState == .joined,
                         "join states \(ga.localDeviceState) / \(gb.localDeviceState), ends \(oa.ended) \(ob.ended)")
            let aid = try #require(ga.localDeviceState.demuxId), bid = try #require(gb.localDeviceState.demuxId)
            #expect(previousA != aid)
            await LoopbackCallTests.wait(12) {
                ga.remoteDeviceStates?.first { $0.demuxId == bid }?.mediaKeysReceived == true &&
                gb.remoteDeviceStates?.first { $0.demuxId == aid }?.mediaKeysReceived == true
            }
            try #require(ga.remoteDeviceStates?.contains { $0.demuxId == bid && $0.userId == bUser.userId && $0.mediaKeysReceived } == true,
                         "Swift roster \(String(describing:ga.remoteDeviceStates)); native roster \(String(describing:gb.remoteDeviceStates))")
            try #require(gb.remoteDeviceStates?.contains { $0.demuxId == aid && $0.userId == aUser.userId && $0.mediaKeysReceived } == true,
                         "Native roster \(String(describing:gb.remoteDeviceStates))")
            if dred, let phrase { try await speak(phrase); break }
            let requestedLayers = ProcessInfo.processInfo.environment["SEREIN_TEST_VIDEO_LAYERS"]
            let exerciseLayers = requestedLayers == "1" || requestedLayers == "3"
            let w = requestedLayers == "3" ? 1280 : exerciseLayers ? 640 : 160
            let h = requestedLayers == "3" ? 720 : exerciseLayers ? 360 : 96
            let width = max(w, 320), height = max(h, 240)
            ga.requestVideo([.init(demuxId:bid,width:width,height:height)],activeSpeakerHeight:height)
            gb.requestVideo([.init(demuxId:aid,width:width,height:height)],activeSpeakerHeight:height)
            ga.setOutgoingVideoMuted(false)
            gb.setOutgoingVideoMuted(false)
            for inverted in [false,true] {
                let swiftFrame = image(w,h,inverted:inverted), nativeFrame = image(w,h,inverted:!inverted)
                ga.setOutgoingVideoIsScreenShare(inverted)
                var gotA = false, gotB = false, maxA = 0, maxB = 0, buf = Array(repeating:UInt8(0),count:w*h*4)
                let deadline = ContinuousClock.now + .seconds(exerciseLayers ? 24 : 12)
                while ContinuousClock.now < deadline, !(gotA && gotB && (!inverted || proxy?.repairedBothDirections != false)) {
                    _ = ga.sendVideoFrame(width:w,height:h,format:.i420,buffer:swiftFrame)
                    _ = gb.sendVideoFrame(width:w,height:h,format:.i420,buffer:nativeFrame)
                    try await Task.sleep(for:.milliseconds(50))
                    if let f = ga.receiveVideoFrame(demuxId:bid,into:&buf,maxWidth:w,maxHeight:h), matches(buf,f,inverted:!inverted) {
                        maxA = max(maxA, f.height)
                        gotA = !exerciseLayers || maxA >= 180
                    }
                    if let f = gb.receiveVideoFrame(demuxId:aid,into:&buf,maxWidth:w,maxHeight:h), matches(buf,f,inverted:inverted) {
                        maxB = max(maxB, f.height)
                        gotB = !exerciseLayers || maxB >= h
                    }
                }
                try #require(gotA && gotB, "real SFU, rejoined=\(rejoined), inverted=\(inverted), native→Swift=\(gotA) at \(maxA)p, Swift→native=\(gotB) at \(maxB)p, receiver=\(nativeVideoStats)")
            }
            if !rejoined {
                if !reference {
                    await LoopbackCallTests.wait(3) {
                        swiftStats.contains { $0["kind"] as? String == "video" && ($0["packetsSent"] as? Int ?? 0) > 0 }
                        && swiftStats.contains { $0["kind"] as? String == "video" && ($0["packetsReceived"] as? Int ?? 0) > 0 }
                    }
                    #expect(swiftStats.contains { $0["type"] as? String == "candidate-pair" && $0["nominated"] as? Bool == true })
                    #expect(swiftStats.contains { $0["ssrc"] as? UInt32 == aid + (swiftSvc == nil ? 2 : 8) && ($0["packetsSent"] as? Int ?? 0) > 0 })
                    #expect(swiftStats.contains { $0["kind"] as? String == "video" && ($0["packetsReceived"] as? Int ?? 0) > 0 })
                    }
                    if proxy != nil {
                        await LoopbackCallTests.wait(3) {
                            swiftStats.contains { ($0["retransmittedPacketsSent"] as? Int ?? 0) > 0 }
                                && swiftStats.contains { ($0["retransmittedPacketsReceived"] as? Int ?? 0) > 0 }
                        }
                        #expect(swiftStats.contains { ($0["retransmittedPacketsSent"] as? Int ?? 0) > 0 })
                        #expect(swiftStats.contains { ($0["retransmittedPacketsReceived"] as? Int ?? 0) > 0 })
                }
                if compareStats {
                    await LoopbackCallTests.wait(4) {
                        nativeStats.contains { ($0["framesDecoded"] as? Int ?? 0) > 0 }
                            && swiftStats.contains { ($0["framesRendered"] as? Int ?? 0) > 0 }
                    }
                    for (backend, records) in [("Swift", swiftStats), ("RingRTC", nativeStats)] {
                        let inbound = try #require(records.first { ($0["framesDecoded"] as? Int ?? 0) > 0 })
                        let outbound = try #require(records.first { ($0["framesEncoded"] as? Int ?? 0) > 0 })
                        for stream in [inbound,outbound] {
                            let codec = try #require(records.first { $0["id"] as? String == stream["codecId"] as? String })
                            #expect(["video/VP8","video/VP9"].contains(codec["mimeType"] as? String ?? ""))
                            #expect(codec["clockRate"] as? Int == 90_000)
                            #expect((stream["frameWidth"] as? Int ?? 0) > 0 && (stream["frameHeight"] as? Int ?? 0) > 0)
                        }
                        let pair = try #require(records.first { $0["type"] as? String == "candidate-pair" && $0["nominated"] as? Bool == true })
                        for (key, type) in [("localCandidateId", "local-candidate"), ("remoteCandidateId", "remote-candidate")] {
                            let candidate = try #require(pair[key] as? String)
                            #expect(records.contains { $0["id"] as? String == candidate && $0["type"] as? String == type })
                        }
                        let dropped = try #require(inbound["framesDropped"] as? Int)
                        #expect(dropped >= 0)
                        #expect((pair["currentRoundTripTime"] as? Double ?? -1) >= 0)
                        #expect((pair["currentRoundTripTime"] as? Double ?? 5) < 5)
                        print("Measured RTC", backend, "decoded", inbound["framesDecoded"] ?? "", "dropped", dropped,
                              "width", inbound["frameWidth"] ?? "", "height", inbound["frameHeight"] ?? "", "RTT", pair["currentRoundTripTime"] ?? "")
                    }
                }
                if let phrase { try await speak(phrase) }
                ga.setRtcStatsInterval(millis: 0)
                ga.react("🍋"); gb.react("🌊"); ga.raiseHand(true)
                await LoopbackCallTests.wait(8) {
                    oa.reactions.contains { $0.demuxId == bid && $0.value == "🌊" } &&
                    ob.reactions.contains { $0.demuxId == aid && $0.value == "🍋" } && ob.hands.contains(aid) &&
                    gb.remoteDeviceStates?.first { $0.demuxId == aid }?.sharingScreen == true
                }
                #expect(oa.reactions.contains { $0.demuxId == bid && $0.value == "🌊" })
                #expect(ob.reactions.contains { $0.demuxId == aid && $0.value == "🍋" })
                #expect(ob.hands.contains(aid))
                #expect(gb.remoteDeviceStates?.first { $0.demuxId == aid }?.sharingScreen == true)
                if !reference && !link {
                    previousA = aid
                    ga.leave()
                    await LoopbackCallTests.wait(8) { ga.localDeviceState.joinState == .notJoined && gb.remoteDeviceStates?.contains { $0.demuxId == aid } != true }
                    try #require(ga.localDeviceState.joinState == .notJoined)
                    ga.join()
                }
            }
        }
        if videoLoss, let proxy {
            print("Video repair directions", proxy.evidence)
            #expect(proxy.repairedBothDirections, "Expected bidirectional SFU RTX across the induced loss: \(proxy.evidence)")
        }
        ga.disconnect(); gb.disconnect()
        await LoopbackCallTests.wait(8) { !oa.ended.isEmpty && !ob.ended.isEmpty }
        #expect(!oa.ended.isEmpty && !ob.ended.isEmpty)
        if compareStats {
            for (backend, observer) in [("Swift", oa), ("RingRTC", ob)] {
                let summary = try #require(observer.summaries.last)
                let raw = try #require(summary.rawStats)
                #expect(!raw.isEmpty && raw.count <= 65_536)
                let text = try #require(summary.rawStatsText)
                let json = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String:Any])
                let stats = try #require(json["stats_sets"] as? [[String:Any]])
                let received = stats.flatMap { $0["video_recv_stats"] as? [[String:Any]] ?? [] }
                #expect(received.contains { ($0["bitrate"] as? Double ?? 0) > 0 && ($0["width"] as? Int ?? 0) > 0 })
                let details = try #require(json["group_call_summary"] as? [String:Any])
                let streams = try #require(details["stream_summaries"] as? [String:Any])
                let videos = try #require(streams["video_send_stream_summaries"] as? [[String:Any]])
                #expect(videos.contains { [8,9].contains($0["video_codec"] as? Int ?? 0) })
                print("Group summary", backend, "bytes", raw.count, "intervals", stats.count, "video receive rows", received.count)
            }
        }
    }

    private func image(_ w: Int, _ h: Int,inverted: Bool) -> [UInt8] {
        (0..<w*h).map { (($0 % w >= w/2) != inverted) ? UInt8(180) : UInt8(40) } + Array(repeating:128,count:w*h/2)
    }
    private func matches(_ bytes: [UInt8],_ f:(width:Int,height:Int),inverted: Bool) -> Bool {
        let row = f.width*(f.height/2)
        let delta = Int(bytes[(row + 3*f.width/4)*4]) - Int(bytes[(row + f.width/4)*4])
        return inverted ? delta < -80 : delta > 80
    }
}
