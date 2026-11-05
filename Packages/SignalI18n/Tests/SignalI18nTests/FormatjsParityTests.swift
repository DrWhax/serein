import Foundation
import Synchronization
import Testing
@testable import SignalI18n

/// Every fixture message, both modes, compared with formatjs' output.
@Suite struct FormatjsParityTests {
    struct Tally: Sendable {
        var cases = 0, stringOK = 0, richCases = 0, richOK = 0
    }

    static let totals = Mutex<[String: Tally]>([:])

    @Test(arguments: Localizer.availableLocales)
    func messagesMatchFormatjs(locale: String) throws {
        let fixture = try Fixtures.load(MessageFixture.self, "messages-\(locale).json")
        let i18n = Localizer(locale: locale)
        #expect(i18n.locale == locale)
        var tally = Tally()
        var failures: [String] = []
        for c in fixture.cases {
            tally.cases += 1
            let args = c.a.arguments
            if let expected = c.s {
                do {
                    let got = try i18n.format(c.k, args)
                    if got == expected { tally.stringOK += 1 } else { failures.append("\(c.k) \(c.a): got \(got.debugDescription), formatjs \(expected.debugDescription)") }
                } catch {
                    failures.append("\(c.k) \(c.a): threw \(error), formatjs \(expected.debugDescription)")
                }
            } else if let kind = c.se {
                // formatjs failed (and upstream would render the raw message); we must fail too.
                if (try? i18n.format(c.k, args)) == nil { tally.stringOK += 1 } else { failures.append("\(c.k): formatjs error \(kind), we formatted") }
            }
            if c.r != nil || c.re != nil {
                tally.richCases += 1
                let richArgs = (c.ra ?? c.a).arguments
                do {
                    let got = try i18n.formatRichText(c.k, richArgs).runs.map(FixtureRun.init)
                    if let expected = c.r, got == expected { tally.richOK += 1 } else { failures.append("\(c.k) rich: got \(got), formatjs \(c.r ?? [])") }
                } catch {
                    if c.re != nil { tally.richOK += 1 } else { failures.append("\(c.k) rich: threw \(error)") }
                }
            }
        }
        Self.totals.withLock { $0[locale] = tally }
        print("parity \(locale)\(fixture.full ? " (full)" : ""): strings \(tally.stringOK)/\(tally.cases), rich \(tally.richOK)/\(tally.richCases)")
        for failure in failures.prefix(20) { Issue.record("\(locale): \(failure)") }
        #expect(failures.isEmpty, "\(locale): \(failures.count) mismatches")
    }

    @Test func everyEnglishMessageIsCovered() throws {
        let fixture = try Fixtures.load(MessageFixture.self, "messages-en.json")
        let keys = try MessageCatalog.bundled.keys()
        #expect(Set(fixture.cases.map(\.k)) == Set(keys))
        #expect(keys.count == 3109)
    }
}

@Suite struct CLDRTests {
    struct Plurals: Decodable {
        struct Locale: Decodable { let cardinal: [String]; let ordinal: [String] }
        let values: [Double]
        let locales: [String: Locale]
    }

    @Test func pluralRulesMatchIntlForEveryLocale() throws {
        let fixture = try Fixtures.load(Plurals.self, "plurals.json")
        #expect(fixture.locales.count == 68)
        var checked = 0
        for (locale, expected) in fixture.locales {
            let data = try #require(LocaleData.named(locale))
            for (i, x) in fixture.values.enumerated() {
                #expect(PluralRuleSet.select(data.cardinalRules, x).rawValue == expected.cardinal[i], "\(locale) cardinal \(x)")
                #expect(PluralRuleSet.select(data.ordinalRules, x).rawValue == expected.ordinal[i], "\(locale) ordinal \(x)")
                checked += 2
            }
        }
        print("plural rules: \(checked) selections checked")
    }

    struct Numbers: Decodable {
        struct Locale: Decodable { let decimal: [String]; let percent: [String]; let integer: [String]; let special: [String] }
        let values: [Double]
        let locales: [String: Locale]
    }

    @Test func numberFormattingMatchesIntlForEveryLocale() throws {
        let fixture = try Fixtures.load(Numbers.self, "numbers.json")
        for (locale, expected) in fixture.locales {
            let n = try #require(LocaleData.named(locale)).numbers
            for (i, x) in fixture.values.enumerated() {
                #expect(n.format(x) == expected.decimal[i], "\(locale) \(x)")
                #expect(n.format(x, style: .percent) == expected.percent[i], "\(locale) \(x)%")
                #expect(n.format(x, style: .integer) == expected.integer[i], "\(locale) \(x) integer")
            }
            #expect([n.format(.nan), n.format(.infinity), n.format(-.infinity), n.format(-0.0)] == expected.special, "\(locale) special")
        }
    }

    struct JS: Decodable {
        let toString: [[JSValue]]
        let toNumber: [[String]]
        enum JSValue: Decodable {
            case number(Double), string(String)
            init(from decoder: any Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let x = try? c.decode(Double.self) { self = .number(x) } else { self = .string(try c.decode(String.self)) }
            }
        }
    }

    @Test func javascriptNumberSemantics() throws {
        let fixture = try Fixtures.load(JS.self, "js.json")
        for pair in fixture.toString {
            guard case .number(let x) = pair[0], case .string(let expected) = pair[1] else { Issue.record("bad fixture"); continue }
            #expect(jsString(x) == expected, "String(\(x))")
        }
        for pair in fixture.toNumber {
            #expect(jsString(jsToNumber(pair[0])) == pair[1], "Number(\(pair[0].debugDescription))")
        }
    }
}
