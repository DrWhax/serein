// The single error type produced by every recogniser and decoder in SignalCodecs.
//
// LangSec rule: a parser either returns a fully typed value or a structured
// failure that names *where* (byte offset), *which rule* rejected the input and
// *why*. It never traps, never returns a partially initialised value.

public struct ParseFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Reason: Sendable, Equatable {
        /// The rule needed more bytes (or bits) than the bounded input holds.
        case unexpectedEnd(needed: Int, available: Int)
        /// A literal / magic / tag did not match.
        case mismatch(expected: String)
        /// A field parsed but violates a constraint stated by the specification.
        case invalid(String)
        /// A field parsed and is legal per spec, but exceeds a SignalSafe resource limit.
        case limitExceeded(String)
        /// A length-delimited region was not fully consumed by its grammar.
        case trailingBytes(Int)
        /// An integrity check (CRC, Adler, …) failed.
        case checksum(expected: UInt32, computed: UInt32)
    }

    /// Absolute byte offset into the original input where the failing rule started
    /// (for bit-level rules: the byte containing the failing bit).
    public var offset: Int
    /// Innermost rule that rejected the input.
    public var rule: String
    public var reason: Reason
    /// Enclosing rules, outermost first. Filled in as the failure unwinds.
    public var path: [String]

    public init(offset: Int, rule: String, reason: Reason, path: [String] = []) {
        self.offset = offset
        self.rule = rule
        self.reason = reason
        self.path = path
    }

    /// Returns a copy annotated with an enclosing rule name.
    public func within(_ outer: String) -> ParseFailure {
        // A rule that raised its own failure is already named in `rule`.
        if path.isEmpty && rule == outer { return self }
        var copy = self
        copy.path.insert(outer, at: 0)
        return copy
    }

    public var description: String {
        let where_ = (path + [rule]).joined(separator: " › ")
        return "\(where_) @\(offset): \(reason)"
    }
}
