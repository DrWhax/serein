// ts/components/CompositionArea.dom.stories.tsx (all but QuoteWithPayment: payments are out of
// scope). The input focuses itself on open. getDefaultConversation's seeded first name in the
// message request is "Arvid".

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CompositionAreaTests {
    static func model(_ edit: (inout CompositionAreaModel) -> Void = { _ in }) -> CompositionAreaModel {
        var m = CompositionAreaModel(conversationId: "123",
                                     messageRequest: MessageRequestModel(conversationId: "123", conversationType: .direct, conversationName: "Arvid"))
        edit(&m)
        return m
    }

    /// `fakeDraftAttachment({ contentType: IMAGE_JPEG, url: landscapeGreenUrl })`
    static var green: MessageAttachment {
        AttachmentListTests.draft("image/jpeg", "file.jpg", url: "/fixtures/1000x50-green.jpeg")
    }

    static func area(_ text: String = "", _ edit: (inout CompositionAreaModel) -> Void = { _ in }) -> some View {
        CompositionArea(text: .constant(text), model: model(edit)).frame(width: 1168, alignment: .topLeading)
    }

    static var quote: QuoteModel {
        var q = QuoteModel(authorTitle: "Someone", text: "something")
        q.direction = .compose
        q.bubbleColor = .preset("vermilion")
        return q
    }

    static let stories: [(String, AnyView)] = [
        ("default", AnyView(area())),
        ("starting-text", AnyView(area("here's some starting text"))),
        ("sticker-button", AnyView(area())),
        ("no-formatting-menu", AnyView(area())),
        ("quote", AnyView(area { $0.quote = quote; $0.quotedMessageId = "q" })),
        ("attachments", AnyView(area { $0.draftAttachments = [green] })),
        ("view-once-enabled", AnyView(area { $0.draftAttachments = [green]; $0.isViewOnce = true })),
        ("message-request", AnyView(area { $0.acceptedMessageRequest = false })),
        ("pending-approval", AnyView(area { $0.areWePendingApproval = true })),
        ("announcements-only-group", AnyView(area { $0.announcementsOnly = true })),
        ("sms-only", AnyView(area { $0.isSmsOnlyOrUnregistered = true })),
        ("sms-only-fetching-uuid", AnyView(area { $0.isSmsOnlyOrUnregistered = true; $0.isFetchingUUID = true })),
        ("terminated-group", AnyView(area { $0.terminated = true })),
    ]

    @Test(arguments: ["light", "dark"], 0..<13)
    func story(theme: String, index: Int) throws {
        let (name, view) = Self.stories[index]
        try Snapshot.assertMatches(view, story: "components-compositionarea--\(name)", theme: theme)
    }

    @Test func branches() {
        #expect(Self.model { $0.draftAttachments = [Self.green] }.showViewOnceToggle)
        #expect(!Self.model { $0.draftAttachments = [Self.green]; $0.quotedMessageId = "q" }.showViewOnceToggle)
        #expect(!Self.model { $0.draftAttachments = [Self.green, Self.green] }.isViewOnceActive)
        #expect(Self.model { $0.draftAttachments = [Self.green] }.showMediaQualitySelector)
    }
}

/// ts/components/MediaQualitySelector.dom.stories.tsx
@MainActor
@Suite struct MediaQualitySelectorTests {
    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        for (name, hq) in [("standard-quality", false), ("high-quality", true)] {
            try Snapshot.assertMatches(MediaQualitySelector(isHighQuality: hq, onSelectQuality: { _ in }).frame(width: 1168, alignment: .leading),
                                       story: "components-mediaqualityselector--\(name)", theme: theme)
        }
    }
}

/// ts/components/AnnouncementsOnlyGroupBannerAdminsDialog.dom.stories.tsx: four seeded
/// getDefaultConversation admins (kitten avatars) coloured ContactNameColors[i]; the third
/// label's "#" is not an emoji, so it shows the missing-emoji placeholder.
@MainActor
@Suite struct AnnouncementsOnlyGroupBannerAdminsDialogTests {
    static var admins: [GroupAdmin] {
        let rows: [(String, String, ContactLabel?)] = [
            ("Mattie Grady", "kitten-2-64-64.jpg", nil),
            ("Bernadine Feil", "kitten-2-64-64.jpg", ContactLabel(labelString: "Planner", labelEmoji: "✅")),
            ("Regan Murazik", "kitten-1-64-64.jpg", ContactLabel(labelString: "Invalid Emoji", labelEmoji: "#")),
            ("Nyah Stroman", "kitten-2-64-64.jpg", ContactLabel(labelString: "No Emoji")),
        ]
        return rows.enumerated().map { i, r in
            GroupAdmin(id: "\(i)", avatar: ConversationAvatarData(title: r.0, image: fixtureImage(r.1)), label: r.2,
                       contactNameColor: ContactNameTests.colors[i])
        }
    }

    @Test(arguments: ["light", "dark"])
    func story(theme: String) throws {
        let view = PortalStage { EmptyView() } modal: {
            AxoBaseDialog.Host { AnnouncementsOnlyGroupBannerAdminsDialog(groupAdmins: Self.admins, showConversation: { _ in }) }
        }
        try Snapshot.assertMatches(view, story: "components-announcementsonlygroupbanneradminsdialog--default", theme: theme)
    }
}

/// ts/components/DraftGifMessageSendModal.dom.stories.tsx: the capture is taken during the
/// story's 3s delay, so the GIF is still loading.
@MainActor
@Suite struct DraftGifMessageSendModalTests {
    @Test(arguments: ["light", "dark"])
    func story(theme: String) throws {
        let view = PortalStage { EmptyView() } modal: {
            AxoBaseDialog.Host {
                DraftGifMessageSendModal(draftText: .constant(""), gifFrame: nil, gifWidth: 480, gifHeight: 418, loadingState: .loading,
                                         onSubmit: {}, onClose: {})
            }
        }
        try Snapshot.assertMatches(view, story: "components-draftgifmessagesendmodal--default", theme: theme)
    }
}
