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
    /// The direct call this screen shows (RingRTC's call id): its events, and only its, apply.
    /// nil in a lobby until its own setup's call starts.
    var callId: UInt64?
    /// The call can carry our media: not merely its ended-call screen.
    var isLive: Bool { !endedNeedingPermission }
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

/// What the call lifecycle asks of the calling service: CallingService in the app, a stand-in in
/// the conformance tests (Verification/CallCapture), which drive this code against the Lean model.
@MainActor protocol CallControl: AnyObject {
    var isPresenting: Bool { get }
    var activeConversationIds: Set<String> { get }
    func directCallState(_ conversationId: String) -> CallState?
    @discardableResult
    func startOutgoingDirectCall(conversationId: String, hasLocalAudio: Bool, hasLocalVideo: Bool, setup: UInt64) async throws -> UInt64?
    func joinGroupCall(conversationId: String, hasLocalAudio: Bool, hasLocalVideo: Bool, shouldRing: Bool) async throws
    func joinCallLinkCall(roomId: String, rootKey: CallLinkRootKey, adminPasskey: Data?, hasLocalAudio: Bool, hasLocalVideo: Bool) async throws
    func acceptDirectCall(conversationId: String, asVideoCall: Bool, callId: UInt64?)
    func declineDirectCall(conversationId: String, callId: UInt64?)
    func hangup(excludeRinging: Bool)
    func endCall(conversationId: String, callId: UInt64?)
    func setOutgoingAudio(conversationId: String, enabled: Bool)
    func setOutgoingVideo(conversationId: String, enabled: Bool)
    func setPresenting(conversationId: String, _ presenting: Bool)
    func sendVideoFrame(width: Int, height: Int, format: VideoPixelFormat, buffer: [UInt8])
}

extension CallingService: CallControl {
    func directCallState(_ conversationId: String) -> CallState? { directCall(for: conversationId)?.state }
}

@MainActor extension SignalSession {
    /// The calling service as the call lifecycle sees it (`callControlOverride` in tests).
    var callControl: (any CallControl)? {
        if let callControlOverride { return callControlOverride }
        return calling
    }

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
        case .outgoingCall(let id, _, let video, let callId, let setup):
            // Only the call this lobby's own setup started (setup notes `callGeneration`, which
            // every teardown bumps); one the user already left, or an older setup's, is ended.
            guard let a = activeCall, a.conversationId == id, a.isLive, a.callId == nil, setup == callGeneration else {
                return endStrayCall(id, callId: callId)
            }
            activeCall = ActiveCallState(conversationId: id, isGroup: false, stage: .inCall, directState: .prering, callId: callId)
            // The user's video choice stands, also one changed during setup; the service hears it.
            if callLocalVideo != video { callControl?.setOutgoingVideo(conversationId: id, enabled: callLocalVideo) }
        case .incomingDirectCall(let id, let isVideo, let callId):
            guard activeCall == nil else { return }
            ringingCall = (id, isVideo, callId)
            if accountSettings.incomingCallNotification { NSApp.requestUserAttention(.criticalRequest) }
        case .callStateChange(let id, let state, let reason, let acceptedTime, let callId):
            if ringingCall?.callId == callId, state == .ended { ringingCall = nil }
            // Only the call on screen: not an earlier or later call with the same contact, nor a
            // rejected offer (no call of ours).
            guard let a = activeCall, a.callId == callId, a.isLive else {
                if state == .accepted { endStrayCall(id, callId: callId) }   // connected, but not on screen
                return
            }
            switch state {
            case .prering: activeCall?.directState = .prering
            case .ringing: activeCall?.directState = .ringing
            case .accepted:
                activeCall?.directState = .accepted
                activeCall?.acceptedAt = acceptedTime.map { Date(milliseconds: $0) } ?? Date()
            case .reconnecting: activeCall?.directState = .reconnecting
            case .ended:
                if reason == .remoteHangupNeedPermission {
                    // The ended-call screen stays, but nothing of the call does.
                    activeCall?.endedNeedingPermission = true
                    releaseCallMedia(conversationId: id)
                } else {
                    endCallUI()
                }
            }
        case .remoteAudioChange(_, let has, let callId):
            if activeCall?.callId == callId { activeCall?.hasRemoteAudio = has }
        case .remoteVideoChange(_, let has, let callId):
            if activeCall?.callId == callId { activeCall?.hasRemoteVideo = has }
        case .directCallAudioLevels(_, let local, let remote, let callId):
            if activeCall?.callId == callId {
                activeCall?.localAudioLevel = local
                activeCall?.remoteAudioLevel = remote
            }
        case .groupCallChanged(let id, _):
            guard activeCall?.conversationId == id, activeCall?.isLive == true else { return endStrayCall(id) }
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

    /// Closes the call screen (or lobby) and releases everything the call held.
    func endCallUI() {
        let id = activeCall?.conversationId
        activeCall = nil
        callPip = false
        releaseCallMedia(conversationId: id)
    }

    /// The one teardown for every way a call ends, idempotent: setup still in progress and
    /// screen-share starts are invalidated (`callGeneration`), the service ends its calls and
    /// cancels its own setup, presenting stops, the camera stops and no longer sends, and the
    /// ringtone stops. A ringing incoming call is left ringing.
    func releaseCallMedia(conversationId: String?) {
        callGeneration &+= 1
        callSetupTask?.cancel()
        callSetupTask = nil
        stopPresenting(conversationId: conversationId)
        callControl?.hangup(excludeRinging: true)
        cameraSends = false
        updateCamera()
        stopRingtone()
    }

    /// A call the screen is not showing (its setup outlived a hang-up): it must not keep our
    /// microphone or camera, so it is ended. `callId`: only that direct call, never a later one
    /// the conversation has now.
    func endStrayCall(_ conversationId: String, callId: UInt64? = nil) {
        guard let calling = callControl, calling.activeConversationIds.contains(conversationId) else { return }
        if calling.directCallState(conversationId) == .ringing, ringingCall?.conversationId == conversationId,
           callId == nil || ringingCall?.callId == callId { return }
        Self.trace("calling: ending a call that is not on screen")
        calling.endCall(conversationId: conversationId, callId: callId)
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
        guard let a = activeCall, a.isLive, callSetupTask == nil, let calling = callControl else { return }
        applyAudioDevices()
        let audio = callLocalAudio, video = callLocalVideo
        let generation = callGeneration
        let link = a.isCallLink ? callLinks.first(where: { $0.roomId == a.conversationId }) : nil
        callSetupTask = mainTasks.spawn("call.setup") { [weak self] in
            // The task may start after a hang-up or the lobby closing: then no call is asked for.
            guard self?.callGeneration == generation else { return }
            defer { if self?.callGeneration == generation { self?.callSetupTask = nil } }
            do {
                var placed: UInt64?
                if let link {
                    try await calling.joinCallLinkCall(roomId: link.roomId, rootKey: try CallLinkRootKey.fromBytes(link.rootKey), adminPasskey: link.adminKey,
                                                       hasLocalAudio: audio, hasLocalVideo: video)
                } else if a.isGroup {
                    try await calling.joinGroupCall(conversationId: a.conversationId, hasLocalAudio: audio, hasLocalVideo: video, shouldRing: a.outgoingRing)
                } else {
                    placed = try await calling.startOutgoingDirectCall(conversationId: a.conversationId, hasLocalAudio: audio, hasLocalVideo: video,
                                                                       setup: generation)
                }
                // Left during setup (the service's own check should already have stopped it):
                // the call this setup placed ends, not one the conversation has since.
                if self?.callGeneration != generation, let placed { calling.endCall(conversationId: a.conversationId, callId: placed) }
            } catch {
                guard let self, self.callGeneration == generation else { return }   // already torn down
                Self.trace("call failed: \(error)")
                endCallUI()
            }
        }
    }

    func acceptCall(_ conversationId: String, video: Bool) {
        guard let calling = callControl else { return }
        let callId = ringingCall?.conversationId == conversationId ? ringingCall?.callId : nil
        // A call (or lobby) on screen is torn down first, as every other ending does; the
        // ringing call is spared (`hangup(excludeRinging: true)`).
        if activeCall != nil { endCallUI() }
        applyAudioDevices()
        ringingCall = nil
        stopRingtone()
        activeCall = ActiveCallState(conversationId: conversationId, isGroup: false, stage: .inCall, directState: .accepted, acceptedAt: Date(),
                                     callId: callId)
        callLocalAudio = true
        callLocalVideo = video
        calling.acceptDirectCall(conversationId: conversationId, asVideoCall: video, callId: callId)
        updateCamera()
    }

    func declineCall(_ conversationId: String) {
        let callId = ringingCall?.conversationId == conversationId ? ringingCall?.callId : nil
        ringingCall = nil
        stopRingtone()
        callControl?.declineDirectCall(conversationId: conversationId, callId: callId)
    }

    func hangUp() {
        callControl?.hangup(excludeRinging: false)
        endCallUI()
    }

    func setCallAudio(_ on: Bool) {
        callLocalAudio = on
        if let id = activeCall?.conversationId, activeCall?.stage == .inCall { callControl?.setOutgoingAudio(conversationId: id, enabled: on) }
    }

    func setCallVideo(_ on: Bool) {
        callLocalVideo = on
        guard let a = activeCall else { return }
        if a.stage == .inCall { callControl?.setOutgoingVideo(conversationId: a.conversationId, enabled: on) }
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

    /// The camera runs while a live call (or its lobby) is up with our video on.
    var cameraWanted: Bool { activeCall?.isLive == true && callLocalVideo }

    func updateCamera() { cameraReconciler.update() }

    /// The camera as the call lifecycle uses it: the permission prompt and the capture device.
    /// The conformance tests stand in a fake device; the reconciler, the device closures below
    /// and the frame callback are production's.
    @MainActor struct CameraBackend {
        var requestAccess: @MainActor () async -> Bool
        var make: @MainActor (_ onFrame: @escaping @Sendable (CapturedFrame) -> Void) -> any CallCamera

        static let system = CameraBackend(requestAccess: { await CameraCapture.requestAccess() }, make: { CameraCapture(onFrame: $0) })
    }

    /// Starts and stops run one after another; each reads `cameraWanted` again after every
    /// wait (the permission prompt, the camera starting), so a hang-up meanwhile wins.
    var cameraReconciler: CaptureReconciler {
        if let cameraControl { return cameraControl }
        let backend = cameraBackend, tasks = mainTasks
        let device = CaptureReconciler.Device(
            requestAccess: { await backend.requestAccess() },
            start: { [weak self] in
                guard let self else { return }
                let capture = camera ?? backend.make { [weak self] frame in
                    _ = tasks.spawn("camera.frame") { self?.cameraFrame(frame) }
                }
                camera = capture
                try await capture.startCapture(deviceId: preferredCameraId)
            },
            stop: { [weak self] in
                await self?.camera?.stopCapture()
                self?.callLocalVideoModel.clear()
            })
        let r = CaptureReconciler(device: device, wanted: { [weak self] in self?.cameraWanted ?? false }, report: { Self.trace($0) }, tasks: tasks)
        cameraControl = r
        return r
    }

    func cameraFrame(_ frame: CapturedFrame) {
        guard cameraWanted else { return }   // a frame already queued when the camera stopped
        callLocalVideoModel.present(frame)
        // While presenting, the screen's frames go out instead.
        if cameraSends && callControl?.isPresenting != true {
            callControl?.sendVideoFrame(width: frame.width, height: frame.height, format: .nv12, buffer: frame.nv12)
        }
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
        if cameraWanted { cameraReconciler.restart() }
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
