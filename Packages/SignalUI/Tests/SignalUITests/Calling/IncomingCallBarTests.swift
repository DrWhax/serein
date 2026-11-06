import SwiftUI
import Testing
@testable import SignalUI

/// IncomingCallBar stories: the fixed container is the 1200px viewport (16px inline padding),
/// the capture starts at (16, 22) and is cut at the viewport's right edge.
@MainActor
@Suite struct IncomingCallBarTests {
    static let rick = CallingConversation(id: "3051234567", title: "Rick Sanchez", color: "A130")
    static let tahoe = CallingConversation(id: "g", title: "Tahoe Trip", color: "A110", conversationType: .group)
    static func member(_ first: String, _ title: String) -> CallingConversation { CallingConversation(id: title, title: title, firstName: first) }

    func bar(_ c: CallingConversation, _ mode: IncomingCallBar.Mode) -> some View {
        IncomingCallBar(conversation: c, mode: mode, acceptCall: { _ in }, declineCall: {})
            .frame(width: 1232)
            .offset(x: -16)
            .frame(width: 1184, height: 70, alignment: .topLeading)
            .clipped()
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let ringer = Self.member("Rick", "Rick Sanchez")
        let others = [Self.member("Morty", "Morty Smith"), Self.member("Summer", "Summer Smith"), Self.member("Beth", "Beth Sanchez"),
                      Self.member("Jerry", "Beth Smith")]
        let cases: [(String, CallingConversation, IncomingCallBar.Mode)] = [
            ("incoming-direct-call-video", Self.rick, .direct(isVideoCall: true)),
            ("incoming-direct-call-audio", Self.rick, .direct(isVideoCall: false)),
            ("incoming-group-call-only-calling-you", Self.tahoe, .group(ringer: ringer, otherMembersRung: [])),
            ("incoming-group-call-calling-you-and-1-other", Self.tahoe, .group(ringer: ringer, otherMembersRung: Array(others.prefix(1)))),
            ("incoming-group-call-calling-you-and-2-others", Self.tahoe, .group(ringer: ringer, otherMembersRung: Array(others.prefix(2)))),
            ("incoming-group-call-calling-you-and-3-others", Self.tahoe,
             .group(ringer: ringer, otherMembersRung: [others[0], others[1], Self.member("Beth", "Beth Smith")])),
            ("incoming-group-call-calling-you-and-4-others", Self.tahoe, .group(ringer: ringer, otherMembersRung: others)),
        ]
        for (name, c, mode) in cases {
            try Snapshot.assertMatches(bar(c, mode), story: "components-incomingcallbar--\(name)", theme: theme)
        }
    }
}
