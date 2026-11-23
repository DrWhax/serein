// QA and debug builds only (Package.swift `testPeer`; SEREIN_QA_CALL_PEER=1 Tools/build-app.sh).
#if SEREIN_CALL_TEST_PEER
import Foundation
import LibSignalClient
public import SignalRingRTC

public enum LocalCallLinkTestPeerError: LocalizedError {
    case alreadyRunning, joinLink, approvalRequired, otherParticipant, authentication, connection, timedOut, ended

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "A local test peer is already starting or connected."
        case .joinLink: "Join an active call link before adding a test peer."
        case .approvalRequired: "This call link needs admin approval. To test alone, use an unrestricted link or one you created."
        case .otherParticipant: "The test peer needs a call containing only your previously verified devices, with nobody waiting to join."
        case .authentication: "Signal could not authenticate the test peer for this call link."
        case .connection: "The test peer could not connect to the call."
        case .timedOut: "The test peer timed out while joining or exchanging media keys."
        case .ended: "The test peer disconnected."
        }
    }
}

extension CallingService {
    /// A fresh call-link peek resolves each admitted device's account using the
    /// room key. An empty set is a valid empty room. Unresolved or pending users
    /// cannot establish ownership of the complete roster.
    public func ownCallLinkDevices(in peek: PeekInfo) -> Set<UInt32>? {
        LocalCallLinkTestPeer.ownDevices(peek, aci: Self.uuidBytes(account.aci))
    }

    /// Join a second endpoint as this account in the current call link. Its only
    /// signaling partner is the primary device here, and it has no Messenger.
    public func startLocalCallLinkTestPeer(_ link: CallLinkRecord, endpoint: @escaping RingRTCEndpointFactory,
                                           onEnded: @escaping @MainActor () -> Void) async throws -> GroupCall {
        try Task.checkCancellation()
        guard localCallLinkTestPeer == nil else { throw LocalCallLinkTestPeerError.alreadyRunning }
        guard let primary = groupCall(for: link.roomId), primary.kind == .callLink,
              primary.localDeviceState.joinState == .joined, let primaryID = primary.localDeviceState.demuxId,
              !link.revoked, !link.deleted else { throw LocalCallLinkTestPeerError.joinLink }
        let peer = LocalCallLinkTestPeer(service: self, roomId: link.roomId, primary: primary, primaryID: primaryID, onEnded: onEnded)
        localCallLinkTestPeer = peer
        peer.prepare(link, endpoint: endpoint)
        do {
            return try await peer.waitForMedia()
        } catch {
            peer.stop(.ended)
            throw error
        }
    }

    public func stopLocalCallLinkTestPeer() { localCallLinkTestPeer?.stop(.ended) }
}

@MainActor
final class LocalCallLinkTestPeer: GroupCallObserver {
    weak var service: CallingService?
    let roomId: String
    private let primary: GroupCall
    private let primaryID: UInt32
    private var peerID: UInt32?
    private let aci: Data
    private let onEnded: @MainActor () -> Void
    private var setup: Task<Void, Never>?
    private var rtc: RingRTC?
    private(set) var call: GroupCall?
    private var requestedKeys = false
    private var existingDevices: Set<UInt32>?
    private var confirmed: PeekInfo?
    private var lease: Task<Void, Never>?
    private var teardown: Task<Void, Never>?
    private var requests: [UInt32: Task<Void, Never>] = [:]
    private var announced = false
    private var failure: LocalCallLinkTestPeerError?

    init(service: CallingService, roomId: String, primary: GroupCall, primaryID: UInt32, onEnded: @escaping @MainActor () -> Void) {
        self.service = service
        self.roomId = roomId
        self.primary = primary
        self.primaryID = primaryID
        aci = CallingService.uuidBytes(service.account.aci)
        self.onEnded = onEnded
    }

    func prepare(_ link: CallLinkRecord, endpoint: @escaping RingRTCEndpointFactory) {
        setup = Task { [weak self] in
            guard let self, let service else { return }
            do {
                let saved = try await service.database.pool.read { db in try CallLinkStore.get(db, roomId: link.roomId) }
                guard let saved, saved.rootKey == link.rootKey, !saved.revoked, !saved.deleted,
                      try CallLinkStore.roomId(rootKey: saved.rootKey) == roomId else { throw LocalCallLinkTestPeerError.joinLink }
                try checkActive()
                let root = try CallLinkRootKey.fromBytes(saved.rootKey)
                let presentation = try await service.credentials.callLinkAuthPresentation(rootKey: root.bytes)
                try checkActive()
                let params = CallLinkSecretParams.deriveFromRootKey(root.bytes)
                let resolve: (Data) -> Data? = { try? Data(params.decrypt(UuidCiphertext(contents: $0)).serviceIdBinary) }
                // Bypass the lobby's cached peek: require a fresh authenticated response
                // naming the current primary demux before the peer can issue its join.
                let sfu = service.config.sfuURL
                let peek = await service.rtc.peekCallLinkCall(sfuUrl: sfu.absoluteString, authCredentialPresentation: presentation,
                                                              rootKey: root, resolveMember: resolve)
                try checkActive()
                guard case .success(let info) = peek else { throw LocalCallLinkTestPeerError.authentication }
                guard let primaryId = primary.localDeviceState.demuxId, let own = service.ownCallLinkDevices(in: info),
                      own.contains(primaryId), primary.remoteDeviceStates?.allSatisfy({ $0.userId == aci && own.contains($0.demuxId) }) != false
                else { throw LocalCallLinkTestPeerError.otherParticipant }
                existingDevices = own.subtracting([primaryId])
                var state = info.callLinkState
                if state == nil, saved.adminKey == nil {
                    guard case .success(let fresh) = await service.rtc.readCallLink(sfuUrl: sfu.absoluteString, authCredentialPresentation: presentation,
                                                                                  linkRootKey: root) else { throw LocalCallLinkTestPeerError.authentication }
                    try checkActive()
                    state = fresh
                }
                if let state, state.revoked || state.expiration <= Date() || state.rootKey != root { throw LocalCallLinkTestPeerError.joinLink }
                let passkey = try Self.passkey(saved.adminKey, restrictions: state?.restrictions ?? .unknown)
                let server = try service.credentials.serverParams()
                let peerRTC: RingRTC
                do { peerRTC = try RingRTC(endpoint: endpoint); try peerRTC.setSelfUuid(aci) }
                catch { throw LocalCallLinkTestPeerError.connection }
                rtc = peerRTC
                let participantsURL = sfu.appending(path: "v2/conference/participants").absoluteString
                let baseHeaders = Self.headers(roomId: roomId, root: root, presentation: presentation)
                peerRTC.handleSendHttpRequest = { [weak self, weak peerRTC] request, url, method, headers, body in
                    guard let self, let peerRTC else { return }
                    guard self.failure == nil, url == participantsURL, Self.permitsRequest(method, headers, body, expected: baseHeaders),
                          let service = self.service, service.groupCall(for: self.roomId) === self.primary else {
                        peerRTC.httpRequestFailed(requestId: request, debugInfo: "outside local test call")
                        return
                    }
                    guard self.requests[request] == nil, self.requests.count < 4 else { return }
                    self.requests[request] = service.forwardSFURequest(to: peerRTC, requestId: request, url: url, method: method,
                                                                     headers: headers, body: body) { [weak self] in self?.requests[request] = nil }
                }
                peerRTC.handleSendCallMessage = { [weak self] recipient, message, _ in
                    guard let self, recipient == self.aci, self.paired, let existing = self.existingDevices, let call = self.call,
                          let sender = self.rtc, let service = self.service else { return }
                    service.rtc.receiveLocalCallLinkMediaKey(message, from: call, on: sender, to: self.primary,
                                                             deviceId: service.localDeviceId, existingDevices: existing)
                }
                guard let peer = peerRTC.getCallLinkCall(sfuUrl: sfu.absoluteString, endorsementPublicKey: server.endorsementPublicKey,
                                                         authCredentialPresentation: presentation, rootKey: root, adminPasskey: passkey,
                                                         hkdfExtraInfo: Data(), audioLevelsIntervalMillis: CallingService.audioLevelIntervalMillis,
                                                         dredDuration: service.config.dredDuration, svcConfig: service.svcConfig, observer: self,
                                                         scopedLinkSignaling: true, resolveMember: resolve) else { throw LocalCallLinkTestPeerError.connection }
                call = peer
                peer.setOutgoingAudioMuted(true)
                peer.setOutgoingVideoMuted(true)
                peer.connect()
                peer.join()
                monitor(sfu: sfu, presentation: presentation, root: root, resolve: resolve)
            } catch {
                stop(error as? LocalCallLinkTestPeerError ?? .authentication)
            }
        }
    }

    // Native RingRTC coalesces peek events by user ID. An independent peek sees
    // every demux, including unresolved or pending devices absent from media state.
    private func monitor(sfu: URL, presentation: Data, root: CallLinkRootKey, resolve: @escaping (Data) -> Data?) {
        setup = Task { [weak self] in
            do {
                while true {
                    try await Task.sleep(for: self?.announced == true ? .seconds(3) : .seconds(1))
                    guard let self, let service else { return }
                    try checkActive()
                    let result = await service.rtc.peekCallLinkCall(sfuUrl: sfu.absoluteString, authCredentialPresentation: presentation,
                                                                  rootKey: root, resolveMember: resolve)
                    try checkActive()
                    guard case .success(let info) = result else { throw LocalCallLinkTestPeerError.connection }
                    guard Self.ownDevices(info, aci: aci) != nil else { throw LocalCallLinkTestPeerError.otherParticipant }
                    confirmed = info
                    lease?.cancel()
                    lease = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(10)); self?.stop(.connection) } catch {}
                    }
                    update()
                }
            } catch { self?.stop(error as? LocalCallLinkTestPeerError ?? .connection) }
        }
    }

    private static func headers(roomId: String, root: CallLinkRootKey, presentation: Data) -> [String: String] {
        var headers = ["Authorization": "Bearer auth." + presentation.base64EncodedString(), "X-Room-Id": roomId]
        if let epoch = root.epoch { headers["X-Epoch"] = String(epoch) }
        return headers
    }

    nonisolated static func permitsRequest(_ method: HttpMethod, _ headers: [String: String], _ body: Data?, expected: [String: String]) -> Bool {
        var allowed = expected
        switch method {
        case .get: guard body == nil else { return false }
        case .put:
            guard let body, (1...65536).contains(body.count) else { return false }
            allowed["Content-Type"] = "application/json"
        default: return false
        }
        return headers == allowed
    }

    nonisolated static func ownDevices(_ peek: PeekInfo, aci: Data) -> Set<UInt32>? {
        guard aci.count == 16, peek.deviceCountIncludingPendingDevices == peek.devices.count,
              peek.deviceCountExcludingPendingDevices == peek.devices.count, peek.pendingUsers.isEmpty,
              peek.devices.allSatisfy({ $0.userId == aci && $0.demuxId > 0 && $0.demuxId.isMultiple(of: 16) }) else { return nil }
        let ids = Set(peek.devices.map(\.demuxId))
        return ids.count == peek.devices.count ? ids : nil
    }

    nonisolated static func passkey(_ saved: Data?, restrictions: CallLinkRestrictions) throws -> Data? {
        if let saved, !saved.isEmpty { return saved }
        guard restrictions == .none else { throw LocalCallLinkTestPeerError.approvalRequired }
        return nil
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard failure == nil, let service, service.localCallLinkTestPeer === self,
              service.groupCall(for: roomId) === primary, primary.localDeviceState.joinState == .joined,
              primary.localDeviceState.demuxId == primaryID else { throw LocalCallLinkTestPeerError.ended }
    }

    func waitForMedia() async throws -> GroupCall {
        let deadline = ContinuousClock.now + .seconds(35)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let failure { throw failure }
            if let call, paired,
               primary.remoteDeviceStates?.first(where: { $0.demuxId == call.localDeviceState.demuxId })?.mediaKeysReceived == true,
               call.remoteDeviceStates?.first(where: { $0.demuxId == primary.localDeviceState.demuxId })?.mediaKeysReceived == true {
                announced = true
                // Subscribe only to the device hosting this test peer, including camera-to-screen switches.
                call.requestVideo([VideoRequest(demuxId: primaryID, width: 640, height: 360)], activeSpeakerHeight: 0)
                call.setOutgoingAudioMuted(false)
                call.setOutgoingVideoMuted(false)
                return call
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LocalCallLinkTestPeerError.timedOut
    }

    // A peek can report a new demux before the local join event assigns it or the
    // Swift endpoint resolves its ciphertext. Withhold keys until both views agree.
    private func includesOutsider(_ group: GroupCall, known: Set<UInt32>, awaitingPeerID: Bool) -> Bool {
        let remote = group.remoteDeviceStates ?? []
        let remoteIDs = Set(remote.map(\.demuxId))
        let provisionalCount = awaitingPeerID ? 1 : 0
        if remoteIDs.count != remote.count || remoteIDs.subtracting(known).count > provisionalCount || remote.contains(where: { $0.userId != aci }) { return true }
        guard let peek = group.peekInfo else { return false }
        let ids = Set(peek.devices.map(\.demuxId))
        return peek.deviceCountIncludingPendingDevices != peek.devices.count || peek.deviceCountExcludingPendingDevices != peek.devices.count
            || !peek.pendingUsers.isEmpty || ids.count != peek.devices.count || ids.subtracting(known).count > provisionalCount || peek.devices.contains {
                ($0.userId != nil && $0.userId != aci) || (announced && $0.userId == nil)
            }
    }

    private var paired: Bool {
        guard failure == nil, let call, let host = primary.localDeviceState.demuxId, host == primaryID,
              let guest = call.localDeviceState.demuxId, guest == peerID, host != guest, let existingDevices, !existingDevices.contains(guest),
              service?.groupCall(for: roomId) === primary else { return false }
        let localIDs: Set<UInt32> = [host, guest]
        guard let peek = confirmed, let own = Self.ownDevices(peek, aci: aci),
              own.isSuperset(of: localIDs), own.isSubset(of: existingDevices.union(localIDs)) else { return false }
        return primary.hasLocalCallLinkPeer(guest, account: aci, existingDevices: existingDevices)
            && call.hasLocalCallLinkPeer(host, account: aci, existingDevices: existingDevices)
    }

    func update() {
        guard failure == nil else { return }
        guard service?.groupCall(for: roomId) === primary, primary.localDeviceState.joinState == .joined,
              let host = primary.localDeviceState.demuxId, host == primaryID else { stop(.ended); return }
        guard let existingDevices else { return }
        let guest = call?.localDeviceState.demuxId
        if let guest {
            if let peerID, guest != peerID { stop(.ended); return }
            peerID = guest
        }
        let ids = existingDevices.union([host, guest].compactMap { $0 })
        let awaitingPeerID = call != nil && guest == nil
        let freshIDs = confirmed.flatMap { Self.ownDevices($0, aci: aci) }
        if freshIDs.map({ $0.subtracting(ids).count > (awaitingPeerID ? 1 : 0) }) == true
            || guest.map({ $0 == host || existingDevices.contains($0) }) == true
            || includesOutsider(primary, known: ids, awaitingPeerID: awaitingPeerID)
            || call.map({ includesOutsider($0, known: ids, awaitingPeerID: awaitingPeerID) }) == true {
            stop(.otherParticipant)
        } else if paired {
            if !requestedKeys {
                requestedKeys = true
                primary.resendMediaKeys()
                call?.resendMediaKeys()
            }
        } else if announced {
            stop(.ended)
        } else {
            requestedKeys = false
        }
    }

    func handlePrimaryKey(recipient: Data, message: Data) -> Bool {
        guard recipient == aci, primary.isLocalCallLinkMediaKey(message) else { return false }
        if paired, let rtc, let call, let service, let existingDevices {
            rtc.receiveLocalCallLinkMediaKey(message, from: primary, on: service.rtc, to: call, deviceId: service.localDeviceId, existingDevices: existingDevices)
        }
        return true
    }

    func stop(_ reason: LocalCallLinkTestPeerError) {
        guard failure == nil else { return }
        failure = reason
        setup?.cancel()
        setup = nil
        lease?.cancel()
        lease = nil
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
        if service?.localCallLinkTestPeer === self { service?.localCallLinkTestPeer = nil }
        if let call {
            call.setOutgoingAudioMuted(true)
            call.setOutgoingVideoMuted(true)
            call.disconnect()
            // RingRTC sends its SFU leave over RTP and delays its ended callback
            // until the send can flush. Keep the service alive through that callback.
            teardown = Task {
                try? await Task.sleep(for: .seconds(2))
                releaseEndpoint()
            }
        } else { releaseEndpoint() }
        if announced { onEnded() }
    }

    private func releaseEndpoint() {
        teardown?.cancel()
        teardown = nil
        call = nil
        rtc = nil
    }

    func onLocalDeviceStateChanged(_ groupCall: GroupCall) { update() }
    func onRemoteDeviceStatesChanged(_ groupCall: GroupCall) { update() }
    func onPeekChanged(_ groupCall: GroupCall) { update() }
    func onEnded(_ groupCall: GroupCall, reason: CallEndReason, summary: CallSummary) {
        releaseEndpoint()
        stop(.connection)
    }
    func requestMembershipProof(_ groupCall: GroupCall) {}
    func requestGroupMembers(_ groupCall: GroupCall) {}
    func onAudioLevels(_ groupCall: GroupCall) {}
    func onLowBandwidthForVideo(_ groupCall: GroupCall, recovered: Bool) {}
    func onReactions(_ groupCall: GroupCall, reactions: [Reaction]) {}
    func onRaisedHands(_ groupCall: GroupCall, raisedHands: [UInt32]) {}
    func onSpeechEvent(_ groupCall: GroupCall, event: SpeechEvent) {}
    func onRemoteMute(_ groupCall: GroupCall, demuxId: UInt32) {}
    func onObservedRemoteMute(_ groupCall: GroupCall, sourceDemuxId: UInt32, targetDemuxId: UInt32) {}
}
#endif
