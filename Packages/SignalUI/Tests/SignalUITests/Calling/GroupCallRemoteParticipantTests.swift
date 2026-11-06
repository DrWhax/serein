import SwiftUI
import Testing
@testable import SignalUI

/// GroupCallRemoteParticipant stories: 120px tiles (no frames arrive, so the blurred avatar
/// shows). The captures start 12px above-left of the tile (the ×1.2 blur layer's box).
@MainActor
@Suite struct GroupCallRemoteParticipantTests {
    static let title = "Pablo Diego José Francisco de Paula Juan Nepomuceno María de los Remedios Cipriano de la Santísima Trinidad Ruiz y Picasso"
    static func participant(kitten: Int = 2, audio: Bool = false, blocked: Bool = false, keys: Bool = true, hand: Int? = nil, only: Bool = false)
        -> GroupCallRemoteParticipantInfo {
        GroupCallRemoteParticipantInfo(demuxId: 123, conversation: CallingConversation(id: "p\(kitten)", title: title, avatar: fixtureImage("kitten-\(kitten)-64-64.jpg")),
                                       hasRemoteAudio: audio, isBlocked: blocked, mediaKeysReceived: keys, raisedHandOrder: hand, isOnlyHandRaised: only)
    }

    func tile(_ p: GroupCallRemoteParticipantInfo, audioLevel: Double = 0, count: Int = 1) -> some View {
        GroupCallRemoteParticipant(participant: p, width: 120, height: 120, audioLevel: audioLevel, remoteParticipantsCount: count)
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let at12 = { (v: AnyView) in AnyView(v.padding(.leading, 12).padding(.top, 12)) }
        let cases: [(String, AnyView)] = [
            ("default", at12(AnyView(tile(Self.participant())))),
            ("hand-raised-only-one", at12(AnyView(tile(Self.participant(hand: 0, only: true))))),
            ("hand-raised-first-of-many", at12(AnyView(tile(Self.participant(hand: 0))))),
            ("hand-raised-second-of-many", at12(AnyView(tile(Self.participant(hand: 1))))),
            ("no-media-keys", at12(AnyView(tile(Self.participant(audio: true, keys: false))))),
            ("no-media-keys-blocked-intermittent", at12(AnyView(tile(Self.participant(keys: false))))),
            ("blocked", AnyView(tile(Self.participant(blocked: true)))),
            ("speaking", at12(AnyView(HStack(alignment: .top, spacing: 10) {
                tile(Self.participant(kitten: 2, audio: true), audioLevel: 0.5, count: 1)
                tile(Self.participant(kitten: 1, audio: true), audioLevel: 0.5, count: 2)
                tile(Self.participant(kitten: 2, audio: true), audioLevel: 0.5, count: 2)
            }))),
        ]
        for (name, view) in cases {
            try Snapshot.assertMatches(view, story: "components-groupcallremoteparticipant--\(name)", theme: theme)
        }
    }
}
