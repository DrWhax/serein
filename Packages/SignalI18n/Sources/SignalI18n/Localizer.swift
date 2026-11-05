import Synchronization

/// The port of upstream's `LocalizerType` (`window.i18n`, ts/util/setupI18nMain.std.ts).
///
///     let i18n = Localizer(locale: "de")
///     i18n("icu:ok")                                         // "OK"
///     i18n("icu:...", ["count": 3, "name": "Alice"])         // plural, bidi-isolated name
///     i18n.richText("icu:...", ["learnMore": ...])           // runs + tag ranges
///
/// Message lookup is upstream's: the locale's string, else en's (`merge(en, locale)`).
/// Errors never trap: the non-throwing calls report them to `onError` and fall back
/// locale → en → key; `format` / `formatRichText` throw them instead.
public final class Localizer: Sendable {
    /// The locale id in use (one of `Localizer.availableLocales`).
    public let locale: String
    /// The locale's writing direction (upstream `getLocaleDirection`).
    public var direction: LayoutDirection { data.direction }

    private let data: LocaleData
    private let catalog: MessageCatalog
    private let onError: (@Sendable (_ key: String, _ error: I18nError) -> Void)?
    private let cache = Mutex<[CacheKey: Result<[MessageElement], MessageSyntaxError>]>([:])

    private struct CacheKey: Hashable {
        let key: String
        let english: Bool
    }

    /// The 68 locales upstream ships (Signal-Desktop/build/available-locales.json).
    public static var availableLocales: [String] { LocaleData.all.map(\.identifier) }

    /// - Parameter locale: a Signal locale id, or any BCP 47 tag (matched with
    ///   `Localizer.match`).
    public init(
        locale: String,
        catalog: MessageCatalog = .bundled,
        onError: (@Sendable (_ key: String, _ error: I18nError) -> Void)? = nil
    ) {
        let data = LocaleData.named(locale) ?? LocaleData.named(Self.match([locale])) ?? LocaleData.english
        self.data = data
        self.locale = data.identifier
        self.catalog = catalog
        self.onError = onError
    }

    // MARK: Plain strings (upstream `i18n(key, substitutions, options)`)

    /// The formatted string. String arguments are bidi-isolated like upstream's
    /// `normalizeSubstitutions` unless `bidi` says otherwise. Tags are flattened to their
    /// text (`<emojify>` included). Never fails: see `onError`.
    public func callAsFunction(_ key: String, _ arguments: [String: I18nArgument] = [:], bidi: BidiHandling = .isolate) -> String {
        resolve(key) { (elements) throws(I18nError) -> String in
            try self.flatten(elements, arguments, bidi)
        }
    }

    /// Throwing variant of `callAsFunction`: no fallback past upstream's locale → en lookup.
    public func format(_ key: String, _ arguments: [String: I18nArgument] = [:], bidi: BidiHandling = .isolate) throws(I18nError) -> String {
        try flatten(try parsed(key, english: false), arguments, bidi)
    }

    // MARK: Rich text (upstream `<I18n id=… components=…>`)

    /// The formatted message as runs and tag ranges. Like `<I18n>`, string arguments are
    /// substituted as given (`bidi: .none`). Every tag is reported; none needs a handler.
    public func richText(_ key: String, _ arguments: [String: I18nArgument] = [:], bidi: BidiHandling = .none) -> RichText {
        resolve(key) { (elements) throws(I18nError) -> RichText in
            try self.rich(elements, arguments, bidi)
        } fallback: {
            RichText(parts: [.literal(key)])
        }
    }

    /// Throwing variant of `richText`.
    public func formatRichText(_ key: String, _ arguments: [String: I18nArgument] = [:], bidi: BidiHandling = .none) throws(I18nError) -> RichText {
        try rich(try parsed(key, english: false), arguments, bidi)
    }

    // MARK: Messages

    /// The raw ICU message used for `key` (locale, else en), if any.
    public func message(_ key: String) -> String? {
        (try? catalog.message(key, locale: data.identifier)) ?? (try? catalog.message(key, locale: "en")) ?? nil
    }

    /// Formats an ICU message that is not in the catalog, with this locale's rules.
    public func format(message: String, _ arguments: [String: I18nArgument] = [:], bidi: BidiHandling = .none) throws(I18nError) -> String {
        try flatten(try Self.parse(message), arguments, bidi)
    }

    /// Rich-text variant of `format(message:)`.
    public func formatRichText(message: String, _ arguments: [String: I18nArgument] = [:], bidi: BidiHandling = .none) throws(I18nError) -> RichText {
        try rich(try Self.parse(message), arguments, bidi)
    }

    // MARK: Internals

    private static func parse(_ message: String) throws(I18nError) -> [MessageElement] {
        do {
            return try MessageParser.parse(message)
        } catch {
            throw .syntax(error)
        }
    }

    private func prepare(_ arguments: [String: I18nArgument], _ bidi: BidiHandling) -> [String: I18nArgument] {
        guard bidi != .none else { return arguments }
        return arguments.mapValues { value in
            if case .string(let s) = value { return .string(Bidi.apply(bidi, to: s)) }
            return value
        }
    }

    private func flatten(_ elements: [MessageElement], _ arguments: [String: I18nArgument], _ bidi: BidiHandling) throws(I18nError) -> String {
        let formatter = MessageFormatter(locale: data, values: prepare(arguments, bidi), tags: .flatten)
        var out = ""
        for part in try formatter.format(elements) {
            if case .literal(let s) = part { out += s }
        }
        return out
    }

    private func rich(_ elements: [MessageElement], _ arguments: [String: I18nArgument], _ bidi: BidiHandling) throws(I18nError) -> RichText {
        let formatter = MessageFormatter(locale: data, values: prepare(arguments, bidi), tags: .structure)
        return RichText(parts: try formatter.format(elements))
    }

    /// The parsed message for `key`: this locale's string (or en's when `english`, or when
    /// the locale has none).
    private func parsed(_ key: String, english: Bool) throws(I18nError) -> [MessageElement] {
        var useEnglish = english
        var source = useEnglish ? nil : try catalog.message(key, locale: data.identifier)
        if source == nil {
            useEnglish = true
            source = try catalog.message(key, locale: "en")
        }
        guard let source else { throw .missingKey(key) }
        let cacheKey = CacheKey(key: key, english: useEnglish)
        if let hit = cache.withLock({ $0[cacheKey] }) {
            return try hit.mapError { I18nError.syntax($0) }.get()
        }
        let result: Result<[MessageElement], MessageSyntaxError>
        do {
            result = .success(try MessageParser.parse(source))
        } catch {
            result = .failure(error)
        }
        cache.withLock { $0[cacheKey] = result }
        return try result.mapError { I18nError.syntax($0) }.get()
    }

    /// locale message → en message → `fallback` (the key), reporting each failure.
    private func resolve<T>(
        _ key: String,
        _ body: ([MessageElement]) throws(I18nError) -> T,
        fallback: () -> T
    ) -> T {
        do {
            return try body(try parsed(key, english: false))
        } catch {
            onError?(key, error)
        }
        let hasLocaleMessage = data.identifier != "en" && ((try? catalog.message(key, locale: data.identifier)) ?? nil) != nil
        if hasLocaleMessage {
            do {
                return try body(try parsed(key, english: true))
            } catch {
                onError?(key, error)
            }
        }
        return fallback()
    }

    private func resolve(_ key: String, _ body: ([MessageElement]) throws(I18nError) -> String) -> String {
        resolve(key, body, fallback: { key })
    }

    // MARK: Locale matching

    /// Picks the supported locale for a list of preferred BCP 47 tags (upstream uses
    /// @formatjs/intl-localematcher's best fit with default `en`). This is a simpler
    /// matcher: exact tag, then Chinese / Portuguese script and region rules, then the
    /// language alone.
    public static func match(_ preferred: [String]) -> String {
        let supported = availableLocales
        let lowered = Dictionary(supported.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        for tag in preferred {
            let t = tag.replacing("_", with: "-").lowercased()
            if let exact = lowered[t] { return exact }
            let parts = t.split(separator: "-").map(String.init)
            guard var language = parts.first else { continue }
            language = ["iw": "he", "in": "id", "no": "nb", "nn": "nb", "fil": "tl", "tl": "tl"][language] ?? language
            let rest = Set(parts.dropFirst())
            switch language {
            case "zh":
                if rest.contains("hk") || rest.contains("mo") { return "zh-HK" }
                if rest.contains("hant") || rest.contains("tw") { return "zh-Hant" }
                return "zh-CN"
            case "pt":
                return rest.isEmpty || rest.contains("br") ? "pt-BR" : "pt-PT"
            case "tl":
                return "tl-PH"
            default:
                if let hit = supported.first(where: { $0.lowercased() == language || $0.lowercased().hasPrefix(language + "-") }) {
                    return hit
                }
            }
        }
        return "en"
    }
}
