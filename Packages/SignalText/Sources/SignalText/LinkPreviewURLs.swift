// ts/types/LinkPreview.std.ts: which links get a preview, and the Signal URLs that get their
// own (ts/util/signalRoutes.std.ts: signal.art/addstickers, signal.group, signal.link/call).

import Foundation

extension LinkPreviewRules {
    /// `EXCLUDED_DOMAINS`
    static let excludedDomains = ["debuglogs.org", "example", "example.com", "example.net", "example.org", "invalid", "localhost", "onion", "test"]

    /// `maybeParseUrl`: absolute URL with its fragment dropped.
    public static func parse(_ href: String, relativeTo base: String? = nil) -> URL? {
        let url = base.flatMap { URL(string: $0) }.flatMap { URL(string: href, relativeTo: $0)?.absoluteURL } ?? URL(string: href)
        guard let url, url.scheme != nil, var c = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        c.fragment = nil
        return c.url
    }

    static func isDomainExcluded(_ host: String) -> Bool {
        let h = host.lowercased()
        return excludedDomains.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// `shouldPreviewHref`: https, not an excluded domain, not sneaky.
    public static func shouldPreviewHref(_ href: String) -> Bool {
        guard let url = parse(href), url.scheme?.lowercased() == "https", let host = url.host(), !isDomainExcluded(host) else { return false }
        return isLinkSneaky(href) == .no
    }

    /// `findLinks` (no caret: every link in the text).
    public static func findLinks(_ text: String) -> [String] {
        guard shouldLinkifyMessage(text) else { return [] }
        return LinkifyIt.match(text).map(\.text)
    }

    /// `findLinks` with the composer caret: a link the caret is inside of (still being typed)
    /// is left out, unless it ends the text with the caret at the end.
    public static func findLinks(_ text: String, caretLocation: Int) -> [String] {
        guard shouldLinkifyMessage(text) else { return [] }
        let length = (text as NSString).length
        return LinkifyIt.match(text).compactMap { m in
            if m.lastIndex == length && caretLocation == length { return m.text }
            if m.index > caretLocation || m.lastIndex < caretLocation { return m.text }
            return nil
        }
    }

    /// `isValidLinkPreview` (received previews): the URL must be previewable and in the body.
    public static func isValidLinkPreview(url: String, urlsInBody: [String], isStory: Bool = false) -> Bool {
        guard !url.isEmpty, shouldPreviewHref(url) else { return false }
        return isStory || urlsInBody.contains(url)
    }

    /// `getDomain`
    public static func domain(_ href: String) -> String? { parse(href)?.host() }

    static func hash(_ href: String, host: String, path: [String]) -> String? {
        guard let url = URL(string: href), url.scheme?.lowercased() == "https", url.host()?.lowercased() == host else { return nil }
        let p = url.path(percentEncoded: false)
        guard path.contains(p) else { return nil }
        return url.fragment(percentEncoded: true)
    }

    /// `isStickerPack` → (pack id hex, pack key hex) from `#pack_id=…&pack_key=…`.
    public static func stickerPack(_ href: String) -> (packId: String, packKey: String)? {
        guard let fragment = hash(href, host: "signal.art", path: ["/addstickers", "/addstickers/"]) else { return nil }
        var items: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { items[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        guard let id = items["pack_id"], let key = items["pack_key"], id.count == 32, key.count == 64,
              (id + key).allSatisfy(\.isHexDigit) else { return nil }
        return (id.lowercased(), key.lowercased())
    }

    /// `isGroupLink` → the fragment (base64url GroupInviteLink).
    public static func groupInviteFragment(_ href: String) -> String? {
        guard let f = hash(href, host: "signal.group", path: ["", "/"]), !f.isEmpty, !f.contains("/") else { return nil }
        return f
    }

    /// `isCallLink`
    public static func isCallLink(_ href: String) -> Bool {
        hash(href, host: "signal.link", path: ["/call", "/call/"]) != nil
    }
}
