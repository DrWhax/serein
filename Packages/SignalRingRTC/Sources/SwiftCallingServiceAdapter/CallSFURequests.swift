import CryptoKit
import Foundation
import SignalRingRTC
import SwiftCalling

/// SFU operations whose HTTP transport is supplied by the app. HTTP IDs span all
/// operations while the app uses independent ID sequences for its three result types.
struct CallSFURequests {
    private enum Kind: String {
        case groupPeek = "peekGroupCall", linkPeek = "peekCallLinkCall", read = "readCallLink"
        case create = "createCallLink", update = "updateCallLink", delete = "deleteCallLink"

        var isPeek: Bool { self == .groupPeek || self == .linkPeek }
        var resultEvent: String {
            if isPeek { return "handlePeekResponse" }
            return self == .delete ? "handleEmptyResponse" : "handleCallLinkResponse"
        }
    }

    private struct Operation {
        let id: UInt32
        let kind: Kind
        let root: CallLinkRootKey?
        let members: [String: Data]

        func result(_ status: Int, value: JSONValue = .null) -> JSONValue {
            var event: [String: JSONValue] = ["type": .string(kind.resultEvent), "requestId": .int(Int64(id)), "status": .int(Int64(status))]
            if !value.isNull { event[kind.isPeek ? "info" : "state"] = value }
            return .object(event)
        }
    }

    private var nextID: UInt32 = 0
    private var pending: [UInt32: Operation] = [:]

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        return String(decoding: bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
    }

    private static func memberMap(_ rows: [JSONValue]) throws -> [String: Data] {
        guard rows.count <= 4096 else { throw RingRTCError.invalidResponse }
        var members: [String: Data] = [:]
        for row in rows {
            guard let cipher = row["userIdCipherText"].data, let aci = row["userId"].data else { throw RingRTCError.invalidResponse }
            members[hex(SHA256.hash(data: cipher))] = aci
        }
        return members
    }

    mutating func start(_ command: String, _ fields: [String: JSONValue]) throws -> JSONValue {
        guard let kind = Kind(rawValue: command), let id = fields["requestId"]?.uint64.flatMap(UInt32.init(exactly:)),
              let base = fields["sfuUrl"]?.string, base.utf8.count <= 8192 else { throw RingRTCError.invalidResponse }
        let root: CallLinkRootKey?
        var headers: [String: JSONValue] = [:]
        var members: [String: Data] = [:]
        if kind == .groupPeek {
            root = nil
            guard let proof = fields["membershipProof"]?.data, let token = String(data: proof, encoding: .utf8) else {
                return Operation(id: id, kind: kind, root: nil, members: [:]).result(601)
            }
            let user = token.prefix { $0 != ":" }
            headers["Authorization"] = .string("Basic " + Data((user + ":" + token).utf8).base64EncodedString())
            members = try Self.memberMap(fields["members"]?.array ?? [])
        } else {
            guard let bytes = fields["rootKey"]?.data, let presentation = fields[kind == .create ? "createPresentation" : "authPresentation"]?.data else {
                throw RingRTCError.invalidResponse
            }
            let key = try CallLinkRootKey.fromBytes(bytes)
            root = key
            if (kind == .create) != key.awaitingEpoch {
                return Operation(id: id, kind: kind, root: root, members: [:]).result(kind == .create ? 705 : 704)
            }
            headers["Authorization"] = .string((kind == .create ? "Bearer create." : "Bearer auth.") + presentation.base64EncodedString())
            headers["X-Room-Id"] = .string(Self.hex(try key.deriveRoomId()))
            headers["X-Epoch"] = key.epoch.map { .string(String($0)) }
        }
        let op = Operation(id: id, kind: kind, root: root, members: members)
        guard pending.count < 64 else { return op.result(602) }
        var body = JSONValue.null
        var method = HttpMethod.get
        if !kind.isPeek { headers["Content-Type"] = .string("application/json") }
        if [.create, .update, .delete].contains(kind) {
            guard let admin = fields["adminPasskey"]?.data, let root else { throw RingRTCError.invalidResponse }
            var object: [String: JSONValue] = ["adminPasskey": .bytes(admin)]
            if kind == .create {
                guard let params = fields["publicZkparams"]?.data else { throw RingRTCError.invalidResponse }
                object["zkparams"] = .bytes(params)
            }
            if let restriction = fields[kind == .create ? "restrictions" : "newRestrictions"]?.int {
                if restriction == 0 { object["restrictions"] = .string("none") }
                if restriction == 1 { object["restrictions"] = .string("adminApproval") }
            }
            if kind == .update {
                if let name = fields["newName"]?.string { object["name"] = .bytes(try CallLinkNameCipher(rootKey: root.bytes).seal(name)) }
                if let revoked = fields["newRevoked"]?.bool { object["revoked"] = .bool(revoked) }
            }
            body = .bytes(try JSONEncoder().encode(JSONValue.object(object)))
            method = kind == .delete ? .delete : .put
        }
        repeat { nextID = (nextID &+ 1) & 0x7fff_ffff } while pending[nextID] != nil
        pending[nextID] = op
        let url = base.reversed().drop(while: { $0 == "/" }).reversed()
        let path = kind.isPeek ? "/v2/conference/participants" : "/v1/call-link"
        return .object(["type": .string("sendHttpRequest"), "requestId": .int(Int64(nextID)), "url": .string(String(url) + path),
                        "method": .int(Int64(method.rawValue)), "headers": .object(headers), "body": body])
    }

    private struct LinkState: Decodable {
        let name: String
        let restrictions: String
        let revoked: Bool
        let expiration: UInt64
        let epoch: UInt32?

        func event(root: CallLinkRootKey) throws -> JSONValue {
            guard expiration <= UInt64(Int64.max / 1000) else { throw RingRTCError.invalidResponse }
            let plain = Data(base64Encoded: name).flatMap { try? CallLinkNameCipher(rootKey: root.bytes).open($0) }
            return .object(["name": .string(plain ?? ""), "revoked": .bool(revoked), "rootKey": .bytes(root.bytes),
                            "expirationMillis": .int(Int64(expiration) * 1000),
                            "rawRestrictions": .int(restrictions == "none" ? 0 : restrictions == "adminApproval" ? 1 : -1)])
        }
    }

    private struct Peek: Decodable {
        struct Device: Decodable {
            let demuxId: UInt32
            let opaqueUserId: String?
            let requiresSvc: Bool?
        }
        let participants: [Device]
        let pendingClients: [Device]?
        let creator: String?
        let conferenceId: String?
        let maxDevices: UInt32?
        let callLinkState: LinkState?

        func event(members: [String: Data], root: CallLinkRootKey?) throws -> JSONValue {
            let pending = pendingClients ?? []
            guard participants.count + pending.count <= 4096 else { throw RingRTCError.invalidResponse }
            var seen = Set<Data>()
            var info: [String: JSONValue] = [
                "devices": .array(participants.map { d in
                    .object(["demuxId": .int(Int64(d.demuxId)), "userId": .bytes(d.opaqueUserId.flatMap { members[$0] }),
                             "opaqueUserId": root == nil ? .null : d.opaqueUserId.map(JSONValue.string) ?? .null])
                }),
                "deviceCountIncludingPendingDevices": .int(Int64(participants.count + pending.count)),
                "deviceCountExcludingPendingDevices": .int(Int64(participants.count)),
                "pendingDevices": .array(pending.map { d in
                    .object(["demuxId": .int(Int64(d.demuxId)), "userId": .bytes(d.opaqueUserId.flatMap { members[$0] }),
                             "opaqueUserId": root == nil ? .null : d.opaqueUserId.map(JSONValue.string) ?? .null])
                }),
                "pendingUsers": .array(pending.compactMap { d in
                    guard let aci = d.opaqueUserId.flatMap({ members[$0] }), seen.insert(aci).inserted else { return nil }
                    return .bytes(aci)
                }),
                "creator": .bytes(creator.flatMap { members[$0] }),
            ]
            if root != nil {
                info["opaquePending"] = .array(pending.compactMap { $0.opaqueUserId.map(JSONValue.string) })
                info["opaqueCreator"] = creator.map(JSONValue.string)
            }
            info["eraId"] = conferenceId.map(JSONValue.string)
            info["maxDevices"] = maxDevices.map { .int(Int64($0)) }
            if let state = callLinkState, let root = root { info["callLinkState"] = try state.event(root: root) }
            return .object(info)
        }
    }

    static func inCallPeek(_ packet: GroupSFUUpdate.Peek, members: [JSONValue], rootKey: Data?) throws -> JSONValue {
        func device(_ value: GroupSFUUpdate.Device) throws -> Peek.Device {
            guard let id = value.demuxID else { throw RingRTCError.invalidResponse }
            return .init(demuxId: id, opaqueUserId: value.opaqueUserID, requiresSvc: value.requiresSVC)
        }
        let link = try packet.linkState.map { state in
            guard let name = state.encryptedName, let restriction = state.restrictions,
                  let revoked = state.revoked, let expiry = state.expiration else { throw RingRTCError.invalidResponse }
            return LinkState(name: name, restrictions: restriction == 0 ? "none" : restriction == 1 ? "adminApproval" : "unknown",
                             revoked: revoked, expiration: expiry, epoch: nil)
        }
        let value = try Peek(participants: packet.devices.map(device), pendingClients: packet.pendingDevices.map(device), creator: packet.creator,
                             conferenceId: packet.eraID, maxDevices: packet.maxDevices, callLinkState: link)
        return try value.event(members: memberMap(members), root: rootKey.map(CallLinkRootKey.fromBytes))
    }

    mutating func complete(_ command: String, _ fields: [String: JSONValue]) -> JSONValue? {
        guard let id = fields["requestId"]?.uint64.flatMap(UInt32.init(exactly:)), let op = pending.removeValue(forKey: id) else { return nil }
        guard command == "receivedHttpResponse", let status = fields["statusCode"]?.int, let data = fields["body"]?.data else { return op.result(602) }
        guard data.count <= 1 << 20 else { return op.result(702) }
        let decoder = JSONDecoder()
        if op.kind.isPeek && status == 404 {
            if data.isEmpty { return op.result(200, value: .object([:])) }
            let reason = (try? decoder.decode(JSONValue.self, from: data))?["reason"].string
            return op.result(reason == "expired" ? 703 : reason == "invalid" ? 704 : status)
        }
        guard (200..<300).contains(status) else { return op.result(status) }
        do {
            if op.kind.isPeek { return try op.result(200, value: decoder.decode(Peek.self, from: data).event(members: op.members, root: op.root)) }
            if op.kind == .delete {
                guard case .object = try decoder.decode(JSONValue.self, from: data) else { return op.result(702) }
                return op.result(200)
            }
            let state = try decoder.decode(LinkState.self, from: data)
            guard let root = op.root else { return op.result(702) }
            return try op.result(200, value: state.event(root: root.issued(epoch: state.epoch)))
        } catch { return op.result(702) }
    }
}
