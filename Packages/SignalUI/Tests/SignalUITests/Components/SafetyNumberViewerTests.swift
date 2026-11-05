// ts/components/SafetyNumberViewer.dom.stories.tsx. The stories draw random QR data and
// digits; SafetyNumberViewerFixtures holds each capture's (per theme).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct SafetyNumberViewerTests {
    static func number(_ story: String, _ theme: String) -> SafetyNumber? {
        guard let f = SafetyNumberViewerFixtures.stories["\(story).\(theme)"] else { return nil }
        return SafetyNumber(numberBlocks: f.blocks, qrModules: f.modules.map { $0.map { $0 == "1" } })
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let summer = "Summer Smith"
        func v(_ story: String, _ title: String = summer, verified: Bool, status: KeyTransparencyStatus = .idle, disabled: Bool = false) -> (String, SafetyNumberViewer) {
            (story, SafetyNumberViewer(contactTitle: title, isVerified: verified, safetyNumber: Self.number(story, theme), verificationDisabled: disabled,
                                       keyTransparencyStatus: status))
        }
        let stories = [
            v("safety-number", verified: true),
            v("safety-number-not-verified", verified: false),
            v("safety-number-key-transparency-running", verified: false, status: .running),
            v("safety-number-key-transparency-ok", verified: false, status: .ok),
            v("safety-number-key-transparency-fail", verified: false, status: .fail),
            v("safety-number-key-transparency-unavailable", verified: false, status: .unavailable),
            // Captured before its 2s interval first fires.
            v("safety-number-key-transparency-animation", verified: false),
            v("verification-disabled", verified: true, disabled: true),
            v("safety-number-dialog-close", verified: true),
            v("just-profile-and-number", "-*Smartest Dude*-", verified: false),
            v("just-number", "(305) 123-4567", verified: false),
            v("no-aci-cannot-verify", "Unknown contact", verified: false),
        ]
        for (name, view) in stories {
            try Snapshot.assertMatches(view.frame(width: 1168), story: "components-safetynumberviewer--\(name)", theme: theme)
        }
    }

    /// SafetyNumberChangeDialog stories: the seeded contacts' colours read off the captures.
    /// MultipleContactsAllWithBadges is omitted (donor badges).
    @Test(arguments: ["light", "dark"])
    func changeDialog(theme: String) throws {
        let rick = SafetyNumberChangeContact(id: "abc", title: "Rick Sanchez", color: "A100", phoneNumber: "(305) 123-4567", hasName: true,
                                             isInSystemContacts: true, serviceId: "rick")
        let dude = SafetyNumberChangeContact(id: "def", title: "-*Smartest Dude*-", color: "A140", phoneNumber: "(305) 123-4567", hasName: true,
                                             isVerified: true, serviceId: "dude")
        let number = SafetyNumberChangeContact(id: "xyz", title: "(305) 123-4567", color: "A100", phoneNumber: "(305) 123-4567", isVerified: true,
                                               serviceId: "number")
        let nothing = SafetyNumberChangeContact(id: "some-guid", title: "Unknown contact", color: "A160", serviceId: "nothing")
        typealias Section = SafetyNumberChangeSection
        let stories: [(String, String?, [Section])] = [
            ("single-contact-dialog", nil, [Section(contacts: [rick])]),
            ("different-confirmation-text", "You are awesome", [Section(contacts: [rick])]),
            ("multi-contact-dialog", nil, [Section(contacts: [rick, dude]), Section(contacts: [number, nothing])]),
            ("all-verified", nil, [Section(contacts: [dude, number])]),
            ("ten-contacts", nil, [Section(contacts: [rick, dude, number, nothing] + Array(repeating: rick, count: 6))]),
            ("no-contacts", nil, [Section(story: .init(name: "My Story", distributionId: "my-story", isMyStory: true), contacts: []),
                                  Section(story: .init(name: "Custom List A", distributionId: "list-a"), contacts: [])]),
            ("in-multiple-stories", nil, [Section(story: .init(name: "Not to be trusted", distributionId: "my-story", isMyStory: true), contacts: [rick, dude]),
                                          Section(story: .init(name: "Custom List A", distributionId: "list-a"), contacts: [rick, rick, rick]),
                                          Section(story: .init(name: "Hiking Buds"), contacts: [number, rick, rick])]),
        ]
        for (name, confirm, sections) in stories {
            let view = SafetyNumberChangeDialog(confirmText: confirm, sections: sections, removeFromStory: { _, _ in }) { _, _ in EmptyView() }
            try Snapshot.assertMatches(PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { view } },
                                       story: "components-safetynumberchangedialog--\(name)", theme: theme)
        }
    }
}
