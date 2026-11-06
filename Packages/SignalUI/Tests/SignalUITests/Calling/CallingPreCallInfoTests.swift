import SwiftUI
import Testing
@testable import SignalUI

/// CallingPreCallInfo stories. Storybook's fake conversations (getDefaultConversation) are
/// "Carmine Hane" with the kitten-1 avatar; the inputs below reproduce each capture's text.
@MainActor
@Suite struct CallingPreCallInfoTests {
    static let kitten = fixtureImage("kitten-1-64-64.jpg")
    static let carmine = CallingConversation(id: "carmine", title: "Carmine Hane", firstName: "Carmine", avatar: kitten)
    static let tahoe = CallingConversation(id: "tahoe", title: "Tahoe Trip", avatar: kitten, conversationType: .group)
    static let funLink = CallingConversation(id: "link", title: "Fun Link", color: "A200", conversationType: .callLink)
    static func person(_ first: String) -> CallingConversation { CallingConversation(id: first, title: "\(first) X", firstName: first) }

    func info(_ c: CallingConversation, _ ring: RingMode, members: [CallingConversation] = [], full: Bool = false,
              peeked: [PeekedParticipant] = [], meAci: String? = nil) -> some View {
        CallingPreCallInfo(conversation: c, meId: "me", meAci: meAci, ringMode: ring, groupMembers: members, isCallFull: full, peekedParticipants: peeked)
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let unknown = PeekedParticipant(CallingConversation(id: "u", title: "Unknown contact"), isKnown: false)
        let known = PeekedParticipant(Self.carmine)
        let peek = ["Mattie", "Bernadine", "Regan", "Zed"].map { PeekedParticipant(Self.person($0)) }
        var cases: [(String, AnyView)] = [
            ("direct-conversation", AnyView(info(Self.carmine, .willRing))),
            ("group-conversation-call-is-full", AnyView(info(Self.tahoe, .willRing, members: [Self.carmine], full: true))),
            ("group-conversation-you-on-an-other-device",
             AnyView(info(Self.tahoe, .willRing, peeked: [PeekedParticipant(CallingConversation(id: "me", title: "Me", aci: "me-aci"))], meAci: "me-aci"))),
            ("call-link-unknown-contact", AnyView(info(Self.funLink, .willNotRing, peeked: [unknown]))),
            ("call-link-1-known-1-unknown-contact", AnyView(info(Self.funLink, .willNotRing, peeked: [known, unknown]))),
            ("call-link-1-known-2-unknown-contacts", AnyView(info(Self.funLink, .willNotRing, peeked: [known, unknown, unknown]))),
            ("call-link-3-unknown-contacts", AnyView(info(Self.funLink, .willNotRing, peeked: [unknown, unknown, unknown]))),
        ]
        for n in 0...4 {
            cases.append(("ring-\(n)", AnyView(info(Self.tahoe, .willRing, members: [Self.carmine]))))
            cases.append(("notify-\(n)", AnyView(info(Self.tahoe, .willNotRing, members: [Self.carmine]))))
        }
        for n in 1...4 { cases.append(("peek-\(n)", AnyView(info(Self.tahoe, .willRing, peeked: Array(peek.prefix(n)))))) }
        for (name, view) in cases {
            try Snapshot.assertMatches(view, story: "components-callingprecallinfo--\(name)", theme: theme)
        }
    }

    /// The subtitle rules beyond what the captures show.
    @Test func subtitles() {
        let i18n = DefaultLocalizer.english
        func s(_ ring: RingMode, _ members: Int, connecting: Bool = false) -> String {
            CallingPreCallInfo.subtitle(i18n: i18n, conversation: Self.tahoe, meId: "me", meAci: nil, ringMode: ring,
                                        groupMembers: (0..<members).map { Self.person("P\($0)") } + [CallingConversation(id: "me", title: "Me")],
                                        isCallFull: false, isConnecting: connecting, peekedParticipants: [])
        }
        #expect(s(.willRing, 0) == i18n("icu:calling__pre-call-info--empty-group"))
        #expect(s(.willRing, 2).contains("P0") && s(.willRing, 2).contains("P1"))
        #expect(s(.willNotRing, 5).contains("3"))
        #expect(s(.isRinging, 2) == i18n("icu:outgoingCallRinging"))
        #expect(s(.isRinging, 2, connecting: true) == i18n("icu:outgoingCallConnecting"))
    }
}
