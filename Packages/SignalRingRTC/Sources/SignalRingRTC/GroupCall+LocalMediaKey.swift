// QA and debug builds only (Package.swift `testPeer`; SEREIN_QA_CALL_PEER=1 Tools/build-app.sh).
#if SEREIN_CALL_TEST_PEER
import CallingWire
import Foundation

extension GroupCall {
    /// The opposite endpoint is identified by its demux. Other devices previously
    /// verified for this account can remain in the room without receiving its key.
    public func hasLocalCallLinkPeer(_ peerID: UInt32, account: Data, existingDevices: Set<UInt32>) -> Bool {
        guard kind == .callLink, localDeviceState.joinState == .joined, localDeviceState.connectionState == .connected,
              let localID = localDeviceState.demuxId, localID != peerID, !existingDevices.contains(localID), !existingDevices.contains(peerID),
              let states = remoteDeviceStates, states.allSatisfy({ $0.userId == account }) else { return false }
        let remoteIDs = Set(states.map(\.demuxId))
        return remoteIDs.count == states.count && remoteIDs.contains(peerID) && remoteIDs.subtracting(existingDevices) == [peerID]
    }

    /// A paired local test endpoint may exchange exactly a sending key for this
    /// client. Reject duplicate fields and every other signaling message type.
    public func isLocalCallLinkMediaKey(_ message: Data) -> Bool {
        guard kind == .callLink, let linkRoomId, let demux = localDeviceState.demuxId, demux != 0 else { return false }
        return (try? Self.isMediaKey(message, room: linkRoomId, demux: demux)) == true
    }

    nonisolated static func isMediaKey(_ message: Data, room: Data, demux: UInt32) throws -> Bool {
        var envelope = try CallingProtoReader(message, limit: 256)
        guard let group = try envelope.next(), group.number == 1 else { return false }
        var groupRoom: Data?
        var hasKey = false
        try envelope.message(group) { field, reader in
            switch field.number {
            case 1 where groupRoom == nil:
                groupRoom = Data(try reader.bytes(field))
            case 2 where !hasKey:
                var ratchet: UInt8?, secretLength: Int?, sender: UInt32?
                try reader.message(field) { field, key in
                    switch field.number {
                    case 1 where ratchet == nil:
                        guard let value = UInt8(exactly: try key.integer(field)) else { throw CallingWireError.malformed }
                        ratchet = value
                    case 2 where secretLength == nil: secretLength = try key.bytes(field).count
                    case 3 where sender == nil: sender = try key.uint32(field)
                    default: throw CallingWireError.malformed
                    }
                }
                guard ratchet != nil, secretLength == 32, sender == demux else { throw CallingWireError.malformed }
                hasKey = true
            default: throw CallingWireError.malformed
            }
        }
        return try envelope.next() == nil && groupRoom == room && hasKey
    }
}

extension RingRTC {
    /// Feed only this pair's validated media key to the destination client.
    /// This in-memory delivery confers no incoming Signal message or ring authority.
    public func receiveLocalCallLinkMediaKey(_ message: Data, from source: GroupCall, on sender: RingRTC, to destination: GroupCall,
                                             deviceId: DeviceId, existingDevices: Set<UInt32> = []) {
        guard sender !== self, sender.groupCallByClientId[source.clientId] === source, groupCallByClientId[destination.clientId] === destination,
              let aci = selfUuid, sender.selfUuid == aci, let room = source.linkRoomId, room == destination.linkRoomId,
              !groupCallByClientId.values.contains(where: { $0 !== destination && ($0.linkRoomId == room || $0.groupId == room) }),
              source.isLocalCallLinkMediaKey(message), let sourceID = source.localDeviceState.demuxId, let destinationID = destination.localDeviceState.demuxId,
              source.hasLocalCallLinkPeer(destinationID, account: aci, existingDevices: existingDevices),
              destination.hasLocalCallLinkPeer(sourceID, account: aci, existingDevices: existingDevices) else { return }
        _ = try? run("receivedCallMessage", [
            "remoteUserId": .bytes(aci), "remoteDeviceId": .int(Int64(deviceId)), "localDeviceId": .int(Int64(deviceId)),
            "data": .bytes(message), "messageAgeSec": .int(0),
        ], generation: destination.generation)
    }
}
#endif
