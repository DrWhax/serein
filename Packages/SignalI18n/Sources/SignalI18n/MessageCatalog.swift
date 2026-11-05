import Foundation
import Synchronization

/// Signal Desktop's string tables: `keys.json` plus one `[String?]` table per locale,
/// aligned with the keys (upstream's packaged `build/compact-locales` layout). Tables are
/// read on first use of a locale and kept.
public final class MessageCatalog: Sendable {
    /// The tables generated from Signal-Desktop/_locales into this package.
    public static let bundled = MessageCatalog(directory: Bundle.module.url(forResource: "Locales", withExtension: nil))

    private enum Source: Sendable {
        case directory(URL?)
        case memory([String: [String: String]])
    }

    private struct State {
        var index: [String: Int]?
        var tables: [String: [String?]] = [:]
    }

    private let source: Source
    private let state = Mutex(State())

    /// Tables in `directory` (`keys.json`, `<locale>.json`).
    public init(directory: URL?) {
        source = .directory(directory)
    }

    /// In-memory tables: locale → key → ICU message.
    public init(messages: [String: [String: String]]) {
        source = .memory(messages)
    }

    /// The ICU source of `key` in `locale` exactly (no fallback); nil if not translated.
    public func message(_ key: String, locale: String) throws(I18nError) -> String? {
        switch source {
        case .memory(let messages):
            return messages[locale]?[key]
        case .directory(let directory):
            guard let directory else { throw .resourceUnavailable("SignalI18n resource bundle has no Locales directory") }
            let result: Result<String?, I18nError> = state.withLock { state in
                do throws(I18nError) {
                    if state.index == nil {
                        let keys = try Self.load([String].self, directory.appending(path: "keys.json"))
                        state.index = Dictionary(keys.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
                    }
                    guard let i = state.index?[key] else { return .success(nil) }
                    if state.tables[locale] == nil {
                        let table = try Self.load([String?].self, directory.appending(path: "\(locale).json"))
                        guard table.count == state.index?.count else {
                            throw .resourceUnavailable("\(locale).json has \(table.count) entries, keys.json \(state.index?.count ?? 0)")
                        }
                        state.tables[locale] = table
                    }
                    return .success(state.tables[locale]?[i] ?? nil)
                } catch {
                    return .failure(error)
                }
            }
            return try result.get()
        }
    }

    /// All keys (sorted), for tooling and tests.
    public func keys() throws(I18nError) -> [String] {
        switch source {
        case .memory(let messages):
            return Set(messages.values.flatMap(\.keys)).sorted()
        case .directory(let directory):
            guard let directory else { throw .resourceUnavailable("SignalI18n resource bundle has no Locales directory") }
            return try Self.load([String].self, directory.appending(path: "keys.json"))
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ url: URL) throws(I18nError) -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch {
            throw .resourceUnavailable("\(url.lastPathComponent): \(error)")
        }
    }
}
