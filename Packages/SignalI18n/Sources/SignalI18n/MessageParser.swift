// Recogniser for the ICU MessageFormat dialect of @formatjs/icu-messageformat-parser 3.5.3
// (the parser behind Signal Desktop's intl-messageformat), with its default options
// (`requiresOtherClause: true`, `ignoreTag: false`, `shouldParseSkeletons: true`).
//
// LangSec discipline: the whole message is recognised against the grammar below into a
// typed AST (`[MessageElement]`) before anything is formatted. Every rule is a total
// function over the input: it returns an element or a typed `MessageSyntaxError` with the
// rule and offset, never traps. Recursion is bounded (`maxNesting`), and so is the
// message length (`maxLength`). Positions, error kinds and error offsets follow formatjs
// exactly, so error tests can be compared one to one.
//
//   message        = { element } ;
//   element        = argument | tag | pound | literal ;
//   pound          = "#" ;                      (only directly inside a plural branch)
//   argument       = "{" ws id ws ( "}" | "," ws argumentBody ) ;
//   argumentBody   = ( "number" | "date" | "time" ) ws [ "," ws style ] "}"
//                  | ( "plural" | "selectordinal" ) ws "," ws [ "offset:" ws int ws ] options "}"
//                  | "select" ws "," ws options "}" ;
//   options        = option { ws option } ;     (an "other" option is required)
//   option         = ( id | "=" int ) ws "{" message "}" ;  ("=" int not in select)
//   style          = { styleChar | "'" { char } "'" | "{" … "}" } ;  (up to the closing "}")
//   tag            = "<" tagName ws ( "/>" | ">" message "</" tagName ws ">" ) ;
//   tagName        = asciiAlpha { PENChar } ;
//   literal        = { quoted | unquoted | "<" (not followed by asciiAlpha or "/") } ;
//   quoted         = "''" | "'" ( "{" | "}" | "<" | ">" | "#"(in plural) ) { char | "''" } [ "'" ] ;
//   id             = { char - (White_Space | Pattern_Syntax) } ;
//   int            = [ "+" | "-" ] digit { digit } ;   (a safe integer, |n| < 2^53)
//   ws             = { 9…13 | 32 | 0x85 | 0x200E | 0x200F | 0x2028 | 0x2029 } ;

/// A message that does not match the grammar.
public struct MessageSyntaxError: Error, Sendable, Hashable, CustomStringConvertible {
    /// formatjs' `ErrorKind` names, plus the two resource limits of this recogniser.
    public enum Kind: String, Sendable, Hashable {
        case expectArgumentClosingBrace = "EXPECT_ARGUMENT_CLOSING_BRACE"
        case emptyArgument = "EMPTY_ARGUMENT"
        case malformedArgument = "MALFORMED_ARGUMENT"
        case expectArgumentType = "EXPECT_ARGUMENT_TYPE"
        case invalidArgumentType = "INVALID_ARGUMENT_TYPE"
        case expectArgumentStyle = "EXPECT_ARGUMENT_STYLE"
        case invalidNumberSkeleton = "INVALID_NUMBER_SKELETON"
        case expectDateTimeSkeleton = "EXPECT_DATE_TIME_SKELETON"
        case unclosedQuoteInArgumentStyle = "UNCLOSED_QUOTE_IN_ARGUMENT_STYLE"
        case expectSelectArgumentOptions = "EXPECT_SELECT_ARGUMENT_OPTIONS"
        case expectPluralArgumentOffsetValue = "EXPECT_PLURAL_ARGUMENT_OFFSET_VALUE"
        case invalidPluralArgumentOffsetValue = "INVALID_PLURAL_ARGUMENT_OFFSET_VALUE"
        case expectSelectArgumentSelector = "EXPECT_SELECT_ARGUMENT_SELECTOR"
        case expectPluralArgumentSelector = "EXPECT_PLURAL_ARGUMENT_SELECTOR"
        case expectSelectArgumentSelectorFragment = "EXPECT_SELECT_ARGUMENT_SELECTOR_FRAGMENT"
        case expectPluralArgumentSelectorFragment = "EXPECT_PLURAL_ARGUMENT_SELECTOR_FRAGMENT"
        case invalidPluralArgumentSelector = "INVALID_PLURAL_ARGUMENT_SELECTOR"
        case duplicatePluralArgumentSelector = "DUPLICATE_PLURAL_ARGUMENT_SELECTOR"
        case duplicateSelectArgumentSelector = "DUPLICATE_SELECT_ARGUMENT_SELECTOR"
        case missingOtherClause = "MISSING_OTHER_CLAUSE"
        case invalidTag = "INVALID_TAG"
        case unmatchedClosingTag = "UNMATCHED_CLOSING_TAG"
        case unclosedTag = "UNCLOSED_TAG"
        /// Nesting of tags / branches beyond `MessageParser.maxNesting`.
        case nestingTooDeep = "NESTING_TOO_DEEP"
        /// More than `MessageParser.maxLength` code points.
        case messageTooLong = "MESSAGE_TOO_LONG"
    }

    public let kind: Kind
    /// Offset of the error location's start, in Unicode scalars.
    public let offset: Int
    /// The same offset in UTF-16 code units (formatjs' `location.start.offset`).
    public let utf16Offset: Int

    public var description: String { "\(kind.rawValue) at \(offset)" }
}

/// Grammar-driven recogniser: `String` → `[MessageElement]`.
public struct MessageParser: Sendable {
    /// Deepest accepted nesting of tags and plural/select branches.
    public static let maxNesting = 48
    /// Longest accepted message, in Unicode scalars.
    public static let maxLength = 1 << 16

    public static func parse(_ message: String) throws(MessageSyntaxError) -> [MessageElement] {
        var p = MessageParser(message)
        guard p.s.count <= maxLength else { throw p.error(.messageTooLong, at: maxLength) }
        return try p.parseMessage(nesting: 0, parent: .none, expectingCloseTag: false)
    }

    private enum Parent { case none, plural, selectordinal, select
        var allowsPound: Bool { self == .plural || self == .selectordinal }
    }

    private let s: [Unicode.Scalar]
    private var pos = 0

    private init(_ message: String) {
        s = Array(message.unicodeScalars)
    }

    // MARK: Input primitives (formatjs: char / peek / bump / bumpIf / bumpSpace)

    private var isEOF: Bool { pos >= s.count }
    private var char: UInt32 { pos < s.count ? s[pos].value : 0 }
    private var peek: UInt32? { pos + 1 < s.count ? s[pos + 1].value : nil }

    private mutating func bump() { if pos < s.count { pos += 1 } }

    private func hasPrefix(_ prefix: String, at offset: Int) -> Bool {
        var i = offset
        for scalar in prefix.unicodeScalars {
            guard i < s.count, s[i] == scalar else { return false }
            i += 1
        }
        return true
    }

    private mutating func bumpIf(_ prefix: String) -> Bool {
        guard hasPrefix(prefix, at: pos) else { return false }
        pos += prefix.unicodeScalars.count
        return true
    }

    private mutating func bumpSpace() {
        while !isEOF, Self.isPatternWhiteSpace(char) { bump() }
    }

    private func error(_ kind: MessageSyntaxError.Kind, at offset: Int) -> MessageSyntaxError {
        let clamped = min(offset, s.count)
        var utf16 = 0
        for i in 0..<clamped { utf16 += s[i].utf16.count }
        return MessageSyntaxError(kind: kind, offset: clamped, utf16Offset: utf16)
    }

    private func text(_ range: Range<Int>) -> String {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: s[range])
        return String(out)
    }

    // MARK: message = { element }

    private mutating func parseMessage(nesting: Int, parent: Parent, expectingCloseTag: Bool) throws(MessageSyntaxError) -> [MessageElement] {
        guard nesting <= Self.maxNesting else { throw error(.nestingTooDeep, at: pos) }
        var elements: [MessageElement] = []
        while !isEOF {
            let c = char
            if c == 0x7B /* { */ {
                elements.append(try parseArgument(nesting: nesting, expectingCloseTag: expectingCloseTag))
            } else if c == 0x7D /* } */, nesting > 0 {
                break
            } else if c == 0x23 /* # */, parent.allowsPound {
                bump()
                elements.append(.pound)
            } else if c == 0x3C /* < */, peek == 0x2F /* / */ {
                if expectingCloseTag { break }
                throw error(.unmatchedClosingTag, at: pos)
            } else if c == 0x3C, let next = peek, Self.isASCIIAlpha(next) {
                elements.append(try parseTag(nesting: nesting, parent: parent))
            } else {
                elements.append(.literal(parseLiteral(nesting: nesting, parent: parent)))
            }
        }
        return elements
    }

    // MARK: tag = "<" tagName ws ( "/>" | ">" message "</" tagName ws ">" )

    private mutating func parseTag(nesting: Int, parent: Parent) throws(MessageSyntaxError) -> MessageElement {
        let start = pos
        bump() // <
        let name = parseTagName()
        bumpSpace()
        if bumpIf("/>") {
            return .literal("<\(name)/>")
        }
        guard bumpIf(">") else { throw error(.invalidTag, at: start) }
        let children = try parseMessage(nesting: nesting + 1, parent: parent, expectingCloseTag: true)
        let endTagStart = pos
        guard bumpIf("</") else { throw error(.unclosedTag, at: start) }
        guard !isEOF, Self.isASCIIAlpha(char) else { throw error(.invalidTag, at: endTagStart) }
        let closingNameStart = pos
        let closingName = parseTagName()
        guard closingName == name else { throw error(.unmatchedClosingTag, at: closingNameStart) }
        bumpSpace()
        guard bumpIf(">") else { throw error(.invalidTag, at: endTagStart) }
        return .tag(name, children: children)
    }

    /// The caller has checked that the first character is an ASCII letter.
    private mutating func parseTagName() -> String {
        let start = pos
        bump()
        while !isEOF, Self.isPotentialElementNameChar(char) { bump() }
        return text(start..<pos)
    }

    // MARK: literal

    private mutating func parseLiteral(nesting: Int, parent: Parent) -> String {
        var value = String.UnicodeScalarView()
        while true {
            if tryParseQuote(parent: parent, into: &value) { continue }
            if tryParseUnquoted(nesting: nesting, parent: parent, into: &value) { continue }
            if tryParseLeftAngleBracket(into: &value) { continue }
            break
        }
        return String(value)
    }

    private mutating func tryParseLeftAngleBracket(into value: inout String.UnicodeScalarView) -> Bool {
        guard !isEOF, char == 0x3C else { return false }
        if let next = peek, Self.isASCIIAlpha(next) || next == 0x2F { return false }
        bump()
        value.append("<")
        return true
    }

    /// ICU ≥ 4.8 apostrophe mode: `'` only quotes when it precedes a character that needs it.
    private mutating func tryParseQuote(parent: Parent, into value: inout String.UnicodeScalarView) -> Bool {
        guard !isEOF, char == 0x27 else { return false }
        switch peek {
        case 0x27:
            bump(); bump()
            value.append("'")
            return true
        case 0x7B, 0x3C, 0x3E, 0x7D:
            break
        case 0x23 where parent.allowsPound:
            break
        default:
            return false
        }
        bump() // opening '
        value.append(s[pos])
        bump()
        while !isEOF {
            if char == 0x27 {
                if peek == 0x27 {
                    value.append("'")
                    bump()
                } else {
                    bump() // closing '
                    break
                }
            } else {
                value.append(s[pos])
            }
            bump()
        }
        return true
    }

    private mutating func tryParseUnquoted(nesting: Int, parent: Parent, into value: inout String.UnicodeScalarView) -> Bool {
        guard !isEOF else { return false }
        let c = char
        if c == 0x3C || c == 0x7B || (c == 0x23 && parent.allowsPound) || (c == 0x7D && nesting > 0) {
            return false
        }
        value.append(s[pos])
        bump()
        return true
    }

    // MARK: argument = "{" ws id ws ( "}" | "," ws argumentBody )

    private mutating func parseArgument(nesting: Int, expectingCloseTag: Bool) throws(MessageSyntaxError) -> MessageElement {
        let open = pos
        bump() // {
        bumpSpace()
        guard !isEOF else { throw error(.expectArgumentClosingBrace, at: open) }
        if char == 0x7D {
            bump()
            throw error(.emptyArgument, at: open)
        }
        let name = parseIdentifier()
        guard !name.isEmpty else { throw error(.malformedArgument, at: open) }
        bumpSpace()
        guard !isEOF else { throw error(.expectArgumentClosingBrace, at: open) }
        switch char {
        case 0x7D:
            bump()
            return .argument(name)
        case 0x2C:
            bump()
            bumpSpace()
            guard !isEOF else { throw error(.expectArgumentClosingBrace, at: open) }
            return try parseArgumentOptions(nesting: nesting, expectingCloseTag: expectingCloseTag, name: name, open: open)
        default:
            throw error(.malformedArgument, at: open)
        }
    }

    /// `[^\p{White_Space}\p{Pattern_Syntax}]*` at the current position.
    private mutating func parseIdentifier() -> String {
        let start = pos
        while !isEOF, !Self.isIdentifierStop(char) { bump() }
        return text(start..<pos)
    }

    private mutating func parseArgumentOptions(nesting: Int, expectingCloseTag: Bool, name: String, open: Int) throws(MessageSyntaxError) -> MessageElement {
        let typeStart = pos
        let type = parseIdentifier()
        switch type {
        case "":
            throw error(.expectArgumentType, at: typeStart)
        case "number", "date", "time":
            bumpSpace()
            var style: (text: String, start: Int)?
            if bumpIf(",") {
                bumpSpace()
                let styleStart = pos
                let raw = try parseSimpleArgStyle()
                let trimmed = Self.trimEnd(raw)
                guard !trimmed.isEmpty else { throw error(.expectArgumentStyle, at: pos) }
                style = (trimmed, styleStart)
            }
            try parseArgumentClose(open: open)
            guard let style else {
                return type == "number" ? .number(name, style: nil) : type == "date" ? .date(name, style: nil) : .time(name, style: nil)
            }
            if style.text.hasPrefix("::") {
                let skeleton = Self.trimStart(String(style.text.unicodeScalars.dropFirst(2)))
                if type == "number" {
                    guard let tokens = Self.numberSkeletonTokens(skeleton) else {
                        throw error(.invalidNumberSkeleton, at: style.start)
                    }
                    return .number(name, style: .numberSkeleton(tokens))
                }
                guard !skeleton.isEmpty else { throw error(.expectDateTimeSkeleton, at: open) }
                return type == "date" ? .date(name, style: .dateTimeSkeleton(skeleton)) : .time(name, style: .dateTimeSkeleton(skeleton))
            }
            let named = ArgumentStyle.named(style.text)
            return type == "number" ? .number(name, style: named) : type == "date" ? .date(name, style: named) : .time(name, style: named)
        case "plural", "selectordinal", "select":
            let typeEnd = pos
            bumpSpace()
            guard bumpIf(",") else { throw error(.expectSelectArgumentOptions, at: typeEnd) }
            bumpSpace()
            var firstStart = pos
            var first = parseIdentifier()
            var offset = 0
            if type != "select", first == "offset" {
                guard bumpIf(":") else { throw error(.expectPluralArgumentOffsetValue, at: pos) }
                bumpSpace()
                offset = try parseDecimalInteger(expect: .expectPluralArgumentOffsetValue, invalid: .invalidPluralArgumentOffsetValue)
                bumpSpace()
                firstStart = pos
                first = parseIdentifier()
            }
            let parent: Parent = type == "plural" ? .plural : type == "selectordinal" ? .selectordinal : .select
            let options = try parseOptions(nesting: nesting, parent: parent, expectingCloseTag: expectingCloseTag, first: first, firstStart: firstStart)
            try parseArgumentClose(open: open)
            if parent == .select { return .select(name, options: options) }
            return .plural(name, kind: parent == .plural ? .cardinal : .ordinal, offset: offset, options: options)
        default:
            throw error(.invalidArgumentType, at: typeStart)
        }
    }

    private mutating func parseArgumentClose(open: Int) throws(MessageSyntaxError) {
        guard !isEOF, char == 0x7D else { throw error(.expectArgumentClosingBrace, at: open) }
        bump()
    }

    /// ICU MessagePattern's simple-argument style: up to the `}` that closes the argument,
    /// apostrophes quote (and are kept), `{…}` nest.
    private mutating func parseSimpleArgStyle() throws(MessageSyntaxError) -> String {
        var nestedBraces = 0
        let start = pos
        while !isEOF {
            switch char {
            case 0x27:
                bump()
                let apostrophe = pos
                guard let close = s[pos...].firstIndex(of: "'") else {
                    pos = s.count
                    throw error(.unclosedQuoteInArgumentStyle, at: apostrophe)
                }
                pos = close
                bump()
            case 0x7B:
                nestedBraces += 1
                bump()
            case 0x7D:
                // formatjs does not advance here: the same `}` is seen again with one
                // less level, so `a{b}c` ends the style at the inner `}`.
                if nestedBraces > 0 { nestedBraces -= 1 } else { return text(start..<pos) }
            default:
                bump()
            }
        }
        return text(start..<pos)
    }

    /// options = option { ws option }, option = ( id | "=" int ) ws "{" message "}"
    private mutating func parseOptions(nesting: Int, parent: Parent, expectingCloseTag: Bool, first: String, firstStart: Int) throws(MessageSyntaxError) -> [MessageOption] {
        var hasOther = false
        var options: [MessageOption] = []
        var seen: Set<String> = []
        var selector = first
        var selectorStart = firstStart
        while true {
            if selector.isEmpty {
                let start = pos
                guard parent != .select, bumpIf("=") else { break }
                _ = try parseDecimalInteger(expect: .expectPluralArgumentSelector, invalid: .invalidPluralArgumentSelector)
                selectorStart = start
                selector = text(start..<pos)
            }
            guard !seen.contains(selector) else {
                throw error(parent == .select ? .duplicateSelectArgumentSelector : .duplicatePluralArgumentSelector, at: selectorStart)
            }
            if selector == "other" { hasOther = true }
            bumpSpace()
            let open = pos
            guard bumpIf("{") else {
                throw error(parent == .select ? .expectSelectArgumentSelectorFragment : .expectPluralArgumentSelectorFragment, at: pos)
            }
            let fragment = try parseMessage(nesting: nesting + 1, parent: parent, expectingCloseTag: expectingCloseTag)
            try parseArgumentClose(open: open)
            options.append(MessageOption(selector: selector, value: fragment))
            seen.insert(selector)
            bumpSpace()
            selectorStart = pos
            selector = parseIdentifier()
        }
        guard !options.isEmpty else {
            throw error(parent == .select ? .expectSelectArgumentSelector : .expectPluralArgumentSelector, at: pos)
        }
        guard hasOther else { throw error(.missingOtherClause, at: pos) }
        return options
    }

    /// int = [ "+" | "-" ] digit { digit }, required to be a safe integer.
    private mutating func parseDecimalInteger(expect: MessageSyntaxError.Kind, invalid: MessageSyntaxError.Kind) throws(MessageSyntaxError) -> Int {
        let start = pos
        var sign = 1
        if bumpIf("+") {} else if bumpIf("-") { sign = -1 }
        var hasDigits = false
        var value = 0
        var overflow = false
        while !isEOF, char >= 0x30, char <= 0x39 {
            hasDigits = true
            if !overflow {
                value = value * 10 + Int(char - 0x30)
                if value > Self.maxSafeInteger { overflow = true }
            }
            bump()
        }
        guard hasDigits else { throw error(expect, at: start) }
        guard !overflow else { throw error(invalid, at: start) }
        return value * sign
    }

    private static let maxSafeInteger = (1 << 53) - 1

    // MARK: Number skeleton tokens (@formatjs/icu-skeleton-parser parseNumberSkeletonFromString)

    private static func numberSkeletonTokens(_ skeleton: String) -> [NumberSkeletonToken]? {
        guard !skeleton.isEmpty else { return nil }
        var tokens: [NumberSkeletonToken] = []
        let words = skeleton.unicodeScalars.split(whereSeparator: { isPatternWhiteSpace($0.value) })
        for word in words {
            let parts = word.split(separator: "/", omittingEmptySubsequences: false).map { String($0) }
            guard let stem = parts.first else { return nil }
            let options = Array(parts.dropFirst())
            guard !options.contains(where: \.isEmpty) else { return nil }
            tokens.append(NumberSkeletonToken(stem: stem, options: options))
        }
        return tokens
    }

    // MARK: Character classes

    static func isASCIIAlpha(_ c: UInt32) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
    }

    /// formatjs `_isWhiteSpace` (Pattern_White_Space).
    static func isPatternWhiteSpace(_ c: UInt32) -> Bool {
        (c >= 9 && c <= 13) || c == 32 || c == 0x85 || c == 0x200E || c == 0x200F || c == 0x2028 || c == 0x2029
    }

    /// formatjs `_isPotentialElementNameChar` (HTML custom element PENChar, uppercase allowed).
    static func isPotentialElementNameChar(_ c: UInt32) -> Bool {
        c == 0x2D || c == 0x2E || (c >= 0x30 && c <= 0x39) || c == 0x5F || isASCIIAlpha(c) || c == 0xB7
            || (c >= 0xC0 && c <= 0xD6) || (c >= 0xD8 && c <= 0xF6) || (c >= 0xF8 && c <= 0x37D)
            || (c >= 0x37F && c <= 0x1FFF) || (c >= 0x200C && c <= 0x200D) || (c >= 0x203F && c <= 0x2040)
            || (c >= 0x2070 && c <= 0x218F) || (c >= 0x2C00 && c <= 0x2FEF) || (c >= 0x3001 && c <= 0xD7FF)
            || (c >= 0xF900 && c <= 0xFDCF) || (c >= 0xFDF0 && c <= 0xFFFD) || (c >= 0x10000 && c <= 0xEFFFF)
    }

    static func isIdentifierStop(_ c: UInt32) -> Bool {
        UnicodeSets.identifierStop.contains { $0.contains(c) }
    }

    static func isECMAWhiteSpace(_ c: UInt32) -> Bool {
        UnicodeSets.ecmaWhiteSpace.contains { $0.contains(c) }
    }

    static func trimEnd(_ string: String) -> String {
        var scalars = Substring(string).unicodeScalars
        while let last = scalars.last, isECMAWhiteSpace(last.value) { scalars.removeLast() }
        return String(scalars)
    }

    static func trimStart(_ string: String) -> String {
        var scalars = Substring(string).unicodeScalars
        while let first = scalars.first, isECMAWhiteSpace(first.value) { scalars.removeFirst() }
        return String(scalars)
    }
}
