// TimelineMessage stories rendered from their evaluated story props (Support/TimelineFixtures).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct TimelineMessageFixtureTests {
    static let stories = [
        "image", "image-with-caption", "broken-image", "broken-image-with-expiration-timer", "broken-images", "video", "broken-video",
        "broken-video-with-expiration-timer", "multiple-images-2", "multiple-images-3", "multiple-images-4", "multiple-images-5",
        "multiple-images-with-one-too-big", "multiple-images-with-body-text-one-too-big", "image-too-large-to-display",
        "image-missing-dimensions", "multiple-images-with-first-too-large-to-display", "video-too-large-to-display",
        "attachment-too-big", "attachment-too-big-with-text", "attachment-too-big-with-image", "attachment-too-big-with-image-and-text",
        "gif", "gif-reduced-motion", "gif-in-a-group", "gif-that-fails-to-load", "not-downloaded-gif", "pending-gif", "downloading-gif",
        "partial-download-not-pending-gif",
        "link-preview-in-group", "link-preview-with-long-word", "link-preview-with-quote", "link-preview-with-small-image",
        "link-preview-image-that-fails-to-load", "link-preview-with-undownloaded-image", "link-preview-with-downloading-image",
        "link-preview-with-undownloaded-small-image", "link-preview-with-downloading-small-image", "link-preview-without-image",
        "link-preview-with-no-description", "link-preview-with-long-description", "link-preview-with-small-image-long-description",
        "link-preview-with-no-date", "link-preview-with-too-new-a-date", "link-preview-with-sticker", "not-approved-with-link-preview", "story-reply", "story-reply-yours", "story-reply-emoji",
        "link-preview-with-call-link", "link-preview-with-call-link-in-another-call", "link-preview-with-call-link-in-current-call",
        "sticker", "sticker-that-fails-to-load", "sticker-in-group", "sticker-with-label-in-group", "sticker-with-long-name-and-label-in-group",
        "embedded-contact-full-contact", "embedded-contact-avatar-undownloaded", "embedded-contact-avatar-downloading", "embedded-contact-avatar-transient-error", "embedded-contact-avatar-permanent-error", "embedded-contact-with-send-message",
        "reactions-wider-message", "reactions-short-message", "emoji-messages",
        "poll-animation-playground", "all-the-context-menus", "attachment-with-error", "signal-release-note-message",
        "permanently-undownloadable-attachments",
        "poll", "poll-multiple-choice", "poll-with-votes", "poll-with-pending-votes", "poll-terminated", "poll-long-text", "poll-multiple-choice-with-votes",
        "audio", "audio-viewed", "long-audio", "audio-with-caption", "audio-with-not-downloaded-attachment", "audio-with-pending-attachment",
        "embedded-contact-only-email", "embedded-contact-given-name", "embedded-contact-organization-only", "embedded-contact-name-and-organization", "embedded-contact-given-family-name", "embedded-contact-family-name",
    ]

    /// MultiSelect: three MultiSelectMessage (a useState wrapper the extraction can't follow):
    /// createProps({ text: 'Hello', isSelectMode: true }), unselected.
    @Test(arguments: ["light", "dark"])
    func multiSelect(theme: String) throws {
        let id = "components-conversation-timelinemessage--multi-select"
        let view = VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                Message(props: TimelineMessageTests.props("Hello", author: "Celia Barton") {
                    $0.isSelectMode = true
                    $0.toggleSelectMessage = { _, _ in }
                })
            }
        }
        try Snapshot.assertMatches(TimelineMessageTests.stage(view, storyHeight: try Snapshot.referenceHeight(id, theme)), story: id, theme: theme)
    }

    @Test func fixturesLoaded() {
        #expect(TimelineFixtures.all.count == 159)
        for s in Self.stories { #expect(TimelineFixtures.all[s] != nil, "\(s)") }
    }

    @Test(arguments: ["light", "dark"], 0..<91)
    func story(theme: String, index: Int) throws {
        let name = Self.stories[index]
        let id = "components-conversation-timelinemessage--\(name)"
        try Snapshot.assertMatches(TimelineMessageTests.stage(TimelineFixtures.messages(name), storyHeight: try Snapshot.referenceHeight(id, theme)),
                                   story: id, theme: theme)
    }
}
