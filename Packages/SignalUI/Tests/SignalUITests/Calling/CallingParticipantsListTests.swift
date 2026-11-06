import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CallingParticipantsListTests {
    /// (story, [(row text, avatar colour, muted, in contacts)]) read from each capture.
    static let stories: [(String, [(String, String, Bool, Bool)])] = [
        ("many-participants", [("Chi Chi", "A160", true, false), ("Goku Black", "A140", false, true), ("Prince Vegeta", "A210", false, false), ("Rage Trunks Presenting", "A110", false, true), ("Someone With A Really Long Name", "A180", true, false), ("Son Goku", "A170", true, false), ("Supreme Kai Zamasu", "A100", true, false)]),
        ("no-one", []),
        ("overflow", [("Kirby", "A170", true, false), ("Kirby", "A110", true, false), ("Kirby", "A210", true, false), ("Kirby", "A140", true, false), ("Kirby", "A100", true, false), ("Kirby", "A160", true, false), ("Kirby", "A180", true, false), ("Kirby", "A190", true, false), ("Kirby", "A130", true, false), ("Kirby", "A130", true, false), ("Kirby", "A120", true, false), ("Kirby", "A160", true, false), ("Kirby", "A130", true, false), ("Kirby", "A110", true, false), ("Kirby", "A130", true, false), ("Kirby", "A210", true, false), ("Kirby", "A200", true, false), ("Kirby", "A170", true, false), ("Kirby", "A110", true, false), ("Kirby", "A140", true, false), ("Kirby", "A130", true, false), ("Kirby", "A150", true, false), ("Kirby", "A150", true, false), ("Kirby", "A170", true, false), ("Kirby", "A210", true, false), ("Kirby", "A150", true, false), ("Kirby", "A100", true, false), ("Kirby", "A200", true, false), ("Kirby", "A100", true, false), ("Kirby", "A150", true, false), ("Kirby", "A130", true, false), ("Kirby", "A180", true, false), ("Kirby", "A160", true, false), ("Kirby", "A210", true, false), ("Kirby", "A130", true, false), ("Kirby", "A210", true, false), ("Kirby", "A200", true, false), ("Kirby", "A150", true, false), ("Kirby", "A140", true, false), ("Kirby", "A110", true, false), ("Kirby", "A130", true, false), ("Kirby", "A190", true, false), ("Kirby", "A100", true, false), ("Kirby", "A140", true, false), ("Kirby", "A140", true, false), ("Kirby", "A140", true, false), ("Kirby", "A200", true, false), ("Kirby", "A120", true, false), ("Kirby", "A100", true, false), ("Kirby", "A110", true, false)]),
        ("solo-call", [("Bardock", "A170", true, false)]),
    ]

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        for (story, rows) in Self.stories {
            let ps = rows.enumerated().map { i, r in
                let presenting = r.0.hasSuffix(" Presenting")
                let title = presenting ? String(r.0.dropLast(" Presenting".count)) : r.0
                return CallingParticipant(conversation: CallingConversation(id: "\(i)", title: title, color: r.1), demuxId: UInt32(i), hasRemoteAudio: !r.2,
                                          presenting: presenting, isInSystemContacts: r.3)
            }
            try Snapshot.assertMatches(CallingParticipantsListOverlay(CallingParticipantsList(participants: ps, onClose: {})),
                                       story: "components-callingparticipantslist--\(story)", theme: theme)
        }
    }
}
