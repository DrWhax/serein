// What the call UI shows beyond the call itself (upstream's calling duck): incoming group rings,
// the lobby's peek, raised hands, reactions, the lower-hand hint and remote mutes, and whether a
// ring may sound (notification profiles). None of this starts or ends a call or touches capture:
// a group ring accepted joins through the lobby's own path (`openCallLobby`, then
// `startCallFromLobby`), which the call/capture slice covers.

import AppKit
import Foundation
import GRDB
import SignalCore
import SignalRingRTC
import SignalUI

@MainActor extension SignalSession {
    /// The calling events Calls.swift's `handleCallingEvent` leaves to the extras.
    func handleCallExtrasEvent(_ e: CallingEvent) {
        switch e {
        case .incomingGroupRing(let id, let ringId, let ringer):
            // CallingService already dropped rings while it has a call; one arriving while our
            // lobby (or a 1:1 ring) is up is not shown either, as upstream's ringing bar is not.
            guard activeCall == nil, ringingCall == nil else { return }
            ringingGroupCall = (id, ringId, ringer, [])
            if accountSettings.incomingCallNotification { NSApp.requestUserAttention(.criticalRequest) }
            // The bar names the other members the ring went to.
            if let db = clientDatabase {
                Task { [weak self] in
                    let details = try? await db.pool.read { try ConversationQueries.details($0, conversationId: id) }
                    guard let self, self.ringingGroupCall?.ringId == ringId, let group = details?.group else { return }
                    self.ringingGroupCall?.members = group.membersV2.map(\.aci)
                }
            }
        case .cancelGroupRing(let id, let ringId):
            if ringingGroupCall?.conversationId == id, ringingGroupCall?.ringId == ringId { ringingGroupCall = nil }
        case .peekResult(let id, let info):
            if activeCall?.conversationId == id { callPeek = (id, info) }
        case .groupCallReactions(let id, let reactions):
            guard activeCall?.conversationId == id, activeCall?.stage == .inCall else { return }
            addCallReactions(reactions.map { ($0.demuxId, $0.value) })
        case .groupCallRaisedHands(let id, let hands):
            if activeCall?.conversationId == id { callRaisedHands = hands }
        case .suggestLowerHand(let on):
            if activeCall?.stage == .inCall { callSuggestLowerHand = on }
        case .mutedBy(let demuxId):
            // `setMutedBy`: someone in the call muted us (we can unmute ourselves).
            guard activeCall?.stage == .inCall, callLocalAudio else { return }
            callMutedBy = demuxId
            setCallAudio(false)
        case .observedRemoteMute(let source, let target):
            if activeCall?.stage == .inCall { callObservedRemoteMute = ObservedRemoteMute(source: source, target: target) }
        default:
            break
        }
    }

    /// A new call (or none): nothing of the last one's extras stays.
    func resetCallExtras() {
        callPeek = nil
        callRaisedHands = []
        callReactions = []
        callSuggestLowerHand = false
        callMutedBy = nil
        callObservedRemoteMute = nil
    }

    // MARK: group rings

    /// The ringing bar's accept: upstream joins at once with our audio on and no ring of our own;
    /// here the lobby opens and joins.
    func acceptGroupRing(video: Bool) {
        guard let r = ringingGroupCall else { return }
        ringingGroupCall = nil
        stopRingtone()
        guard activeCall == nil else { return }
        openCallLobby(r.conversationId, video: video)
        activeCall?.outgoingRing = false
        startCallFromLobby()
    }

    func declineGroupRing() {
        guard let r = ringingGroupCall else { return }
        ringingGroupCall = nil
        stopRingtone()
        guard let calling else { return }
        Task { await calling.declineGroupCall(conversationId: r.conversationId, ringId: r.ringId) }
    }

    /// `shouldNotify(isCall: true)`: a ring sounds unless the active notification profile
    /// holds back calls from this chat.
    func ringAllowed(_ conversationId: String) -> Bool {
        guard let db = clientDatabase else { return true }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let profile = (try? db.pool.read { try NotificationProfiles.active($0, time: now) }) ?? nil
        return NotificationProfiles.shouldNotify(isCall: true, isMentionOrReply: false, conversationId: conversationId, activeProfile: profile)
    }

    // MARK: reactions

    /// `GROUP_CALL_REACTIONS_RECEIVED`: the five most recent, each for 4s.
    func addCallReactions(_ new: [(demuxId: UInt32, value: String)]) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        callReactions = Array((callReactions + new.map { CallReaction(timestamp: now, demuxId: $0.demuxId, value: $0.value) }).suffix(5))
        let id = activeCall?.conversationId
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))     // CALLING_REACTIONS_LIFETIME
            guard let self, self.activeCall?.conversationId == id else { return }
            self.callReactions.removeAll { $0.timestamp <= now }
        }
    }

    /// `sendGroupCallReaction`: ringrtc does not echo our own reaction back, so ours is added here.
    func sendCallReaction(_ value: String) {
        guard let id = activeCall?.conversationId, let calling else { return }
        calling.react(conversationId: id, value)
        if let me = calling.groupCall(for: id)?.localDeviceState.demuxId { addCallReactions([(me, value)]) }
    }

    // MARK: peek

    /// The lobby's "N people in this call": who the peek found, once each (`peekInfo.acis`).
    func peekedAcis(_ conversationId: String) -> [String] {
        guard callPeek?.conversationId == conversationId, let devices = callPeek?.info?.devices else { return [] }
        var seen = Set<String>()
        return devices.compactMap { $0.userId.flatMap(Self.aci) }.filter { seen.insert($0).inserted }
    }

    /// `isCallFull`: the peek found as many devices as the call takes.
    func isCallFull(_ conversationId: String) -> Bool {
        guard callPeek?.conversationId == conversationId, let info = callPeek?.info, let max = info.maxDevices else { return false }
        return info.deviceCount >= max
    }
}
