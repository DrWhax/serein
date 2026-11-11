// Regression tests for the call/capture defects the Lean model found and that are now fixed
// (Verification/CallCapture, README "Defects"). Each drives production through the conformance
// rig with the scenario that showed the defect (in the oracle's event notation: `run.k` runs the
// k-th pending main-actor job) and checks the behaviour the fix gives.

import Testing
@testable import SignalSafe

@MainActor @Suite struct CallCaptureDefectRegressions {
    /// Runs `events`; `effects` is every effect production requested, in order.
    func run(_ events: String) async -> (rig: CallRig, effects: [String]) {
        let rig = CallRig(cfg: [0, 0, 0, 0])
        var effects: [String] = []
        for e in events.split(separator: " ") {
            rig.log = []
            await rig.step(String(e))
            effects += rig.log
        }
        return (rig, effects)
    }

    /// D1: video turned off between Start and the call starting stays off; the camera does not
    /// start, and the service hears the choice.
    @Test func videoOffDuringSetupStaysOff() async {
        let (rig, effects) = await run("open.1.1 run.0 start run.0 video.0 setup.0.1 run.0 run.0 run.0 cacc.1 run.0")
        #expect(!rig.session.callLocalVideo)
        #expect(!effects.contains { $0.hasPrefix("cs") }, "camera start requested after the user turned video off")
        #expect(effects.contains("video1.0"), "the service was not told video is off")
        await rig.finish()
    }

    /// D1: video turned on during setup stays on (and the service hears it), so a running camera
    /// matches what the call shows.
    @Test func videoOnDuringSetupStaysOn() async {
        let (rig, effects) = await run("open.0.0 run.0 start run.0 video.1 run.0 cacc.1 run.0 cstart.1 run.0 setup.0.1 run.0 run.0 run.0 run.0")
        #expect(rig.session.callLocalVideo)
        #expect(effects.contains("video0.1"))
        #expect(rig.session.cameraWanted == rig.session.cameraReconciler.isRunning)
        await rig.finish()
    }

    /// D2: the previous call's late `ended` does not close the new lobby for the same contact.
    @Test func lateEndOfPreviousCallLeavesTheNewLobby() async {
        let (rig, _) = await run("open.0.0 run.0 start run.0 setup.0.1 run.0 run.0 nst.R run.0 hangup run.0 run.0 run.0 open.0.0 run.0 nend.L run.0 run.0 run.0")
        #expect(rig.session.activeCall?.conversationId == "c0", "the new lobby was closed")
        await rig.finish()
    }

    /// D2: a rejected offer from the contact (no call of ours) leaves the lobby.
    @Test func rejectedOfferLeavesTheLobby() async {
        let (rig, _) = await run("open.0.0 run.0 nrej.0 run.0")
        #expect(rig.session.activeCall?.conversationId == "c0")
        await rig.finish()
    }

    /// D2: a call from the contact whose lobby is open does not drive the lobby.
    @Test func incomingCallDoesNotDriveTheLobby() async {
        let (rig, _) = await run("open.0.0 run.0 nin.0.1 run.0 nst.R run.0")
        #expect(rig.session.activeCall?.directState == nil)
        await rig.finish()
    }

    /// D2: a rejected offer from the contact no longer ends the call the user accepted, so no
    /// lobby takes its place to be marked accepted by it: the call on screen is still the one
    /// that rang and was accepted.
    @Test func acceptedCallIsNotEndedByARejectedOffer() async {
        let (rig, _) = await run("nin.0.1 run.0 nst.R run.0 accept.0.1 run.0 nrej.0 run.0 open.0.0 nst.A run.0 run.0")
        #expect(rig.session.activeCall?.callId == 0)
        #expect(rig.session.activeCall?.stage == .inCall && rig.session.activeCall?.isLive == true)
        await rig.finish()
    }

    /// D3: `acceptCall` tears down the call it replaces: the old call's share starts nothing.
    @Test func acceptCallTearsDownTheCallItReplaces() async {
        let (rig, effects) = await run("open.0.1 run.0 toggle run.0 src.0.1 run.0 accept.0.1 pick run.0 run.0")
        #expect(!effects.contains { $0.hasPrefix("sb") }, "a stream was started for the replaced call's share")
        await rig.finish()
    }

    /// D4: a new share stops the capture of the one it replaces; no stream runs without an owner.
    @Test func noRunningStreamIsDropped() async {
        let (rig, _) = await run("open.0.1 run.0 start run.0 setup.0.1 run.0 run.0 toggle run.0 src.0.1 run.0 pick run.0 sstart.0.1 run.0 run.0 nend.R toggle run.0 run.0 run.0 run.0 run.0 run.0")
        let orphaned = rig.streams.filter { $0.phase == "running" && rig.session.screenCapture !== rig.caps[$0.owner] }
        #expect(orphaned.isEmpty, "stream \(orphaned.map(\.j)) runs with no owner to stop it")
        await rig.finish()
    }

    /// D5: the share button's task that starts after the hang-up asks ScreenCaptureKit for nothing.
    @Test func sourcesTaskStartingAfterTheHangUpTakesNoThumbnails() async {
        let (rig, effects) = await run("open.0.0 run.0 start run.0 setup.0.1 run.0 run.0 toggle hangup run.0 run.0 run.0 run.0 run.0")
        #expect(!effects.contains { $0.hasPrefix("ss") }, "sources requested after the hang-up")
        await rig.finish()
    }

    /// D5: the setup task that starts after the lobby closed asks for no call.
    @Test func setupTaskStartingAfterTheLobbyClosedAsksForNoCall() async {
        let (rig, effects) = await run("open.0.0 run.0 start close run.0 run.0 run.0")
        #expect(!effects.contains { $0.hasPrefix("start") }, "startOutgoingDirectCall after the lobby closed")
        #expect(rig.service.ncall == nil)
        await rig.finish()
    }
}
