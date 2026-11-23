import Foundation
import SignalRingRTC
import SwiftCalling

extension GroupRoom {
    private func send(_ command: GroupSFUCommand) async {
        guard joinedTransport, let payloads = try? control.send(command) else { return }
        for bytes in payloads { try? await media?.sendToSFU(bytes) }
    }

    func mediaCommand(_ name: String, _ fields: Fields) async {
        switch name {
        case "setOutgoingAudioMuted", "setOutgoingAudioMutedRemotely":
            guard let muted = name == "setOutgoingAudioMutedRemotely" ? true : fields["muted"]?.bool else { return }
            if !muted || heartbeat.audioMuted != true {
                heartbeat.mutedBy = muted ? fields["muteSource"]?.uint64.flatMap(UInt32.init(exactly:)) : nil
            }
            heartbeat.audioMuted = muted
            await media?.setAudioEnabled(joinedTransport && admitted && !muted)
            await sendHeartbeat()
        case "setOutgoingVideoMuted":
            guard let muted = fields["muted"]?.bool else { return }
            heartbeat.videoMuted = muted
            await media?.setVideoEnabled(joinedTransport && admitted && !muted)
            await sendHeartbeat()
        case "setPresenting", "setOutgoingGroupCallVideoIsScreenShare":
            if name == "setPresenting" { heartbeat.presenting = fields["presenting"]?.bool }
            else {
                heartbeat.sharingScreen = fields["isScreenshare"]?.bool
                media?.setScreenSharing(heartbeat.sharingScreen == true)
            }
            await sendHeartbeat()
        case "groupReact", "sendRemoteMuteRequest":
            guard admitted && joinedTransport else { return }
            var message = GroupDeviceMessage()
            if name == "groupReact" {
                guard let value = fields["reaction"]?.string, !value.isEmpty, value.utf8.count <= 256 else { return }
                message.reaction = value
            } else {
                guard let target = fields["muteTarget"]?.uint64.flatMap(UInt32.init(exactly:)), remotes[target] != nil else { return }
                message.muteTarget = target
                if let demux, remotes[target]?["audioMuted"]?.bool == false { seenMuteRequests[target, default: []].insert(demux) }
            }
            try? await media?.sendToDevices(message.encode())
        case "groupRaiseHand":
            if let raised = fields["raise"]?.bool, admitted { await send(.raiseHand(raised)) }
        case "groupRing":
            requestedRing = true
            ringIfReady()
        case "resendMediaKeys": sendKeys()
        case "setRtcStatsInterval":
            guard let ms = fields["intervalMillis"]?.uint64 else { return }
            statsInterval = ms
            await media?.setStatsInterval(ms)
        case "requestVideo", "setDataMode":
            if name == "requestVideo" {
                guard let rows = fields["resolutions"]?.array, rows.count <= 1024 else { return }
                requests = rows.compactMap { row in
                    guard let id = row["demuxId"].uint64.flatMap(UInt32.init(exactly:)), let h = row["height"].uint64.flatMap(UInt32.init(exactly:)) else { return nil }
                    let w = row["width"].uint64.flatMap(UInt32.init(exactly:)) ?? h
                    return .init(demuxID: id, height: min(w, h))
                }
                activeHeight = fields["activeSpeakerHeight"]?.uint64.flatMap(UInt32.init(exactly:))
            } else if let mode = fields["dataMode"]?.int.flatMap(DataMode.init(rawValue:)) { localDataMode = mode }
            await media?.setLowDataMode(localDataMode == .low)
            await requestVideo()
        case "approveUser", "denyUser":
            guard link, self.fields["adminPasskey"]?.data != nil, let user = fields["otherUserId"]?.data else { return }
            for id in pendingDevices[user] ?? [] { await send(name == "approveUser" ? .approve(id) : .deny(id)) }
        case "removeClient", "blockClient":
            guard link, self.fields["adminPasskey"]?.data != nil, let id = fields["otherDemuxId"]?.uint64.flatMap(UInt32.init(exactly:)),
                  remotes[id] != nil else { return }
            await send(name == "removeClient" ? .remove(id) : .block(id))
        default: break
        }
    }

    func requestVideo() async {
        guard joinedTransport, let requests else { return }
        await send(.videoRequest(requests, maxKbps: localDataMode == .low ? 500 : nil, activeSpeakerHeight: activeHeight))
    }

    func handleDevice(_ message: GroupDeviceMessage, demux source: UInt32, timestamp: UInt32) async {
        guard remotes[source] != nil, admitted, message.group == nil || message.group == group else { return }
        if let value = message.reaction {
            event("handleReactions", ["reactions": .array([.object(["demuxId": .int(Int64(source)), "value": .string(value)])])])
        }
        if let target = message.muteTarget {
            if target == demux { event("onRemoteMute", ["demuxId": .int(Int64(source))]) }
            else if remotes[target] != nil && remotes[target]?["audioMuted"]?.bool != true { seenMuteRequests[target, default: []].insert(source) }
        }
        if message.leaving { peek() }
        let flags = [("audioMuted", message.audioMuted), ("videoMuted", message.videoMuted), ("presenting", message.presenting), ("sharingScreen", message.sharingScreen)]
        guard flags.contains(where: { $0.1 != nil }) else { return }
        if let previous = lastDeviceTime[source], Int32(bitPattern: timestamp &- previous) <= 0 { return }
        lastDeviceTime[source] = timestamp
        if message.audioMuted == false && remotes[source]?["audioMuted"]?.bool != false {
            seenMuteRequests[source] = nil
        }
        if message.audioMuted == true, let muter = message.mutedBy, muteAttribution[source] != muter, seenMuteRequests[source]?.contains(muter) == true {
            event("onObservedRemoteMute", ["sourceDemuxId": .int(Int64(muter)), "targetDemuxId": .int(Int64(source))])
        }
        muteAttribution[source] = message.mutedBy
        var changed = false
        for (key, value) in flags {
            if let value, remotes[source]?[key]?.bool != value {
                remotes[source]?[key] = .bool(value)
                changed = true
            }
        }
        if changed { reportDevices() }
    }

    func handleServer(_ update: GroupSFUUpdate) async {
        if link, let response = update.endorsements {
            sawLinkEndorsements = true
            event("receiveCallLinkEndorsements", ["serialized": .bytes(response.serialized),
                                                  "memberCiphertexts": .array(response.memberCiphertexts.map { .bytes($0) })])
        }
        if let address = update.serverAddress { await media?.setServerAddress(address) }
        if let height = update.videoHeight { await media?.setMaxSendHeight(height) }
        if update.removed { await end(admitted ? .removedFromCall : .deniedRequestToJoinCall); return }
        if let roster = update.peek {
            if lastWirePeek.map({ Int32(bitPattern: update.timestamp &- $0) > 0 }) ?? true {
                if let info = try? CallSFURequests.inCallPeek(roster, members: fields["members"]?.array ?? [], rootKey: fields["rootKey"]?.data) {
                    // An earlier HTTP request can complete after a removal or
                    // approval arrives over the authenticated control stream.
                    pollNumber &+= 1
                    poll?.cancel()
                    poll = nil
                    lastWirePeek = update.timestamp
                    lastPoll = .now
                    await applyPeek(info)
                } else { peek() }
            }
        } else if update.rosterChanged { peek() }
        if let hands = update.raisedHands { event("handleRaisedHands", ["raisedHands": .array(hands.demuxIDs.map { .int(Int64($0)) })]) }
        if let id = update.speaker, remotes[id] != nil {
            remotes[id]?["speakerTime"] = .int(Int64(Date().timeIntervalSince1970 * 1000))
            reportDevices()
        }
        if let current = update.currentDevices {
            let forwarded = Set(current.withVideo)
            var changed = false
            for id in Array(remotes.keys) {
                let visible = forwarded.contains(id)
                if remotes[id]?["forwardingVideo"]?.bool != visible { remotes[id]?["forwardingVideo"] = .bool(visible); changed = true }
            }
            if changed { reportDevices() }
        }
    }
}
