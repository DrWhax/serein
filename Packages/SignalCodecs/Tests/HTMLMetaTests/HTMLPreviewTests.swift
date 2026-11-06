// Parser-level cases of upstream's ts/test-electron/linkPreviews/linkPreviewFetch_test (the
// DOMParser + querySelector behaviour HTMLPreview reproduces), plus hostile inputs.

import CodecCore
import Testing
@testable import HTMLMeta

struct HTMLPreviewTests {
    func html(_ head: [String]) -> String {
        "<!doctype html>\n<html>\n<head>\n" + head.joined(separator: "\n") + "\n</head>\n<body><h1>should be ignored</h1></body>\n</html>"
    }
    func parse(_ s: String, charset: String? = "utf-8") -> HTMLPreviewMetadata? { HTMLPreview.parse(ByteSlice(Array(s.utf8)), httpCharset: charset) }
    func parse(bytes: [UInt8], charset: String? = nil) -> HTMLPreviewMetadata? { HTMLPreview.parse(ByteSlice(bytes), httpCharset: charset) }

    @Test func kitchenSink() {
        let m = parse(html(["<meta property=\"og:title\" content=\"test title\">", "<meta property=\"og:description\" content=\"test description\">",
                            "<meta property=\"og:image\" content=\"https://signal.org/image.jpg\">",
                            "<meta property=\"og:published_time\" content=\"2020-04-20T12:34:56.009Z\">"]))
        #expect(m == HTMLPreviewMetadata(title: "test title", description: "test description", imageHref: "https://signal.org/image.jpg",
                                         rawDate: "2020-04-20T12:34:56.009Z"))
    }

    @Test func imageSourceOrder() {
        let tags = [("<meta property=\"og:image\" content=\"https://signal.org/og-image.jpg\">", "https://signal.org/og-image.jpg"),
                    ("<meta property=\"og:image:url\" content=\"https://signal.org/og-image-url.jpg\">", "https://signal.org/og-image-url.jpg"),
                    ("<link rel=\"apple-touch-icon\" href=\"https://signal.org/apple-touch-icon.jpg\">", "https://signal.org/apple-touch-icon.jpg"),
                    ("<link rel=\"apple-touch-icon-precomposed\" href=\"https://signal.org/apple-touch-icon-precomposed.jpg\">", "https://signal.org/apple-touch-icon-precomposed.jpg"),
                    ("<link rel=\"shortcut icon\" href=\"https://signal.org/shortcut-icon.jpg\">", "https://signal.org/shortcut-icon.jpg"),
                    ("<link rel=\"icon\" href=\"https://signal.org/icon.jpg\">", "https://signal.org/icon.jpg")]
        for i in tags.indices {
            // Lower-priority sources first in the document: the order of the rules decides.
            let present = tags[i...].map(\.0).reversed()
            #expect(parse(html(["<meta property=\"og:title\" content=\"test title\">"] + present))?.imageHref == tags[i].1)
        }
    }

    @Test func titlesAndDescriptions() {
        #expect(parse(html(["<meta property=\"og:description\" content=\"ignored\">"])) == nil)
        #expect(parse(html(["<title>ignored</title>", "<meta property=\"og:title\" content=\"foo bar\">"]))?.title == "foo bar")
        #expect(parse(html(["<title>foo</title>", "<meta name=\"description\" content=\"ignored\">", "<meta property=\"og:description\" content=\"bar\">"]))?.description == "bar")
        #expect(parse(html(["<title>foo</title>", "<meta name=\"description\" content=\"bar\">"]))?.description == "bar")
        #expect(parse(html(["<title>foo</title>", "<meta property=\"og:description\" content=\"\">"]))?.description == nil)
        #expect(parse(html(["<title>foo</title>", "<meta property=\"og:image\" content=\"  \">"]))?.imageHref == nil)
        #expect(parse(html(["<title>foo</title>", "<meta property=\"og:image\" content=\"assets/image.jpg\">"]))?.imageHref == "assets/image.jpg")
        // document.title: strip and collapse whitespace, decode references, first <title> only.
        #expect(parse("<title>\n  a   &amp; b\t&#x1F389;&#127881;  </title><title>second</title>")?.title == "a & b 🎉🎉")
        #expect(parse("<TITLE>Caps &eacute;</TITLE><META PROPERTY=\"og:description\" CONTENT='x &lt;y&gt;'>")?.description == "x <y>")
        #expect(parse("<TITLE>Caps &eacute;</TITLE>")?.title == "Caps é")
        // Unquoted values, duplicate attributes (first wins), self-closing tags.
        #expect(parse("<title>t</title><meta property=og:image content=https://a.example/x.png content=no />")?.imageHref == "https://a.example/x.png")
    }

    @Test func charsets() {
        let party = Array("<title>\u{1F389}</title>".utf8)
        #expect(parse(bytes: [0xEF, 0xBB, 0xBF] + party, charset: "latin1")?.title == "\u{1F389}")
        #expect(parse(bytes: [0xEF, 0xBB, 0xBF] + Array("<!doctype html><head><meta http-equiv=\"content-type\" content=\"text/html; charset=latin1\">".utf8) + party)?.title == "\u{1F389}")
        #expect(parse(bytes: Array("<!doctype html><head><meta http-equiv=\"content-type\" content=\"text/html; charset=latin1\">".utf8) + party, charset: "utf-8")?.title == "\u{1F389}")
        // No HTTP charset: http-equiv wins over <meta charset>.
        #expect(parse(bytes: Array(html(["<meta http-equiv=\"content-type\" content=\"text/html; charset=utf8\">", "<meta charset=\"latin1\">", "<title>\u{1F389}</title>"]).utf8))?.title == "\u{1F389}")
        #expect(parse(bytes: Array("<meta charset=\"latin1\"><title>".utf8) + [0xE9, 0x80] + Array("</title>".utf8))?.title == "é€")
        #expect(parse(bytes: Array("<title>".utf8) + [0x63, 0x61, 0x66, 0xE9] + Array("</title>".utf8), charset: "latin1")?.title == "café")
        #expect(HTMLPreview.charset(fromContentType: "text/html; Charset=\"UTF-8\"") == "utf-8")
    }

    @Test func hostileInput() {
        // Incomplete bodies, unterminated constructs, scripts that look like markup.
        #expect(parse("<!doctype html><head><title>foo bar</title><meta")?.title == "foo bar")
        #expect(parse("<title>foo")?.title == "foo")
        #expect(parse("<!-- <title>no</title> --><title>yes</title>")?.title == "yes")
        #expect(parse("<script>var s = '<title>no</title>';</script><title>yes</title>")?.title == "yes")
        #expect(parse("<style>/* <meta property=\"og:title\" content=\"no\"> */</style><title>yes</title>")?.title == "yes")
        #expect(parse("<!--") == nil && parse("<") == nil && parse("<<<<>>>>") == nil && parse("<meta property=\"og:title\" content=\"") == nil)
        #expect(parse("<title>&#0;&#xD800;&#x110000;&bogus;&amp</title>")?.title == "\u{FFFD}\u{FFFD}\u{FFFD}&bogus;&amp")
        // Bounded output, many tags.
        let long = "<title>" + String(repeating: "a", count: 100_000) + "</title>"
        #expect(parse(long)?.title?.count == HTMLPreview.maxString)
        let many = String(repeating: "<meta a=b>", count: 50_000) + "<title>late</title>"
        #expect(parse(many) == nil)   // past the tag limit
        #expect(parse(bytes: [0xFF, 0xFE, 0x00, 0xD8], charset: "utf-16le") == nil)
    }
}
