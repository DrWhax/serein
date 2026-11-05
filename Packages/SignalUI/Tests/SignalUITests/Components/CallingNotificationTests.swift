// CallingNotification stories (ts/components/conversation/CallingNotification.dom.stories.tsx):
// every call is "now" (the fixed clock).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CallingNotificationTests {
    static let now = Date(timeIntervalSince1970: 1_793_793_600)

    static func direct(_ type: CallType, _ direction: CallDirection, _ status: CallStatus, active: String? = nil, nextIsCall: Bool = false) -> CallingNotification {
        CallingNotification(callHistory: CallHistoryDetails(mode: .direct, type: type, direction: direction, status: status, timestamp: now),
                            callCreator: CallingNotification.Creator(title: "Mattie Grady", isMe: direction == .outgoing), conversationId: "c1",
                            activeConversationId: active, groupCallEnded: nil, deviceCount: 0, maxDevices: .max, isNextItemCallingNotification: nextIsCall)
    }

    static func group(_ direction: CallDirection, _ status: CallStatus, creator: CallingNotification.Creator?, ended: Bool, devices: Int, max: Int,
                      active: String? = nil) -> CallingNotification {
        CallingNotification(callHistory: CallHistoryDetails(mode: .group, type: .group, direction: direction, status: status, timestamp: now),
                            callCreator: creator, conversationId: "g1", activeConversationId: active, groupCallEnded: ended, deviceCount: devices, maxDevices: max)
    }

    static let someone = CallingNotification.Creator(title: "Mattie Grady", isMe: false)

    static var stories: [(String, AnyView)] {
        [
            ("accepted-incoming-audio-call", AnyView(direct(.audio, .incoming, .accepted))),
            ("accepted-incoming-audio-call-with-active-call", AnyView(direct(.audio, .incoming, .accepted, active: "someOtherConversation"))),
            ("accepted-incoming-audio-call-in-current-call", AnyView(direct(.audio, .incoming, .accepted, active: "c1"))),
            ("accepted-incoming-video-call", AnyView(direct(.video, .incoming, .accepted))),
            ("declined-incoming-audio-call", AnyView(direct(.audio, .incoming, .declined))),
            ("declined-incoming-video-call", AnyView(direct(.video, .incoming, .declined))),
            ("accepted-outgoing-audio-call", AnyView(direct(.audio, .outgoing, .accepted))),
            ("accepted-outgoing-video-call", AnyView(direct(.video, .outgoing, .accepted))),
            ("declined-outgoing-audio-call", AnyView(direct(.audio, .outgoing, .declined))),
            ("declined-outgoing-video-call", AnyView(direct(.video, .outgoing, .declined))),
            ("two-incoming-direct-calls-back-to-back", AnyView(VStack(spacing: 0) {
                direct(.video, .incoming, .declined, nextIsCall: true); direct(.audio, .incoming, .declined)
            })),
            ("two-outgoing-direct-calls-back-to-back", AnyView(VStack(spacing: 0) {
                direct(.video, .outgoing, .declined, nextIsCall: true); direct(.audio, .outgoing, .declined)
            })),
            ("group-call-by-unknown", AnyView(group(.incoming, .accepted, creator: nil, ended: false, devices: 1, max: 8))),
            ("group-call-by-you", AnyView(group(.outgoing, .accepted, creator: .init(title: "Me", isMe: true), ended: false, devices: 1, max: 8))),
            ("group-call-by-someone", AnyView(group(.incoming, .genericGroupCall, creator: someone, ended: false, devices: 1, max: 8))),
            ("group-call-started-by-someone-with-a-long-name", AnyView(group(.incoming, .genericGroupCall, creator: someone, ended: false, devices: 1, max: 8))),
            ("group-call-active-call-full", AnyView(group(.incoming, .genericGroupCall, creator: someone, ended: false, devices: 8, max: 8))),
            ("group-call-active-in-another-call", AnyView(group(.incoming, .genericGroupCall, creator: someone, ended: false, devices: 8, max: 10,
                                                               active: "someOtherId"))),
            ("group-call-active-in-current-call", AnyView(group(.incoming, .genericGroupCall, creator: someone, ended: false, devices: 8, max: 10, active: "g1"))),
            ("group-call-ended", AnyView(group(.incoming, .genericGroupCall, creator: someone, ended: true, devices: 0, max: .max))),
        ]
    }

    @Test(arguments: ["light", "dark"], 0..<20)
    func story(theme: String, index: Int) throws {
        let (name, view) = Self.stories[index]
        try Snapshot.assertMatches(view.environment(\.conversationListNow, Self.now).environment(\.timeZone, TimeZone(identifier: "Europe/London")!),
                                   story: "components-conversation-callingnotification--\(name)", theme: theme)
    }
}
