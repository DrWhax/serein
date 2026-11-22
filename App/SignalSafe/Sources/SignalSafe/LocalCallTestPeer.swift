import CallXPC
import Foundation
import OSLog
import SignalCore
import SignalRingRTC

enum LocalCallTestPeerState: Equatable {
    case idle, starting, running, failed(String)
}

@MainActor extension SignalSession {
    private static let testPeerInstalled = RemoteCallEndpoint.testPeerFactory() != nil
    private static let testPeerLog = Logger(subsystem: "org.signalsafe.SignalSafe", category: "CallTestPeer")
    var hasLocalCallTestPeer: Bool { Self.testPeerInstalled }

    /// A single user-selected link on stdin keeps its root key out of process arguments.
    func openCurrentTestCallLink() async {
        guard !handledTestPeerLaunch, hasLocalCallTestPeer, let calling else { return }
        handledTestPeerLaunch = true
        let generation = callGeneration
        do {
            let input = try await Task.detached {
                try FileHandle.standardInput.read(upToCount: 512).flatMap { String(data: $0, encoding: .utf8) }
            }.value
            guard let input, let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let key = CallLinkURL.rootKey(from: url) else {
                reportTestPeerLaunchError("Serein needs a valid Signal call link to start the test.")
                return
            }
            let link = try await calling.addCallLink(rootKey: key)
            let root = try CallLinkRootKey.fromBytes(link.rootKey)
            if let activeCall {
                if activeCall.isCallLink, activeCall.conversationId == link.roomId {
                    if activeCall.stage == .inCall { startLocalCallTestPeer() }
                    else { automaticTestPeerRoom = link.roomId }
                }
                return
            }
            guard !link.deleted, let state = try await calling.readCallLink(rootKey: root), !state.revoked, state.expiration > Date() else {
                reportTestPeerLaunchError("This call link expired or was revoked.")
                return
            }
            guard link.isAdmin || state.restrictions == .none else {
                reportTestPeerLaunchError("This link requires admin approval. Use a link you administer on this Mac or one that lets guests join directly.")
                return
            }
            guard generation == callGeneration, activeCall == nil, ringingCall == nil, ringingGroupCall == nil else { return }
            if callLink(link.roomId) == nil { callLinks.append(link) }
            openCallLinkLobby(link.roomId, audio: false, video: false)
            // After a closed client disappears, the SFU can report its last device for
            // a while. Keep the selected lobby visible and let the user cancel or join.
            let deadline = ContinuousClock.now + .seconds(75)
            defer { if generation == callGeneration { waitingForTestRoom = false } }
            while true {
                let peek = try await calling.peekCallLinkCall(roomId: link.roomId, rootKey: root)
                guard generation == callGeneration, activeCall?.conversationId == link.roomId else { return }
                if activeCall?.stage == .inCall { startLocalCallTestPeer(); return }
                if callSetupTask != nil || callLinkJoinTimeoutTask != nil { automaticTestPeerRoom = link.roomId; return }
                if calling.ownCallLinkDevices(in: peek) != nil {
                    if !peek.devices.isEmpty { Self.testPeerLog.notice("The selected room contains another device from this account") }
                    break
                }
                if !waitingForTestRoom {
                    waitingForTestRoom = true
                    Self.testPeerLog.notice("Waiting for previously joined devices to leave the test room")
                }
                guard ContinuousClock.now < deadline else {
                    reportTestPeerLaunchError("This room still has a participant. You can join from this lobby and start the peer once you have the room to yourself.")
                    return
                }
                try await Task.sleep(for: .seconds(3))
            }
            automaticTestPeerRoom = link.roomId
            Self.testPeerLog.notice("Joining selected test room with capture off")
            startCallFromLobby()
        } catch CallingError.callLinkRequestFailed(let status) {
            guard generation == callGeneration else { return }
            reportTestPeerLaunchError("The calling service could not open this link (status \(status)).")
        } catch {
            guard generation == callGeneration else { return }
            reportTestPeerLaunchError("Serein could not look up this link on the calling service.")
        }
    }

    private func reportTestPeerLaunchError(_ message: String) {
        localCallTestPeerLaunchError = message
        Self.testPeerLog.notice("Test call: \(message, privacy: .public)")
    }

    func startLocalCallTestPeer() {
        guard localCallTestPeerAttempt == nil, let endpoint = RemoteCallEndpoint.testPeerFactory(),
              let a = activeCall, a.isCallLink, a.stage == .inCall, let link = callLink(a.conversationId),
              let calling else { return }
        let attempt = UUID()
        localCallTestPeerAttempt = attempt
        localCallTestPeerState = .starting
        Self.testPeerLog.notice("Starting local RingRTC peer")
        localCallTestPeerTask = Task { [weak self] in
            do {
                let peer = try await calling.startLocalCallLinkTestPeer(link, endpoint: endpoint) { [weak self] in
                    guard let self, localCallTestPeerAttempt == attempt else { return }
                    finishLocalCallTestPeer(.failed("The test peer left the room."))
                }
                guard let self, localCallTestPeerAttempt == attempt, !Task.isCancelled else { return }
                localCallTestPeerDemuxId = peer.localDeviceState.demuxId
                localCallTestPeerState = .running
                Self.testPeerLog.notice("Local RingRTC peer joined and exchanged media keys")
                if let id = localCallTestPeerDemuxId {
                    groupVideoSource(link.roomId, id).onNextFrame = { [weak self] in
                        guard self?.localCallTestPeerAttempt == attempt else { return }
                        Self.testPeerLog.notice("Call screen received test peer video")
                    }
                }
                var receivedAudio = false
                var index = 0
                var dropped = 0
                while !Task.isCancelled {
                    if !receivedAudio, let remote = calling.groupCall(for: link.roomId)?.remoteDeviceStates?.first(where: { $0.demuxId == localCallTestPeerDemuxId }),
                       remote.audioLevel > 0 {
                        receivedAudio = true
                        Self.testPeerLog.notice("Received nonzero test peer audio")
                    }
                    let sent = peer.sendVideoFrame(width: CallTestPeerVideo.width, height: CallTestPeerVideo.height,
                                                   format: .i420, buffer: CallTestPeerVideo.frame(index))
                    dropped = sent ? 0 : dropped + 1
                    if dropped >= 50 {
                        finishLocalCallTestPeer(.failed("The test peer could not send video."))
                        calling.stopLocalCallLinkTestPeer()
                        return
                    }
                    index &+= 1
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                guard let self, localCallTestPeerAttempt == attempt else { return }
                let message = (error as? LocalCallLinkTestPeerError)?.errorDescription ?? "The test peer could not join this call."
                finishLocalCallTestPeer(.failed(message))
            }
        }
    }

    func stopLocalCallTestPeer() {
        let active = localCallTestPeerAttempt != nil
        finishLocalCallTestPeer(.idle)
        if active { calling?.stopLocalCallLinkTestPeer() }
    }

    private func finishLocalCallTestPeer(_ state: LocalCallTestPeerState) {
        if case .failed(let message) = state { Self.testPeerLog.notice("Local test peer stopped: \(message, privacy: .public)") }
        localCallTestPeerAttempt = nil
        localCallTestPeerTask?.cancel()
        localCallTestPeerTask = nil
        localCallTestPeerDemuxId = nil
        localCallTestPeerState = state
    }
}
