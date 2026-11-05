// Parser combinators for LangSec-style recognisers.
//
// A `Parser<Output>` is a named, total function from a bounded cursor to a typed
// value. Grammars for each format are composed from these combinators and from
// small hand-written rules that only use `ByteCursor` primitives. The important
// structural guarantees:
//
//  * `lengthPrefixed` / `region` run a sub-grammar on a *new* cursor bounded to
//    exactly the declared length, and require it to consume all of it. A wrong
//    length field therefore cannot make the sub-grammar read neighbouring data.
//  * `oneOf` is ordered choice (PEG). Each alternative starts at the same
//    position; no unbounded backtracking because alternatives are linear.
//  * `repeated` always carries an explicit upper bound.
//  * `validate` attaches specification constraints to an already parsed value,
//    reporting the offset where that value started.
//
// Grammars recognise first, decoders act second: nothing in here allocates in
// proportion to an unvalidated length except `bytes`, which is a no-copy view.

public struct Parser<Output>: Sendable {
    public let name: String
    @usableFromInline let body: @Sendable (inout ByteCursor) throws(ParseFailure) -> Output

    public init(_ name: String, _ body: @escaping @Sendable (inout ByteCursor) throws(ParseFailure) -> Output) {
        self.name = name
        self.body = body
    }

    @inlinable
    public func parse(_ cursor: inout ByteCursor) throws(ParseFailure) -> Output {
        do throws(ParseFailure) {
            return try body(&cursor)
        } catch {
            throw error.within(name)
        }
    }

    /// Parses `slice` and requires the grammar to consume every byte.
    public func parseComplete(_ slice: ByteSlice) throws(ParseFailure) -> Output {
        var c = slice.cursor()
        let v = try parse(&c)
        try c.expectEnd(name)
        return v
    }

    public func parseComplete(_ bytes: [UInt8]) throws(ParseFailure) -> Output {
        try parseComplete(ByteSlice(bytes))
    }

    /// Parses a prefix of `slice`; returns the value and the unconsumed rest.
    public func parsePrefix(_ slice: ByteSlice) throws(ParseFailure) -> (Output, ByteSlice) {
        var c = slice.cursor()
        let v = try parse(&c)
        return (v, c.rest())
    }

    public func map<T>(_ transform: @escaping @Sendable (Output) -> T) -> Parser<T> {
        Parser<T>(name) { (c: inout ByteCursor) throws(ParseFailure) -> T in
            transform(try self.body(&c))
        }
    }

    /// Transform that may reject (e.g. mapping a raw integer onto an enum).
    public func tryMap<T>(_ what: String, _ transform: @escaping @Sendable (Output) -> T?) -> Parser<T> {
        Parser<T>(name) { (c: inout ByteCursor) throws(ParseFailure) -> T in
            let at = c.position
            let raw = try self.body(&c)
            guard let v = transform(raw) else {
                throw ParseFailure(offset: at, rule: self.name, reason: .invalid("\(what): \(raw)"))
            }
            return v
        }
    }

    /// Attaches a specification constraint.
    public func validate(_ what: String, _ predicate: @escaping @Sendable (Output) -> Bool) -> Parser<Output> {
        Parser(name) { (c: inout ByteCursor) throws(ParseFailure) -> Output in
            let at = c.position
            let v = try self.body(&c)
            guard predicate(v) else {
                throw ParseFailure(offset: at, rule: self.name, reason: .invalid(what))
            }
            return v
        }
    }

    /// Attaches a SignalSafe resource limit (distinct from spec validity in errors).
    public func limit(_ what: String, _ predicate: @escaping @Sendable (Output) -> Bool) -> Parser<Output> {
        Parser(name) { (c: inout ByteCursor) throws(ParseFailure) -> Output in
            let at = c.position
            let v = try self.body(&c)
            guard predicate(v) else {
                throw ParseFailure(offset: at, rule: self.name, reason: .limitExceeded(what))
            }
            return v
        }
    }

    public func named(_ newName: String) -> Parser<Output> {
        Parser(newName, body)
    }

    /// Exactly `count` repetitions, with `count` checked against `maxCount` before
    /// any work (so a hostile count field cannot drive allocation).
    public func repeated(count: Int, maxCount: Int) -> Parser<[Output]> {
        Parser<[Output]>(name + "*") { (c: inout ByteCursor) throws(ParseFailure) -> [Output] in
            guard count >= 0 else { throw c.fail(self.name, .invalid("negative repeat count \(count)")) }
            guard count <= maxCount else { throw c.fail(self.name, .limitExceeded("repeat count \(count) > \(maxCount)")) }
            var out: [Output] = []
            out.reserveCapacity(count)
            for _ in 0..<count { out.append(try self.parse(&c)) }
            return out
        }
    }

    /// Repeats until the bounded region is exhausted.
    public func repeatedToEnd(maxCount: Int) -> Parser<[Output]> {
        Parser<[Output]>(name + "*") { (c: inout ByteCursor) throws(ParseFailure) -> [Output] in
            var out: [Output] = []
            while !c.isAtEnd {
                guard out.count < maxCount else { throw c.fail(self.name, .limitExceeded("more than \(maxCount) items")) }
                let before = c.position
                out.append(try self.parse(&c))
                if c.position == before { throw c.fail(self.name, .invalid("rule consumed no input")) }
            }
            return out
        }
    }
}

/// Namespace for primitive rules and structural combinators.
public enum Grammar {
    public static let u8 = Parser<UInt8>("u8") { (c: inout ByteCursor) throws(ParseFailure) in try c.u8() }
    public static let u16be = Parser<UInt16>("u16be") { (c: inout ByteCursor) throws(ParseFailure) in try c.u16be() }
    public static let u16le = Parser<UInt16>("u16le") { (c: inout ByteCursor) throws(ParseFailure) in try c.u16le() }
    public static let u24be = Parser<UInt32>("u24be") { (c: inout ByteCursor) throws(ParseFailure) in try c.u24be() }
    public static let u24le = Parser<UInt32>("u24le") { (c: inout ByteCursor) throws(ParseFailure) in try c.u24le() }
    public static let u32be = Parser<UInt32>("u32be") { (c: inout ByteCursor) throws(ParseFailure) in try c.u32be() }
    public static let u32le = Parser<UInt32>("u32le") { (c: inout ByteCursor) throws(ParseFailure) in try c.u32le() }

    public static func literal(_ name: String, _ bytes: [UInt8]) -> Parser<Void> {
        Parser<Void>(name) { (c: inout ByteCursor) throws(ParseFailure) in try c.expect(bytes, name) }
    }

    public static func bytes(_ name: String, count: Int) -> Parser<ByteSlice> {
        Parser<ByteSlice>(name) { (c: inout ByteCursor) throws(ParseFailure) in try c.bytes(count, name) }
    }

    /// Runs `body` on exactly the next `length` bytes and requires full consumption.
    public static func region<T>(_ name: String, length: Int, _ body: Parser<T>) -> Parser<T> {
        Parser<T>(name) { (c: inout ByteCursor) throws(ParseFailure) -> T in
            let slice = try c.bytes(length, name)
            return try body.parseComplete(slice)
        }
    }

    /// `length` field followed by a region governed by `body`.
    public static func lengthPrefixed<L: BinaryInteger & Sendable, T>(
        _ name: String, length: Parser<L>, maxLength: Int, _ body: Parser<T>
    ) -> Parser<T> {
        Parser<T>(name) { (c: inout ByteCursor) throws(ParseFailure) -> T in
            let at = c.position
            let raw = try length.parse(&c)
            guard raw >= 0, raw <= L(clamping: maxLength) else {
                throw ParseFailure(offset: at, rule: name, reason: .limitExceeded("length \(raw) > \(maxLength)"))
            }
            let slice = try c.bytes(Int(raw), name)
            return try body.parseComplete(slice)
        }
    }

    /// Ordered choice. Every alternative starts at the same position; the first
    /// that succeeds wins. If all fail, the failure that got furthest is reported.
    public static func oneOf<T>(_ name: String, _ alternatives: [Parser<T>]) -> Parser<T> {
        Parser<T>(name) { (c: inout ByteCursor) throws(ParseFailure) -> T in
            var best: ParseFailure?
            for alt in alternatives {
                var attempt = c
                do throws(ParseFailure) {
                    let v = try alt.parse(&attempt)
                    c = attempt
                    return v
                } catch {
                    if best == nil || error.offset > best!.offset { best = error }
                }
            }
            throw best ?? c.fail(name, .invalid("no alternatives"))
        }
    }

    /// Succeeds only at the end of the bounded region.
    public static func end(_ name: String = "end") -> Parser<Void> {
        Parser<Void>(name) { (c: inout ByteCursor) throws(ParseFailure) in try c.expectEnd(name) }
    }
}
