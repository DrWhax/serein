import SwiftUI
import Testing
@testable import SignalUI

/// CallingLobby stories (Storybook's fake conversations: the names, kitten avatars and the
/// blurred own avatar behind the preview come from each capture's DOM).
@MainActor
@Suite struct CallingLobbyTests {
    static func kitten(_ n: Int, _ size: Int = 64) -> RGBAImage? { fixtureImage("kitten-\(n)-\(size)-\(size).jpg") }
    static func me(_ avatar: RGBAImage?) -> CallingConversation {
        CallingConversation(id: "me", title: "Me", color: "A100", avatar: avatar, isMe: true, aci: "me-aci")
    }
    static func person(_ first: String, _ last: String = "X", avatar: RGBAImage? = nil) -> CallingConversation {
        CallingConversation(id: first, title: "\(first) \(last)", firstName: first, avatar: avatar)
    }
    static func tahoe(_ k: Int) -> CallingConversation {
        CallingConversation(id: "tahoe", title: "Tahoe Trip", color: "A130", avatar: kitten(k), conversationType: .group)
    }
    static let funLink = CallingConversation(id: "link", title: "Fun Link", color: "A200", conversationType: .callLink)

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let mattie = Self.person("Mattie", "Grady", avatar: Self.kitten(2))
        let peek = ["Mattie", "Bernadine", "Regan", "Zed", "Yan"].map { PeekedParticipant(Self.person($0)) }
        func lobby(_ mode: CallingLobby.Mode, _ c: CallingConversation, me: Int?, members: [CallingConversation] = [], peeked: [PeekedParticipant] = [],
                   audio: Bool = true, video: Bool = false, camera: Bool = true, full: Bool = false, approval: Bool = false, pending: Bool = false,
                   meAvatar: RGBAImage? = nil) -> AnyView {
            AnyView(CallingLobby(callMode: mode, conversation: c, me: Self.me(meAvatar ?? me.flatMap { Self.kitten($0) }), groupMembers: members,
                                 peekedParticipants: peeked, hasLocalAudio: audio, hasLocalVideo: video, hasCamera: camera,
                                 isAdhocAdminApprovalRequired: approval, isAdhocJoinRequestPending: pending, isCallFull: full, outgoingRing: false,
                                 localVideo: video ? LocalVideoModel() : nil))
        }
        let groupMembers = [Self.me(nil), Self.person("Mattie")]
        let cases: [(String, AnyView)] = [
            ("default", lobby(.direct, mattie, me: 1)),
            ("no-camera-no-avatar", lobby(.direct, mattie, me: 1, camera: false)),
            ("no-camera-local-avatar", lobby(.direct, Self.person("Bernadine", "Feil", avatar: Self.kitten(1)), me: nil, camera: false,
                                             meAvatar: fixtureImage("kitten-4-112-112.jpg"))),
            ("local-video", lobby(.direct, mattie, me: nil, video: true)),
            ("initially-muted", lobby(.direct, mattie, me: 1, audio: false)),
            ("group-call-with-no-peeked-participants", lobby(.group, Self.tahoe(2), me: 3, members: groupMembers)),
            ("group-call-with-0-peeked-participants-big-group", lobby(.group, Self.tahoe(2), me: 3, members: [Self.me(nil), Self.person("Jodie")])),
            ("group-call-with-1-peeked-participant", lobby(.group, Self.tahoe(1), me: 2, members: groupMembers, peeked: [peek[0]])),
            ("group-call-with-1-peeked-participant-self", lobby(.group, Self.tahoe(2), me: 2, members: groupMembers, peeked: [peek[1]])),
            ("group-call-with-4-peeked-participants", lobby(.group, Self.tahoe(2), me: 3, members: groupMembers, peeked: peek)),
            ("group-call-with-4-peeked-participants-participants-list", lobby(.group, Self.tahoe(2), me: 3, members: groupMembers, peeked: peek)),
            ("group-call-with-call-full", lobby(.group, Self.tahoe(2), me: 1, members: groupMembers, peeked: Array(peek.prefix(2)), full: true)),
            ("call-link", lobby(.adhoc, Self.funLink, me: 2)),
            ("call-link-admin-approval", lobby(.adhoc, Self.funLink, me: 2, approval: true)),
            ("call-link-join-request-pending", lobby(.adhoc, Self.funLink, me: 2, pending: true)),
        ]
        for (name, view) in cases {
            try Snapshot.assertMatches(view, story: "components-callinglobby--\(name)", theme: theme)
        }
    }
}
