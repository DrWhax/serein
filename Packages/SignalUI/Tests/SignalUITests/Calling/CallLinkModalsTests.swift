// CallLinkEditModal / CallLinkAddNameModal (FAKE_CALL_LINK_WITH_ADMIN_KEY) and
// CallLinkPendingParticipantModal (getDefaultConversation: random name and kitten avatar,
// read from each capture).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CallLinkModalsTests {
    @Test(arguments: [("basic", false), ("in-another-call", true)], ["light", "dark"])
    func editModal(_ s: (String, Bool), theme: String) throws {
        try Snapshot.assertMatches(SmallDialogsTests.modal(CallLinkEditModal(callLink: CallLinkDetailsTests.admin, hasActiveCall: s.1)),
                                   story: "components-calllinkeditmodal--\(s.0)", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func addNameModal(theme: String) throws {
        try Snapshot.assertMatches(SmallDialogsTests.modal(CallLinkAddNameModal(callLink: CallLinkDetailsTests.admin)),
                                   story: "components-calllinkaddnamemodal--basic", theme: theme)
    }

    @Test(arguments: ["default", "system-contact", "with-shared-groups"], ["light", "dark"])
    func pendingParticipantModal(story: String, theme: String) throws {
        let id = "components-calllinkpendingparticipantmodal--\(story)"
        let dom = StoryDOM(id, theme: theme)
        let title = dom.nodes.first { $0.tag == "h2" }?.text ?? ""
        let avatar = dom.nodes.first { $0.cls.contains("module-Avatar__image") }?.fixture.flatMap { fixtureImage($0) }
        let color = CallingAdhocCallInfoTests.colorName(dom.nodes.first { $0.cls.contains("module-Avatar__contents") }?.style["color"])
        let modal = CallLinkPendingParticipantModal(conversation: CallingConversation(id: "c", title: title, color: color, avatar: avatar),
                                                    isInSystemContacts: story == "system-contact",
                                                    sharedGroupNames: story == "with-shared-groups" ? ["Axolotl lovers"] : [])
        // AxoTheme.Override wraps the whole dialog root, its overlay included.
        try Snapshot.assertMatches(AxoThemeOverride(theme: .forceDark) { SmallDialogsTests.modal(modal) }, story: id, theme: theme)
    }
}
