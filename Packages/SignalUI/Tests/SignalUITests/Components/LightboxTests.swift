// ts/components/Lightbox.dom.stories.tsx. Portals over the whole 1200 × 900 viewport; the close
// button has the initial focus. Video stories are captured with CAPTURE_PAUSE_MEDIA (the
// first frame); the frame here is that frame of pixabay-Soap-Bubble-7141.mp4, extracted with
// ffmpeg into Fixtures/ until Phase 5 decodes H.264.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct LightboxTests {
    static let lighthouse = "/fixtures/tina-rolf-269345-unsplash.jpg"
    static let lighthouseCaption = "This lighthouse is really cool because there are lots of rocks and there is a tower that has a light and the light is really bright because it shines so much. The day was super duper cloudy and stormy and you can see all the waves hitting against the rocks. Wait? What is that weird red hose line thingy running all the way to the tower? Those rocks look slippery! I bet that water is really cold. I am cold now, can I get a sweater? I wonder where this place is, probably somewhere cold like Coldsgar, Frozenville."

    static func image(_ url: String, caption: String? = nil) -> LightboxMediaItem {
        LightboxMediaItem(kind: .image, image: fixtureByURL(url), caption: caption)
    }

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let multimedia = [
            Self.image(Self.lighthouse, caption: "Still from The Lighthouse, starring Robert Pattinson and Willem Defoe."),
            LightboxMediaItem(kind: .video),
            Self.image("/fixtures/kitten-1-64-64.jpg"),
            Self.image("/fixtures/kitten-2-64-64.jpg"),
        ]
        let stories: [(String, AnyView)] = [
            ("single-image", AnyView(Lightbox(media: [Self.image(Self.lighthouse)]))),
            ("missing-media", AnyView(Lightbox(media: [Self.image(Self.lighthouse)]))),
            ("image-with-caption-normal-image", AnyView(Lightbox(media: [Self.image(Self.lighthouse, caption: Self.lighthouseCaption)]))),
            ("image-with-caption-all-white-image", AnyView(Lightbox(media: [Self.image("/fixtures/2000x2000-white.png",
                caption: "This is the user-provided caption. It should be visible on light backgrounds.")]))),
            ("multimedia", AnyView(Lightbox(media: multimedia))),
            ("unsupported-image-type", AnyView(Lightbox(media: [LightboxMediaItem(kind: .unsupportedImage)]))),
            ("unsupported-video-type", AnyView(Lightbox(media: [LightboxMediaItem(kind: .unsupportedVideo)]))),
            ("unsupported-content", AnyView(Lightbox(media: [LightboxMediaItem(kind: .file)]))),
            ("custom-children", AnyView(Lightbox(media: [], children: {
                CSSText("I am middle child", style: LegacyType.body1(), color: AxoColor(LegacyColor.white))
            }))),
        ]
        for (name, view) in stories {
            try Snapshot.assertMatches(view.frame(width: 1200, height: 900), story: "components-lightbox--\(name)", theme: theme)
        }
    }

    static var bubbleFrame: LightboxMediaItem {
        var item = LightboxMediaItem(kind: .video, image: fixturePNGFile("pixabay-Soap-Bubble-7141.frame0.png"))
        item.duration = 39.571667
        return item
    }

    /// `ViewOnceVideo`: looping, so no controls; no forward / save.
    @Test(arguments: ["light", "dark"])
    func viewOnceVideo(theme: String) throws {
        try Snapshot.assertMatches(Lightbox(media: [Self.bubbleFrame], isViewOnce: true).frame(width: 1200, height: 900),
                                   story: "components-lightbox--view-once-video", theme: theme)
    }

    /// The paused video stories, with Chromium's native `<video controls>` panel at the bottom
    /// of the video element. SingleVideoWCaption's capture had the first 65px of its timeline
    /// buffered.
    @Test(arguments: ["light", "dark"])
    func videoStories(theme: String) throws {
        var captioned = Self.bubbleFrame
        captioned.caption = "This is the user-provided caption. It can get long and wrap onto multiple lines."
        captioned.bufferedFraction = 65.0 / 1168
        let header = LightboxHeaderInfo(title: "Test", avatar: fixtureByURL("/fixtures/kitten-1-64-64.jpg"), timestamp: "Now")
        let stories: [(String, AnyView)] = [
            ("single-video", AnyView(Lightbox(media: [Self.bubbleFrame]))),
            ("single-video-w-caption", AnyView(Lightbox(media: [captioned]))),
            ("conversation-header", AnyView(Lightbox(media: [Self.bubbleFrame], header: header))),
            ("incremental-video", AnyView(Lightbox(media: [Self.bubbleFrame]))),
        ]
        for (name, view) in stories {
            try Snapshot.assertMatches(view.frame(width: 1200, height: 900), story: "components-lightbox--\(name)", theme: theme)
        }
    }

    @Test(arguments: ["light", "dark"])
    func avatarLightbox(theme: String) throws {
        // AvatarColors[0] (A100); Person is getDefaultConversation()'s (seeded) title and colour.
        let stories: [(String, AvatarLightbox)] = [
            ("group", AvatarLightbox(avatarColor: "A100", isGroup: true)),
            ("person", AvatarLightbox(avatarColor: "A110", conversationTitle: "Mattie Grady")),
            ("photo", AvatarLightbox(avatarColor: "A100", avatarImage: fixtureByURL("/fixtures/kitten-1-64-64.jpg"))),
        ]
        for (name, view) in stories {
            try Snapshot.assertMatches(view.frame(width: 1200, height: 900), story: "components-avatarlightbox--\(name)", theme: theme)
        }
    }
}
