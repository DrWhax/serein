// Stories of small components ported as parts of larger ones: UniversalTimerNotification,
// InContactsIcon, OfficialChatInlineBadge, QrCode, BrandedQRCode, DisappearingTimerSelect.

import CoreText
import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct SmallComponentStoriesTests {
    static func top(_ v: some View) -> some View {
        TimelineMessageTests.stage(v.frame(width: 1168, alignment: .topLeading))
    }

    /// ts/test-helpers/expireTimers.std.ts
    static let expireTimers: [(String, Int)] = [("seconds", 42), ("minutes", 5 * 60), ("hours", 3600), ("days", 6 * 86400), ("weeks", 3 * 7 * 86400)]

    @Test(arguments: ["light", "dark"])
    func universalTimerNotification(theme: String) throws {
        for (story, seconds) in Self.expireTimers {
            try Snapshot.assertMatches(Self.top(UniversalTimerNotification(expireTimer: seconds)),
                                       story: "components-universaltimernotification--\(story)", theme: theme)
        }
    }

    @Test(arguments: ["light", "dark"])
    func icons(theme: String) throws {
        try Snapshot.assertMatches(Self.top(InContactsIcon()), story: "components-incontactsicon--default", theme: theme)
        try Snapshot.assertMatches(Self.top(OfficialChatInlineBadge(size: 14)), story: "components-officialchatinlinebadge--default", theme: theme)
    }

    static let link = "sgnl://linkdevice?uuid=gCkj0T2xiSUaPRhMYiF24w&pub_key=7RshtQrb3UTMowITe79uW9dgw_CLTGWenj0OT80i0HpH"

    /// QrCode: an unstyled <img> at its intrinsic size (cellSize 1: 37 modules).
    @Test(arguments: ["light", "dark"])
    func qrCodes(theme: String) throws {
        try Snapshot.assertMatches(Self.top(QrCode(text: Self.link, alt: "Scan this little code!").frame(width: 37, height: 37)), story: "components-qrcode--default", theme: theme)
        // A 16-unit viewBox stretched to the story's width.
        try Snapshot.assertMatches(Self.top(BrandedQRCode(size: 1168, link: Self.link, color: .black)), story: "components-brandedqrcode--default", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func disappearingTimerSelect(theme: String) throws {
        try Snapshot.assertMatches(Self.top(DisappearingTimerSelect(value: 86400)), story: "components-disappearingtimerselect--initial-value-1-day", theme: theme)
        try Snapshot.assertMatches(Self.top(DisappearingTimerSelect(value: 3 * 86400)),
                                   story: "components-disappearingtimerselect--initial-value-3-days-custom-time", theme: theme)
    }

    static let demoCountries = [("Belgium", "BE", "+32"), ("Canada", "CA", "+1"), ("France", "FR", "+33"), ("Germany", "DE", "+49"),
                                ("Hong Kong", "HK", "+852"), ("Spain", "ES", "+34"), ("Switzerland", "CH", "+41"), ("USA", "US", "+1"),
                                ("Japan", "JP", "+81")].map { CountryData(region: $0.1, displayName: $0.0, code: $0.2) }

    @Test(arguments: ["light", "dark"])
    func countryCodeSelect(theme: String) throws {
        try Snapshot.assertMatches(Self.top(CountryCodeSelect(countries: Self.demoCountries, defaultRegion: "US", value: "")),
                                   story: "components-countrycodeselect--defaults", theme: theme)
    }

    static let lorem = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Etiam feugiat quam vitae semper facilisis. Praesent eu efficitur dui. Donec semper mattis nisl non hendrerit."

    /// ListTile.dom.stories.tsx `Item`: TemplateList(400) — a 400×400 scroller (outline 1px gray).
    @Test(arguments: ["light", "dark"])
    func listTile(theme: String) throws {
        typealias T = ListTile<EmptyView, EmptyView, EmptyView, EmptyView>
        func tile(_ title: String, emojiTitle: Bool = false, subtitle: String? = "Hello my friend", emojiSubtitle: Bool = false, lines: Int = 2,
                  checked: Bool? = nil, clickable: Bool = true, disabled: Bool = false) -> some View {
            ListTile(clickable: clickable, subtitleMaxLines: lines, disabled: disabled, onClick: {}) {
                Circle().fill(Color.gray).frame(width: 36, height: 36)
            } title: {
                CSSText(runs: [{ var r = CSSTextRun(title); r.emojify = emojiTitle; return r }()], style: T.titleStyle, wrap: .truncate)
            } subtitle: {
                if let subtitle { ListTileSubtitle(subtitle, emojify: emojiSubtitle) }
            } trailing: {
                if let checked { CircleCheckbox(checked: checked) }
            }
        }
        let list = VStack(spacing: 0) {
            tile("Some user", subtitle: "Checkbox", checked: false)
            tile("Some user", subtitle: "Checkbox", checked: true)
            tile("Some user")
            tile("Long title - \(Self.lorem)")
            tile("Some user", subtitle: "Disabled", disabled: true)
            tile("Emoji in title 📞", emojiTitle: true, subtitle: "Clickable")
            tile("With a LOT of emoji 🚗", emojiTitle: true, subtitle: "😂, 😃, 🧘🏻‍♂️, 🌍, 🌦️, 🍞, 🚗, 📞, 🎉, ❤️, 🍆, 🍑 and 🏁", emojiSubtitle: true)
            tile("Some user", subtitle: "One line max - \(Self.lorem)", lines: 1)
        }
        let box = AxoDialog.TopAligned { list }.frame(width: 400, height: 400).clipped()
            .overlay(Rectangle().stroke(Color.gray, lineWidth: 2).padding(-1).frame(width: 402, height: 402))
        try Snapshot.assertMatches(Self.top(box), story: "components-listtile--item", theme: theme)
    }

    /// Two getDefaultConversation()s; the capture drew kitten-2 for both.
    @Test(arguments: ["light", "dark"])
    func collidingAvatars(theme: String) throws {
        let a = ConversationAvatarData(title: "Alice", image: fixtureImage("kitten-2-64-64.jpg"))
        try Snapshot.assertMatches(Self.top(CollidingAvatars(conversations: [a, a])), story: "components-collidingavatars--defaults", theme: theme)
    }

    /// PlaybackButton.dom.stories.tsx: for each variant, an incoming and an outgoing row (padding 10)
    /// of the five mods; each button has margin-end 12. The message variant sits in an
    /// `animated.div`, whose line box adds the 14px/20px strut below the button's baseline.
    @Test(arguments: ["light", "dark"])
    func playbackButton(theme: String) throws {
        let font = LegacyType.body1().ctFont
        let strutBelow = CTFontGetDescent(font) + (20 - CTFontGetAscent(font) - CTFontGetDescent(font)) / 2
        var attachment = MessageAttachment(contentType: "audio/mp3", size: 3000)
        attachment.totalDownloaded = 1000
        let mods: [PlaybackButton.Mod] = [.play, .pause, .notDownloaded, .downloading, .computing]
        let incomingRow = AxoColor(light: RGBA(hex: 0xe9e9e9), dark: RGBA(hex: 0x3b3b3b))
        let view = VStack(spacing: 0) {
            ForEach([PlaybackButton.Variant.message, .draft, .mini], id: \.self) { variant in
                ForEach([true, false], id: \.self) { incoming in
                    HStack(spacing: 0) {
                        ForEach(mods.indices, id: \.self) { i in
                            PlaybackButton(mod: mods[i], variant: variant, incoming: incoming, attachment: mods[i] == .downloading ? nil : attachment,
                                           label: "playback") {}
                                .padding(.trailing, 12)
                                .padding(.bottom, variant == .message ? strutBelow : 0)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(incoming ? incomingRow : AxoColor(RGBA(hex: 0x2c6bed)))
                }
            }
        }
        try Snapshot.assertMatches(Self.top(view), story: "components-playbackbutton--default", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func i18nStories(theme: String) throws {
        var bold = CSSTextRun("Fred"); bold.fontName = AxoFonts.interName(weight: 700)
        var bold2 = CSSTextRun("The Fredster"); bold2.fontName = AxoFonts.interName(weight: 700)
        let cases: [(String, I18n)] = [
            ("no-replacements", I18n("icu:deleteAndRestart")),
            ("single-string-replacement", I18n("icu:leftTheGroup", components: ["name": .string("Theodora")])),
            // A reset <button>: inline text.
            ("single-tag-replacement", I18n("icu:leftTheGroup", components: ["name": .run(CSSTextRun("Theodora"))])),
            ("multiple-string-replacement", I18n("icu:changedRightAfterVerify", components: ["name1": .string("Fred"), "name2": .string("The Fredster")])),
            ("multiple-tag-replacement", I18n("icu:changedRightAfterVerify", components: ["name1": .run(bold), "name2": .run(bold2)])),
            ("with-emoji", I18n("icu:Message__reaction-emoji-label--you", components: ["emoji": .string("😛")])),
        ]
        for (story, view) in cases { try Snapshot.assertMatches(Self.top(view), story: "components-i18n--\(story)", theme: theme) }
    }

    @Test(arguments: ["light", "dark"])
    func slider(theme: String) throws {
        for story in ["default", "draggable-test"] {
            try Snapshot.assertMatches(Self.top(Slider(label: "Slider Handle", value: .constant(30))), story: "components-slider--\(story)", theme: theme)
        }
    }

    /// One 100×100 identicon per avatar colour, stacked.
    @Test(arguments: ["light", "dark"])
    func identicons(theme: String) throws {
        let colors = AxoTokens.Avatar.allColorNames.map { AxoTokens.Avatar.colorValues($0) }
        let kinds: [(String, IdenticonSVG.Kind)] = [("contact", .contact(text: "HI")), ("group", .group), ("call-link", .callLink)]
        for (story, kind) in kinds {
            let view = VStack(spacing: 0) { ForEach(colors.indices, id: \.self) { IdenticonSVG(kind, background: colors[$0].bg, foreground: colors[$0].fg) } }
            try Snapshot.assertMatches(Self.top(view), story: "components-identiconsvg--all-colors-for-\(story)", theme: theme)
        }
    }

    /// The stories show the closed trigger ("Open"); the menu is the dropdown's content.
    @Test(arguments: ["light", "dark"])
    func notificationProfilesMenu(theme: String) throws {
        let profiles = [NotificationProfileSummary(id: "Weekday", name: "Weekday", emoji: "😬", color: 0xffe3e3fe),
                        NotificationProfileSummary(id: "Weekend", name: "Weekend", emoji: "❤️‍🔥", color: 0xffd7d7d9),
                        NotificationProfileSummary(id: "Random", name: "Random", color: 0xfffef5d0)]
        for story in ["default", "with-emoji-less-profile-active", "with-enabled-override", "with-enabled-override-and-ends-at-ms",
                      "with-no-profiles", "with-profile-active"] {
            let menu = AxoDropdownMenu.Root(isOpen: .constant(false)) {
                AxoButton.Root("Open", variant: .strongSecondary, size: .md)
            } items: {
                NotificationProfilesMenu(activeProfileId: nil, allProfiles: profiles)
            }
            try Snapshot.assertMatches(Self.top(menu), story: "components-notificationprofilesmenu--\(story)", theme: theme)
        }
    }

    /// AnimatedEmojiGalore.dom.stories.tsx `Hearts`, captured mid-animation: the first eleven
    /// hearts are at rest above the page (Chromium paints nothing above y 0) and the last five
    /// have not launched. Their `left`s (of the 1200px viewport) are read from the DOM. The
    /// capture is the page from (72, 0).
    @Test(arguments: ["light", "dark"])
    func animatedEmojiGalore(theme: String) throws {
        let lefts = [86, 100, 74, 66, 64, 51, 14, 88, 85, 38, 24, 29, 33, 6, 14, 46]
        let particles = lefts.map { AnimatedEmojiGalore.Particle(left: $0, delay: 0, rotate: 0, scale: 0.5) }
        let page = AnimatedEmojiGalore(emoji: "\u{2764}\u{FE0F}", particles: particles, initiallyAtRest: 11)
            .frame(width: 1200, height: 900).padding(.top, 16)
            .frame(width: 1200, height: 1344, alignment: .topLeading)
            .offset(x: -72)
            .frame(width: 1128, height: 1344, alignment: .topLeading).clipped()
        try Snapshot.assertMatches(TimelineMessageTests.stage(page), story: "components-animatedemojigalore--hearts", theme: theme)
    }

    /// ChatsTab.dom.stories.tsx `Basic`: no left pane, no conversation — the splash, full window.
    @Test(arguments: ["light", "dark"])
    func chatsTab(theme: String) throws {
        let view = ChatsTab(selectedConversationId: nil) { EmptyView() } renderConversationView: { _ in EmptyView() } renderMiniPlayer: { EmptyView() }
            .frame(width: 1200, height: 900)
        try Snapshot.assertMatches(TimelineMessageTests.stage(view), story: "components-chatstab--basic", theme: theme)
    }

    /// ClearingData.dom.stories.tsx: the 100vw × 100vh screen at the story root's 16,16. Taller
    /// than the 900px viewport there, the capture grew the viewport to 932 (so 100vh is 932)
    /// and clipped at the root's width. The logo is placed against the (relative) screen.
    /// DeletingAccount is primary-only (out of scope).
    @Test(arguments: ["light", "dark"])
    func clearingData(theme: String) throws {
        let steps: [(String, ClearingData.Step?)] = [("callback-not-called-yet", nil), ("leaving-groups", .leavingGroups), ("deleting-data", .deletingData)]
        for (story, step) in steps {
            let view = ClearingData(step: step).frame(width: 1200, height: 932)
                .frame(width: 1168, height: 916, alignment: .topLeading).clipped()
            try Snapshot.assertMatches(TimelineMessageTests.stage(view), story: "components-clearingdata--\(story)", theme: theme)
        }
    }

    /// CompositionRecordingDraft.dom.stories.tsx: the draft of incompetech-com-Agnus-Dei-X.mp3,
    /// its peaks (computed in the browser from the decoded audio) read off the capture's bars.
    @Test(arguments: ["light", "dark"])
    func compositionRecordingDraft(theme: String) throws {
        let id = "components-compositionrecordingdraft--default"
        let peaks = StoryDOM(id, theme: theme).nodes.filter { $0.cls == "Waveform__bar" }.map { $0.rect[3] / 20 }
        try Snapshot.assertMatches(Self.top(CompositionRecordingDraft(peaks: peaks, duration: 1)), story: id, theme: theme)
    }

    /// CompositionRecording.dom.stories.tsx `Default`, after its "Activate" button (captured
    /// with CAPTURE_CLICK=Activate): the recorder just started, PEAKS = (i / 50) % 1.
    @Test(arguments: ["light", "dark"])
    func compositionRecording(theme: String) throws {
        let peaks = (0..<200).map { RecordingPeak(value: Double($0) / 50 - Double($0 / 50), index: $0) }
        try Snapshot.assertMatches(Self.top(CompositionRecording(peaks: peaks, startedAt: TimelineMessageTests.now)),
                                   story: "components-compositionrecording--default", theme: theme)
    }

    /// MiniPlayer.dom.stories.tsx `Default` after "Activate" (CAPTURE_CLICK): loading, the
    /// audio's duration not known yet (0:00). Absolutely placed 52px down the viewport.
    @Test(arguments: ["light", "dark"])
    func miniPlayer(theme: String) throws {
        let view = MiniPlayer(title: "Paige Hall 😉", state: .loading, currentTime: 0, duration: 0, playbackRate: 1).frame(width: 1200)
        try Snapshot.assertMatches(TimelineMessageTests.stage(view), story: "components-miniplayer--default", theme: theme)
    }
}
