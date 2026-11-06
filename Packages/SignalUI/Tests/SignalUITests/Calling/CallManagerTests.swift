// CallManager stories: the routing (lobby / call screen / need permission), and the call
// screen for a call link we administer, with its requests to join. getDefaultConversation's
// avatars (kitten-N) are read back from each capture.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CallManagerTests {
    static let funLink = CallingConversation(id: "link", title: "Fun Link", color: "A200", conversationType: .callLink)

    static func dom(_ story: String, _ theme: String) -> StoryDOM { StoryDOM("components-callmanager--\(story)", theme: theme) }

    static func me(_ dom: StoryDOM) -> CallingConversation {
        // The self view's avatar is the last Avatar image in the capture.
        let image = dom.nodes.last { $0.cls.contains("module-Avatar__image") }?.fixture.flatMap { fixtureImage($0) }
        return CallingConversation(id: "me", title: "Morty Smith", color: "A100", avatar: image, isMe: true, aci: "me")
    }

    static func callLinkScreen(_ story: String, theme: String, pendingCount: Int, firstUnknown: Bool = false, firstInContacts: Bool = false,
                               participantsOpen: Bool = false) -> some View {
        let d = dom(story, theme)
        let first = d.nodes.first { $0.cls.contains("module-Avatar__image") }?.fixture.flatMap { fixtureImage($0) }
        let firstColor = CallingAdhocCallInfoTests.colorName(d.nodes.first { $0.cls.contains("module-Avatar__contents") }?.style["color"])
        let pending = (0..<pendingCount).map { i in
            i == 0 && firstUnknown
                ? CallingParticipant(conversation: CallingConversation(id: "u", title: "Unknown contact", color: "A200", aci: "aci-u"), isUnknownContact: true)
                : CallingParticipant(conversation: CallingConversation(id: "p\(i + 2)", title: "Participant \(i + 2)", color: i == 0 ? firstColor : "A100",
                                                                       avatar: i == 0 ? first : nil, aci: "aci-\(i + 2)"),
                                     isInSystemContacts: i == 0 && firstInContacts)
        }
        let meRow = d.nodes.filter { $0.cls.contains("module-Avatar__image") }.dropFirst().first?.fixture.flatMap { fixtureImage($0) }
        let panel: AnyView? = participantsOpen
            ? AnyView(CallingAdhocCallInfo(participants: [CallingParticipant(conversation: CallingConversation(id: "me", title: "Morty Smith", color: "A100",
                                                                                                                avatar: meRow, isMe: true, aci: "me"),
                                                                             hasRemoteAudio: true)],
                                           ourAci: "me", isUnknownContactDiscrete: true, onClose: {}, onCopyCallLink: {}, onShareCallLinkViaSignal: {}))
            : nil
        let model = CallScreenModel(mode: .group(isAdhoc: true, connectionState: .connected, joinState: .joined, participants: [], viewMode: .paginated,
                                                 raisedHands: [], localDemuxId: 1, outgoingRing: false, presenting: [], speakerTime: [:],
                                                 audioLevels: [:], videoSource: { _ in nil }),
                                    conversation: funLink, me: me(d), hasLocalAudio: true, hasLocalVideo: true, isCallLinkAdmin: true,
                                    pendingParticipants: pending)
        return CallManager(activeCall: CallManagerActiveCall(stage: .screen, conversation: funLink, lobby: { AnyView(EmptyView()) },
                                                             screen: { AnyView(CallScreen(model: model, now: Date(timeIntervalSince1970: 60))) },
                                                             pip: { AnyView(EmptyView()) }, participantsPanel: panel),
                           ringingCall: nil)
    }

    @Test(arguments: [("call-link-with-join-requests-one", 1), ("call-link-with-join-requests-two", 2), ("call-link-with-join-requests-many", 10)],
          ["light", "dark"])
    func joinRequests(_ s: (String, Int), theme: String) throws {
        try Snapshot.assertMatches(Self.callLinkScreen(s.0, theme: theme, pendingCount: s.1), story: "components-callmanager--\(s.0)", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func joinRequestVariants(theme: String) throws {
        try Snapshot.assertMatches(Self.callLinkScreen("call-link-with-join-request-unknown-contact", theme: theme, pendingCount: 3, firstUnknown: true),
                                   story: "components-callmanager--call-link-with-join-request-unknown-contact", theme: theme)
        try Snapshot.assertMatches(Self.callLinkScreen("call-link-with-join-requests-system-contact", theme: theme, pendingCount: 1, firstInContacts: true),
                                   story: "components-callmanager--call-link-with-join-requests-system-contact", theme: theme)
        try Snapshot.assertMatches(Self.callLinkScreen("call-link-with-join-requests-system-contact-many", theme: theme, pendingCount: 3,
                                                       firstInContacts: true),
                                   story: "components-callmanager--call-link-with-join-requests-system-contact-many", theme: theme)
        try Snapshot.assertMatches(Self.callLinkScreen("call-link-with-join-requests-participants-open", theme: theme, pendingCount: 3,
                                                       participantsOpen: true),
                                   story: "components-callmanager--call-link-with-join-requests-participants-open", theme: theme)
    }

    /// OngoingDirectCall and CallRequestNeeded: an accepted 1:1 call with Rick (Storybook
    /// draws no frame for the remote video, so his avatar shows); RemoteHangupNeedPermission
    /// only matters once the call has ended.
    @Test(arguments: ["ongoing-direct-call", "call-request-needed"], ["light", "dark"])
    func directCall(story: String, theme: String) throws {
        let d = Self.dom(story, theme)
        let model = CallScreenModel(mode: .direct(state: .accepted, hasRemoteVideo: true, hasRemoteAudio: true, remoteAudioLevel: 0,
                                                  joinedAt: Date(timeIntervalSince1970: 0), remoteVideo: nil),
                                    conversation: CallScreenTests.rick, me: Self.me(d), hasLocalAudio: true, hasLocalVideo: false)
        #expect(CallManagerStage.direct(hasCallState: true, endedNeedingPermission: false, pip: false) == .screen)
        let view = CallManager(activeCall: CallManagerActiveCall(stage: .screen, conversation: CallScreenTests.rick, lobby: { AnyView(EmptyView()) },
                                                                 screen: { AnyView(CallScreen(model: model, now: Date(timeIntervalSince1970: 60))) },
                                                                 pip: { AnyView(EmptyView()) }),
                               ringingCall: nil)
        try Snapshot.assertMatches(view, story: "components-callmanager--\(story)", theme: theme)
    }

    @Test func routing() {
        #expect(CallManagerStage.direct(hasCallState: false, endedNeedingPermission: false, pip: false) == .lobby)
        #expect(CallManagerStage.direct(hasCallState: true, endedNeedingPermission: true, pip: true) == .needPermission)
        #expect(CallManagerStage.direct(hasCallState: true, endedNeedingPermission: false, pip: true) == .pip)
        #expect(CallManagerStage.group(joinState: .pending, pip: false) == .lobby)
        #expect(CallManagerStage.group(joinState: .joined, pip: false) == .screen)
    }

    /// The panel's rows: known peeked participants (title, colour, kitten, muted) and the
    /// unknown ones folded into the "+N more" row. Inline emoji (FunInlineEmoji) sit between
    /// the two spaces they leave in the title text.
    static func peeked(_ d: StoryDOM) -> [CallingParticipant] {
        var out: [CallingParticipant] = []
        for (i, nodes) in d.groups(startingWith: "module-calling-participants-list__contact").enumerated() {
            let contents = nodes.filter { $0.cls.split(separator: " ").contains("module-Avatar__contents") }
            if nodes.contains(where: { $0.cls.contains("CallingAdhocCallInfo__UnknownContactAvatar") }) {
                let label = nodes.first { $0.cls.contains("module-calling-participants-list__name") }?.text ?? ""
                let count = Int(label.filter(\.isNumber)) ?? contents.count
                for k in 0..<count {
                    let color = CallingAdhocCallInfoTests.colorName(contents[min(k, contents.count - 1)].style["color"])
                    out.append(CallingParticipant(conversation: CallingConversation(id: "u\(i)-\(k)", title: "Unknown contact",
                                                                                    aci: CallingAdhocCallInfoTests.aci(for: color, k)),
                                                  isUnknownContact: true))
                }
                continue
            }
            var title = nodes.first { $0.text != nil && !$0.text!.isEmpty && !$0.cls.contains("FunInlineEmoji") }?.text ?? ""
            if let emoji = nodes.first(where: { $0.cls.contains("FunInlineEmoji") })?.text {
                title = title.replacingOccurrences(of: "  ", with: " \(emoji) ")
            } else {
                title = title.replacingOccurrences(of: "  ", with: " ")
            }
            let image = nodes.first { $0.cls.contains("module-Avatar__image") }?.fixture.flatMap { fixtureImage($0) }
            out.append(CallingParticipant(conversation: CallingConversation(id: "p\(i)", title: title, color: CallingAdhocCallInfoTests.colorName(contents.first?.style["color"]),
                                                                            avatar: image, aci: "aci-\(i)"),
                                          hasRemoteAudio: !nodes.contains { $0.cls.contains("__muted--audio") }))
        }
        return out
    }

    @Test(arguments: ["call-link-lobby-participants-known", "call-link-lobby-participants-1-unknown", "call-link-lobby-participants-1-known-1-unknown",
                      "call-link-lobby-participants-1-known-2-unknown", "call-link-lobby-participants-1-known-12-unknown",
                      "call-link-lobby-participants-3-unknown"], ["light", "dark"])
    func callLinkLobby(story: String, theme: String) throws {
        let d = Self.dom(story, theme)
        let participants = Self.peeked(d)
        // The subtitle's first names ("Bernadine, Regan, and Nyah are in this call").
        let subtitle = d.nodes.first { $0.cls.contains("CallingPreCallInfo__subtitle") }?.text ?? ""
        let firstNames = subtitle.hasSuffix(" are in this call") && !subtitle.first!.isNumber
            ? subtitle.replacingOccurrences(of: " are in this call", with: "").replacingOccurrences(of: ", and ", with: ", ").components(separatedBy: ", ")
            : []
        var known = 0
        let peeked = participants.map { p -> PeekedParticipant in
            var c = p.conversation
            if !p.isUnknownContact, known < firstNames.count { c.firstName = firstNames[known]; known += 1 }
            return PeekedParticipant(c, isKnown: !p.isUnknownContact)
        }
        let me = CallingConversation(id: "me", title: "Morty Smith", color: "A100", avatar: fixtureImage("kitten-1-64-64.jpg"), isMe: true, aci: "me")
        let lobby = CallingLobby(callMode: .adhoc, conversation: Self.funLink, me: me, peekedParticipants: peeked, hasLocalAudio: true, hasLocalVideo: true,
                                 outgoingRing: false)
        let panel = CallingAdhocCallInfo(participants: participants, ourAci: "me", participantMenuDisabled: true, onClose: {}, onCopyCallLink: {},
                                         onShareCallLinkViaSignal: {})
        let view = CallManager(activeCall: CallManagerActiveCall(stage: .lobby, conversation: Self.funLink, lobby: { AnyView(lobby) },
                                                                 screen: { AnyView(EmptyView()) }, pip: { AnyView(EmptyView()) },
                                                                 participantsPanel: AnyView(panel)),
                               ringingCall: nil)
        try Snapshot.assertMatches(view, story: "components-callmanager--\(story)", theme: theme)
    }
}
