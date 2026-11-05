// Formats a parsed message, following intl-messageformat 11.2's `formatToParts`
// (src/formatters.js) step by step, including its merging of adjacent literal parts.

/// A value substituted into a message.
public enum I18nArgument: Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByStringInterpolation,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral
{
    /// A string (bidi-isolated by `Localizer.string` unless told otherwise).
    case string(String)
    /// A number: `plural`, `selectordinal`, `{n, number}`, `#`; `{n}` prints it like JS `String(n)`.
    case number(Double)
    /// An inline component, rich text only (upstream: a JSX element passed to `<I18n>`).
    /// It comes back as a `RichText.Run` with `.element(id)` content.
    case element(String)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public static func int(_ value: some BinaryInteger) -> I18nArgument { .number(Double(value)) }
}

/// Everything that can go wrong formatting a message. Formatting never traps.
public enum I18nError: Error, Sendable, Hashable {
    /// No such key in the locale or in en.
    case missingKey(String)
    /// The message does not match the ICU grammar.
    case syntax(MessageSyntaxError)
    /// The message uses `{name}` but no value was given (formatjs MissingValueError).
    case missingValue(String)
    /// No branch matches and there is no `other` (formatjs InvalidValueError).
    case invalidValue(argument: String, value: String)
    /// An `.element` value where plain text is required.
    case invalidValueType(argument: String)
    /// `date`/`time` arguments, number skeletons and the `currency` style: upstream's
    /// strings use none of them, and they are not implemented.
    case unsupported(argument: String, feature: String)
    /// The bundled string tables could not be read.
    case resourceUnavailable(String)
}

/// Output of formatting, before it is flattened to a string or rich text.
enum FormattedPart: Hashable {
    case literal(String)
    case element(String)
    case tag(String, [FormattedPart])
}

struct MessageFormatter {
    enum TagMode {
        /// Tag contents are spliced into the surrounding text (plain-string formatting).
        case flatten
        /// Tags become `.tag` parts (rich text; every tag is supplied, like `<I18n>` does).
        case structure
    }

    let locale: LocaleData
    let values: [String: I18nArgument]
    let tags: TagMode

    func format(_ elements: [MessageElement]) throws(I18nError) -> [FormattedPart] {
        try formatToParts(elements, pluralValue: nil)
    }

    private func value(_ name: String) throws(I18nError) -> I18nArgument {
        guard let value = values[name] else { throw .missingValue(name) }
        return value
    }

    private func number(_ value: I18nArgument) -> Double {
        switch value {
        case .number(let x): x
        case .string(let s): jsToNumber(s)
        case .element: .nan // ToNumber(object)
        }
    }

    /// The JS `String(value)` / property key of a value.
    private func key(_ value: I18nArgument) -> String {
        switch value {
        case .number(let x): jsString(x)
        case .string(let s): s
        case .element: "[object Object]"
        }
    }

    private func formatToParts(_ elements: [MessageElement], pluralValue: Double?) throws(I18nError) -> [FormattedPart] {
        if elements.count == 1, case .literal(let text) = elements[0] { return [.literal(text)] }
        var result: [FormattedPart] = []
        for element in elements {
            switch element {
            case .literal(let text):
                result.append(.literal(text))
            case .pound:
                if let pluralValue { result.append(.literal(locale.numbers.format(pluralValue))) }
            case .argument(let name):
                switch try value(name) {
                case .string(let s): result.append(.literal(s))
                case .number(let x): result.append(.literal(jsString(x)))
                case .element(let id):
                    guard tags == .structure else { throw .invalidValueType(argument: name) }
                    result.append(.element(id))
                }
            case .date(let name, _):
                _ = try value(name)
                throw .unsupported(argument: name, feature: "date")
            case .time(let name, _):
                _ = try value(name)
                throw .unsupported(argument: name, feature: "time")
            case .number(let name, let style):
                let x = number(try value(name))
                let numberStyle: NumberSymbols.Style
                switch style {
                case nil: numberStyle = .decimal
                case .named("percent"): numberStyle = .percent
                case .named("integer"): numberStyle = .integer
                case .named("currency"): throw .unsupported(argument: name, feature: "currency")
                case .named: numberStyle = .decimal // unknown named styles: default options
                case .numberSkeleton, .dateTimeSkeleton: throw .unsupported(argument: name, feature: "number skeleton")
                }
                result.append(.literal(locale.numbers.format(x, style: numberStyle)))
            case .tag(let name, let children):
                let parts = try formatToParts(children, pluralValue: pluralValue)
                switch tags {
                case .flatten: result.append(contentsOf: parts)
                case .structure: result.append(.tag(name, parts))
                }
            case .select(let name, let options):
                let v = try value(name)
                guard let branch = options.branch(key(v)) ?? options.branch("other") else {
                    throw .invalidValue(argument: name, value: key(v))
                }
                result.append(contentsOf: try formatToParts(branch, pluralValue: nil))
            case .plural(let name, let kind, let offset, let options):
                let v = try value(name)
                let x = number(v) - Double(offset)
                var branch = options.branch("=" + key(v))
                if branch == nil {
                    let rules = kind == .cardinal ? locale.cardinalRules : locale.ordinalRules
                    let category = PluralRuleSet.select(rules, x)
                    branch = options.branch(category.rawValue) ?? options.branch("other")
                }
                guard let branch else { throw .invalidValue(argument: name, value: key(v)) }
                result.append(contentsOf: try formatToParts(branch, pluralValue: x))
            }
        }
        return Self.mergeLiterals(result)
    }

    static func mergeLiterals(_ parts: [FormattedPart]) -> [FormattedPart] {
        guard parts.count >= 2 else { return parts }
        var out: [FormattedPart] = []
        out.reserveCapacity(parts.count)
        for part in parts {
            if case .literal(let next) = part, case .literal(let previous)? = out.last {
                out[out.count - 1] = .literal(previous + next)
            } else {
                out.append(part)
            }
        }
        return out
    }
}
