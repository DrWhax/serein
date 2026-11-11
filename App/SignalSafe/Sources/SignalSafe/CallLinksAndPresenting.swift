// Call links and screen sharing in the app (upstream calling duck: createCallLink,
// startCallLinkLobby, updateCallLinkName / Restrictions, deleteCallLink, and
// #startPresenting / #stopPresenting with the source picker).
// - Call links: created from the Calls tab (then the edit modal: name, approval, share),
//   joined from the Calls tab or a signal.link/call URL in a message; their calls are group
//   calls keyed by the link's room id.
// - Presenting: the screen-recording permission, ScreenCaptureKit's displays and windows to
//   pick from, then that source's frames go out instead of the camera's until stopped.

import AppKit
import Foundation
import SignalCore
import SignalRingRTC
import SignalUI

/// The call link modal on screen.
enum CallLinkModal: Equatable {
    case edit(roomId: String)
    case addName(roomId: String)
    case needsScreenRecordingPermission
}

@MainActor extension SignalSession {
    // MARK: call links

    func callLink(_ roomId: String) -> CallLinkRecord? { callLinks.first { $0.roomId == roomId } }

    /// The link's URL to share (nil if its key is unreadable).
    func callLinkURL(_ link: CallLinkRecord) -> String? { try? CallLinkURL.url(rootKey: link.rootKey) }

    /// What SignalUI shows for a link.
    func callLinkInfo(_ link: CallLinkRecord) -> CallLinkInfo {
        CallLinkInfo(name: link.name, rootKey: (try? CallLinkRootKey.fromBytes(link.rootKey).formatted()) ?? "", isAdmin: link.isAdmin,
                     requiresAdminApproval: link.restrictions == CallLinkRestrictions.adminApproval.rawValue, revoked: link.revoked)
    }

    /// A call link's title (its name, else "Signal Call").
    func callLinkTitle(_ link: CallLinkRecord, _ defaultTitle: String) -> String { link.name.isEmpty ? defaultTitle : link.name }

    /// Calls tab "Create a call link": made on the SFU, then the edit modal.
    func createCallLink() {
        guard let calling else { return }
        Task {
            do {
                let link = try await calling.createCallLink()
                callLinkModal = .edit(roomId: link.roomId)
            } catch {
                Self.trace("create call link failed: \(error)")
                toast = .error
            }
        }
    }

    func renameCallLink(_ roomId: String, _ name: String) {
        guard let calling, let link = callLink(roomId) else { return }
        Task {
            do { _ = try await calling.updateCallLinkName(link, name: name) } catch { Self.trace("rename call link failed: \(error)"); toast = .error }
        }
    }

    func setCallLinkApproval(_ roomId: String, _ required: Bool) {
        guard let calling, let link = callLink(roomId) else { return }
        Task {
            do {
                _ = try await calling.updateCallLinkRestrictions(link, restrictions: required ? .adminApproval : .none)
            } catch {
                Self.trace("call link restrictions failed: \(error)")
                toast = .error
            }
        }
    }

    func deleteCallLink(_ roomId: String) {
        guard let calling, let link = callLink(roomId) else { return }
        Task {
            do { try await calling.deleteCallLink(link) } catch { Self.trace("delete call link failed: \(error)"); toast = .error }
        }
    }

    func copyCallLink(_ roomId: String) {
        guard let link = callLink(roomId), let url = callLinkURL(link) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        toast = .copiedCallLink
    }

    /// "Share link via Signal": the forward dialog with the link as the message.
    func shareCallLinkViaSignal(_ roomId: String, _ text: (String) -> String) {
        guard let link = callLink(roomId), let url = callLinkURL(link) else { return }
        callLinkModal = nil
        shareText = text(url)
    }

    /// The lobby for a call link's call.
    func openCallLinkLobby(_ roomId: String) {
        guard activeCall == nil, let link = callLink(roomId) else { return }
        callLinkModal = nil
        activeCall = ActiveCallState(conversationId: roomId, isGroup: true, stage: .lobby, outgoingRing: false, isCallLink: true)
        callLocalAudio = true
        callLocalVideo = true
        setCameraPreview(true)
        if let calling, let key = try? CallLinkRootKey.fromBytes(link.rootKey) {
            Task { _ = try? await calling.peekCallLinkCall(roomId: roomId, rootKey: key) }
        }
    }

    /// A clicked link: a call link opens its lobby (added first if new); true when handled.
    func openCallLinkURL(_ url: URL) -> Bool {
        guard let key = CallLinkURL.rootKey(from: url) else { return false }
        guard let calling else { return true }
        Task {
            do {
                let link = try await calling.addCallLink(rootKey: key)
                if !callLinks.contains(where: { $0.roomId == link.roomId }) { callLinks.append(link) }
                openCallLinkLobby(link.roomId)
            } catch {
                Self.trace("call link failed: \(error)")
                toast = .error
            }
        }
        return true
    }

    // MARK: presenting

    /// ScreenCaptureKit as presenting uses it: the permission, the sources, starting a picked
    /// source. The conformance tests replace it with stand-ins (the capture's own start and stop
    /// logic still runs).
    @MainActor struct ScreenShareBackend {
        var isGranted: () -> Bool
        var sources: @MainActor (ScreenShareCapture) async throws -> [PresentableSource]
        var start: @MainActor (ScreenShareCapture, String) async throws -> Void

        static let system = ScreenShareBackend(isGranted: { ScreenRecordingPermission.isGranted },
                                               sources: { try await $0.sources() },
                                               start: { capture, sourceId in try await capture.start(try capture.filter(for: sourceId)) })
    }

    /// The call screen's "Share screen" button: stop, or ask for the source.
    func togglePresenting() {
        guard let id = activeCall?.conversationId, let calling = callControl else { return }
        if calling.isPresenting {
            stopPresenting()
            return
        }
        guard screenShareBackend.isGranted() else {
            ScreenRecordingPermission.request()
            callLinkModal = .needsScreenRecordingPermission
            return
        }
        // A share not presenting yet (its sources loading or its stream starting), or one the
        // service stopped presenting on its own (the call ended), goes, with its capture.
        if screenCapture != nil { clearScreenShare() }
        lastScreenShareToken &+= 1
        let token = lastScreenShareToken
        let tasks = mainTasks
        let capture = ScreenShareCapture(onFrame: { [weak self] frame in
            _ = tasks.spawn("screen.frame") { self?.screenFrame(frame, token: token) }
        }, onStop: { [weak self] error in
            _ = tasks.spawn("screen.stopped") { self?.screenShareStopped(token: token, error: error) }
        }, tasks: tasks)
        screenCapture = capture
        screenShareToken = token
        let generation = callGeneration
        let backend = screenShareBackend
        _ = tasks.spawn("screen.sources") { [self] in
            // The task may start after a hang-up or another press: then nothing is asked for.
            guard isCurrentScreenShare(token, generation: generation, conversationId: id) else { return }
            do {
                let sources = try await backend.sources(capture)
                guard isCurrentScreenShare(token, generation: generation, conversationId: id) else { return }   // the call ended meanwhile
                presentingSources = sources
            } catch {
                Self.trace("screen sources failed: \(error)")
                if screenShareToken == token { clearScreenShare() }
            }
        }
    }

    /// Whether the share `token` is still the one wanted: the same call (no teardown since
    /// `generation`), still live, and no other share or stop since.
    func isCurrentScreenShare(_ token: UInt64, generation: UInt64, conversationId: String) -> Bool {
        screenShareToken == token && screenCapture != nil && callGeneration == generation
            && activeCall?.conversationId == conversationId && activeCall?.isLive == true
    }

    /// Drops the share; its capture is stopped (also a start still in progress), so no stream
    /// is left running without an owner.
    func clearScreenShare() {
        if let capture = screenCapture {
            capture.cancelStart()   // at once: a start continuing before the stop task runs gives up
            _ = mainTasks.spawn("screen.stop") { await capture.stop() }
        }
        screenCapture = nil
        screenShareToken = nil
    }

    /// The stream stopped on its own (an error, the source went away): only the share it
    /// belonged to stops.
    func screenShareStopped(token: UInt64, error: (any Error)?) {
        if let error { Self.trace("screen share stopped: \(error)") }
        guard screenShareToken == token else { return }
        stopPresenting()
    }

    /// A source picked: its frames replace the camera's.
    func startPresenting(_ sourceId: String) {
        presentingSources = nil
        guard let id = activeCall?.conversationId, activeCall?.isLive == true, let calling = callControl, let capture = screenCapture,
              let token = screenShareToken else { return }
        let generation = callGeneration
        let backend = screenShareBackend
        _ = mainTasks.spawn("screen.present") { [self] in
            // The task may start after a hang-up or another pick: then nothing is captured.
            guard isCurrentScreenShare(token, generation: generation, conversationId: id) else { return }
            do {
                try await backend.start(capture, sourceId)
                // The call ended, or sharing was stopped, while the stream was starting.
                guard isCurrentScreenShare(token, generation: generation, conversationId: id) else {
                    await capture.stop()
                    return
                }
                calling.setPresenting(conversationId: id, true)
                activeCall?.groupRevision += 1
            } catch is CancellationError {
                // Stopped while starting: stopPresenting already cleaned up.
            } catch {
                Self.trace("screen share failed: \(error)")
                if screenShareToken == token { clearScreenShare() }
            }
        }
    }

    func cancelPresentingSources() {
        presentingSources = nil
        clearScreenShare()
    }

    /// `conversationId`: the call's, when the screen has already closed.
    func stopPresenting(conversationId: String? = nil) {
        presentingSources = nil
        clearScreenShare()
        if callControl?.isPresenting == true {
            callControl?.setPresenting(conversationId: conversationId ?? activeCall?.conversationId ?? "", false)
            activeCall?.groupRevision += 1
        }
    }

    func screenFrame(_ frame: CapturedFrame, token: UInt64) {
        // Frames of an older share, or queued when sharing stopped, are dropped.
        guard screenShareToken == token, screenCapture != nil, callControl?.isPresenting == true, activeCall?.isLive == true else { return }
        callControl?.sendVideoFrame(width: frame.width, height: frame.height, format: .nv12, buffer: frame.nv12)
    }
}
