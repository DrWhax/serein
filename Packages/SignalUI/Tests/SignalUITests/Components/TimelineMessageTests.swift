// TimelineMessage stories (ts/components/conversation/TimelineMessage.dom.stories.tsx): each
// story renders three incoming messages (the first two collapsed and without metadata) and
// the same three outgoing, in a wide timeline (container max-width 50vw = 600).

import ImagePNG
import SwiftUI
import Testing
@testable import SignalUI

func fixturePNG(_ name: String) -> RGBAImage? {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Signal-Desktop/fixtures/\(name)")
    guard let data = try? Data(contentsOf: url), let image = try? PNGDecoder.decode([UInt8](data)) else { return nil }
    return RGBAImage(image.stillImage)
}

@MainActor
@Suite struct TimelineMessageTests {
    static let now = Date(timeIntervalSince1970: 1_793_793_600)
    static let wrapText = "Hello there from a pal! I am sending a long message so that it will wrap a bit, since I like that look."

    static func props(_ text: String?, direction: MessageDirection = .incoming, author: String = "Mattie Grady", avatar: String? = nil,
                      configure: (inout MessageProps) -> Void = { _ in }) -> MessageProps {
        var a = MessageProps.Author(id: "a", title: author)
        a.avatar = avatar.flatMap { $0.hasSuffix(".png") ? fixturePNG($0) : fixtureImage($0) }
        var p = MessageProps(id: "m", direction: direction, author: a, text: text, timestamp: now)
        p.status = .sent
        configure(&p)
        return p
    }

    static let longFileName = "INSERT-APP-NAME_INSERT-APP-APPLE-ID_AppStore_AppsGamesWatch.psd.zip"

    /// A message with one `fakeAttachment` file (the stories' url keeps it ready to show, even
    /// when its path is unset or it is pending).
    static func file(_ name: String, contentType: String = "text/plain", size: Int = 10304, text: String = "",
                     _ configure: (inout MessageProps) -> Void = { _ in }) -> MessageProps {
        props(text) {
            $0.attachments = [MessageAttachment(contentType: contentType, fileName: name, size: size)]
            configure(&$0)
        }
    }

    static func jpeg() -> MessageAttachment {
        MessageAttachment(contentType: "image/jpeg", fileName: "tina-rolf-269345-unsplash.jpg", width: 128, height: 128)
    }

    /// An `isTapToView` message (no text).
    static func tapToView(_ a: MessageAttachment?, _ state: TapToViewState = TapToViewState(),
                          _ configure: (inout MessageProps) -> Void = { _ in }) -> MessageProps {
        props("") {
            $0.attachments = a.map { [$0] } ?? []
            $0.tapToView = state
            $0.showTapToViewNotAvailableModal = {}
            configure(&$0)
        }
    }

    /// `renderThree`
    static func three(_ p: MessageProps) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                Message(props: {
                    var q = p
                    q.shouldHideMetadata = i < 2 || p.shouldHideMetadata
                    q.shouldCollapseAbove = i > 0
                    q.shouldCollapseBelow = i < 2
                    return q
                }())
            }
        }
    }

    /// `renderBothDirections`
    static func both(_ p: MessageProps) -> some View {
        VStack(spacing: 0) {
            three(p)
            three({ var q = p; q.direction = .outgoing; return q }())
        }
    }

    /// The story root sits at 16,16 of the viewport; Playwright grows the viewport to the page
    /// for tall stories, which the fixed chat-colour gradients span.
    static func stage(_ v: some View, storyHeight: CGFloat = 0) -> some View {
        v.environment(\.messageContainerMaxWidth, 600)
            .environment(\.chatColorViewport, CGRect(x: -16, y: -16, width: 1200, height: max(900, storyHeight + 32)))
            .environment(\.conversationListNow, now).environment(\.timeZone, TimeZone(identifier: "Europe/London")!)
    }

    static var stories: [(String, AnyView)] {
        [
            ("plain-message", AnyView(both(props(wrapText)))),
            ("delivered", AnyView(both(props(wrapText) { $0.status = .delivered }))),
            ("read", AnyView(both(props(wrapText) { $0.status = .read }))),
            ("sending", AnyView(both(props(wrapText) { $0.status = .sending }))),
            ("expiring", AnyView(both(props(wrapText) {
                $0.expirationLength = 30
                $0.expirationTimestamp = now.addingTimeInterval(30)
            }))),
            ("will-expire-but-still-sending", AnyView(both(props("We always show the timer if a message has an expiration length, even if unread or still sending.") {
                $0.status = .sending
                $0.expirationLength = 30
            }))),
            ("pending", AnyView(both(props(wrapText) { $0.textPending = true }))),
            ("recent", AnyView(both(props("Hello there from a pal!") { $0.timestamp = now.addingTimeInterval(-30 * 60) }))),
            ("older", AnyView(both(props("Hello there from a pal!") { $0.timestamp = now.addingTimeInterval(-180 * 86_400) }))),
            ("deleted", AnyView(VStack(spacing: 0) {
                // createProps' seeded authors
                both(props(nil, author: "Celia Barton") { $0.deletedForEveryone = true })
                both(props(nil, author: "Mattie Grady") { $0.deletedForEveryone = true; $0.status = .sending })
            })),
            ("error", AnyView(both(props("I hope you get this.") { $0.status = .error }))),
            ("paused", AnyView(both(props("I am up to a challenge") { $0.status = .paused }))),
            ("partial-send", AnyView(both(props("I hope you get this.") { $0.status = .partialSent }))),
            ("plain-rtl-message", AnyView(both(props(rtlText)))),
            ("can-delete-for-everyone", AnyView(both(props("I hope you get this.", direction: .outgoing) { $0.status = .read }))),
            ("edit-error", AnyView(both(props("I hope you get this.") { $0.status = .error; $0.isEdited = true }))),
            ("sms", AnyView(both(props("hello") { $0.isSMS = true }))),
            ("pinned-messages", AnyView(both(props("I am pinned") { $0.isPinned = true }))),
            ("mentions", AnyView(both(props("\u{FFFC} This Is It. The Moment We Should Have Trained For.") {
                $0.bodyRanges = [BodyRange(start: 0, length: 1, kind: .mention(aci: "z", conversationID: "x", replacementText: "Zapp Brannigan"))]
            }))),
            ("deleted-pending", AnyView(three(props(nil, direction: .outgoing) {
                $0.deletedForEveryone = true; $0.status = .sending; $0.timestamp = now.addingTimeInterval(-60); $0.conversationType = .group
            }))),
            ("deleted-with-error", AnyView(VStack(spacing: 0) {
                three(props(nil, direction: .outgoing) {
                    $0.deletedForEveryone = true; $0.status = .partialSent; $0.timestamp = now.addingTimeInterval(-60); $0.conversationType = .group
                })
                three(props(nil, direction: .outgoing) {
                    $0.deletedForEveryone = true; $0.status = .error; $0.timestamp = now.addingTimeInterval(-60); $0.conversationType = .group
                })
            })),
            ("collapsing-text-only-d-ms", AnyView(many([
                props("One") { $0.timestamp = now.addingTimeInterval(-300) }, props("Two") { $0.timestamp = now.addingTimeInterval(-240) },
                props("Three") { $0.timestamp = now.addingTimeInterval(-180) },
                props("Four", direction: .outgoing) { $0.timestamp = now.addingTimeInterval(-120) },
                props("Five", direction: .outgoing) { $0.timestamp = now.addingTimeInterval(-60) }, props("Six", direction: .outgoing),
            ]))),
            ("avatar-in-group", AnyView(both(props("Hello it is me, the saxophone.", author: "Laisha Boehm", avatar: sax) {
                $0.conversationType = .group; $0.contactNameColor = "100"
            }))),
            ("quote", AnyView(both(props("", author: "Quoter Dude") {
                $0.conversationType = .group; $0.contactNameColor = "100"
                $0.quote = QuoteModel(authorTitle: "Author", text: "hello my good friend")
                $0.scrollToQuotedMessage = {}
            }))),
            ("long-body-can-be-downloaded", AnyView(both(props(wrapText) { $0.textCanDownload = true; $0.kickOffBodyDownload = {} }))),
            ("custom-color", AnyView(VStack(alignment: .leading, spacing: 20) {
                three(props("Solid.", direction: .outgoing) { $0.bubbleColor = .solid(RGBA.hsl(82, 0.35, 0.30)) })
                three(props("Gradient.", direction: .outgoing) {
                    $0.bubbleColor = .gradient(CSSLinearGradient(deg: 270 - 192, start: RGBA.hsl(304, 0.85, 0.4033), end: RGBA.hsl(231, 0.76, 0.47)))
                })
            })),
            ("other-file-type", AnyView(both(file("things.zip", size: 10_200_000)))),
            ("other-file-type-with-expiration-timer", AnyView(both(file("things.zip", size: 10_200_000) {
                $0.expirationLength = 30
                $0.expirationTimestamp = now.addingTimeInterval(30)
            }))),
            ("other-file-type-four-char", AnyView(both(file("things.four", size: 10_200_000)))),
            ("other-file-type-five-char", AnyView(both(file("things.cinco", size: 10_200_000)))),
            ("other-file-type-undownloaded", AnyView(both(file("things.zip", size: 10_200_000)))),
            ("other-file-type-downloading", AnyView(both(file("things.zip", size: 10_200_000)))),
            ("other-file-type-with-caption", AnyView(both(file("my-resume.txt", text: "This is what I have done.")))),
            ("other-file-type-with-long-filename", AnyView(both(file(longFileName)))),
            ("other-file-type-with-long-filename-and-caption", AnyView(both(file(longFileName, text: "This is what I have done.")))),
            ("dangerous-file-type", AnyView(both(file("terrible.exe", contentType: "application/vnd.microsoft.portable-executable")))),
            ("tap-to-view-image", AnyView(both(tapToView(jpeg())))),
            ("tap-to-view-image-in-group", AnyView(both(tapToView(jpeg()) { $0.conversationType = .group; $0.contactNameColor = "100" }))),
            ("tap-to-view-video", AnyView(both(tapToView(MessageAttachment(contentType: "video/mp4", fileName: "pixabay-Soap-Bubble-7141.mp4", width: 128, height: 128))))),
            ("tap-to-view-gif", AnyView(both(tapToView(MessageAttachment(contentType: "video/mp4", fileName: "cat-gif.mp4", width: 400, height: 332))))),
            ("tap-to-view-image-undownloaded", AnyView(both(tapToView({ var a = jpeg(); a.isDownloaded = false; a.hasUrl = false; a.size = 1_800_000; return a }())))),
            ("tap-to-view-image-downloading", AnyView(both(tapToView({
                var a = jpeg(); a.isDownloaded = false; a.hasUrl = false; a.pending = true; a.size = 1_800_000; a.totalDownloaded = 500_000; return a
            }())))),
            ("tap-to-view-viewed", AnyView(both(tapToView(nil, TapToViewState(isExpired: true, isViewed: true))))),
            ("tap-to-view-expired", AnyView(both(tapToView(nil, TapToViewState(isExpired: true))))),
            ("tap-to-view-error", AnyView(both(tapToView(nil, TapToViewState(isError: true))))),
            ("label-in-group", AnyView(both(props("Hello it is me, the saxophone.", author: "Celia Barton", avatar: "kitten-3-64-64.jpg") {
                $0.conversationType = .group; $0.contactNameColor = "260"; $0.contactLabel = chicken
            }))),
            ("label-in-group-with-long-name", AnyView(both(props("Hello it is me, the saxophone.", author: longName, avatar: "kitten-1-64-64.jpg") {
                $0.conversationType = .group; $0.contactNameColor = "260"; $0.contactLabel = chicken
            }))),
            ("label-in-group-with-long-name-and-long-message", AnyView(both(props(
                "Hello it is me, the saxophone. I am a good friend of yours. Do you remember? A long long long long long long long time ago.",
                author: longName, avatar: "kitten-1-64-64.jpg") {
                $0.conversationType = .group; $0.contactNameColor = "260"; $0.contactLabel = chicken
            }))),
            ("deleted-by-admin", AnyView(both(props(nil, author: "Celia Barton", avatar: "kitten-3-64-64.jpg") {
                $0.conversationType = .group; $0.deletedForEveryone = true; $0.deletedByAdmin = ("Alice Smith", false, "200")
            }))),
            ("deleted-with-expire-timer", AnyView(both(props(nil, author: "Celia Barton", avatar: "kitten-3-64-64.jpg") {
                $0.conversationType = .group; $0.contactNameColor = "100"; $0.deletedForEveryone = true
                $0.timestamp = now.addingTimeInterval(-60); $0.expirationLength = 300; $0.expirationTimestamp = now.addingTimeInterval(180)
            }))),
            ("collapsing-text-only-group-messages", AnyView(many(["One", "Two", "Three"].enumerated().map { i, t in
                props(t, author: "Celia Barton", avatar: "kitten-3-64-64.jpg") {
                    $0.conversationType = .group; $0.contactNameColor = "100"; $0.timestamp = now.addingTimeInterval(Double(i - 2) * 60)
                }
            }))),
            ("admin-deleted-pending", AnyView(VStack(spacing: 0) {
                three(admin(.outgoing, .sending, "Mattie Grady", nil))
                three(admin(.incoming, .sending, "Milford Friesen", "kitten-3-64-64.jpg"))
            })),
            ("admin-deleted-with-error", AnyView(VStack(spacing: 0) {
                three(admin(.outgoing, .partialSent, "Mattie Grady", nil)); three(admin(.outgoing, .error, "Mattie Grady", nil))
                three(admin(.incoming, .partialSent, "Sim Larson", "kitten-1-64-64.jpg")); three(admin(.incoming, .error, "Sarah Barrows", "kitten-1-64-64.jpg"))
            })),
            ("admin-deleted-with-error-can-retry", AnyView(VStack(spacing: 0) {
                three(admin(.outgoing, .partialSent, "Mattie Grady", nil, retry: true)); three(admin(.outgoing, .error, "Mattie Grady", nil, retry: true))
                three(admin(.incoming, .partialSent, "Sim Larson", "kitten-1-64-64.jpg", retry: true))
                three(admin(.incoming, .error, "Sarah Barrows", "kitten-1-64-64.jpg", retry: true))
            })),
            ("deleted-with-error-can-retry", AnyView(VStack(spacing: 0) {
                three(props(nil, direction: .outgoing) {
                    $0.deletedForEveryone = true; $0.canRetryDeleteForEveryone = true; $0.status = .partialSent
                    $0.timestamp = now.addingTimeInterval(-60); $0.conversationType = .group
                })
                three(props(nil, direction: .outgoing) {
                    $0.deletedForEveryone = true; $0.canRetryDeleteForEveryone = true; $0.status = .error
                    $0.timestamp = now.addingTimeInterval(-60); $0.conversationType = .group
                })
            })),
            ("colors", AnyView(VStack(spacing: 0) {
                ForEach(chatColors, id: \.self) { c in
                    let p = props("Here is a preview of the chat color: \(c). The color is visible to only you.") { $0.bubbleColor = .preset(c) }
                    Message(props: p)
                    Message(props: { var q = p; q.direction = .outgoing; return q }())
                }
            })),
        ]
    }

    static let chatColors = ["ultramarine", "crimson", "vermilion", "burlap", "forest", "wintergreen", "teal", "blue", "indigo", "violet", "plum",
                             "taupe", "steel", "ember", "midnight", "infrared", "lagoon", "fluorescent", "basil", "sublime", "sea", "tangerine"]

    static func admin(_ d: MessageDirection, _ status: MessageStatus, _ author: String, _ avatar: String?, retry: Bool = false) -> MessageProps {
        props(nil, direction: d, author: author, avatar: avatar) {
            $0.timestamp = now.addingTimeInterval(-60); $0.conversationType = .group; $0.contactNameColor = "100"
            $0.deletedForEveryone = true; $0.deletedByAdmin = ("Alice Smith", false, "200"); $0.status = status
            $0.canRetryDeleteForEveryone = retry
        }
    }

    static let sax = "freepngs-2cd43b_bed7d1327e88454487397574d87b64dc_mv2.png"
    static let longName = "Long long long long long long long long long long long name"
    static let chicken = ContactLabel(labelString: "Chicken Taster", labelEmoji: "🍗")

    static var rtlText: String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/timelinemessage-rtl.txt")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// `renderMany`: collapsed with any neighbour.
    static func many(_ list: [MessageProps]) -> some View {
        VStack(spacing: 0) {
            ForEach(list.indices, id: \.self) { i in
                Message(props: {
                    var q = list[i]
                    q.shouldCollapseAbove = i > 0
                    q.shouldCollapseBelow = i < list.count - 1
                    return q
                }())
            }
        }
    }

    @Test(arguments: ["light", "dark"], Array(0..<56))
    func story(theme: String, index: Int) throws {
        let (name, view) = Self.stories[index]
        let id = "components-conversation-timelinemessage--\(name)"
        try Snapshot.assertMatches(Self.stage(view, storyHeight: try Snapshot.referenceHeight(id, theme)), story: id, theme: theme)
    }
}
