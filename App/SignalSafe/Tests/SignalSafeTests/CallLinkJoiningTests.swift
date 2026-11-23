import Foundation
import SignalCore
import SignalRingRTC
import SignalUI
import Testing
@testable import SignalSafe

@MainActor @Suite struct CallLinkJoiningTests {
    private func lobby() throws -> SignalSession {
        let s = SignalSession()
        let root = try CallLinkRootKey.generate()
        s.callLinks = [CallLinkRecord(roomId: "room", rootKey: root.bytes, adminKey: Data([42]))]
        s.openCallLinkLobby("room", audio: false, video: false)
        return s
    }

    @Test func unavailableServiceEndsProgressAndExplainsTheFailure() async throws {
        let s = try lobby()
        s.startCallFromLobby()
        let setup = try #require(s.callSetupTask)
        #expect(s.callLinkJoinTimeoutTask != nil)
        await setup.value
        #expect(s.callLinkJoinTimeoutTask == nil && s.activeCall == nil)
        #expect(s.callLinkModal == .joinFailed(roomId: "room", reason: .ended(.connectionFailure)))
    }

    @Test func stalledJoinReleasesMediaAndRetryKeepsDeviceChoices() throws {
        let s = try lobby()
        s.startCallFromLobby()
        let first = s.callGeneration
        s.callLinkJoinTimedOut(first)
        #expect(s.callLinkModal == .joinFailed(roomId: "room", reason: .ended(.timeout)))
        #expect(s.activeCall == nil && s.callSetupTask == nil && !s.cameraWanted)
        s.retryCallLinkJoin("room")
        #expect(s.activeCall?.isCallLink == true && !s.callLocalAudio && !s.callLocalVideo)
        s.callLinkJoinTimedOut(first)
        #expect(s.callLinkJoinTimeoutTask != nil && s.callLinkModal == nil)
        s.endCallUI()
        #expect(s.callLinkJoinTimeoutTask == nil)
    }

    @Test func approvalAndAdmissionHaveDifferentDeadlines() throws {
        let s = try lobby()
        s.startCallFromLobby()
        let generation = s.callGeneration
        s.updateGroupJoinState(.pending, connection: .connecting)
        #expect(s.callLinkJoinTimeoutTask == nil)
        s.callLinkJoinTimedOut(generation)
        #expect(s.activeCall?.stage == .lobby && s.callLinkModal == nil)
        s.handleCallingEvent(.groupCallEnded(conversationId: "room", reason: .deniedRequestToJoinCall))
        #expect(s.callLinkModal == .joinFailed(roomId: "room", reason: .ended(.deniedRequestToJoinCall)))

        s.openCallLinkLobby("room", audio: false, video: false)
        s.startCallFromLobby()
        s.updateGroupJoinState(.joined, connection: .connecting)
        #expect(s.activeCall?.stage == .inCall && s.callLinkJoinTimeoutTask != nil)
        s.updateGroupJoinState(.joined, connection: .connected)
        #expect(s.callLinkJoinTimeoutTask == nil && s.callLinkModal == nil)
        s.endCallUI()
    }

    @Test func queuedEndCannotCloseAnImmediateRetryForTheSameRoom() async throws {
        let s = try lobby()
        // Hold setup so we can deliver the old end while the retry awaits the service.
        s.mainTasks = MainTasks { _, _ in Task {} }
        s.startCallFromLobby()
        let end = s.enqueueCallingEvent(.groupCallEnded(conversationId: "room", reason: .sfuClientFailedToJoin))
        s.callLinkJoinTimedOut(s.callGeneration)
        s.retryCallLinkJoin("room")
        await end.value
        #expect(s.activeCall?.conversationId == "room" && s.callLinkModal == nil)
        #expect(s.callLinkJoinTimeoutTask != nil)
        s.endCallUI()
    }
}
