import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct SmallDialogsTests {
    static func modal(_ v: some View) -> some View { PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { v } } }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let cases: [(String, AnyView)] = [
            ("components-errormodal--normal", AnyView(ErrorModal(title: "Real bad!", description: "Just avoid that next time, kay?"))),
            ("components-terminategroupfailedmodal--modal", AnyView(TerminateGroupFailedModal())),
            ("components-deleteattachmentconfirmationdialog--default", AnyView(DeleteAttachmentConfirmationDialog())),
            ("components-taptoviewnotavailablemodal--error", AnyView(TapToViewNotAvailableModal(type: .error, name: "FirstName"))),
            ("components-taptoviewnotavailablemodal--expired", AnyView(TapToViewNotAvailableModal(type: .expired, name: "FirstName"))),
            ("components-backfillfailuremodal--timeout", AnyView(BackfillFailureModal(kind: .timeout))),
            ("components-backfillfailuremodal--not-found", AnyView(BackfillFailureModal(kind: .notFound))),
            ("components-notepreviewmodal--normal",
             AnyView(NotePreviewModal(note: "Met at UC Berkeley, mutual friends with Katie Hall.\n\nWebsite: https://example.com/"))),
            ("components-criticalidleprimarydevicemodal--default", AnyView(CriticalIdlePrimaryDeviceModal())),
            ("components-keytransparencyerrordialog--default", AnyView(KeyTransparencyErrorDialog())),
            ("components-keytransparencyonboardingdialog--default", AnyView(KeyTransparencyOnboardingDialog())),
            // getBuildCreation: the capture day; no version in Storybook.
            ("components-whatsnewmodal--modal", AnyView(WhatsNewModal(date: Date(timeIntervalSince1970: 1_793_793_600), version: ""))),
            ("components-signalconnectionsmodal--default", AnyView(SignalConnectionsModal())),
            ("components-safetynumbermodal--not-ready", AnyView(SafetyNumberModal(isAvailable: false) { EmptyView() })),
            ("components-usernameonboardingmodal--normal", AnyView(UsernameOnboardingModal())),
            ("components-safetytipsmodal--default", AnyView(SafetyTipsModal())),
            ("components-groupmemberlabelinfomodal--no-existing-label", AnyView(GroupMemberLabelInfoModal(canAddLabel: true, hasLabel: false, isEditMemberLabelEnabled: true))),
            ("components-groupmemberlabelinfomodal--existing-label", AnyView(GroupMemberLabelInfoModal(canAddLabel: true, hasLabel: true, isEditMemberLabelEnabled: true))),
            ("components-groupmemberlabelinfomodal--cannot-add-label", AnyView(GroupMemberLabelInfoModal(canAddLabel: false, hasLabel: false, isEditMemberLabelEnabled: true))),
            ("components-groupmemberlabelinfomodal--can-add-label-but-feature-disabled",
             AnyView(GroupMemberLabelInfoModal(canAddLabel: false, hasLabel: false, isEditMemberLabelEnabled: true))),
            ("components-editnicknameandnotemodal--normal",
             AnyView(EditNicknameAndNoteModal(avatar: ConversationAvatarData(title: "Bestie", image: fixtureImage("kitten-2-64-64.jpg")),
                                              nicknameAndNote: NicknameAndNote(givenName: "Bestie", familyName: "McBesterson",
                                                                               note: "Met at UC Berkeley, mutual friends with Katie Hall.\n\nWebsite: https://example.com/")))),
        ]
        for (story, view) in cases { try Snapshot.assertMatches(Self.modal(view), story: story, theme: theme) }
        let viewer = SafetyNumberViewer(contactTitle: "Summer Smith", isVerified: true, safetyNumber: SafetyNumberViewerTests.number("modal-default", theme))
        try Snapshot.assertMatches(Self.modal(SafetyNumberModal(isAvailable: true) { viewer }), story: "components-safetynumbermodal--default", theme: theme)
    }

    /// Captured on 2026-11-04 in a Western European Time zone: tomorrow is 11/05/2026.
    @Test(arguments: ["light", "dark"])
    func muteUntilDialog(theme: String) throws {
        let view = Self.modal(MuteUntilDialog(now: Date(timeIntervalSince1970: 1_793_793_600)))
            .environment(\.timeZone, TimeZone(identifier: "Europe/Lisbon")!)
        try Snapshot.assertMatches(view, story: "components-muteuntildialog--default", theme: theme)
    }

    /// 100 getDefaultGroup()s sorted by title; the capture shows the first six.
    @Test(arguments: ["light", "dark"])
    func addUserToAnotherGroupModal(theme: String) throws {
        let groups: [(String, Int, Int)] = [("Accusantium non", 13, 1), ("Ad et", 2, 3), ("Ad ipsam", 20, 1), ("Ad necessitatibus cupiditate", 8, 1),
                                            ("Ad quod", 19, 2), ("Aliquam quis", 18, 2), ("Asperiores in quo", 4, 2)]
        let candidates = groups.map { t, n, k in
            AddUserToAnotherGroupCandidate(group: GroupListItemData(id: t, title: t, membersCount: n,
                                                                     avatar: ConversationAvatarData(title: t, conversationType: .group, image: fixtureImage("kitten-\(k)-64-64.jpg"))))
        }
        try Snapshot.assertMatches(ModalTests.stage(AddUserToAnotherGroupModal(contactTitle: "Contact", contactServiceId: "aci", candidates: candidates)),
                                   story: "components-addusertoanothergroupmodal--modal", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func groupV1MigrationDialog(theme: String) throws {
        let alice = GroupV1MigrationMember(id: "guid-1", title: "Alice", avatar: fixtureImage("kitten-2-64-64.jpg"))
        let bob = GroupV1MigrationMember(id: "guid-2", title: "Bob", avatar: fixtureImage("kitten-2-64-64.jpg"))
        let chet = GroupV1MigrationMember(id: "guid-3", title: "Chet", avatar: fixtureImage("kitten-1-64-64.jpg"))
        let cases: [(String, GroupV1MigrationDialog)] = [
            ("basic", GroupV1MigrationDialog(areWeInvited: false, droppedMembers: nil, droppedMemberCount: 0, invitedMembers: nil, invitedMemberCount: 0)),
            ("you-are-invited", GroupV1MigrationDialog(areWeInvited: true, droppedMembers: nil, droppedMemberCount: 0, invitedMembers: nil, invitedMemberCount: 0)),
            ("multiple-dropped-and-invited-member",
             GroupV1MigrationDialog(areWeInvited: false, droppedMembers: [alice], droppedMemberCount: 1, invitedMembers: [bob], invitedMemberCount: 1)),
            ("multiple-dropped-and-invited-members",
             GroupV1MigrationDialog(areWeInvited: false, droppedMembers: [chet, alice, bob], droppedMemberCount: 3, invitedMembers: [bob, chet, alice], invitedMemberCount: 3)),
            ("just-count-is-1", GroupV1MigrationDialog(areWeInvited: false, droppedMembers: nil, droppedMemberCount: 1, invitedMembers: nil, invitedMemberCount: 1)),
            ("just-count-is-2", GroupV1MigrationDialog(areWeInvited: false, droppedMembers: nil, droppedMemberCount: 2, invitedMembers: nil, invitedMemberCount: 2)),
        ]
        for (story, view) in cases { try Snapshot.assertMatches(Self.modal(view), story: "components-groupv1migrationdialog--\(story)", theme: theme) }
    }

    /// The stories open on the contact picker; mockContacts(30) is seeded, the first rows show.
    @Test(arguments: ["light", "dark"])
    func shareContactDialog(theme: String) throws {
        let visible: [(String, Int)] = [("Adelia", 3), ("Alize", 1), ("Ardella", 1), ("Arielle", 1), ("Arvid", 2), ("Bernadine", 2), ("Carmine", 1),
                                        ("Casandra Renner", 3), ("Davion Waters", 3), ("Dolores", 1)]
        let contacts = visible.map { ShareContactCandidate(id: $0.0, title: $0.0, avatar: fixtureImage("kitten-\($0.1)-64-64.jpg")) }
        let draft = ShareContactDraft(aci: "aci", name: EmbeddedContactName(givenName: "Paige", familyName: "Hall"), e164: "+15101234567")
        for story in ["default", "no-photos", "not-on-signal", "phone-number-only", "profile-photo-only", "with-nickname-and-notes", "no-contacts"] {
            let view = ShareContactDialog(contacts: story == "no-contacts" ? [] : contacts, recipientTitle: "Maya Johnson", ourRegionCode: "US",
                                          getContactDraft: { _ in draft })
            try Snapshot.assertMatches(Self.modal(view), story: "components-sharecontactdialog--\(story)", theme: theme)
        }
    }

    /// Four outgoing "hello world" messages (no status) at the story clock.
    @Test(arguments: ["light", "dark"])
    func editHistoryMessagesModal(theme: String) throws {
        func m() -> MessageProps { MessageProps(id: "", direction: .outgoing, author: MessageProps.Author(id: "a", title: "Author"), text: "hello world",
                                                timestamp: TimelineMessageTests.now) }
        // Storybook dates the messages far from its clock: absolute date and time.
        let view = Self.modal(TimelineMessageTests.stage(EditHistoryMessagesModal(editHistoryMessages: [m(), m(), m(), m()])
            .environment(\.conversationListNow, TimelineMessageTests.now.addingTimeInterval(400 * 86_400))))
        try Snapshot.assertMatches(view, story: "components-edithistorymessagesmodal--default", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func pollCreateModal(theme: String) throws {
        try Snapshot.assertMatches(Self.modal(TimelineMessageTests.stage(PollCreateModal())), story: "components-pollcreatemodal--default", theme: theme)
    }

    /// MediaPermissionsModal.dom.stories.tsx, macOS (the Windows variants are out of scope).
    @Test(arguments: ["light", "dark"])
    func mediaPermissionsModal(theme: String) throws {
        let cases: [(String, MediaPermissionsModal.MediaType, MediaPermissionsModal.Requestor)] = [
            ("camera", .camera, .call), ("microphone", .microphone, .call), ("voice-note", .microphone, .voiceNote),
        ]
        for (story, media, requestor) in cases {
            try Snapshot.assertMatches(Self.modal(MediaPermissionsModal(mediaType: media, requestor: requestor)),
                                       story: "components-mediapermissionsmodal--\(story)", theme: theme)
        }
    }
}
