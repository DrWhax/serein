// The typed AST of an ICU MessageFormat message, as recognised by `MessageParser`.
// Mirrors @formatjs/icu-messageformat-parser's element types (TYPE.literal … TYPE.tag);
// only this AST ever reaches the formatter.

/// One element of a parsed message.
public indirect enum MessageElement: Sendable, Hashable {
    /// Literal text, quotes already resolved.
    case literal(String)
    /// `{name}`
    case argument(String)
    /// `{name, number}`, `{name, number, style}`
    case number(String, style: ArgumentStyle?)
    /// `{name, date[, style]}` (recognised; upstream's strings never use it)
    case date(String, style: ArgumentStyle?)
    /// `{name, time[, style]}` (recognised; upstream's strings never use it)
    case time(String, style: ArgumentStyle?)
    /// `{name, select, key {…} … other {…}}`
    case select(String, options: [MessageOption])
    /// `{name, plural|selectordinal, [offset:n] =N {…} one {…} … other {…}}`
    case plural(String, kind: PluralKind, offset: Int, options: [MessageOption])
    /// `#` inside a plural / selectordinal branch.
    case pound
    /// `<name>children</name>`
    case tag(String, children: [MessageElement])
}

/// A selector and its branch (`one {…}`, `=0 {…}`, `male {…}`).
public struct MessageOption: Sendable, Hashable {
    /// The selector exactly as written (`one`, `=0`, `=+1`, `male`).
    public let selector: String
    public let value: [MessageElement]
}

/// The style part of a `number` / `date` / `time` argument.
public enum ArgumentStyle: Sendable, Hashable {
    /// A named style (`percent`, `integer`, `short`, …).
    case named(String)
    /// `::` number skeleton, as tokens (stem and options).
    case numberSkeleton([NumberSkeletonToken])
    /// `::` date-time skeleton.
    case dateTimeSkeleton(String)
}

public struct NumberSkeletonToken: Sendable, Hashable {
    public let stem: String
    public let options: [String]
}

public enum PluralKind: Sendable, Hashable {
    /// `plural`
    case cardinal
    /// `selectordinal`
    case ordinal
}

extension [MessageOption] {
    /// The branch for `selector`, like formatjs' `hasOwnProperty(el.options, key)`.
    func branch(_ selector: String) -> [MessageElement]? {
        first { $0.selector == selector }?.value
    }
}
