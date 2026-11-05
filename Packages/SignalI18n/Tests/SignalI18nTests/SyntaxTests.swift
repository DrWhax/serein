import Foundation
import Testing
@testable import SignalI18n

struct SyntaxFixture: Decodable {
    struct ErrorCase: Decodable { let m: String; let ok: Bool?; let kind: String?; let offset: Int? }
    struct EdgeCase: Decodable { let m: String; let a: [String: FixtureArgument]; let s: String?; let r: [FixtureRun]?; let err: String? }
    let errors: [ErrorCase]
    let cases: [EdgeCase]
}

/// Parser behaviour on malformed input and on the corners of the grammar, against formatjs.
@Suite struct SyntaxTests {
    @Test func malformedMessagesFailLikeFormatjs() throws {
        let fixture = try Fixtures.load(SyntaxFixture.self, "syntax.json")
        for c in fixture.errors {
            do {
                _ = try MessageParser.parse(c.m)
                #expect(c.ok == true, "\(c.m.debugDescription) parsed, formatjs: \(c.kind ?? "")")
            } catch {
                #expect(error.kind.rawValue == c.kind, "\(c.m.debugDescription)")
                #expect(error.utf16Offset == c.offset, "\(c.m.debugDescription) offset")
            }
        }
    }

    @Test func edgeCasesFormatLikeFormatjs() throws {
        let fixture = try Fixtures.load(SyntaxFixture.self, "syntax.json")
        let i18n = Localizer(locale: "en")
        for c in fixture.cases {
            let args = c.a.arguments
            if c.m.contains("::") {
                // Number skeletons are recognised but not formatted (upstream uses none).
                #expect(throws: I18nError.unsupported(argument: "n", feature: "number skeleton")) { try i18n.format(message: c.m, args) }
            } else if let expected = c.s {
                #expect((try? i18n.format(message: c.m, args)) == expected, "\(c.m.debugDescription)")
                let runs = try? i18n.formatRichText(message: c.m, args).runs.map(FixtureRun.init)
                #expect(runs == c.r, "\(c.m.debugDescription) rich")
            } else {
                #expect((try? i18n.format(message: c.m, args)) == nil, "\(c.m.debugDescription) should fail (\(c.err ?? ""))")
            }
        }
    }

    // MARK: Typed errors

    func kind(_ message: String) -> MessageSyntaxError.Kind? {
        do {
            _ = try MessageParser.parse(message)
            return nil
        } catch {
            return error.kind
        }
    }

    @Test func errorKinds() {
        #expect(kind("{") == .expectArgumentClosingBrace)
        #expect(kind("{}") == .emptyArgument)
        #expect(kind("{a b}") == .malformedArgument)
        #expect(kind("{a,") == .expectArgumentClosingBrace)
        #expect(kind("{a,}") == .expectArgumentType)
        #expect(kind("{a, }") == .expectArgumentType)
        #expect(kind("{a, money}") == .invalidArgumentType)
        #expect(kind("{a, number, }") == .expectArgumentStyle)
        #expect(kind("{a, number, 'x}") == .unclosedQuoteInArgumentStyle)
        #expect(kind("{a, number, ::}") == .invalidNumberSkeleton)
        #expect(kind("{a, time, ::}") == .expectDateTimeSkeleton)
        #expect(kind("{a, plural}") == .expectSelectArgumentOptions)
        #expect(kind("{a, plural, offset:}") == .expectPluralArgumentOffsetValue)
        #expect(kind("{a, plural, offset:9007199254740992 other {}}") == .invalidPluralArgumentOffsetValue)
        #expect(kind("{a, plural, offset:9007199254740991 other {}}") == nil)
        #expect(kind("{a, plural, =x {} other {}}") == .expectPluralArgumentSelector)
        #expect(kind("{a, plural, =9007199254740992 {} other {}}") == .invalidPluralArgumentSelector)
        #expect(kind("{a, select, }") == .expectSelectArgumentSelector)
        #expect(kind("{a, select, x y}") == .expectSelectArgumentSelectorFragment)
        #expect(kind("{a, plural, one y}") == .expectPluralArgumentSelectorFragment)
        #expect(kind("{a, select, x {} x {} other {}}") == .duplicateSelectArgumentSelector)
        #expect(kind("{a, plural, one {} one {} other {}}") == .duplicatePluralArgumentSelector)
        #expect(kind("{a, plural, one {}}") == .missingOtherClause)
        #expect(kind("{a, select, x {}}") == .missingOtherClause)
        #expect(kind("<b x>") == .invalidTag)
        #expect(kind("<b>x</1>") == .invalidTag)
        #expect(kind("<b>x</i>") == .unmatchedClosingTag)
        #expect(kind("x</b>") == .unmatchedClosingTag)
        #expect(kind("<b>x") == .unclosedTag)
    }

    @Test func offsetsCountUTF16LikeFormatjs() throws {
        do {
            _ = try MessageParser.parse("😀😀 {a, foo}")
            Issue.record("parsed")
        } catch {
            #expect(error.kind == .invalidArgumentType)
            #expect(error.offset == 7) // scalars: the `f` of `foo`
            #expect(error.utf16Offset == 9) // formatjs location.start.offset
        }
    }

    @Test func nestingAndLengthAreBounded() {
        let deep = String(repeating: "<b>", count: 100) + "x" + String(repeating: "</b>", count: 100)
        #expect(kind(deep) == .nestingTooDeep)
        let deepPlural = String(repeating: "{n, plural, other {", count: 100) + String(repeating: "}}", count: 100)
        #expect(kind(deepPlural) == .nestingTooDeep)
        let ok = String(repeating: "<b>", count: 40) + "x" + String(repeating: "</b>", count: 40)
        #expect(kind(ok) == nil)
        #expect(kind(String(repeating: "a", count: MessageParser.maxLength + 1)) == .messageTooLong)
    }

    // MARK: AST shape

    @Test func astOfAPluralWithTagsAndQuotes() throws {
        let ast = try MessageParser.parse("Hi '{name}', <bold>{n, plural, offset:1 =0 {none} one {# file} other {# '#' files}}</bold><br/>")
        #expect(ast == [
            .literal("Hi {name}, "),
            .tag("bold", children: [
                .plural("n", kind: .cardinal, offset: 1, options: [
                    MessageOption(selector: "=0", value: [.literal("none")]),
                    MessageOption(selector: "one", value: [.pound, .literal(" file")]),
                    MessageOption(selector: "other", value: [.pound, .literal(" # files")]),
                ]),
            ]),
            .literal("<br/>"),
        ])
        #expect(try MessageParser.parse("{d, date, short} {t, time} {o, selectordinal, other {#}}") == [
            .date("d", style: .named("short")), .literal(" "), .time("t", style: nil), .literal(" "),
            .plural("o", kind: .ordinal, offset: 0, options: [MessageOption(selector: "other", value: [.pound])]),
        ])
        #expect(try MessageParser.parse("{n, number, ::percent scale/100}") == [
            .number("n", style: .numberSkeleton([.init(stem: "percent", options: []), .init(stem: "scale", options: ["100"])])),
        ])
    }

    /// Every prefix of every en message either parses or fails with a typed error.
    @Test func everyPrefixOfEveryEnglishMessageIsTotal() throws {
        let catalog = MessageCatalog.bundled
        var parsed = 0, rejected = 0
        for key in try catalog.keys() {
            guard let message = try catalog.message(key, locale: "en") else { continue }
            let scalars = Array(message.unicodeScalars)
            for end in stride(from: 0, through: scalars.count, by: 1) {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[0..<end])
                do {
                    _ = try MessageParser.parse(String(view))
                    parsed += 1
                } catch {
                    #expect(error.offset <= end)
                    rejected += 1
                }
            }
        }
        #expect(parsed > 0 && rejected > 0)
    }

    @Test func formattingErrorsAreTyped() {
        let i18n = Localizer(locale: "en")
        #expect(throws: I18nError.missingValue("n")) { try i18n.format(message: "{n, plural, other {#}}") }
        #expect(throws: I18nError.unsupported(argument: "d", feature: "date")) { try i18n.format(message: "{d, date}", ["d": 0]) }
        #expect(throws: I18nError.invalidValueType(argument: "x")) { try i18n.format(message: "{x}", ["x": .element("x")]) }
        #expect(throws: I18nError.syntax(MessageSyntaxError(kind: .emptyArgument, offset: 0, utf16Offset: 0))) { try i18n.format(message: "{}") }
        #expect(throws: I18nError.missingKey("icu:does-not-exist")) { try i18n.format("icu:does-not-exist") }
    }
}
