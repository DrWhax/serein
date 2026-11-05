import Foundation
@testable import SignalI18n

/// Loading of the formatjs fixtures written by Tools/gen-i18n-fixtures.mjs.
enum Fixtures {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appending(path: name)
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url(name)))
    }
}

/// A JSON argument value: number, string or `{"el": id}`.
enum FixtureArgument: Decodable {
    case number(Double), string(String), element(String)

    private struct Element: Decodable { let el: String }

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let x = try? c.decode(Double.self) { self = .number(x) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .element(try c.decode(Element.self).el) }
    }

    var argument: I18nArgument {
        switch self {
        case .number(let x): .number(x)
        case .string(let s): .string(s)
        case .element(let id): .element(id)
        }
    }
}

/// `["t", text, [tags]]` or `["e", id, [tags]]`.
struct FixtureRun: Decodable, Equatable, CustomStringConvertible {
    let kind: String
    let value: String
    let tags: [String]

    init(kind: String, value: String, tags: [String]) {
        self.kind = kind
        self.value = value
        self.tags = tags
    }

    init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        kind = try c.decode(String.self)
        value = try c.decode(String.self)
        tags = try c.decode([String].self)
    }

    init(_ run: RichText.Run) {
        switch run.content {
        case .text(let s): self.init(kind: "t", value: s, tags: run.tags)
        case .element(let id): self.init(kind: "e", value: id, tags: run.tags)
        }
    }

    var description: String { "\(kind):\(value.debugDescription)\(tags.isEmpty ? "" : "\(tags)")" }
}

struct MessageFixture: Decodable {
    struct Case: Decodable {
        let k: String
        let a: [String: FixtureArgument]
        let ra: [String: FixtureArgument]?
        let s: String?
        let se: String?
        let r: [FixtureRun]?
        let re: String?
    }

    let locale: String
    let full: Bool
    let cases: [Case]
}

extension [String: FixtureArgument] {
    var arguments: [String: I18nArgument] { mapValues(\.argument) }
}
