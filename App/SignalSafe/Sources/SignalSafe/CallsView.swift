// The call UI over the window (upstream SmartCallManager): CallManager with the active call's
// lobby, call screen and picture-in-picture, or the incoming call bar; the ringtone; the display
// kept awake while a call is up; the call's Settings dialog (the header's gear,
// `settingsDialogOpen`: camera, microphone and speaker, as in Settings → Calls); the
// participants panel (`showParticipantsList`); the expanded self view; raised hands, reactions
// and the call's toasts; and a call link's request to join, opened from the admin's list.

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
    /// `settingsDialogOpen`: the gear in the lobby's or the call's header.
    @State private var settingsOpen = false
    /// `showParticipantsList`: the header's participant count (lobby or call).
    @State private var participantsOpen = false
    /// `selfViewExpanded`: the self view's maximize button, a click on it, or ⇧P.
    @State private var selfViewExpanded = false
    /// `toggleCallLinkPendingParticipantModal`: a request to join, from the admin's list.
    @State private var pendingParticipant: CallingParticipant?
    /// The call screen's reaction toasts and button toasts, one set per call.
    @State private var reactions: CallReactionsModel?
    @State private var buttonToasts: CallingButtonToasts?

    var body: some View {
        CallManager(activeCall: active, ringingCall: ringing, shouldRing: { session.ringAllowed($0) },
                    acceptCall: { id, video in
                        if session.ringingCall == nil, session.ringingGroupCall?.conversationId == id {
                            session.acceptGroupRing(video: video)
                        } else {
                            session.acceptCall(id, video: video)
                        }
                    },
                    declineCall: { id in
                        if session.ringingCall == nil, session.ringingGroupCall?.conversationId == id {
                            session.declineGroupRing()
                        } else {
                            session.declineCall(id)
                        }
                    },
                    playRingtone: { session.playRingtone() }, stopRingtone: { session.stopRingtone() },
                    setOutgoingRing: { session.activeCall?.outgoingRing = $0 }, setIsCallActive: { model.isCallActive = $0 })
            // A new call starts without the dialogs, with its own toasts.
            .onChange(of: session.activeCall?.conversationId) {
                settingsOpen = false
                participantsOpen = false
                selfViewExpanded = false
                pendingParticipant = nil
                reactions = session.activeCall == nil ? nil : CallReactionsModel(i18n: i18n)
                buttonToasts = session.activeCall == nil ? nil : CallingButtonToasts(i18n: i18n)
                updateButtonToasts()
            }
            .onChange(of: session.callReactions) { updateReactions() }
            .onChange(of: buttonToastState) { updateButtonToasts() }
    }

    // MARK: toasts

    /// The call state the button toasts follow (`CallingButtonToastsContainer`).
    var buttonToastState: CallingButtonToasts.State? {
        guard let a = session.activeCall, a.stage == .inCall else { return nil }
        let local = a.isGroup ? session.calling?.groupCall(for: a.conversationId)?.localDeviceState.demuxId : nil
        return CallingButtonToasts.State(hasLocalAudio: session.callLocalAudio, outgoingRing: a.isGroup && !a.isCallLink ? a.outgoingRing : nil,
                                         raisedHands: session.callRaisedHands, suggestLowerHand: session.callSuggestLowerHand,
                                         isHandRaised: local.map { session.callRaisedHands.contains($0) } ?? false,
                                         mutedBy: session.callMutedBy, observedRemoteMute: session.callObservedRemoteMute)
    }

    func updateButtonToasts() {
        guard let state = buttonToastState, let id = session.activeCall?.conversationId else { return }
        let local = session.calling?.groupCall(for: id)?.localDeviceState.demuxId
        buttonToasts?.update(state, people: { demux in
            if demux == local { return CallingButtonToasts.Person(title: i18n("icu:you"), isMe: true, aci: session.ourAci) }
            guard let aci = demuxAci(id, demux) else { return nil }
            return CallingButtonToasts.Person(title: session.contactTitle(aci), isMe: aci == session.ourAci, aci: aci)
        }, localDemuxId: local)
    }

    func updateReactions() {
        guard let id = session.activeCall?.conversationId else { return }
        let local = session.calling?.groupCall(for: id)?.localDeviceState.demuxId
        reactions?.update(session.callReactions, people: { demux in
            if demux == local { return (i18n("icu:you"), session.ourAci) }
            return demuxAci(id, demux).map { (session.contactTitle($0), $0) }
        }, localDemuxId: local, ourServiceId: session.ourAci, now: Int64(Date().timeIntervalSince1970 * 1000))
    }

    /// The ACI behind a participant's demux id in the group call.
    func demuxAci(_ conversationId: String, _ demuxId: UInt32) -> String? {
        session.calling?.groupCall(for: conversationId)?.remoteDeviceStates?.first { $0.demuxId == demuxId }.flatMap { SignalSession.aci($0.userId) }
    }

    /// `CallingDeviceSelection`: the call's Settings dialog over the lobby or the call.
    var deviceSelection: AnyView? {
        guard settingsOpen else { return nil }
        let devices = session.callDevices
        return AnyView(CallingDeviceSelection(availableCameras: devices.cameras, availableMicrophones: devices.microphones,
                                              availableSpeakers: devices.speakers, selectedCamera: session.preferredCameraId,
                                              selectedMicrophone: CallDevices.pref(session.preferredMicrophoneId, devices.microphones),
                                              selectedSpeaker: CallDevices.pref(session.preferredSpeakerId, devices.speakers),
                                              onClose: { settingsOpen = false }, onSelectedCameraChange: { session.selectCamera($0) },
                                              onSelectedMicrophoneChange: { session.selectMicrophone($0) },
                                              onSelectedSpeakerChange: { session.selectSpeaker($0) })
            .task { session.refreshCallDevices() })
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
        if let r = session.ringingCall, let c = callingConversation(r.conversationId) {
            return CallManagerRingingCall(conversation: c, mode: .direct(isVideoCall: r.isVideo))
        }
        // A group ring: who rang, and the other members it rang (`otherMembersRung`).
        guard let g = session.ringingGroupCall, let c = callingConversation(g.conversationId) else { return nil }
        let me = session.ourAci
        let members = g.members
        return CallManagerRingingCall(conversation: c, mode: .group(ringer: person(g.ringerAci),
                                                                     otherMembersRung: members.filter { $0 != g.ringerAci && $0 != me }.map(person)))
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
                                     pip: { AnyView(pip(a, c, group)) }, deviceSelection: deviceSelection,
                                     participantsPanel: participantsOpen ? AnyView(participantsPanel(a, group)) : nil, presentingSources: sources,
                                     mightBeRingingOutgoingGroupCall: a.isGroup && !a.isCallLink && a.outgoingRing,
                                     closeNeedPermissionScreen: { session.endCallUI() })
    }

    func lobby(_ a: ActiveCallState, _ c: CallingConversation) -> some View {
        CallingLobby(callMode: a.isCallLink ? .adhoc : a.isGroup ? .group : .direct, conversation: c, me: me,
                     groupMembers: a.isGroup && !a.isCallLink ? groupMembers : [],
                     peekedParticipants: session.peekedAcis(a.conversationId).map { PeekedParticipant(person($0), isKnown: session.contacts[$0] != nil) },
                     hasLocalAudio: session.callLocalAudio, hasLocalVideo: session.callLocalVideo,
                     // A call link that needs an admin's approval, unless it is ours (restrictions 1: adminApproval).
                     isAdhocAdminApprovalRequired: a.isCallLink && session.callLink(a.conversationId).map { !$0.isAdmin && $0.restrictions == 1 } == true,
                     isCallFull: session.isCallFull(a.conversationId),
                     outgoingRing: a.outgoingRing,
                     localVideo: session.callLocalVideoModel, setLocalAudio: { session.setCallAudio($0) }, setLocalVideo: { session.setCallVideo($0) },
                     setOutgoingRing: { session.activeCall?.outgoingRing = $0 }, onJoinCall: { session.startCallFromLobby() },
                     onCallCanceled: { session.endCallUI() }, toggleParticipants: { participantsOpen.toggle() }, togglePip: { session.callPip.toggle() },
                     toggleSettings: { settingsOpen = $0 })
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
                          viewMode: viewMode, raisedHands: session.callRaisedHands, localDemuxId: local.demuxId, outgoingRing: a.outgoingRing,
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
                               isPresenting: session.calling?.isPresenting ?? false, selfViewExpanded: selfViewExpanded, localVideo: session.callLocalVideoModel,
                               isCallLinkAdmin: a.isCallLink && session.callLink(a.conversationId)?.isAdmin == true,
                               pendingParticipants: a.isCallLink ? (group?.peekInfo?.pendingUsers ?? []).compactMap(SignalSession.aci).map {
                                   CallingParticipant(conversation: person($0))
                               } : [])
    }

    func screen(_ a: ActiveCallState, _ c: CallingConversation, _ group: GroupCall?) -> some View {
        var actions = CallScreenActions()
        actions.setLocalAudio = { on in
            if on { session.callMutedBy = nil }     // SET_LOCAL_AUDIO_FULFILLED
            session.setCallAudio(on)
        }
        actions.setLocalVideo = { session.setCallVideo($0) }
        actions.hangUp = { session.hangUp() }
        actions.togglePip = { session.callPip.toggle() }
        actions.toggleRaiseHand = { session.calling?.raiseHand(conversationId: a.conversationId, $0) }
        actions.sendReaction = { session.sendCallReaction($0) }
        actions.changeCallView = { viewMode = $0 }
        actions.togglePresenting = { session.togglePresenting() }
        actions.toggleSettings = { settingsOpen = $0 }
        actions.toggleParticipants = { participantsOpen.toggle() }
        actions.toggleSelfViewExpanded = { selfViewExpanded.toggle() }
        actions.showPendingParticipant = { pendingParticipant = $0 }
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
        return CallScreen(model: screenModel(a, c, group), actions: actions, buttonToasts: buttonToasts, reactions: reactions)
            .overlay {
                if let p = pendingParticipant, let aci = p.conversation.aci {
                    AxoBaseDialog.Host {
                        CallLinkPendingParticipantModal(conversation: p.conversation, isInSystemContacts: p.isInSystemContacts,
                                                        approveUser: {
                                                            session.calling?.approveUser(conversationId: a.conversationId, aci: aci)
                                                            pendingParticipant = nil
                                                        },
                                                        denyUser: {
                                                            session.calling?.denyUser(conversationId: a.conversationId, aci: aci)
                                                            pendingParticipant = nil
                                                        },
                                                        onClose: { pendingParticipant = nil })
                    }
                }
            }
    }

    /// `showParticipantsList`: in the lobby, who the peek found; in the call, everyone in it and
    /// us (`groupCallParticipantsForParticipantsList`). A call link's is CallingAdhocCallInfo,
    /// with its link to copy or share.
    func participantsPanel(_ a: ActiveCallState, _ group: GroupCall?) -> some View {
        let list: [CallingParticipant]
        let inCall = a.stage == .inCall
        if inCall {
            let local = group?.localDeviceState
            list = participants(a, group).map { p in
                CallingParticipant(conversation: p.conversation, demuxId: p.demuxId, hasRemoteAudio: p.hasRemoteAudio, presenting: p.sharingScreen,
                                   isInSystemContacts: false, isUnknownContact: p.conversation.aci.map { session.contacts[$0] == nil } ?? true)
            } + [CallingParticipant(conversation: me, demuxId: local?.demuxId, hasRemoteAudio: session.callLocalAudio,
                                    presenting: session.calling?.isPresenting ?? false)]
        } else {
            list = session.peekedAcis(a.conversationId).map { CallingParticipant(conversation: person($0), isUnknownContact: session.contacts[$0] == nil) }
        }
        let menu: (CallingParticipant) -> CallingParticipantMenuActions = { p in participantMenu(p, call: a, group: group) }
        return Group {
            if a.isCallLink {
                CallingAdhocCallInfo(participants: list, ourAci: session.ourAci, isUnknownContactDiscrete: inCall, participantMenuDisabled: !inCall,
                                     onClose: { participantsOpen = false }, onCopyCallLink: { session.copyCallLink(a.conversationId) },
                                     onShareCallLinkViaSignal: {
                                         participantsOpen = false
                                         session.shareCallLinkViaSignal(a.conversationId) { i18n("icu:ShareCallLinkViaSignal__DraftMessageText", ["url": .string($0)]) }
                                     },
                                     onParticipantMenu: menu)
            } else {
                CallingParticipantsList(participants: list, ourAci: session.ourAci, participantMenuDisabled: !inCall, onClose: { participantsOpen = false },
                                        onParticipantMenu: menu)
            }
        }
    }

    /// SmartCallingParticipantMenu: our own entry mutes or unmutes us; someone else's opens their
    /// chat, and, for a call link we administer, removes or blocks them. Remote mute is behind
    /// upstream's remote-config flag (`desktop.remoteMute.send`), so it is not offered.
    func participantMenu(_ p: CallingParticipant, call a: ActiveCallState, group: GroupCall?) -> CallingParticipantMenuActions {
        var m = CallingParticipantMenuActions()
        m.isMuteAudioDisabled = !p.hasRemoteAudio
        let local = group?.localDeviceState.demuxId
        if let aci = p.conversation.aci, aci == session.ourAci {
            if p.demuxId == local {
                if session.callLocalAudio { m.onMuteAudio = { session.setCallAudio(false) } } else {
                    m.onUnmuteAudio = { session.callMutedBy = nil; session.setCallAudio(true) }
                }
            }
        } else if let aci = p.conversation.aci {
            m.onGoToChat = {
                session.callPip = true
                session.openDirect(serviceId: aci)
            }
        }
        if a.isCallLink, session.callLink(a.conversationId)?.isAdmin == true, let demux = p.demuxId, demux != local {
            m.onBlockFromCall = { session.calling?.blockClient(conversationId: a.conversationId, demuxId: demux) }
            m.onRemoveFromCall = { session.calling?.removeClient(conversationId: a.conversationId, demuxId: demux) }
        }
        return m
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

extension CallDevices {
    /// The saved device in `list`, or the system default.
    static func pref(_ id: String?, _ list: SignalUI.AudioDeviceList) -> AudioDevicePref {
        id.flatMap { id in list.devices.first { $0.uniqueId == id } }.map { .specificDevice($0) } ?? .nonWindowsDefault
    }
}
