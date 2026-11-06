import SwiftUI
import Testing
@testable import SignalUI

/// CallingPip stories: the 224×400 PiP of a large window, 976px from the left of the viewport.
/// Our camera's preview (Chromium's fake device stream) is excluded from the comparison.
@MainActor
@Suite struct CallingPipTests {
    static let rick = CallingConversation(id: "rick", title: "Rick Sanchez", color: "A100")
    static let localPreview = CGRect(x: 8, y: 8, width: 120, height: 90)
    /// The remote video canvas of a 1:1 call (Storybook feeds it frames too).
    static let remoteCanvas = CGRect(x: 0, y: 144, width: 224, height: 112)

    func pip(_ remote: CallingPip.Remote, audio: Bool = true, video: Bool = true, group: Bool = false, lonely: Bool = false, hands: Int = 0,
             requests: Int = 0, conversation: CallingConversation = rick) -> some View {
        CallingPip(conversation: conversation, remote: remote, hasLocalAudio: audio, hasLocalVideo: video, isGroupCall: group, isLonelyInCall: lonely,
                   raisedHandsCount: hands, callJoinRequests: requests)
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let speaker = GroupCallRemoteParticipantInfo(demuxId: 1, conversation: CallingConversation(id: "a", title: "Arsene"), hasRemoteVideo: false,
                                                     mediaKeysReceived: false)
        let videoSpeaker = GroupCallRemoteParticipantInfo(demuxId: 1, conversation: CallingConversation(id: "a", title: "Arsene"))
        let cases: [(String, AnyView, Bool)] = [
            ("default", AnyView(pip(.direct(hasRemoteVideo: true, source: nil))), true),
            ("no-local-video", AnyView(pip(.direct(hasRemoteVideo: true, source: nil), video: false)), false),
            ("no-local-audio", AnyView(pip(.direct(hasRemoteVideo: true, source: nil), audio: false)), true),
            ("remote-muted", AnyView(pip(.direct(hasRemoteVideo: true, source: nil))), true),
            ("default-both-speaking", AnyView(pip(.direct(hasRemoteVideo: true, source: nil))), true),
            ("contact-no-color", AnyView(pip(.direct(hasRemoteVideo: true, source: nil))), true),
            ("group-call", AnyView(pip(.group(speaker: speaker, source: nil), group: true)), true),
            ("group-call-remote-muted", AnyView(pip(.group(speaker: videoSpeaker, source: nil), group: true, hands: 3, requests: 2)), true),
            ("group-call-remote-speaking", AnyView(pip(.group(speaker: videoSpeaker, source: nil), group: true, hands: 3, requests: 2)), true),
            ("group-call-with-raised-hands", AnyView(pip(.group(speaker: speaker, source: nil), group: true, hands: 3)), true),
            ("group-call-with-pending-participants", AnyView(pip(.group(speaker: speaker, source: nil), group: true, requests: 2)), true),
            ("group-call-with-pending-and-raised", AnyView(pip(.group(speaker: speaker, source: nil), group: true, hands: 3, requests: 2)), true),
        ]
        for (name, view, hasPreview) in cases {
            var ignoring = hasPreview ? [Self.localPreview] : []
            if !name.hasPrefix("group") { ignoring.append(Self.remoteCanvas) }
            // The speaker's video canvas (width 100%, 1.3:1).
            if name.hasPrefix("group-call-remote") { ignoring.append(CGRect(x: 0, y: 113.84, width: 224, height: 172.3)) }
            try Snapshot.assertMatches(view, story: "components-callingpip--\(name)", theme: theme, ignoring: ignoring)
        }
    }
}
