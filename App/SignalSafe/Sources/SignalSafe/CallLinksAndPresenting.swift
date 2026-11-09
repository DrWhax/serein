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

    /// The call screen's "Share screen" button: stop, or ask for the source.
    func togglePresenting() {
        guard let id = activeCall?.conversationId, let calling else { return }
        if calling.isPresenting {
            stopPresenting()
            return
        }
        guard ScreenRecordingPermission.isGranted else {
            ScreenRecordingPermission.request()
            callLinkModal = .needsScreenRecordingPermission
            return
        }
        let capture = ScreenShareCapture(onFrame: { [weak self] frame in
            Task { @MainActor in self?.screenFrame(frame) }
        }, onStop: { [weak self] error in
            Task { @MainActor in
                if let error { Self.trace("screen share stopped: \(error)") }
                self?.stopPresenting()
            }
        })
        screenCapture = capture
        Task {
            do {
                presentingSources = try await capture.sources()
            } catch {
                Self.trace("screen sources failed: \(error)")
                screenCapture = nil
            }
        }
        _ = id
    }

    /// A source picked: its frames replace the camera's.
    func startPresenting(_ sourceId: String) {
        presentingSources = nil
        guard let id = activeCall?.conversationId, let calling, let capture = screenCapture else { return }
        Task {
            do {
                try await capture.start(try capture.filter(for: sourceId))
                calling.setPresenting(conversationId: id, true)
                activeCall?.groupRevision += 1
            } catch {
                Self.trace("screen share failed: \(error)")
                screenCapture = nil
            }
        }
    }

    func cancelPresentingSources() {
        presentingSources = nil
        screenCapture = nil
    }

    func stopPresenting() {
        presentingSources = nil
        let capture = screenCapture
        screenCapture = nil
        if let capture { Task { await capture.stop() } }
        if let id = activeCall?.conversationId, calling?.isPresenting == true {
            calling?.setPresenting(conversationId: id, false)
            activeCall?.groupRevision += 1
        }
    }

    func screenFrame(_ frame: CapturedFrame) {
        guard calling?.isPresenting == true else { return }
        calling?.sendVideoFrame(width: frame.width, height: frame.height, format: .nv12, buffer: frame.nv12)
    }
}
