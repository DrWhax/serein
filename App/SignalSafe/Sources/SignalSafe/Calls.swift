// Calls in the app (upstream's calling duck and SmartCallManager over CallingClass): direct
// audio/video calls (lobby → ring → call → hang up; incoming bar → accept / decline) and group
// calls (lobby → join; participants' video requested and pulled from ringrtc). SignalCore's
// CallingService does signalling, relays and call history; SignalRingRTC (ringrtc + WebRTC)
// the media; the camera through CameraCapture, the local preview through LocalVideoModel. While
// a call is up the display stays awake (AppModel.isCallActive).

import AppKit
import Foundation
import GRDB
import SignalCore
import SignalRingRTC
import SignalUI

/// The call on screen (or in the lobby).
struct ActiveCallState: Equatable {
    enum Stage: Equatable { case lobby, inCall }
    var conversationId: String
    var isGroup: Bool
    var stage: Stage
    var directState: DirectCallState?
    var endedNeedingPermission = false
    var hasRemoteVideo = false
    var hasRemoteAudio = true
    var remoteAudioLevel = 0.0
    var localAudioLevel = 0.0
    var acceptedAt: Date?
    var outgoingRing = true
    /// A call link's call (`conversationId` is then the link's room id).
    var isCallLink = false
    /// Bumped when a group call changes (participants, join state): the screen re-reads it.
    var groupRevision = 0
}

/// Settings → Calls' device lists.
struct CallDevices {
    var cameras: [CameraDevice] = []
    var microphones = SignalUI.AudioDeviceList(devices: [])
    var speakers = SignalUI.AudioDeviceList(devices: [])
}

/// A 1:1 call's remote video, pulled by the video view on each display refresh.
@MainActor final class DirectCallVideo: CallVideoFrameSource {
    weak var calling: CallingService?
    let conversationId: String
    init(calling: CallingService?, conversationId: String) {
        self.calling = calling
        self.conversationId = conversationId
    }
    func receiveVideoFrame(into buffer: inout [UInt8], maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int)? {
        calling?.directCall(for: conversationId)?.receiveVideoFrame(into: &buffer, maxWidth: maxWidth, maxHeight: maxHeight)
    }
}

/// One group participant's video.
@MainActor final class GroupCallVideo: CallVideoFrameSource {
    weak var calling: CallingService?
    let conversationId: String
    let demuxId: UInt32
    init(calling: CallingService?, conversationId: String, demuxId: UInt32) {
        self.calling = calling
        self.conversationId = conversationId
        self.demuxId = demuxId
    }
    func receiveVideoFrame(into buffer: inout [UInt8], maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int)? {
        calling?.groupCall(for: conversationId)?.receiveVideoFrame(demuxId: demuxId, into: &buffer, maxWidth: maxWidth, maxHeight: maxHeight)
    }
}

@MainActor extension SignalSession {
    // MARK: setup

    /// The calling service for the linked account; its events drive the call UI.
    func startCalling() {
        guard calling == nil, let client = signalClient else { return }
        let sfu = Self.environment.sfuURL
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let service = try await client.makeCallingService(sfuURL: sfu) else { return }
                await service.register()
                service.onEvent = { [weak self] e in Task { @MainActor in self?.handleCallingEvent(e) } }
                service.onCameraNeeded = { [weak self] on in Task { @MainActor in self?.setCameraSending(on) } }
                calling = service
                preferredMicrophoneId = UserDefaults.standard.string(forKey: "preferredMicrophone")
                preferredSpeakerId = UserDefaults.standard.string(forKey: "preferredSpeaker")
                preferredCameraId = UserDefaults.standard.string(forKey: "preferredCamera")
                applyAudioDevices()
                Self.trace("calling: ready")
                // Debugging the call UI: open a voice-call lobby (no call is placed).
                if ProcessInfo.processInfo.environment["SIGNALSAFE_DEBUG_LOBBY"] == "1" {
                    try? await Task.sleep(for: .seconds(3))
                    if let c = conversations.first(where: { $0.kind == .private && $0.isAccepted && $0.serviceId != ourAci }) {
                        openCallLobby(c.id, video: false)
                    }
                }
            } catch {
                Self.trace("calling failed to start: \(error)")
            }
        }
    }

    /// A CallMessage from the receive pipeline.
    func handleCallMessage(_ e: CallMessageEnvelope) {
        guard let calling else { return }
        Task { await calling.handleCallingMessage(e) }
    }

    // MARK: events

    func handleCallingEvent(_ e: CallingEvent) {
        switch e {
        case .outgoingCall(let id, _, let video):
            activeCall = ActiveCallState(conversationId: id, isGroup: false, stage: .inCall, directState: .prering)
            callLocalVideo = video
        case .incomingDirectCall(let id, let isVideo):
            guard activeCall == nil else { return }
            ringingCall = (id, isVideo)
            if accountSettings.incomingCallNotification { NSApp.requestUserAttention(.criticalRequest) }
        case .callStateChange(let id, let state, let reason, let acceptedTime):
            if ringingCall?.conversationId == id, state == .ended || state == .accepted { if state == .ended { ringingCall = nil } }
            guard activeCall?.conversationId == id else { return }
            switch state {
            case .prering: activeCall?.directState = .prering
            case .ringing: activeCall?.directState = .ringing
            case .accepted:
                activeCall?.directState = .accepted
                activeCall?.acceptedAt = acceptedTime.map { Date(milliseconds: $0) } ?? Date()
            case .reconnecting: activeCall?.directState = .reconnecting
            case .ended:
                if reason == .remoteHangupNeedPermission {
                    activeCall?.endedNeedingPermission = true
                } else {
                    endCallUI()
                }
            }
        case .remoteAudioChange(let id, let has):
            if activeCall?.conversationId == id { activeCall?.hasRemoteAudio = has }
        case .remoteVideoChange(let id, let has):
            if activeCall?.conversationId == id { activeCall?.hasRemoteVideo = has }
        case .directCallAudioLevels(let id, let local, let remote):
            if activeCall?.conversationId == id {
                activeCall?.localAudioLevel = local
                activeCall?.remoteAudioLevel = remote
            }
        case .groupCallChanged(let id, _):
            guard activeCall?.conversationId == id else { return }
            if calling?.groupCall(for: id)?.localDeviceState.joinState == .joined { activeCall?.stage = .inCall }
            activeCall?.groupRevision += 1
            requestGroupVideo(id)
        case .groupCallEnded(let id, _):
            if activeCall?.conversationId == id { endCallUI() }
        case .groupCallAudioLevels(let id):
            if activeCall?.conversationId == id { activeCall?.groupRevision += 1 }
        default:
            break
        }
    }

    func endCallUI() {
        stopPresenting()
        activeCall = nil
        callPip = false
        cameraSends = false
        updateCamera()
        stopRingtone()
    }

    // MARK: actions

    /// The header's call buttons: the lobby for a direct call or a group call.
    func openCallLobby(_ conversationId: String, video: Bool) {
        guard activeCall == nil, let c = conversation(conversationId) else { return }
        activeCall = ActiveCallState(conversationId: conversationId, isGroup: c.kind == .group, stage: .lobby)
        callLocalAudio = true
        callLocalVideo = video
        setCameraPreview(video)
        if c.kind == .group, let calling { Task { _ = try? await calling.peekGroupCall(conversationId: conversationId) } }
    }

    /// The lobby's "Start call" / "Join".
    func startCallFromLobby() {
        guard let a = activeCall, let calling else { return }
        applyAudioDevices()
        let audio = callLocalAudio, video = callLocalVideo
        Task {
            do {
                if a.isCallLink, let link = callLinks.first(where: { $0.roomId == a.conversationId }) {
                    try await calling.joinCallLinkCall(roomId: link.roomId, rootKey: try CallLinkRootKey.fromBytes(link.rootKey), adminPasskey: link.adminKey,
                                                       hasLocalAudio: audio, hasLocalVideo: video)
                } else if a.isGroup {
                    try await calling.joinGroupCall(conversationId: a.conversationId, hasLocalAudio: audio, hasLocalVideo: video, shouldRing: a.outgoingRing)
                } else {
                    try await calling.startOutgoingDirectCall(conversationId: a.conversationId, hasLocalAudio: audio, hasLocalVideo: video)
                }
            } catch {
                Self.trace("call failed: \(error)")
                endCallUI()
            }
        }
    }

    func acceptCall(_ conversationId: String, video: Bool) {
        guard let calling else { return }
        applyAudioDevices()
        ringingCall = nil
        stopRingtone()
        activeCall = ActiveCallState(conversationId: conversationId, isGroup: false, stage: .inCall, directState: .accepted, acceptedAt: Date())
        callLocalAudio = true
        callLocalVideo = video
        calling.acceptDirectCall(conversationId: conversationId, asVideoCall: video)
        updateCamera()
    }

    func declineCall(_ conversationId: String) {
        ringingCall = nil
        stopRingtone()
        calling?.declineDirectCall(conversationId: conversationId)
    }

    func hangUp() {
        stopPresenting()
        calling?.hangup()
        endCallUI()
    }

    func setCallAudio(_ on: Bool) {
        callLocalAudio = on
        if let id = activeCall?.conversationId, activeCall?.stage == .inCall { calling?.setOutgoingAudio(conversationId: id, enabled: on) }
    }

    func setCallVideo(_ on: Bool) {
        callLocalVideo = on
        guard let a = activeCall else { return }
        if a.stage == .inCall { calling?.setOutgoingVideo(conversationId: a.conversationId, enabled: on) }
        updateCamera()
    }

    // MARK: camera

    /// The lobby's preview (frames shown, not sent).
    func setCameraPreview(_ on: Bool) {
        cameraSends = false
        updateCamera()
    }

    /// CallingService: frames should (or should no longer) go to the call. The camera itself
    /// keeps running while our video is on — the service briefly reports "not needed" as a
    /// call starts, which must not stop the preview.
    func setCameraSending(_ on: Bool) {
        cameraSends = on
        updateCamera()
    }

    /// The camera runs while a call (or its lobby) is up with our video on.
    func updateCamera() {
        let wanted = activeCall != nil && callLocalVideo
        wanted ? startCamera() : stopCamera()
    }

    /// Camera starts and stops run one after another, in the order asked.
    private func enqueueCamera(_ op: @escaping @MainActor (SignalSession) async -> Void) {
        let previous = cameraOp
        cameraOp = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await op(self)
        }
    }

    func startCamera() {
        enqueueCamera { s in
            guard await CameraCapture.requestAccess() else { return Self.trace("camera: no permission") }
            let capture = s.camera ?? CameraCapture { [weak s] frame in
                Task { @MainActor in s?.cameraFrame(frame) }
            }
            s.camera = capture
            if await capture.isCapturing { return }
            do { try await capture.start(deviceId: s.preferredCameraId) } catch { Self.trace("camera failed: \(error)") }
        }
    }

    func stopCamera() {
        enqueueCamera { s in
            if let camera = s.camera { await camera.stop() }
            s.callLocalVideoModel.clear()
        }
    }

    func cameraFrame(_ frame: CapturedFrame) {
        callLocalVideoModel.present(frame)
        // While presenting, the screen's frames go out instead.
        if cameraSends && calling?.isPresenting != true { calling?.sendVideoFrame(width: frame.width, height: frame.height, format: .nv12, buffer: frame.nv12) }
    }

    /// The 1:1 call's remote video source (one per call).
    func directVideoSource(_ conversationId: String) -> DirectCallVideo {
        if let s = directVideo, s.conversationId == conversationId { return s }
        let s = DirectCallVideo(calling: calling, conversationId: conversationId)
        directVideo = s
        return s
    }

    // MARK: group video

    /// Every participant's video at a modest size (upstream requests per visible tile).
    func requestGroupVideo(_ conversationId: String) {
        guard let states = calling?.groupCall(for: conversationId)?.remoteDeviceStates else { return }
        let requests = states.filter { $0.videoMuted != true }.map { VideoRequest(demuxId: $0.demuxId, width: 640, height: 360) }
        calling?.requestVideo(conversationId: conversationId, requests, speakerHeight: 720)
    }

    func groupVideoSource(_ conversationId: String, _ demuxId: UInt32) -> GroupCallVideo {
        let key = "\(conversationId)|\(demuxId)"
        if let s = groupVideoSources[key] { return s }
        let s = GroupCallVideo(calling: calling, conversationId: conversationId, demuxId: demuxId)
        groupVideoSources[key] = s
        return s
    }

    /// An ACI from ringrtc's 16 bytes (lower-case, dashed).
    static func aci(_ bytes: Data) -> String? {
        let b = [UInt8](bytes)
        guard b.count == 16 else { return nil }
        let digits = Array("0123456789abcdef")
        var s = ""
        for (i, byte) in b.enumerated() {
            if [4, 6, 8, 10].contains(i) { s += "-" }
            s.append(digits[Int(byte >> 4)])
            s.append(digits[Int(byte & 0xF)])
        }
        return s
    }

    // MARK: history (Calls tab)

    func observeCallHistory() {
        guard callHistoryTask == nil, let db = clientDatabase else { return }
        callLinksTask = Task { [weak self] in
            do {
                for try await links in db.callLinkUpdates() { self?.callLinks = links }
            } catch {}
        }
        callHistoryTask = Task { [weak self] in
            do {
                for try await groups in db.callHistoryUpdates() { self?.callHistory = groups }
            } catch {}
        }
    }

    /// A history row's chat: the contact (direct) or group; call links are not listed here.
    func callPeer(_ peerId: String, mode: SignalCore.CallMode) -> ConversationSummary? {
        switch mode {
        case .direct: return conversations.first { $0.kind == .private && $0.serviceId == peerId }
        case .group: return conversations.first { c in c.kind == .group && c.masterKey.flatMap { try? GroupKeys(masterKey: $0).groupIdBase64 } == peerId }
        case .adhoc: return nil
        }
    }

    func clearCallHistory() {
        guard let calling else { return }
        Task { do { try await calling.clearCallHistory() } catch { Self.trace("clear call history failed: \(error)") } }
    }

    func markCallHistoryRead(_ conversationId: String) {
        guard let calling else { return }
        Task { try? await calling.markCallHistoryRead(conversationId: conversationId) }
    }

    // MARK: devices (Settings → Calls)

    /// The devices to choose from (ringrtc's audio devices, AVFoundation's cameras).
    func refreshCallDevices() {
        guard let rtc = calling?.rtc else { return }
        func list(_ l: SignalRingRTC.AudioDeviceList?) -> SignalUI.AudioDeviceList {
            SignalUI.AudioDeviceList(devices: (l?.devices ?? []).map { SignalUI.AudioDevice(name: $0.name, uniqueId: $0.uniqueId) },
                                     defaultDevice: l?.defaultDevice.map { SignalUI.AudioDevice(name: $0.name, uniqueId: $0.uniqueId) })
        }
        callDevices = CallDevices(cameras: CameraCapture.devices(), microphones: list(rtc.getAudioInputs()), speakers: list(rtc.getAudioOutputs()))
    }

    func selectMicrophone(_ p: AudioDevicePref) {
        let id: String? = if case .specificDevice(let d) = p { d.uniqueId } else { nil }
        preferredMicrophoneId = id
        UserDefaults.standard.set(id, forKey: "preferredMicrophone")
        applyAudioDevices()
    }

    func selectSpeaker(_ p: AudioDevicePref) {
        let id: String? = if case .specificDevice(let d) = p { d.uniqueId } else { nil }
        preferredSpeakerId = id
        UserDefaults.standard.set(id, forKey: "preferredSpeaker")
        applyAudioDevices()
    }

    func selectCamera(_ id: String) {
        preferredCameraId = id
        UserDefaults.standard.set(id, forKey: "preferredCamera")
        if camera != nil, callLocalVideo, activeCall != nil { stopCamera(); startCamera() }
    }

    /// The chosen microphone and speaker (the system default when none is chosen) and the call
    /// settings, applied to ringrtc.
    func applyAudioDevices() {
        guard let calling else { return }
        calling.config.alwaysRelayCalls = accountSettings.alwaysRelayCalls
        calling.config.incomingCallNotification = accountSettings.incomingCallNotification
        let rtc = calling.rtc
        let mic = preferredMicrophoneId ?? rtc.getAudioInputs()?.defaultDevice?.uniqueId
        let speaker = preferredSpeakerId ?? rtc.getAudioOutputs()?.defaultDevice?.uniqueId
        Task {
            if let mic { _ = try? await rtc.setAudioInputById(mic) }
            if let speaker { _ = try? await rtc.setAudioOutputById(speaker) }
        }
    }

    // MARK: ringtone

    func playRingtone() {
        guard ringtone == nil, accountSettings.callRingtoneNotification else { return }
        // Our own bundled WAV (generated at build time), not received media.
        let sound = NSSound(named: "ringtone_minimal")
        sound?.loops = true
        sound?.play()
        ringtone = sound
    }

    func stopRingtone() {
        ringtone?.stop()
        ringtone = nil
    }
}

@MainActor extension SignalSession {
    /// Diagnostics (SIGNALSAFE_TRACE): failed jobs (queue, final or retrying, the error's kind),
    /// and at start the outgoing messages still pending after a minute and the queued jobs — so
    /// a send stuck on "sending" can be explained. Kinds and counts only, no content.
    func traceSendHealth(_ session: SignalClient.Session) {
        guard Self.tracing, let db = clientDatabase else { return }
        let jobs = session.jobs
        Task.detached {
            for await e in jobs.events {
                if case .failed(let job, let error, let final) = e {
                    Self.trace("job failed: \(job.queueType) \(final ? "final" : "will retry"): \(error.prefix(160))")
                }
            }
        }
        Task {
            let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - 60_000
            let report = try? await db.pool.read { db -> String in
                let stuck = try Row.fetchAll(db, sql: """
                    SELECT m.sent_at, c.type AS kind, m.hasAttachments, length(m.body) AS len, m.json ->> '$.sendStateByConversationId' AS states
                    FROM messages m JOIN conversations c ON c.id = m.conversationId
                    WHERE m.type = 'outgoing' AND m.json LIKE '%"Pending"%' AND m.sent_at < ? ORDER BY m.sent_at DESC LIMIT 5
                    """, arguments: [cutoff])
                let jobs = try Row.fetchAll(db, sql: "SELECT queueType, count(*) AS n FROM jobs GROUP BY queueType")
                let lines = stuck.map { r -> String in
                    let states = (r["states"] as String?) ?? ""
                    let pending = states.components(separatedBy: "\"Pending\"").count - 1
                    let sent = states.components(separatedBy: "\"Sent\"").count - 1 + states.components(separatedBy: "\"Delivered\"").count - 1
                    return "\(r["kind"] as String? ?? "?") age \((cutoff + 60_000 - (r["sent_at"] as Int64? ?? 0)) / 1000)s attachments \(r["hasAttachments"] as Int? ?? 0) bodyLen \(r["len"] as Int? ?? 0) recipients pending \(pending) sent \(sent)"
                }
                return "stuck sends: \(stuck.count) [\(lines.joined(separator: "; "))]; jobs: " + jobs.map { "\($0["queueType"] as String? ?? "?")=\($0["n"] as Int? ?? 0)" }.joined(separator: ", ")
            }
            if let report { Self.trace(report) }
        }
    }
}
