// The call UI over the window (upstream SmartCallManager): CallManager with the active call's
// lobby, call screen and picture-in-picture, or the incoming call bar; the ringtone; and the
// display kept awake while a call is up.

import SignalCore
import SignalI18n
import SignalRingRTC
import SignalUI
import SwiftUI

struct AppCallManager: View {
    @Bindable var session: SignalSession
    let model: AppModel
    let i18n: Localizer
    @State private var viewMode = CallViewMode.paginated

    var body: some View {
        CallManager(activeCall: active, ringingCall: ringing, acceptCall: { session.acceptCall($0, video: $1) }, declineCall: { session.declineCall($0) },
                    playRingtone: { session.playRingtone() }, stopRingtone: { session.stopRingtone() },
                    setOutgoingRing: { session.activeCall?.outgoingRing = $0 }, setIsCallActive: { model.isCallActive = $0 })
    }

    func callingConversation(_ id: String) -> CallingConversation? {
        if let link = session.callLink(id) {
            return CallingConversation(id: id, title: session.callLinkTitle(link, i18n("icu:calling__call-link-default-title")), color: "A200",
                                       conversationType: .callLink)
        }
        guard let c = session.conversation(id) else { return nil }
        return CallingConversation(id: c.id, title: c.title, color: c.color, avatar: session.avatarImage(c.avatar),
                                   conversationType: c.kind == .group ? .group : .direct, aci: c.serviceId, acceptedMessageRequest: c.isAccepted)
    }

    func person(_ aci: String) -> CallingConversation {
        CallingConversation(id: aci, title: session.contactTitle(aci), color: session.contactColor(aci),
                            avatar: session.avatarImage(session.contacts[aci]?.avatar), aci: aci)
    }

    var me: CallingConversation {
        CallingConversation(id: session.ourAci ?? "me", title: i18n("icu:you"), isMe: true, aci: session.ourAci)
    }

    var ringing: CallManagerRingingCall? {
        guard let r = session.ringingCall, let c = callingConversation(r.conversationId) else { return nil }
        return CallManagerRingingCall(conversation: c, mode: .direct(isVideoCall: r.isVideo))
    }

    var groupMembers: [CallingConversation] {
        let me = session.ourAci
        return (session.details?.group?.membersV2.map(\.aci) ?? []).filter { $0 != me }.map(person)
    }

    var active: CallManagerActiveCall? {
        guard let a = session.activeCall, let c = callingConversation(a.conversationId) else { return nil }
        let _ = a.groupRevision
        let group = a.isGroup ? session.calling?.groupCall(for: a.conversationId) : nil
        let stage: CallManagerStage
        if a.stage == .lobby {
            stage = .lobby
        } else if a.isGroup {
            stage = .group(joinState: GroupCallJoinState(rawValue: group?.localDeviceState.joinState.rawValue ?? 0) ?? .notJoined, pip: session.callPip)
        } else {
            stage = .direct(hasCallState: a.directState != nil, endedNeedingPermission: a.endedNeedingPermission, pip: session.callPip)
        }
        let sources = session.presentingSources.map { s in
            AnyView(CallingSelectPresentingSourcesModal(sources: s, onSourceSelect: { session.startPresenting($0) },
                                                        onCancel: { session.cancelPresentingSources() }))
        }
        return CallManagerActiveCall(stage: stage, conversation: c, lobby: { AnyView(lobby(a, c)) }, screen: { AnyView(screen(a, c, group)) },
                                     pip: { AnyView(pip(a, c, group)) }, presentingSources: sources,
                                     mightBeRingingOutgoingGroupCall: a.isGroup && !a.isCallLink && a.outgoingRing,
                                     closeNeedPermissionScreen: { session.endCallUI() })
    }

    func lobby(_ a: ActiveCallState, _ c: CallingConversation) -> some View {
        CallingLobby(callMode: a.isCallLink ? .adhoc : a.isGroup ? .group : .direct, conversation: c, me: me,
                     groupMembers: a.isGroup && !a.isCallLink ? groupMembers : [],
                     hasLocalAudio: session.callLocalAudio, hasLocalVideo: session.callLocalVideo, outgoingRing: a.outgoingRing,
                     localVideo: session.callLocalVideoModel, setLocalAudio: { session.setCallAudio($0) }, setLocalVideo: { session.setCallVideo($0) },
                     setOutgoingRing: { session.activeCall?.outgoingRing = $0 }, onJoinCall: { session.startCallFromLobby() },
                     onCallCanceled: { session.endCallUI() }, togglePip: { session.callPip.toggle() })
    }

    func participants(_ a: ActiveCallState, _ group: GroupCall?) -> [GroupCallRemoteParticipantInfo] {
        (group?.remoteDeviceStates ?? []).compactMap { d in
            guard let aci = SignalSession.aci(d.userId) else { return nil }
            return GroupCallRemoteParticipantInfo(demuxId: d.demuxId, conversation: person(aci), hasRemoteAudio: d.audioMuted == false,
                                                  hasRemoteVideo: d.videoMuted == false, mediaKeysReceived: d.mediaKeysReceived,
                                                  sharingScreen: d.sharingScreen == true, videoAspectRatio: d.videoAspectRatio ?? 1.3,
                                                  addedTime: Int64(d.addedTime))
        }
    }

    func screenModel(_ a: ActiveCallState, _ c: CallingConversation, _ group: GroupCall?) -> CallScreenModel {
        let mode: CallScreenModel.Mode
        if a.isGroup, let group {
            let local = group.localDeviceState
            let states = group.remoteDeviceStates ?? []
            let id = a.conversationId
            mode = .group(isAdhoc: a.isCallLink, connectionState: GroupCallConnectionState(rawValue: local.connectionState.rawValue) ?? .notConnected,
                          joinState: GroupCallJoinState(rawValue: local.joinState.rawValue) ?? .notJoined, participants: participants(a, group),
                          viewMode: viewMode, raisedHands: [], localDemuxId: local.demuxId, outgoingRing: a.outgoingRing,
                          presenting: Set(states.filter { $0.presenting == true }.map(\.demuxId)),
                          speakerTime: Dictionary(states.map { ($0.demuxId, Double($0.speakerTime)) }, uniquingKeysWith: { x, _ in x }),
                          audioLevels: Dictionary(states.map { ($0.demuxId, Double($0.audioLevel)) }, uniquingKeysWith: { x, _ in x }),
                          videoSource: { session.groupVideoSource(id, $0) })
        } else {
            mode = .direct(state: a.directState ?? .prering, hasRemoteVideo: a.hasRemoteVideo, hasRemoteAudio: a.hasRemoteAudio,
                           remoteAudioLevel: a.remoteAudioLevel, joinedAt: a.acceptedAt, remoteVideo: session.directVideoSource(a.conversationId))
        }
        return CallScreenModel(mode: mode, conversation: c, me: me, groupMembers: a.isGroup && !a.isCallLink ? groupMembers : [],
                               hasLocalAudio: session.callLocalAudio, hasLocalVideo: session.callLocalVideo, localAudioLevel: a.localAudioLevel,
                               isPresenting: session.calling?.isPresenting ?? false, localVideo: session.callLocalVideoModel,
                               isCallLinkAdmin: a.isCallLink && session.callLink(a.conversationId)?.isAdmin == true,
                               pendingParticipants: a.isCallLink ? (group?.peekInfo?.pendingUsers ?? []).compactMap(SignalSession.aci).map {
                                   CallingParticipant(conversation: person($0))
                               } : [])
    }

    func screen(_ a: ActiveCallState, _ c: CallingConversation, _ group: GroupCall?) -> some View {
        var actions = CallScreenActions()
        actions.setLocalAudio = { session.setCallAudio($0) }
        actions.setLocalVideo = { session.setCallVideo($0) }
        actions.hangUp = { session.hangUp() }
        actions.togglePip = { session.callPip.toggle() }
        actions.toggleRaiseHand = { session.calling?.raiseHand(conversationId: a.conversationId, $0) }
        actions.sendReaction = { session.calling?.react(conversationId: a.conversationId, $0) }
        actions.changeCallView = { viewMode = $0 }
        actions.togglePresenting = { session.togglePresenting() }
        // Call links we administer: let people in, or not.
        actions.approveUser = { p in if let aci = p.conversation.aci { session.calling?.approveUser(conversationId: a.conversationId, aci: aci) } }
        actions.denyUser = { p in if let aci = p.conversation.aci { session.calling?.denyUser(conversationId: a.conversationId, aci: aci) } }
        actions.batchUserAction = { action, acis in
            for aci in acis {
                if action == .approve {
                    session.calling?.approveUser(conversationId: a.conversationId, aci: aci)
                } else {
                    session.calling?.denyUser(conversationId: a.conversationId, aci: aci)
                }
            }
        }
        return CallScreen(model: screenModel(a, c, group), actions: actions)
    }

    func pip(_ a: ActiveCallState, _ c: CallingConversation, _ group: GroupCall?) -> some View {
        let remote: CallingPip.Remote
        if a.isGroup {
            let speaker = participants(a, group).max { ($0.addedTime ?? 0) < ($1.addedTime ?? 0) }
            remote = .group(speaker: speaker, source: speaker.map { session.groupVideoSource(a.conversationId, $0.demuxId) })
        } else {
            remote = .direct(hasRemoteVideo: a.hasRemoteVideo, source: session.directVideoSource(a.conversationId))
        }
        return CallingPip(conversation: c, remote: remote, hasLocalAudio: session.callLocalAudio, hasLocalVideo: session.callLocalVideo, isGroupCall: a.isGroup,
                          localVideo: session.callLocalVideoModel, setLocalAudio: { session.setCallAudio($0) }, setLocalVideo: { session.setCallVideo($0) },
                          hangUp: { session.hangUp() }, togglePip: { session.callPip.toggle() })
    }
}
