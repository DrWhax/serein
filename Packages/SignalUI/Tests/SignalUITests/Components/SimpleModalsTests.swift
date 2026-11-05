// ProgressModal, ConfirmDiscardDialog and DebugLogErrorModal stories. The donation stories
// (ConfirmDiscardDialog DonateFlow, DebugLogErrorModal Donations) are omitted with donations.

import Foundation
import ImageGIF
import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct SimpleModalsTests {
    static func gifFrame(_ name: String, _ index: Int) -> RGBAImage? {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Signal-Desktop/fixtures/\(name)")
        guard let data = try? Data(contentsOf: url), case .animated(let gif, _)? = try? GIFDecoder.decode([UInt8](data)),
              gif.frames.indices.contains(index) else { return nil }
        return RGBAImage(gif.frames[index].image)
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let stories: [(String, AnyView)] = [
            ("progressmodal--default", AnyView(ProgressModal())),
            ("progressmodal--with-description", AnyView(ProgressModal(description: DefaultLocalizer.english("icu:GroupV2--terminate-group-in-progress")))),
            ("confirmdiscarddialog--default", AnyView(ConfirmDiscardDialog())),
            ("debuglogerrormodal--default", AnyView(DebugLogErrorModal())),
        ]
        for (name, view) in stories {
            try Snapshot.assertMatches(PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { view } }, story: "components-\(name)", theme: theme)
        }
    }

    /// EXPIRE_TIMERS (ts/test-helpers/expireTimers.std.ts): 42s, 5m, 1h, 6d, 3w.
    @Test(arguments: ["light", "dark"])
    func disappearingTimeDialog(theme: String) throws {
        for (name, seconds) in [("seconds", 42), ("minutes", 300), ("hours", 3600), ("days", 6 * 86400), ("weeks", 3 * 7 * 86400)] {
            try Snapshot.assertMatches(PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { DisappearingTimeDialog(initialValue: seconds) } },
                                       story: "components-disappearingtimedialog--\(name)", theme: theme)
        }
    }

    @Test(arguments: ["light", "dark"])
    func groupV2JoinDialog(theme: String) throws {
        // The captures show frame 19 of the avatar GIF (Chromium plays it before the capture).
        let gif = Self.gifFrame("giphy-GVNvOUpeYmI7e.gif", 19)
        let stories: [(String, GroupV2JoinDialog)] = [
            ("basic", GroupV2JoinDialog(title: "Random Group!", memberCount: 12)),
            ("approval-required", GroupV2JoinDialog(title: "Approval required!", memberCount: 12, approvalRequired: true)),
            ("with-avatar", GroupV2JoinDialog(title: "Has an avatar!", avatar: gif, memberCount: 12)),
            ("with-one-member", GroupV2JoinDialog(title: "Just one member!", memberCount: 1)),
            ("avatar-loading-state", GroupV2JoinDialog(title: "Avatar loading!", avatarLoading: true, memberCount: 12)),
            ("full", GroupV2JoinDialog(title: "Underwater basket weavers (LA)", avatar: gif, memberCount: 16,
                                       groupDescription: "Discuss meets, events, training, and recruiting.")),
        ]
        for (name, view) in stories {
            try Snapshot.assertMatches(PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { view } },
                                       story: "components-groupv2joindialog--\(name)", theme: theme)
        }
    }

    /// The stories open the dialog over an "Open Dialog" button.
    @Test(arguments: ["light", "dark"])
    func deleteMessagesModal(theme: String) throws {
        let stories: [(String, DeleteMessagesModal)] = [
            ("delete-for-me-only", DeleteMessagesModal()),
            ("delete-for-everyone", DeleteMessagesModal(canDeleteForEveryone: true)),
            ("delete-for-everyone-multiple", DeleteMessagesModal(canDeleteForEveryone: true, messageCount: 3)),
            ("admin-delete", DeleteMessagesModal(canDeleteForEveryone: true, needsAdminDelete: true)),
            ("admin-delete-multiple", DeleteMessagesModal(canDeleteForEveryone: true, needsAdminDelete: true, messageCount: 3)),
            ("admin-delete-after-onboarding", DeleteMessagesModal(canDeleteForEveryone: true, needsAdminDelete: true, hasSeenAdminDeleteEducationDialog: true)),
            ("note-to-self", DeleteMessagesModal(isMe: true)),
            ("note-to-self-multiple", DeleteMessagesModal(isMe: true, messageCount: 3)),
            ("too-many-messages-for-delete-for-everyone", DeleteMessagesModal(canDeleteForEveryone: true, messageCount: 31)),
        ]
        for (name, view) in stories {
            try Snapshot.assertMatches(PortalStage { AxoButton.Root("Open Dialog", variant: .strongSecondary, size: .md) } modal: { AxoBaseDialog.Host { view } },
                                       story: "components-deletemessagesmodal--\(name)", theme: theme)
        }
    }

    /// CONTACTS: getDefaultConversation's seeded avatars, read off the many-contacts capture.
    static let invitedContacts: [NewlyCreatedGroupInvitedContactsDialog.Contact] = [
        ("Fred Willard", 2), ("Marc Barraca", 2), ("Alice Anderson", 1), ("Bob Brown", 2), ("Carol Chen", 3), ("Dave Davis", 3), ("Erin Evans", 2),
        ("Frank Foster", 1), ("Grace Garcia", 1), ("Heidi Hughes", 2),
    ].map { .init(id: $0.0, title: $0.0, avatar: fixtureByURL("/fixtures/kitten-\($0.1)-64-64.jpg")) }

    @Test(arguments: ["light", "dark"])
    func newlyCreatedGroupInvitedContactsDialog(theme: String) throws {
        for (name, count) in [("one-contact", 1), ("two-contacts", 2), ("many-contacts", 10)] {
            let view = NewlyCreatedGroupInvitedContactsDialog(contacts: Array(Self.invitedContacts.prefix(count)))
            try Snapshot.assertMatches(PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { view } },
                                       story: "components-newlycreatedgroupinvitedcontactsdialog--\(name)", theme: theme)
        }
    }
}
