// PollTerminateNotification (ts/components/conversation/PollTerminateNotification.dom.tsx; it has
// no Storybook story, so its wording is checked rather than its pixels).

import SignalI18n
import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct PollTerminateNotificationTests {
    let i18n = Localizer(locale: "en")

    func text(_ senderIsMe: Bool) -> String {
        PollTerminateNotification.contents(i18n, senderTitle: "Ada 🧮", senderIsMe: senderIsMe, pollQuestion: "Tea or coffee? ☕").map(\.text).joined()
    }

    @Test func namesWhoEndedThePoll() {
        let ours = text(true), theirs = text(false)
        #expect(ours.contains("Tea or coffee? ☕") && !ours.contains("Ada"))
        #expect(theirs.contains("Ada 🧮") && theirs.contains("Tea or coffee? ☕"))
        #expect(ours != theirs)
    }

    @Test func rendersInATimelineItem() throws {
        let item = TimelineItem(item: .pollTerminate(PollTerminateNotification(senderTitle: "Ada", senderIsMe: false, pollQuestion: "Tea?")))
        let size = NSHostingView(rootView: item.environment(\.i18n, i18n).frame(width: 400)).fittingSize
        #expect(size.height > 20)
    }
}
