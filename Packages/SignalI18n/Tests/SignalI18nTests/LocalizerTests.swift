import Foundation
import Synchronization
import Testing
@testable import SignalI18n

@Suite struct LocalizerTests {
    @Test func bundledLocales() throws {
        #expect(Localizer.availableLocales.count == 68)
        #expect(Localizer(locale: "he").direction == .rightToLeft)
        #expect(Localizer(locale: "ar").direction == .rightToLeft)
        #expect(Localizer(locale: "de").direction == .leftToRight)
        #expect(Localizer(locale: "de")("icu:ok").isEmpty == false)
    }

    @Test func fallbackLocaleThenEnglishThenKey() {
        let errors = Mutex<[String]>([])
        let catalog = MessageCatalog(messages: [
            "en": ["a": "English A", "b": "English {n, plural, one {# B} other {# Bs}}", "c": "English C"],
            "de": ["a": "Deutsch A", "b": "Deutsch {n, plural, one {# B}", "d": "nur Deutsch"],
        ])
        let i18n = Localizer(locale: "de", catalog: catalog, onError: { key, error in errors.withLock { $0.append("\(key): \(error)") } })
        #expect(i18n("a") == "Deutsch A")
        #expect(i18n("c") == "English C") // not translated: en, like upstream's merge
        #expect(i18n("b", ["n": 1]) == "English 1 B") // malformed translation: en, German number rules
        #expect(i18n("b", ["n": 1000]) == "English 1.000 Bs")
        #expect(i18n("missing") == "missing")
        #expect(i18n("c", ["unused": "x"]) == "English C")
        #expect(errors.withLock { $0.count } == 3) // b, b, missing
        #expect(throws: I18nError.self) { try i18n.format("b", ["n": 1]) }
        #expect(i18n.richText("missing").plainText == "missing")
    }

    @Test func missingArgumentFallsBackToKey() {
        let catalog = MessageCatalog(messages: ["en": ["k": "Hello {name}"]])
        let i18n = Localizer(locale: "en", catalog: catalog)
        #expect(i18n("k") == "k")
        #expect(i18n("k", ["name": "Ann"], bidi: .none) == "Hello Ann")
    }

    @Test func bidiHandling() {
        let catalog = MessageCatalog(messages: ["en": ["k": "Hi {name}!"]])
        let i18n = Localizer(locale: "en", catalog: catalog)
        #expect(i18n("k", ["name": "Ann"]) == "Hi \u{2068}Ann\u{2069}!")
        #expect(i18n("k", ["name": "a\u{202E}b\u{2069}"]) == "Hi \u{2068}a\u{202E}b\u{202C}\u{2069}!")
        #expect(i18n("k", ["name": "a\u{202E}b\u{2069}"], bidi: .strip) == "Hi ab!")
        #expect(i18n("k", ["name": "Ann"], bidi: .none) == "Hi Ann!")
        #expect(i18n.richText("k", ["name": "Ann"]).plainText == "Hi Ann!")
    }

    @Test func richTextStructure() throws {
        let catalog = MessageCatalog(messages: ["en": [
            "k": "Read <learnMoreLink>more about <bold>{name}</bold></learnMoreLink> or <emojify>🙂</emojify>.",
        ]])
        let i18n = Localizer(locale: "en", catalog: catalog)
        let rich = i18n.richText("k", ["name": .element("contact")])
        #expect(rich.runs.map(FixtureRun.init) == [
            FixtureRun(kind: "t", value: "Read ", tags: []),
            FixtureRun(kind: "t", value: "more about ", tags: ["learnMoreLink"]),
            FixtureRun(kind: "e", value: "contact", tags: ["learnMoreLink", "bold"]),
            FixtureRun(kind: "t", value: " or ", tags: []),
            FixtureRun(kind: "t", value: "🙂", tags: ["emojify"]),
            FixtureRun(kind: "t", value: ".", tags: []),
        ])
        #expect(rich.plainText == "Read more about \u{FFFC} or 🙂.")
        #expect(rich.tagRanges.map(\.name) == ["learnMoreLink", "bold", "emojify"])
        #expect(rich.tagRanges.map(\.depth) == [0, 1, 0])
        #expect(String(rich.plainText[rich.tagRanges[0].range]) == "more about \u{FFFC}")
        #expect(rich.tagRanges[0].runs == 1..<3)
        #expect(String(rich.plainText[rich.tagRanges[2].range]) == "🙂")
        #expect(i18n("k", ["name": "Ann"], bidi: .none) == "Read more about Ann or 🙂.")

        let attributed = rich.attributedString(element: { AttributedString("<\($0)>") }) { tag, attributes in
            if tag == "bold" { attributes.inlinePresentationIntent = .stronglyEmphasized }
            if tag == "learnMoreLink" { attributes.link = URL(string: "https://support.signal.org/") }
        }
        #expect(String(attributed.characters) == "Read more about <contact> or 🙂.")
        let bold = attributed.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(bold.count == 1)
        #expect(bold.allSatisfy { $0.link != nil })
    }

    @Test func upstreamSelectQuirkWithBidiIsolation() {
        // Upstream isolates every string substitution, select keys included, so
        // `{direction, select, Outgoing {…} other {…}}` through `i18n()` always takes `other`.
        let i18n = Localizer(locale: "en")
        #expect(i18n("icu:CallHistory__DescriptionVideoCall--Default", ["direction": "Outgoing"]) == "Incoming video call")
        #expect(i18n("icu:CallHistory__DescriptionVideoCall--Default", ["direction": "Outgoing"], bidi: .none) == "Outgoing video call")
    }

    @Test func localeMatching() {
        #expect(Localizer.match(["de-AT"]) == "de")
        #expect(Localizer.match(["pt"]) == "pt-BR")
        #expect(Localizer.match(["pt_PT"]) == "pt-PT")
        #expect(Localizer.match(["zh-TW"]) == "zh-Hant")
        #expect(Localizer.match(["zh-Hans-CN"]) == "zh-CN")
        #expect(Localizer.match(["zh-HK"]) == "zh-HK")
        #expect(Localizer.match(["fil"]) == "tl-PH")
        #expect(Localizer.match(["xx", "fr-CA"]) == "fr")
        #expect(Localizer.match(["xx"]) == "en")
        #expect(Localizer(locale: "es-MX").locale == "es")
    }

    @Test func concurrentUse() async {
        let i18n = Localizer(locale: "ru")
        await withTaskGroup(of: String.self) { group in
            for n in 0..<64 {
                group.addTask { i18n("icu:ok") + String(n) }
            }
            for await s in group { #expect(!s.isEmpty) }
        }
    }
}
