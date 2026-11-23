import Foundation
import SignalRingRTC
import SwiftCalling

extension GroupRoom {
    func senderID(_ device: JSONValue) -> Data? {
        let aci = device["userId"].data ?? device["opaqueUserId"].string.flatMap { resolved[$0] }
        return aci?.count == 16 ? aci : nil
    }

    func applyResolved(_ fields: Fields) async {
        guard link, let rows = fields["members"]?.array, rows.count <= 4096 else { return }
        for row in rows {
            guard let opaque = row["opaqueUserId"].string, outstandingOpaque.remove(opaque) != nil else { continue }
            if let aci = row["userId"].data, aci.count == 16 { resolved[opaque] = aci } else { invalidOpaque.insert(opaque) }
        }
        if let lastPeek { await applyPeek(lastPeek) }
    }

    func refreshMembers() async {
        // Recheck already-rendered members against the new group membership before
        // sending any more keys. A fresh peek maps previously unknown members.
        poll?.cancel()
        poll = nil
        if let lastPeek { await applyPeek(lastPeek) }
        peek()
    }

    func applyPeek(_ info: JSONValue) async {
        lastPeek = info
        guard case .object(var view) = info else { return }
        let devices = info["devices"].array, pending = info["pendingDevices"].array
        let members = Set(fields["members"]?.array.compactMap { $0["userId"].data } ?? [])
        let opaqueIDs = Set((devices + pending).compactMap { $0["opaqueUserId"].string } + (info["opaqueCreator"].string.map { [$0] } ?? []))
        if link {
            resolved = resolved.filter { opaqueIDs.contains($0.key) }
            outstandingOpaque.formIntersection(opaqueIDs)
            invalidOpaque.formIntersection(opaqueIDs)
            let missing = opaqueIDs.subtracting(resolved.keys).subtracting(outstandingOpaque).subtracting(invalidOpaque).filter { $0.utf8.count <= 512 }
            if !missing.isEmpty {
                outstandingOpaque.formUnion(missing)
                event("resolveCallLinkMembers", ["ciphertexts": .array(missing.sorted().map(JSONValue.string))])
            }
        }
        func aci(_ device: JSONValue) -> Data? {
            guard let user = senderID(device), link || members.contains(user) else { return nil }
            return user
        }
        creator = info["creator"].data ?? info["opaqueCreator"].string.flatMap { resolved[$0] }
        view["creator"] = .bytes(creator)
        view["devices"] = .array(devices.map { .object(["demuxId": $0["demuxId"], "userId": .bytes(aci($0))]) })
        var pendingSeen = Set<Data>()
        pendingDevices.removeAll()
        view["pendingUsers"] = .array(pending.compactMap { d in
            guard let user = aci(d), let id = d["demuxId"].uint64.flatMap(UInt32.init(exactly:)) else { return nil }
            pendingDevices[user, default: []].insert(id)
            return pendingSeen.insert(user).inserted ? .bytes(user) : nil
        })
        for key in ["opaqueCreator", "opaquePending", "pendingDevices"] { view.removeValue(forKey: key) }
        let displayed = JSONValue.object(view)
        if displayed != notifiedPeek {
            notifiedPeek = displayed
            event("handlePeekChanged", ["info": displayed])
        }
        guard let demux, let crypto else { return }
        if let era = info["eraId"].string, let joinedEra = self.era, era != joinedEra {
            await end(.serverExplicitlyDisconnected)
            return
        }
        let before = remotes.compactMapValues { $0["userId"]?.data }
        var now: [UInt32: Data] = [:]
        for device in devices {
            guard let id = device["demuxId"].uint64.flatMap(UInt32.init(exactly:)), id > 0, id & 15 == 0 else { continue }
            if id == demux { continue }
            if let user = aci(device) { now[id] = user }
        }
        do { try crypto.setMembers(now.compactMapValues(GroupIdentity.uuid)) } catch { await end(.internalFailure); return }
        let removed = !Set(before.values).isSubset(of: Set(now.values))
        let added = now.filter { before[$0.key] != $0.value }
        for id in before.keys where before[id] != now[id] {
            remotes[id] = nil
            lastDeviceTime[id] = nil
            seenMuteRequests[id] = nil
            muteAttribution[id] = nil
        }
        for (id, user) in added {
            remotes[id] = ["demuxId": .int(Int64(id)), "userId": .bytes(user), "mediaKeysReceived": .bool(false),
                           "addedTime": .int(Int64(Date().timeIntervalSince1970 * 1000))]
        }
        if !added.isEmpty { crypto.advance() }
        if removed { crypto.scheduleRotation() }
        let pendingKeys = waitingKeys
        waitingKeys.removeAll()
        for (sender, key) in pendingKeys {
            if now[key.demux] == sender { install(key, sender: sender) }
            else if now[key.demux] == nil && (link || members.contains(sender)) { waitingKeys.append((sender, key)) }
        }
        if before != now {
            if !now.isEmpty { cancellableRingID = nil; timeline.hadParticipants = true }
            reportDevices()
            await media?.setRemoteDevices(Set(now.keys))
        }
        if !admitted && devices.contains(where: { $0["demuxId"].uint64 == UInt64(demux) }) {
            admitted = true
            setJoin(.joined)
            await enableMedia()
            sendKeys()
        } else if removed || !added.isEmpty { sendKeys() }
        ringIfReady()
    }

    func reportDevices() {
        event("handleRemoteDevicesChanged", ["remoteDeviceStates": .array(remotes.keys.sorted().compactMap { remotes[$0].map(JSONValue.object) })])
    }

    func sendKeys() {
        guard let crypto else { return }
        sendKey(crypto.sendingKey)
        if let pending = crypto.pendingKey { sendKey(pending) }
    }

    func sendKey(_ key: GroupFrameCrypto.SendingKey) {
        guard admitted, let demux else { return }
        var message = GroupDeviceMessage()
        message.group = group
        message.key = .init(demux: demux, ratchet: key.ratchet, secret: key.secret)
        let payload = JSONValue.bytes(message.encode(signaling: true))
        var users = Set(remotes.compactMap { $0.value["userId"]?.data })
        let includeSelf = me.flatMap { users.remove($0) }
        if link && (sawLinkEndorsements || fields["scopedLinkSignaling"]?.bool == true) && !users.isEmpty {
            event("sendCallLinkMessage", ["recipientIds": .array(users.sorted { $0.lexicographicallyPrecedes($1) }.map { .bytes($0) }),
                                          "message": payload, "urgency": .int(0)])
            users.removeAll()
        } else if !link && users.count > 1 {
            event("sendCallMessageToGroup", ["groupId": .bytes(group), "message": payload, "urgency": .int(0),
                                             "overrideRecipients": .array(users.map { .bytes($0) })])
            users.removeAll()
        }
        if let includeSelf { users.insert(includeSelf) }
        for user in users { event("sendCallMessage", ["recipientUuid": .bytes(user), "message": payload, "urgency": .int(0)]) }
    }

    func signaling(_ fields: Fields) async {
        guard let sender = fields["remoteUserId"]?.data, sender.count == 16, let bytes = fields["data"]?.data,
              let message = try? GroupDeviceMessage.fromSignaling(bytes), message.group == group else { return }
        if let key = message.key {
            if remotes[key.demux]?["userId"]?.data == sender {
                install(key, sender: sender)
                reportDevices()
            } else if waitingKeys.count < 128 && !waitingKeys.contains(where: { $0.sender == sender && $0.key.secret == key.secret && $0.key.demux == key.demux }) {
                waitingKeys.append((sender, key))
                peek()
            }
        }
        if message.leaving { peek() }
    }

    func install(_ key: GroupDeviceMessage.Key, sender: Data) {
        guard let uuid = GroupIdentity.uuid(sender), let crypto, remotes[key.demux]?["userId"]?.data == sender else { return }
        do {
            try crypto.install(secret: key.secret, ratchet: key.ratchet, demuxID: key.demux, sender: uuid)
            remotes[key.demux]?["mediaKeysReceived"] = .bool(true)
        } catch {}
    }

    func ringIfReady() {
        guard !link, requestedRing, !sentRing, admitted, let me, creator == me, let era else { return }
        sentRing = true
        let id = Int64(bitPattern: callIdFromEra(era))
        cancellableRingID = remotes.isEmpty ? id : nil
        sendRing(.ring, id: id)
    }

    func sendRing(_ intention: GroupRingMessage.Intention, id: Int64) {
        let ring = GroupRingMessage(group: group, id: id, kind: .intention(intention))
        event("sendCallMessageToGroup", ["groupId": .bytes(group), "message": .bytes(ring.encode()), "urgency": .int(1), "overrideRecipients": .array([])])
    }
}
