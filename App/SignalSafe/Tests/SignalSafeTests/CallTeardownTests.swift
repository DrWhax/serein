// Every way a call ends releases its media, including the remote hang-up that leaves the
// "needs permission" screen up, and a camera start still waiting on permission loses to it.

import SignalCore
import SignalRingRTC
import SignalUI
import Testing
@testable import SignalSafe

@MainActor @Suite struct CallTeardownTests {
    /// A session in a video call whose camera is a stand-in that counts starts and stops; its
    /// permission prompt waits for the test when `holdPrompt` is set.
    @MainActor final class Rig {
        let session = SignalSession()
        var running = false
        var starts = 0
        var prompt: CheckedContinuation<Bool, Never>?
        var holdPrompt = false

        init() {
            let device = CaptureReconciler.Device(
                requestAccess: { [weak self] in
                    guard let self, holdPrompt else { return true }
                    return await withCheckedContinuation { self.prompt = $0 }
                },
                start: { [weak self] in self?.starts += 1; self?.running = true },
                stop: { [weak self] in self?.running = false })
            session.cameraControl = CaptureReconciler(device: device, wanted: { [weak session] in session?.cameraWanted ?? false })
            session.activeCall = ActiveCallState(conversationId: "c1", isGroup: false, stage: .inCall, directState: .accepted)
            session.callLocalVideo = true
        }

        func settle() async { await session.cameraReconciler.settle() }
    }

    @Test func remoteHangupNeedingPermissionStopsTheCamera() async {
        let rig = Rig()
        rig.session.updateCamera()
        await rig.settle()
        #expect(rig.running)
        let before = rig.session.callGeneration
        rig.session.handleCallingEvent(.callStateChange(conversationId: "c1", state: .ended, endedReason: .remoteHangupNeedPermission, acceptedTime: nil))
        await rig.settle()
        #expect(rig.session.activeCall?.endedNeedingPermission == true)   // the screen stays
        #expect(!rig.running && !rig.session.cameraWanted)                 // the camera does not
        #expect(rig.session.callGeneration != before)
        // Turning video on from that screen does not bring the camera back.
        rig.session.setCallVideo(true)
        await rig.settle()
        #expect(!rig.running)
    }

    /// Hanging up while the camera permission prompt is open: granting it starts nothing.
    @Test func hangupWhileThePromptIsOpen() async {
        let rig = Rig()
        rig.holdPrompt = true
        rig.session.updateCamera()
        for _ in 0..<1000 where rig.prompt == nil { await Task.yield() }
        rig.session.hangUp()
        rig.prompt?.resume(returning: true)
        await rig.settle()
        #expect(rig.starts == 0 && !rig.running && rig.session.activeCall == nil)
    }

    /// The lobby's ✕ (or Escape) while setup is in flight: the setup is cancelled.
    @Test func closingTheLobbyInvalidatesSetup() async {
        let rig = Rig()
        rig.session.callSetupTask = Task {}
        let before = rig.session.callGeneration
        rig.session.endCallUI()
        #expect(rig.session.callSetupTask == nil && rig.session.callGeneration != before)
        await rig.settle()
        #expect(!rig.running)
    }

    func share(_ session: SignalSession) -> UInt64 {
        session.lastScreenShareToken &+= 1
        session.screenCapture = ScreenShareCapture(onFrame: { _ in }, onStop: { _ in })
        session.screenShareToken = session.lastScreenShareToken
        return session.lastScreenShareToken
    }

    /// An old stream's late error does not stop the share that replaced it.
    @Test func oldStreamErrorLeavesTheNewShare() {
        let rig = Rig()
        let old = share(rig.session)
        let new = share(rig.session)
        rig.session.screenShareStopped(token: old, error: nil)
        #expect(rig.session.screenCapture != nil && rig.session.screenShareToken == new)
        rig.session.screenShareStopped(token: new, error: nil)
        #expect(rig.session.screenCapture == nil && rig.session.screenShareToken == nil)
    }

    /// What a queued start (and a late frame) checks before capturing: a newer share, a stop,
    /// or a hang-up since it was asked make it stale.
    @Test func staleSharesAreNotCurrent() {
        let rig = Rig()
        let s = rig.session
        let first = share(s)
        let generation = s.callGeneration
        #expect(s.isCurrentScreenShare(first, generation: generation, conversationId: "c1"))
        let second = share(s)
        #expect(!s.isCurrentScreenShare(first, generation: generation, conversationId: "c1"))
        #expect(s.isCurrentScreenShare(second, generation: generation, conversationId: "c1"))
        s.stopPresenting()
        #expect(!s.isCurrentScreenShare(second, generation: generation, conversationId: "c1"))
        let third = share(s)
        s.hangUp()
        #expect(!s.isCurrentScreenShare(third, generation: generation, conversationId: "c1"))
        #expect(s.screenCapture == nil)
    }
}

