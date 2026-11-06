// Text laid out the way Chromium lays out CSS text, drawn with CoreText (which is also
// what Chromium uses to rasterise glyphs on macOS):
//   * exact fractional advance widths (SwiftUI's Text rounds its size to the pixel grid,
//     which drifts rows of buttons and labels off the reference);
//   * line boxes of `line-height` with the font's content area centred in them
//     (half-leading above and below);
//   * `letter-spacing` added after every character, as CSS does;
//   * word wrapping, or a single line with an ellipsis (`truncate`), or `nowrap` overflow.

import CoreText
import Synchronization
import SwiftUI

public struct CSSTextStyle: Sendable, Hashable {
    public var fontName: String
    public var size: CGFloat
    public var lineHeight: CGFloat
    /// letter-spacing in points
    public var letterSpacing: CGFloat
    public var variationWeight: Double?
    /// Fallback fonts for characters the primary font lacks (CSS font-family list).
    public var cascade: [String]
    /// OpenType features, e.g. ["tnum": 1] for CSS `font-variant-numeric: tabular-nums`.
    public var features: [String: Int] = [:]

    /// The CSS font-weight the face stands for (inherited by inline symbol glyphs).
    public var weight: Int {
        if let v = variationWeight { return Int(v) }
        if fontName.hasSuffix("SemiBold") { return 600 }
        if fontName.hasSuffix("Bold") { return 700 }
        if fontName.hasSuffix("Medium") { return 500 }
        return 400
    }

    /// `overflow-wrap: break-word`: a word wider than the line breaks between characters.
    public var breakWord = false

    public func breakingWords() -> CSSTextStyle {
        var s = self
        s.breakWord = true
        return s
    }

    /// `tabular-nums`
    public func tabularNums() -> CSSTextStyle {
        var s = self
        s.features["tnum"] = 1
        return s
    }

    public init(fontName: String, size: CGFloat, lineHeight: CGFloat, letterSpacing: CGFloat = 0, variationWeight: Double? = nil,
                cascade: [String] = []) {
        self.fontName = fontName
        self.size = size
        self.lineHeight = lineHeight
        self.letterSpacing = letterSpacing
        self.variationWeight = variationWeight
        self.cascade = cascade
    }

    /// `font-mono` ('MonoSpecial', then the system stack, which Chromium resolves to Menlo).
    public static func mono(size: CGFloat, lineHeight: CGFloat, letterSpacing: CGFloat = 0) -> CSSTextStyle {
        CSSTextStyle(fontName: "MonoSpecial-Regular", size: size, lineHeight: lineHeight, letterSpacing: letterSpacing,
                     cascade: [AxoFonts.monospaceName])
    }

    public init(_ type: AxoType) {
        self.init(fontName: AxoFonts.interName(weight: type.weight), size: type.size, lineHeight: type.lineHeight,
                  letterSpacing: type.tracking * type.size)
    }

    var ctFont: CTFont {
        AxoFonts.register()
        var attributes: [CFString: Any] = [kCTFontNameAttribute: fontName]
        if let w = variationWeight { attributes[kCTFontVariationAttribute] = [0x7767_6874: w] }
        // Blink turns optional ligatures and contextual alternates off under non-zero
        // letter-spacing (e.g. Inter's raised "@" before capitals stays the default glyph).
        var features = features
        if letterSpacing != 0 {
            for tag in ["liga", "clig", "calt"] where features[tag] == nil { features[tag] = 0 }
        }
        if !features.isEmpty {
            attributes[kCTFontFeatureSettingsAttribute] = features.sorted { $0.key < $1.key }.map {
                [kCTFontOpenTypeFeatureTag: $0.key, kCTFontOpenTypeFeatureValue: $0.value] as [CFString: Any]
            }
        }
        // Upstream's font stacks end in "Signal Emoji Large", "Signal Emoji Small".
        // …then the rest of upstream's stack as Chromium walks it (each family's own glyphs only):
        // -apple-system (SF), "Helvetica Neue", Helvetica, Arial — Arial is where Arabic lands.
        let fallbacks = cascade + ["SignalEmojiLarge", "SignalEmojiSmall", ".AppleSystemUIFont", "HelveticaNeue", "Helvetica", "ArialMT"]
        attributes[kCTFontCascadeListAttribute] = fallbacks.map { CTFontDescriptorCreateWithNameAndSize($0 as CFString, size) }
        return CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), size, nil)
    }
}

public enum CSSTextWrap: Sendable, Hashable {
    case wrap            // white-space: normal
    case balance         // text-wrap: balance (Chromium: narrowest width keeping the same line count)
    case pretty          // text-wrap: pretty (Chromium: no one-word last line when narrowing can fix it)
    case truncate        // overflow: hidden; text-overflow: ellipsis; white-space: nowrap
    case nowrap          // white-space: nowrap (overflows)
    case clamp(Int)      // -webkit-line-clamp: n (display: -webkit-box; overflow: hidden)
}

struct CSSTextLayout {
    struct Decoration {
        var range: NSRange
        var background: CGColor?
        var radius: CGFloat
        var strikethrough: Bool
        var underline: Bool = false
        /// An inline-block's border box (border width, radius): drawn line-box high + borders.
        var box: (border: CGFloat, radius: CGFloat)?
        /// Added at the range's end: an inline-block's end kern, which CoreText's caret offset leaves out.
        var endKern: CGFloat = 0
        var fontSize: CGFloat
        var strikeColor: CGColor?
    }

    /// How far past the available width a line may run. Blink compares in LayoutUnits (1/64px,
    /// `exactWidthTolerance`); the default also absorbs SwiftUI proposals rounded a fraction
    /// under a measured width and CoreText widths a few tenths over Chromium's.
    static let widthTolerance: CGFloat = 0.6
    static let exactWidthTolerance: CGFloat = 1.0 / 64

    var lines: [CTLine]
    var widths: [CGFloat]
    var ascent: CGFloat
    var descent: CGFloat
    var lineHeight: CGFloat

    var width: CGFloat { widths.max() ?? 0 }
    /// Per line: the line box height (an inline box taller than line-height grows it; with
    /// `vertical-align: bottom` the extra space goes above the text).
    var lineHeights: [CGFloat] = []
    /// Per line: the space added above the text's own line box (taller inline boxes).
    var lineExtraAbove: [CGFloat] = []
    /// Empty text has no line boxes in CSS, so it is zero-height.
    var height: CGFloat {
        if isEmpty { return 0 }
        if lineHeights.count == lines.count, !lines.isEmpty { return lineHeights.reduce(0, +) }
        return CGFloat(max(lines.count, 1)) * lineHeight
    }

    func lineHeight(_ i: Int) -> CGFloat { lineHeights.indices.contains(i) ? lineHeights[i] : lineHeight }
    func lineTop(_ i: Int) -> CGFloat { (0..<i).reduce(0) { $0 + lineHeight($1) } }

    /// The line at `y` (text coordinates, y down).
    func lineIndex(at y: CGFloat) -> Int? {
        var top: CGFloat = 0
        for i in lines.indices {
            let h = lineHeight(i)
            if y < top + h { return i }
            top += h
        }
        return nil
    }
    var isEmpty = false
    var decorations: [Decoration] = []
    /// The emoji boxes' UTF-16 ranges (decorations skip them).
    var emojiRanges: [NSRange] = []

    /// CSS min-content width: the widest unbreakable run (each word on its own line).
    static func minContentWidth(_ string: String, _ style: CSSTextStyle) -> CGFloat {
        make(string, style, wrap: .wrap, maxWidth: 0).width
    }

    /// Width of "0" (the CSS `ch` unit) in a style.
    static func ch(_ style: CSSTextStyle) -> CGFloat { make("0", style, wrap: .nowrap, maxWidth: nil).width - style.letterSpacing }

    static func make(_ string: String, _ style: CSSTextStyle, wrap: CSSTextWrap, maxWidth: CGFloat?) -> CSSTextLayout {
        make(runs: [CSSTextRun(string)], style, wrap: wrap, maxWidth: maxWidth, colors: nil)
    }

    /// An emoji grapheme (emoji presentation, a VS16 sequence, or a keycap / ZWJ sequence).
    /// `Emoji.isEmoji`: a parent or skin-tone variant in upstream's emoji data. Others (a bare
    /// 🏝 without U+FE0F) stay text.
    static func isEmoji(_ ch: Character) -> Bool {
        guard ch.unicodeScalars.contains(where: { $0.value > 0x7F }) || ch.unicodeScalars.count > 1 else { return false }
        return EmojiData.shared.isEmoji(String(ch))
    }

    /// FunInlineEmoji: an inline-block `round(1.4em)` square (`vertical-align: bottom`) whose
    /// glyph is drawn at that font size, 0.5px lower once the box is over 16px (1px over 45px).
    /// In CoreText: the emoji font at that size, kerned to the box width, baseline-shifted to
    /// where Blink puts the box's own text baseline. Letter-spacing does not apply to the box.
    /// `MAX_EMOJI_TO_MATCH` (ts/axo/emoji.std.ts): an Emojify segment boxes at most 5000
    /// emoji; any after that stay plain text (the font list's Signal Emoji at the text size).
    static let maxEmojiToMatch = 5000

    static func emojiBoxSize(_ style: CSSTextStyle, _ override: CGFloat?) -> CGFloat { override ?? (style.size * 1.4).rounded() }

    /// How far an emoji glyph's baseline is raised above the text's (kCTBaselineOffset).
    static func emojiBaselineShift(_ style: CSSTextStyle, size: CGFloat, staticBlot: Bool, topMargin: CGFloat? = nil) -> CGFloat {
        // Baselines from the line box top: the text's (Blink rounding), and the glyph's inside
        // the bottom-aligned box.
        let base = style.ctFont
        let a = CTFontGetAscent(base).rounded(), d = CTFontGetDescent(base).rounded()
        let textBaseline = ((style.lineHeight - (a + d)) / 2).rounded(.down) + a
        // The glyph's baseline sits round(0.875 × size) below the box top: the bitmap strikes'
        // ascent (56/64 em), which Chromium's backend uses for this bitmap-only font, with the
        // 0.5–1px padding absorbed by its rounding (fitted against the Emojify stories, 20…56px).
        var glyphBaseline = (topMargin ?? (style.lineHeight - size)) + (size * 0.875).rounded()
        if staticBlot {
            // FunStaticEmoji: size/2 + 0.25 + (A − D)/2 with Signal Emoji's hhea metrics, on the 2x grid.
            let a = size.rounded(), d = (size * 0.3125).rounded()
            glyphBaseline = (style.lineHeight - size) + ((size / 2 + 0.25 + (a - d) / 2) * 2).rounded(.down) / 2
        }
        return textBaseline - glyphBaseline
    }

    /// The attribute marking a FunInlineEmoji box (compared by identity, so boxes never merge).
    final class EmojiBox: NSObject {
        static let key = NSAttributedString.Key("SignalUI.EmojiBox")
        let text: String
        let shift: CGFloat
        init(text: String, shift: CGFloat) { self.text = text; self.shift = shift }
    }

    /// The attribute marking an emoji left as text (past Emojify's 5000, or outside Emojify):
    /// one object per emoji, so each is its own CTRun for drawLine.
    final class PlainEmoji: NSObject {
        static let key = NSAttributedString.Key("SignalUI.PlainEmoji")
        let text: String
        init(text: String) { self.text = text }
    }

    /// Text with each emoji in it tagged `PlainEmoji`.
    static func plainText(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: attributes)
        guard text.unicodeScalars.contains(where: { $0.value > 0x7F }) else { return out }
        var location = 0
        for ch in text {
            let n = ch.utf16.count
            if isEmoji(ch) { out.addAttribute(PlainEmoji.key, value: PlainEmoji(text: String(ch)), range: NSRange(location: location, length: n)) }
            location += n
        }
        return out
    }

    static func emojiPiece(_ text: String, _ style: CSSTextStyle, _ textAttributes: [NSAttributedString.Key: Any], size override: CGFloat? = nil,
                           staticBlot: Bool = false, topMargin: CGFloat? = nil) -> NSAttributedString {
        let size = emojiBoxSize(style, override)
        let font = CTFontCreateWithName("SignalEmojiLarge" as CFString, size, nil)
        var attributes = textAttributes
        attributes[NSAttributedString.Key(kCTFontAttributeName as String)] = font
        attributes[NSAttributedString.Key(kCTTrackingAttributeName as String)] = nil
        let probe = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let advance = CGFloat(CTLineGetTypographicBounds(probe, nil, nil, nil))
        let shift = emojiBaselineShift(style, size: size, staticBlot: staticBlot, topMargin: topMargin)
        attributes[NSAttributedString.Key(kCTBaselineOffsetAttributeName as String)] = shift
        // Its own object per box: each box is its own CTRun, drawn as an image (drawLine).
        attributes[EmojiBox.key] = EmojiBox(text: text, shift: shift)
        let out = NSMutableAttributedString(string: text, attributes: attributes)
        if out.length > 0 {
            // Kern after the cluster's last character so its advance is the box width.
            let last = (text as NSString).rangeOfComposedCharacterSequence(at: out.length - 1)
            out.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String), value: size - advance, range: last)
        }
        return out
    }

    static func isCursive(_ u: UInt32) -> Bool {
        (0x0600...0x08FF).contains(u) || (0x07C0...0x07FF).contains(u) || (0x1800...0x18AF).contains(u) || (0xFB50...0xFDFF).contains(u)
            || (0xFE70...0xFEFF).contains(u)
    }

    /// Per UTF-16 unit: is it in a run of cursive script? As in ICU's script itemization, which
    /// Blink letter-spaces by: letters (and the cursive blocks) are strong; spaces, digits,
    /// punctuation, symbols and marks take the script of the run they are in (leading ones,
    /// the first strong script after them).
    static func cursiveScriptMask(_ s: String) -> [Bool] {
        var mask: [Bool] = []
        mask.reserveCapacity(s.utf16.count)
        var current: Bool?
        for scalar in s.unicodeScalars {
            let strong: Bool?
            if isCursive(scalar.value) {
                strong = true
            } else {
                switch scalar.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: strong = false
                default: strong = nil
                }
            }
            if let strong {
                if current == nil { for k in mask.indices { mask[k] = strong } }
                current = strong
            }
            let value = strong ?? current ?? false
            for _ in 0..<scalar.utf16.count { mask.append(value) }
        }
        return mask
    }

    /// The kern on an inline-block's end spaces: it makes each one padding + border wide.
    static func inlineBlockKern(_ box: CSSInlineBlock, _ style: CSSTextStyle) -> CGFloat {
        let space = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{00A0}", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): style.ctFont]))
        return box.paddingInline + box.border - CGFloat(CTLineGetTypographicBounds(space, nil, nil, nil))
    }

    /// The width of a line's hanging trailing white space: CSS spaces and newlines (a no-break
    /// space does not hang, unlike in CTLineGetTrailingWhitespaceWidth).
    static func hangingWidth(_ line: CTLine, _ units: [UInt16]) -> CGFloat {
        let r = CTLineGetStringRange(line)
        let end = min(r.location + r.length, units.count)
        var start = end
        while start > r.location, CSSLineBreak.isSpace(units[start - 1]) || CSSLineBreak.isNewline(units[start - 1]) { start -= 1 }
        guard start < end else { return 0 }
        return abs(CTLineGetOffsetForStringIndex(line, end, nil) - CTLineGetOffsetForStringIndex(line, start, nil))
    }

    /// The inline emoji boxes in UTF-16 offsets of the runs' attributed string: (offset, size).
    static func inlineBoxes(_ runs: [CSSTextRun], _ style: CSSTextStyle) -> [(Int, CGFloat)] {
        var out: [(Int, CGFloat)] = []
        var offset = 0
        for run in runs {
            if run.emojify {
                var runStyle = style
                if let name = run.fontName { runStyle.fontName = name }
                var count = 0
                for ch in run.text {
                    if isEmoji(ch), count < maxEmojiToMatch {
                        out.append((offset, emojiBoxSize(runStyle, run.emojiSize)))
                        count += 1
                    }
                    offset += ch.utf16.count
                }
            } else {
                offset += run.text.utf16.count
            }
        }
        return out
    }

    /// The runs as one attributed string: each run's font (the style's, or its override) and,
    /// when `colors` resolves them, its own colour (else the context's fill colour).
    static func attributedString(_ runs: [CSSTextRun], _ style: CSSTextStyle, colors: ((AxoColor) -> CGColor)?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let cursive = style.letterSpacing != 0 ? cursiveScriptMask(runs.map(\.text).joined()) : []
        var at = 0
        for run in runs {
            var runStyle = style
            if let name = run.fontName { runStyle.fontName = name }
            // CSS letter-spacing is added on top of the font's kerning: that is CoreText
            // *tracking*. (kCTKernAttributeName replaces kerning, and 0 disables it.)
            var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): runStyle.ctFont]
            if let color = run.color, let colors {
                attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = colors(color)
            } else {
                attributes[NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)] = true
            }
            if style.letterSpacing != 0 { attributes[NSAttributedString.Key(kCTTrackingAttributeName as String)] = style.letterSpacing }
            let piece = NSMutableAttributedString()
            if run.emojify {
                var plain = ""
                var count = 0
                for ch in run.text {
                    if isEmoji(ch), count < maxEmojiToMatch {
                        count += 1
                        if !plain.isEmpty { piece.append(plainText(plain, attributes: attributes)); plain = "" }
                        piece.append(emojiPiece(String(ch), runStyle, attributes, size: run.emojiSize, staticBlot: run.emojiStaticBlot, topMargin: run.emojiTopMargin))
                    } else {
                        plain.append(ch)
                    }
                }
                if !plain.isEmpty { piece.append(plainText(plain, attributes: attributes)) }
            } else {
                piece.append(plainText(run.text, attributes: attributes))
            }
            if style.letterSpacing != 0 {
                // Chromium does not letter-space runs in a cursive script (Arabic, Syriac, N'Ko,
                // Mongolian), neutral characters in them included.
                let mask = piece.length == run.text.utf16.count ? Array(cursive[at..<(at + piece.length)]) : cursiveScriptMask(piece.string)
                var i = 0
                while i < mask.count {
                    guard mask[i] else { i += 1; continue }
                    var j = i
                    while j < mask.count, mask[j] { j += 1 }
                    piece.removeAttribute(NSAttributedString.Key(kCTTrackingAttributeName as String), range: NSRange(location: i, length: j - i))
                    i = j
                }
            }
            at += run.text.utf16.count
            if let box = run.inlineBlock, piece.length > 1 {
                let side = inlineBlockKern(box, runStyle)
                let first = NSRange(location: 0, length: 1), last = NSRange(location: piece.length - 1, length: 1)
                piece.removeAttribute(NSAttributedString.Key(kCTTrackingAttributeName as String), range: first)
                piece.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String), value: side, range: first)
                piece.removeAttribute(NSAttributedString.Key(kCTTrackingAttributeName as String), range: last)
                piece.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String), value: side, range: last)
            }
            if run.marginEnd != 0, piece.length > 0 {
                // Kern after the run's last character. CoreText ignores kern where tracking is
                // set, so that character carries its letter-spacing in the kern instead.
                let last = NSRange(location: piece.length - 1, length: 1)
                piece.removeAttribute(NSAttributedString.Key(kCTTrackingAttributeName as String), range: last)
                piece.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String), value: run.marginEnd + style.letterSpacing, range: last)
            }
            clusterFallback(piece, font: runStyle.ctFont)
            out.append(piece)
        }
        return out
    }

    /// Blink's font fallback is per grapheme cluster: a cluster with a combining mark the
    /// run's font lacks is shaped whole in the first family of the CSS stack that covers all of
    /// it (CoreText would take only the missing marks from its cascade). After Inter that is
    /// Helvetica Neue / Helvetica / Arial (Chromium skips -apple-system here); after Menlo,
    /// the `monospace` generic, Courier.
    static func clusterFallback(_ piece: NSMutableAttributedString, font: CTFont) {
        let string = piece.string
        guard string.unicodeScalars.contains(where: { isMark($0) }) else { return }
        let covered = characterSet(font)
        var location = 0
        for ch in string {
            let n = ch.utf16.count
            defer { location += n }
            guard ch.unicodeScalars.contains(where: { isMark($0) }), !isEmoji(ch),
                  !ch.unicodeScalars.allSatisfy({ covered.contains($0) }) else { continue }
            guard let replacement = fallbackFonts(for: font).first(where: { f in ch.unicodeScalars.allSatisfy { characterSet(f).contains($0) } }) else { continue }
            piece.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: replacement, range: NSRange(location: location, length: n))
        }
    }

    static func isMark(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    private static let characterSets = Mutex<[String: CharacterSet]>([:])
    static func characterSet(_ font: CTFont) -> CharacterSet {
        let name = CTFontCopyPostScriptName(font) as String
        if let cached = characterSets.withLock({ $0[name] }) { return cached }
        let set = CTFontCopyCharacterSet(font) as CharacterSet
        characterSets.withLock { $0[name] = set }
        return set
    }

    static func fallbackFonts(for font: CTFont) -> [CTFont] {
        let name = CTFontCopyPostScriptName(font) as String
        let size = CTFontGetSize(font)
        let traits = CTFontCopyTraits(font) as NSDictionary
        let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        let bold = weight >= 0.3 || CTFontGetSymbolicTraits(font).contains(.traitBold)
        let italic = CTFontGetSymbolicTraits(font).contains(.traitItalic)
        let names: [String]
        if name.hasPrefix("Menlo") {
            names = [bold ? (italic ? "Courier-BoldOblique" : "Courier-Bold") : (italic ? "Courier-Oblique" : "Courier")]
        } else if name.hasPrefix("Inter") {
            names = [bold ? (italic ? "HelveticaNeue-BoldItalic" : "HelveticaNeue-Bold") : (italic ? "HelveticaNeue-Italic" : "HelveticaNeue"),
                     bold ? (italic ? "Helvetica-BoldOblique" : "Helvetica-Bold") : (italic ? "Helvetica-Oblique" : "Helvetica"),
                     bold ? (italic ? "Arial-BoldItalicMT" : "Arial-BoldMT") : (italic ? "Arial-ItalicMT" : "ArialMT")]
        } else {
            names = []
        }
        return names.map { CTFontCreateWithName($0 as CFString, size, nil) }
    }

    static func make(runs: [CSSTextRun], _ style: CSSTextStyle, wrap: CSSTextWrap, maxWidth: CGFloat?,
                     colors: ((AxoColor) -> CGColor)?, tolerance: CGFloat = widthTolerance) -> CSSTextLayout {
        var layout = makeLines(runs: runs, style, wrap: wrap, maxWidth: maxWidth, colors: colors, tolerance: tolerance)
        let boxes = inlineBoxes(runs, style)
        // Inline-blocks: (offset, length, border).
        var blocks: [(Int, Int, CGFloat)] = []
        var at = 0
        for run in runs {
            let n = run.text.utf16.count
            if let b = run.inlineBlock { blocks.append((at, n, b.border)) }
            at += n
        }
        if !boxes.isEmpty || !blocks.isEmpty {
            var heights: [CGFloat] = [], above: [CGFloat] = []
            for line in layout.lines {
                let r = CTLineGetStringRange(line)
                let tallest = boxes.filter { $0.0 >= r.location && $0.0 < r.location + r.length }.map(\.1).max() ?? 0
                let border = blocks.filter { $0.0 < r.location + r.length && $0.0 + $0.1 > r.location }.map(\.2).max() ?? 0
                // A bottom-aligned emoji box adds its excess above; a bordered inline-block adds
                // its border above and below.
                let top = max(max(0, tallest - style.lineHeight), border)
                heights.append(style.lineHeight + top + border)
                above.append(top)
            }
            layout.lineHeights = heights
            layout.lineExtraAbove = above
        }
        guard let colors, runs.contains(where: { $0.background != nil || $0.strikethrough || $0.underline || $0.inlineBlock?.background != nil })
        else { return layout }
        if runs.contains(where: { ($0.strikethrough || $0.underline) && $0.emojify }) {
            var at = 0
            for run in runs {
                var count = 0
                for ch in run.text {
                    let n = ch.utf16.count
                    if run.emojify && isEmoji(ch) && count < maxEmojiToMatch {
                        layout.emojiRanges.append(NSRange(location: at, length: n))
                        count += 1
                    }
                    at += n
                }
            }
        }
        // Decorated ranges, in the attributed string's UTF-16 offsets (emojify keeps lengths).
        var offset = 0
        for run in runs {
            let n = run.text.utf16.count
            if run.background != nil || run.strikethrough || run.underline {
                // An inline-block's text decorations cover its content, not its padding.
                let inner = run.inlineBlock != nil && n > 2 && run.background == nil
                layout.decorations.append(Decoration(range: inner ? NSRange(location: offset + 1, length: n - 2) : NSRange(location: offset, length: n), background: run.background.map(colors),
                                                     radius: run.backgroundRadius, strikethrough: run.strikethrough, underline: run.underline,
                                                     fontSize: style.size, strikeColor: run.color.map(colors)))
            }
            if let b = run.inlineBlock, let bg = b.background {
                var runStyle = style
                if let name = run.fontName { runStyle.fontName = name }
                layout.decorations.insert(Decoration(range: NSRange(location: offset, length: n), background: colors(bg), radius: b.radius,
                                                     strikethrough: false, box: (b.border, b.radius), endKern: inlineBlockKern(b, runStyle),
                                                     fontSize: style.size, strikeColor: nil), at: 0)
            }
            offset += n
        }
        return layout
    }

    static func makeLines(runs: [CSSTextRun], _ style: CSSTextStyle, wrap: CSSTextWrap, maxWidth: CGFloat?,
                          colors: ((AxoColor) -> CGColor)?, tolerance: CGFloat) -> CSSTextLayout {
        let font = style.ctFont
        let attributed = attributedString(runs, style, colors: colors)
        let string = attributed.string
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        func lineWidth(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }
        var lines: [CTLine] = []
        switch wrap {
        case .nowrap:
            lines = [CTLineCreateWithAttributedString(attributed)]
        case .truncate:
            let line = CTLineCreateWithAttributedString(attributed)
            // SwiftUI hands the frame its size rounded to the pixel grid, which can be a
            // fraction of a point under the measured width: only truncate real overflow.
            if let maxWidth, lineWidth(line) > maxWidth + tolerance {
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                ]))
                lines = [CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ellipsis) ?? line]
            } else {
                lines = [line]
            }
        case .balance:
            var layout = make(runs: runs, style, wrap: .wrap, maxWidth: maxWidth, colors: colors)
            if let maxWidth, layout.lines.count > 1 {
                let target = layout.lines.count
                var lo = make(runs: runs, style, wrap: .wrap, maxWidth: 0, colors: nil).width, hi = maxWidth
                while hi - lo > 1 / 64 {
                    let mid = (lo + hi) / 2
                    if make(runs: runs, style, wrap: .wrap, maxWidth: mid, colors: nil).lines.count > target { lo = mid } else { hi = mid }
                }
                layout = make(runs: runs, style, wrap: .wrap, maxWidth: hi, colors: colors)
            }
            return layout
        case .pretty:
            // Blink's score line breaker for short paragraphs: when the greedy breaks leave one
            // word on the last line, break at spaces into the same number of lines, minimising
            // the squared slack of every line but the last, with two or more words last.
            let greedy = makeLines(runs: runs, style, wrap: .wrap, maxWidth: maxWidth, colors: colors, tolerance: tolerance)
            let units = Array(string.utf16)
            let all = units
            func words(_ r: Range<Int>) -> Int {
                String(decoding: units[r], as: UTF16.self).split(whereSeparator: { $0.isWhitespace }).count
            }
            let ranges = greedy.lines.map { l -> Range<Int> in let r = CTLineGetStringRange(l); return r.location..<(r.location + r.length) }
            guard let maxWidth, ranges.count > 1, ranges.count <= 4, let last = ranges.last, words(last) < 2 else { return greedy }
            let typesetter = CSSTextLayout.typesetter(attributed)
            var cache: [Int: CGFloat] = [:]
            func width(_ i: Int, _ j: Int) -> CGFloat {
                if let w = cache[i * 100_000 + j] { return w }
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: i, length: j - i))
                let w = lineWidth(line) - hangingWidth(line, all)
                cache[i * 100_000 + j] = w
                return w
            }
            // Break opportunities: after each space (and the end of the text).
            var stops = [0]
            for k in 1..<units.count where units[k - 1] == 0x20 && units[k] != 0x20 { stops.append(k) }
            stops.append(units.count)
            let target = ranges.count
            let limit = maxWidth + tolerance
            // best[n][s]: least cost to set stops[0..<s] as n lines ending at stops[s].
            var best = Array(repeating: Array(repeating: CGFloat.infinity, count: stops.count), count: target + 1)
            var from = Array(repeating: Array(repeating: -1, count: stops.count), count: target + 1)
            best[0][0] = 0
            for n in 1...target {
                for e in 1..<stops.count {
                    for b in 0..<e where best[n - 1][b].isFinite {
                        let w = width(stops[b], stops[e])
                        guard w <= limit else { continue }
                        let isLast = n == target && e == stops.count - 1
                        if isLast && words(stops[b]..<stops[e]) < 2 { continue }
                        let cost = best[n - 1][b] + (isLast ? 0 : (maxWidth - w) * (maxWidth - w))
                        if cost < best[n][e] { best[n][e] = cost; from[n][e] = b }
                    }
                }
            }
            guard best[target][stops.count - 1].isFinite else { return greedy }
            var breaks: [Range<Int>] = []
            var e = stops.count - 1
            for n in stride(from: target, to: 0, by: -1) {
                let b = from[n][e]
                breaks.insert(stops[b]..<stops[e], at: 0)
                e = b
            }
            lines = breaks.map { CTTypesetterCreateLine(typesetter, CFRange(location: $0.lowerBound, length: $0.count)) }
        case .clamp(let n):
            var layout = make(runs: runs, style, wrap: .wrap, maxWidth: maxWidth, colors: colors)
            guard layout.lines.count > n, n > 0, let maxWidth else { return layout }
            // Blink: the last visible line keeps its own (word-wrapped) content, then "…"; if
            // that overflows, characters come off its end until the ellipsis fits.
            let lastRange = CTLineGetStringRange(layout.lines[n - 1])
            let ns = attributed.attributedSubstring(from: NSRange(location: lastRange.location, length: lastRange.length)).mutableCopy()
            guard let tail = ns as? NSMutableAttributedString else { return layout }
            while tail.length > 0, CSSLineBreak.isSpace(UInt16(truncatingIfNeeded: (tail.string as NSString).character(at: tail.length - 1))) {
                tail.deleteCharacters(in: NSRange(location: tail.length - 1, length: 1))
            }
            // The ellipsis takes the style of the run that holds the last visible character.
            var owner = runs.first ?? CSSTextRun("")
            var offset = 0
            let lastIndex = lastRange.location + max(tail.length - 1, 0)
            for run in runs {
                let n = run.text.utf16.count
                if lastIndex < offset + n { owner = run; break }
                offset += n
            }
            var ellipsisRun = owner
            ellipsisRun.text = "\u{2026}"
            let ellipsis = attributedString([ellipsisRun], style, colors: colors)
            func candidate() -> CTLine {
                let c = NSMutableAttributedString(attributedString: tail)
                c.append(ellipsis)
                return CTLineCreateWithAttributedString(c)
            }
            var line = candidate()
            while tail.length > 0, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maxWidth + tolerance {
                let r = (tail.string as NSString).rangeOfComposedCharacterSequence(at: tail.length - 1)
                tail.deleteCharacters(in: r)
                line = candidate()
            }
            layout.lines = Array(layout.lines.prefix(n - 1)) + [line]
            // The clamped line ends in its ellipsis: nothing hangs.
            layout.widths = Array(layout.widths.prefix(n - 1)) + [CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))]
            return layout
        case .wrap:
            let typesetter = CSSTextLayout.typesetter(attributed)
            let units = Array(string.utf16)
            let length = units.count
            let emojiBreaks = CSSLineBreak.emojiBreaks(string)
            // break-all runs: every position between two of their characters (not inside a
            // surrogate pair) is a break opportunity.
            var breakAll = Set<Int>()
            var at = 0
            for run in runs {
                let n = run.text.utf16.count
                if run.breakAll && n > 1 {
                    for i in (at + 1)..<(at + n) where !UTF16.isTrailSurrogate(units[i]) { breakAll.insert(i) }
                }
                at += n
            }
            var start = 0
            while start < length {
                // Same sub-point tolerance as truncation: SwiftUI may propose a frame a fraction
                // under the measured width, which must not push the last word to a new line.
                let count = maxWidth.map { CTTypesetterSuggestLineBreak(typesetter, start, Double($0 + tolerance)) } ?? (length - start)
                var n = CSSLineBreak.adjust(units, start: start, suggested: max(1, count), emojiBreaks: emojiBreaks, breakWord: style.breakWord)
                // A break-all run fills the line up to the last character that fits.
                if !breakAll.isEmpty, let maxWidth {
                    let fit = CTTypesetterSuggestClusterBreak(typesetter, start, Double(maxWidth + tolerance))
                    let forced = (start..<min(start + n, length)).contains { CSSLineBreak.isNewline(units[$0]) }
                    if !forced {
                        // Before the suggested break when that overflows (no ordinary break
                        // opportunity fits), else up to it.
                        let floor = n > fit ? start : start + n
                        var b = start + fit
                        while b > floor {
                            if breakAll.contains(b) { n = b - start; break }
                            b -= 1
                        }
                    }
                }
                lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: n)))
                start += n
            }
        }
        // Trailing whitespace hangs (does not count toward the line box width), as in CSS.
        let all = Array(string.utf16)
        let widths = lines.map { l in CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) - hangingWidth(l, all) }
        return CSSTextLayout(lines: lines, widths: widths, ascent: ascent, descent: descent, lineHeight: style.lineHeight, isEmpty: string.isEmpty)
    }

    /// A typesetter for the whole paragraph. CoreText's default typesetter bounds its layout:
    /// past ~12k UTF-16 units it silently drops tracking (letter-spacing) and returns empty
    /// lines beyond its limit, so long texts (the Emojify stress stories) need it unbounded.
    static func typesetter(_ attributed: NSAttributedString) -> CTTypesetter {
        CTTypesetterCreateWithAttributedStringAndOptions(attributed, [kCTTypesetterOptionAllowUnboundedLayout: true] as CFDictionary)
            ?? CTTypesetterCreateWithAttributedString(attributed)
    }

    /// CTLineDraw into a context set up at the line's origin (y up), with two of Chromium's
    /// differences:
    /// - Boxed emoji (FunInlineEmoji: Signal Emoji Large runs with a baseline offset) are
    ///   drawn from the font's 64px strike, scaled bilinearly, at the box's left edge snapped
    ///   to the nearest whole CSS pixel (the box is `contain: strict`: a box at 7.48px draws
    ///   at 7, one at 10.5 at 11). CoreText would snap the bitmap to device pixels.
    /// - Colour glyphs in plain text take the text colour's alpha, as Skia modulates them by
    ///   the paint's (CoreText draws them opaque).
    /// `canvasOrigin`: the drawing canvas's top-left on the page (points), for the snapping.
    static func drawLine(_ line: CTLine, context: CGContext, color: CGColor, canvasOrigin: CGPoint = .zero) {
        context.interpolationQuality = .low
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName] as! CTFont
            let runColor = attributes[kCTForegroundColorAttributeName].map { $0 as! CGColor } ?? color
            if let box = attributes[EmojiBox.key] as? EmojiBox {
                // Opaque whatever the text colour, except in a hidden spoiler (transparent
                // text: Emojify's `isInvisible`, `visibility: hidden`).
                guard runColor.alpha > 0 else { continue }
                let range = CTRunGetStringRange(run)
                let a = CTLineGetOffsetForStringIndex(line, range.location, nil), b = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
                drawEmoji(box.text, left: min(a, b), shift: box.shift, font: font, snap: .cssPixel, canvasOrigin: canvasOrigin, context: context)
            } else if let plain = attributes[PlainEmoji.key] as? PlainEmoji, CTFontCopyPostScriptName(font) as String == "SignalEmojiLarge" {
                guard runColor.alpha > 0 else { continue }
                let range = CTRunGetStringRange(run)
                let a = CTLineGetOffsetForStringIndex(line, range.location, nil), b = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
                context.saveGState()
                if runColor.alpha < 1 { context.setAlpha(runColor.alpha) }
                drawEmoji(plain.text, left: min(a, b), shift: 0, font: font, snap: .quarterDevicePixel, canvasOrigin: canvasOrigin, context: context)
                context.restoreGState()
            } else if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs), runColor.alpha < 1 {
                context.saveGState()
                context.setAlpha(runColor.alpha)
                CTRunDraw(run, context, CFRange(location: 0, length: 0))
                context.restoreGState()
            } else {
                CTRunDraw(run, context, CFRange(location: 0, length: 0))
            }
        }
    }

    enum EmojiSnap {
        /// A FunInlineEmoji box (`contain: strict`): its left edge rounded half up to a CSS pixel.
        case cssPixel
        /// A text glyph: Skia's subpixel glyph positions, a quarter device pixel (half up), on a
        /// whole-pixel baseline.
        case quarterDevicePixel
    }

    /// An emoji rendered 1:1 from its sbix strike into a layer of that many device pixels,
    /// then drawn into its 1em square (bottom 8/64 em below its baseline, raised by `shift`)
    /// with low (bilinear) interpolation, which matches Skia's sampling pixel for pixel.
    static func drawEmoji(_ text: String, left: CGFloat, shift: CGFloat, font: CTFont, snap: EmojiSnap, canvasOrigin: CGPoint, context: CGContext) {
        let size = CTFontGetSize(font)
        let toDevice = context.userSpaceToDeviceSpaceTransform
        let scale = max(1, abs(toDevice.a))
        // The strike CoreText picks for the device size: 32px up to 32, else 64.
        let side = (size * scale <= 32 ? 32 : 64) / scale
        guard let layer = CGLayer(context, size: CGSize(width: side, height: side), auxiliaryInfo: nil), let lc = layer.context else { return }
        let strike = CTFontCreateCopyWithAttributes(font, side, nil, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): strike]))
        lc.textMatrix = .identity
        lc.textPosition = CGPoint(x: 0, y: side * 0.125)
        CTLineDraw(line, lc)
        let origin = CGPoint(x: left, y: shift).applying(toDevice)
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch snap {
        case .cssPixel:
            // The box's left edge on the page (device pixels / scale + the canvas's origin =
            // points), rounded half up.
            // SwiftUI places the canvas on whole device pixels.
            let pageX = origin.x / scale + (canvasOrigin.x * scale).rounded() / scale
            dx = ((pageX + 0.5).rounded(.down) - pageX) * scale / toDevice.a

        case .quarterDevicePixel:
            dx = (((origin.x * 4) + 0.5).rounded(.down) / 4 - origin.x) / toDevice.a
            dy = ((origin.y + 0.5).rounded(.down) - origin.y) / toDevice.d
        }
        context.saveGState()
        context.translateBy(x: left + dx, y: shift + dy - size * 0.125)
        context.scaleBy(x: size / side, y: size / side)
        context.draw(layer, at: .zero)
        context.restoreGState()
    }

    func draw(in context: CGContext, width: CGFloat, alignment: CSSTextAlign, color: CGColor, canvasOrigin: CGPoint = .zero) {
        context.setFillColor(color)
        // Bitmap (sbix) emoji glyphs are images: Chromium scales the 64px strike bilinearly
        // (Skia's default sampling), which CoreGraphics' low interpolation matches pixel for
        // pixel; its default (Lanczos-like) filter left visible noise on emoji-dense text.
        context.interpolationQuality = .low
        context.textMatrix = .identity
        // Blink's line-box placement: font ascent and descent are rounded to whole CSS
        // pixels, and the leading's top half is floored (measured against Chromium for
        // Inter 8…24px at line heights 14…32, all exact).
        let a = ascent.rounded(), d = descent.rounded()
        let halfLeading = ((lineHeight - (a + d)) / 2).rounded(.down)
        for (i, line) in lines.enumerated() {
            let x: CGFloat
            switch alignment {
            case .start: x = 0
            case .center: x = (width - widths[i]) / 2
            case .end: x = width - widths[i]
            }
            // Canvas coordinates are flipped (y down); CoreText draws y up.
            let extraAbove = lineExtraAbove.indices.contains(i) ? lineExtraAbove[i] : (lineHeight(i) - lineHeight)
            let baseline = lineTop(i) + extraAbove + halfLeading + a
            let lineRange = CTLineGetStringRange(line)
            func span(_ d: Decoration) -> (CGFloat, CGFloat)? {
                let lo = max(d.range.location, lineRange.location), hi = min(d.range.location + d.range.length, lineRange.location + lineRange.length)
                guard hi > lo else { return nil }
                // RTL runs come back with the offsets reversed.
                let a = CTLineGetOffsetForStringIndex(line, lo, nil), b = CTLineGetOffsetForStringIndex(line, hi, nil)
                let end = hi == d.range.location + d.range.length ? d.endKern : 0
                return (x + min(a, b), x + max(a, b) + end)
            }
            /// [x0, x1] minus the line's emoji boxes: text decorations do not cross atomic inlines
            /// (FunInlineEmoji is an inline-block).
            func skippingEmoji(_ x0: CGFloat, _ x1: CGFloat, line: CTLine, x: CGFloat) -> [(CGFloat, CGFloat)] {
                var out: [(CGFloat, CGFloat)] = []
                var start = x0
                let r = CTLineGetStringRange(line)
                for e in emojiRanges where e.location >= r.location && e.location < r.location + r.length {
                    let a = x + CTLineGetOffsetForStringIndex(line, e.location, nil), b = x + CTLineGetOffsetForStringIndex(line, e.location + e.length, nil)
                    let lo = min(a, b), hi = max(a, b)
                    guard hi > start, lo < x1 else { continue }
                    if lo > start { out.append((start, lo)) }
                    start = max(start, hi)
                }
                if x1 > start { out.append((start, x1)) }
                return out
            }
            for d in decorations {
                guard let bg = d.background, let (x0, x1) = span(d) else { continue }
                // The inline box's content area (the font's rounded ascent + descent), or an
                // inline-block's border box (its line box plus the borders).
                var rect = CGRect(x: x0, y: baseline - a, width: x1 - x0, height: a + descent.rounded())
                if let box = d.box {
                    let textTop = lineTop(i) + extraAbove
                    rect = CGRect(x: x0, y: textTop - box.border, width: x1 - x0, height: lineHeight + 2 * box.border)
                }
                context.addPath(Path(roundedRect: rect, cornerRadius: min(d.radius, rect.width / 2, rect.height / 2)).cgPath)
                context.setFillColor(bg)
                context.fillPath()
                context.setFillColor(color)
            }
            context.saveGState()
            context.translateBy(x: x, y: baseline)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            Self.drawLine(line, context: context, color: color, canvasOrigin: canvasOrigin)
            context.restoreGState()
            let underlines = decorations.filter(\.underline)
            if !underlines.isEmpty {
                // Underlines (from Inter's post table: 464/2816 em below the baseline, 192/2816
                // em thick) with `text-decoration-skip-ink: auto`: drawn in a layer, then cut
                // where the glyphs, widened by about the thickness, cross them.
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                var thickness: CGFloat = 1
                for d in underlines {
                    guard let (x0, x1) = span(d) else { continue }
                    // Chromium (measured, 14px Inter): the thickness rounds to 1px and the
                    // line sits 1px below the baseline, both on whole CSS pixels.
                    thickness = max(1, (d.fontSize * 192 / 2816).rounded())
                    context.setFillColor(d.strikeColor ?? color)
                    for (a, b) in skippingEmoji(x0, x1, line: line, x: x) {
                        context.fill(CGRect(x: a, y: baseline.rounded() + max(1, (d.fontSize * 464 / 2816 - thickness).rounded(.down)),
                                            width: b - a, height: thickness))
                    }
                }
                context.saveGState()
                context.setBlendMode(.destinationOut)
                context.setTextDrawingMode(.fillStroke)
                context.setLineWidth(thickness * 2)
                context.setStrokeColor(CGColor(gray: 0, alpha: 1))
                context.translateBy(x: x, y: baseline)
                context.scaleBy(x: 1, y: -1)
                context.textPosition = .zero
                CTLineDraw(line, context)
                context.restoreGState()
                context.endTransparencyLayer()
                context.setFillColor(color)
            }
            for d in decorations where d.strikethrough {
                guard let (x0, x1) = span(d) else { continue }
                // Inter's OS/2 strikeout: top 922/2816 em above the baseline, 192/2816 em thick,
                // both on whole CSS pixels (as Chromium paints it, like the underline).
                let thickness = max(1, (d.fontSize * 192 / 2816).rounded())
                context.setFillColor(d.strikeColor ?? color)
                for (a, b) in skippingEmoji(x0, x1, line: line, x: x) {
                    context.fill(CGRect(x: a, y: (baseline - d.fontSize * 922 / 2816).rounded(), width: b - a, height: thickness))
                }
                context.setFillColor(color)
            }
        }
    }
}

public enum CSSTextAlign: Sendable, Hashable { case start, center, end }

/// Chromium's soft-wrap opportunities for the scripts the UI shows, applied on top of
/// CoreText's suggestion (which also breaks after "/", "." and the like inside URLs): after
/// spaces, after a hyphen or dash, and around CJK characters. A word longer than the line
/// stays whole and overflows (`overflow-wrap: normal`).
enum CSSLineBreak {
    /// Spaces that hang at a line end (a newline is a forced break, not a hanging space).
    static func isSpace(_ u: UInt16) -> Bool { u == 0x20 || u == 0x09 || u == 0x3000 || u == 0x200B }
    static func isNewline(_ u: UInt16) -> Bool { u == 0x0A || u == 0x0D || u == 0x2028 || u == 0x2029 }
    static func isBreakAfter(_ u: UInt16) -> Bool { u == 0x2D || u == 0x2010 || u == 0x2013 || u == 0x2014 || u == 0x00AD }
    static func isIdeographic(_ u: UInt16) -> Bool {
        (0x3040...0x30FF).contains(u) || (0x3400...0x9FFF).contains(u) || (0xAC00...0xD7AF).contains(u) || (0xF900...0xFAFF).contains(u)
    }

    /// Grapheme boundaries next to an emoji: emoji are line-break class ID (UAX #14), so a
    /// break is allowed on either side (never inside a ZWJ / modifier sequence).
    static func emojiBreaks(_ string: String) -> Set<Int> {
        var out: Set<Int> = []
        var at = 0
        var previousIsEmoji = false
        for ch in string {
            let emoji = CSSTextLayout.isEmoji(ch)
            if at > 0, emoji || previousIsEmoji { out.insert(at) }
            at += ch.utf16.count
            previousIsEmoji = emoji
        }
        return out
    }

    static func allowed(_ units: [UInt16], at i: Int, emojiBreaks: Set<Int> = []) -> Bool {
        guard i > 0, i < units.count else { return true }
        let before = units[i - 1], after = units[i]
        if isSpace(before) || isNewline(before) { return true }
        if isSpace(after) { return false }    // spaces stay on the line they end
        if emojiBreaks.contains(i) { return true }
        if isBreakAfter(before) { return i >= 2 && !isSpace(units[i - 2]) }
        return isIdeographic(before) || isIdeographic(after)
    }

    /// The line length to use instead of CoreText's `suggested` count from `start`.
    static func adjust(_ units: [UInt16], start: Int, suggested: Int, emojiBreaks: Set<Int> = [], breakWord: Bool = false) -> Int {
        func allowed(_ units: [UInt16], at i: Int) -> Bool { Self.allowed(units, at: i, emojiBreaks: emojiBreaks) }
        // A forced break inside the suggested line ends it there.
        if let nl = (start..<min(start + suggested, units.count)).first(where: { isNewline(units[$0]) }) { return nl + 1 - start }
        let end = start + suggested
        guard end < units.count else { return units.count - start }
        // Trailing spaces hang: keep them on this line.
        var e = end
        while e < units.count, isSpace(units[e]) { e += 1 }
        if allowed(units, at: e) && e > end { return e - start }
        if allowed(units, at: end) { return suggested }
        var b = end - 1
        while b > start, !allowed(units, at: b) { b -= 1 }
        if b > start { return b - start }
        // overflow-wrap: break-word: the word breaks where CoreText fits it (a cluster boundary).
        if breakWord { return suggested }
        // No opportunity on the line: the word overflows up to the next one.
        var f = end + 1
        while f < units.count, !allowed(units, at: f) { f += 1 }
        return f - start
    }
}

/// Sizes itself from a CoreText layout of the text for the proposed width.
struct CSSTextFrame: Layout {
    let runs: [CSSTextRun]
    let style: CSSTextStyle
    let wrap: CSSTextWrap
    /// `\.cssTextWrapWidth`: wrap at exactly this width (Blink's 1/64px comparison).
    var exactWrapWidth: CGFloat? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if let exact = exactWrapWidth, wrap == .wrap {
            let layout = CSSTextLayout.make(runs: runs, style, wrap: .wrap, maxWidth: exact, colors: nil, tolerance: CSSTextLayout.exactWidthTolerance)
            // Wrapped (soft breaks): the shrink-to-fit box is the whole width.
            let natural = CSSTextLayout.make(runs: runs, style, wrap: .nowrap, maxWidth: nil, colors: nil)
            let wrapped = natural.width > exact + CSSTextLayout.exactWidthTolerance
            return CGSize(width: wrapped ? exact : layout.width, height: layout.height)
        }
        let natural = CSSTextLayout.make(runs: runs, style, wrap: .nowrap, maxWidth: nil, colors: nil)
        // Text that fits at its natural width needs no limit (only forced breaks); SwiftUI may
        // propose a fraction under that width (pixel rounding), which is no reason to wrap.
        let maxWidth = proposal.width.flatMap { $0 >= natural.width - 0.6 ? nil : $0 }
        let layout = wrap == .nowrap ? natural : CSSTextLayout.make(runs: runs, style, wrap: wrap, maxWidth: maxWidth, colors: nil)
        var width = wrap == .truncate ? min(natural.width, proposal.width ?? natural.width) : layout.width
        // A clamped box is a block: it takes the full width (and is redrawn at exactly it).
        if case .clamp = wrap, let w = proposal.width { width = w }
        // `pretty` re-wraps from the box width when drawn, and is not idempotent at a narrower
        // one: the box keeps the proposed width.
        if wrap == .pretty, let w = proposal.width, maxWidth != nil { width = w }
        return CGSize(width: max(0, width), height: layout.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews { s.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

struct CSSTextColorKey: EnvironmentKey { static let defaultValue: AxoColor = .labelPrimary }

extension EnvironmentValues {
    /// A block's exact content width for wrapping text (`.wrap` only): lines break where Blink
    /// breaks them in a box of that width, for sizing and drawing alike. nil: the proposal.
    @Entry public var cssTextWrapWidth: CGFloat? = nil

    /// Inherited text colour for `CSSText` (CSS `color`).
    public var cssTextColor: AxoColor {
        get { self[CSSTextColorKey.self] }
        set { self[CSSTextColorKey.self] = newValue }
    }
}

extension View {
    /// Sets the inherited CSS `color` for descendant `CSSText` and symbol glyphs.
    public func cssTextColor(_ color: AxoColor) -> some View { environment(\.cssTextColor, color) }
}

/// `display: inline-block` with inline padding, a border and a background (baseline-aligned:
/// it grows its line by the border above and below).
public struct CSSInlineBlock: Sendable, Hashable {
    public var paddingInline: CGFloat
    public var border: CGFloat
    public var background: AxoColor?
    public var radius: CGFloat
    public init(paddingInline: CGFloat, border: CGFloat = 0, background: AxoColor? = nil, radius: CGFloat = 0) {
        self.paddingInline = paddingInline
        self.border = border
        self.background = background
        self.radius = radius
    }
}

/// A styled piece of a `CSSText`: its own font (e.g. the bold face), colour, and a tap
/// action tag (links and inline buttons inside translated strings).
public struct CSSTextRun: Sendable, Hashable {
    public var text: String
    public var fontName: String?
    public var color: AxoColor?
    public var action: String?
    /// `margin-inline-end` of an inline element: extra advance after its last character.
    public var marginEnd: CGFloat = 0
    /// `<Emojify>`: each emoji becomes a FunInlineEmoji box (see `CSSTextLayout.emojiPiece`).
    public var emojify = false
    /// `fontSizeOverride` / `--fun-inline-emoji-size`: the emoji box size (else round(1.4em)).
    public var emojiSize: CGFloat?
    /// Emoji drawn as Quill's FunStaticEmoji blots (the composer): the glyph sits where
    /// FunStaticEmoji puts it in its box, not where FunInlineEmoji does.
    public var emojiStaticBlot = false
    /// Emojify's `style={{ verticalAlign: 'top', marginTop }}` (UserText in label pills): the
    /// boxes sit that far below the line box top instead of on its bottom.
    public var emojiTopMargin: CGFloat?
    /// An inline element's background, painted over the font's content area (spoilers).
    public var background: AxoColor?
    public var backgroundRadius: CGFloat = 0
    /// `text-decoration: line-through` (`<s>`), in the text colour.
    public var strikethrough = false
    /// `text-decoration: underline` (a UA-styled `<a>`), in the text colour.
    public var underline = false
    /// An unbreakable `inline-block` (e.g. an @-mention pill); build with `CSSTextRun.inlineBlock`.
    public var inlineBlock: CSSInlineBlock?
    /// `word-break: break-all`: lines may break between any two of this run's characters.
    public var breakAll = false

    /// CSS `white-space: normal` over a paragraph's runs: each run of spaces and tabs becomes one
    /// space, and spaces at the start, before a newline and after one are removed. (No-break
    /// spaces are kept.) Runs whose text empties out are dropped.
    public static func collapsingWhiteSpace(_ runs: [CSSTextRun]) -> [CSSTextRun] {
        var out: [CSSTextRun] = []
        var afterSpace = true      // at the paragraph start, as after a space
        for var run in runs {
            var text = ""
            for ch in run.text {
                if ch == " " || ch == "\t" {
                    if !afterSpace { text.append(" ") }
                    afterSpace = true
                    continue
                }
                if ch.isNewline {
                    // A space before a forced break goes (it would only hang).
                    if text.last == " " { text.removeLast() }
                    else if text.isEmpty, let i = out.indices.last, out[i].text.last == " " { out[i].text.removeLast() }
                    text.append(ch)
                    afterSpace = true
                    continue
                }
                text.append(ch)
                afterSpace = false
            }
            run.text = text
            out.append(run)
        }
        return out.filter { !$0.text.isEmpty }
    }

    /// An inline-block run: a NO-BREAK SPACE at each end, kerned to that side's padding +
    /// border, and no-break spaces inside. (CoreText drops a zero-width joiner's kern.)
    public static func inlineBlock(_ text: String, _ box: CSSInlineBlock, fontName: String? = nil, color: AxoColor? = nil) -> CSSTextRun {
        var r = CSSTextRun("\u{00A0}" + text.replacingOccurrences(of: " ", with: "\u{00A0}") + "\u{00A0}", fontName: fontName, color: color)
        r.inlineBlock = box
        return r
    }

    public init(_ text: String, fontName: String? = nil, color: AxoColor? = nil, action: String? = nil) {
        self.text = text
        self.fontName = fontName
        self.color = color
        self.action = action
    }
}

/// CSS-accurate text (see the file comment). Colour: `color:` or the inherited `cssTextColor`.
public struct CSSText: View {
    let runs: [CSSTextRun]
    let style: CSSTextStyle
    let wrap: CSSTextWrap
    let alignment: CSSTextAlign
    let color: AxoColor?
    let onTap: ((String) -> Void)?
    @Environment(\.colorScheme) var scheme
    @Environment(\.cssTextColor) var inherited
    @Environment(\.cssTextWrapWidth) var envWrapWidth

    public init(_ string: String, style: CSSTextStyle, wrap: CSSTextWrap = .wrap, alignment: CSSTextAlign = .start, color: AxoColor? = nil) {
        self.init(runs: [CSSTextRun(string)], style: style, wrap: wrap, alignment: alignment, color: color)
    }

    public init(_ string: String, type: AxoType, wrap: CSSTextWrap = .wrap, alignment: CSSTextAlign = .start, color: AxoColor? = nil) {
        self.init(string, style: CSSTextStyle(type), wrap: wrap, alignment: alignment, color: color)
    }

    /// Rich text: runs laid out as one paragraph. `onTap` receives the `action` of the run
    /// under a click.
    public init(runs: [CSSTextRun], style: CSSTextStyle, wrap: CSSTextWrap = .wrap, alignment: CSSTextAlign = .start, color: AxoColor? = nil,
                onTap: ((String) -> Void)? = nil) {
        self.runs = runs
        self.style = style
        self.wrap = wrap
        self.alignment = alignment
        self.color = color
        self.onTap = onTap
    }

    var string: String { runs.map(\.text).joined() }

    /// The frame is the widest line of the wrap done in sizeThatFits, possibly rounded down a
    /// fraction by SwiftUI; re-wrapping at +1pt reproduces exactly those lines.
    func layout(width: CGFloat, colors: ((AxoColor) -> CGColor)?, base: AxoColor? = nil) -> CSSTextLayout {
        // When drawing, every run gets an explicit colour: CTLineDraw leaves the context fill
        // colour set after a coloured run, which later "from context" runs would inherit.
        var resolved = runs
        if let base, runs.contains(where: { $0.color != nil }) {
            for i in resolved.indices where resolved[i].color == nil { resolved[i].color = base }
        }
        if let exact = exactWrapWidth, wrap == .wrap {
            return CSSTextLayout.make(runs: resolved, style, wrap: .wrap, maxWidth: exact, colors: colors, tolerance: CSSTextLayout.exactWidthTolerance)
        }
        return CSSTextLayout.make(runs: resolved, style, wrap: wrap, maxWidth: wrap == .wrap || wrap == .balance || wrap == .pretty ? width + 1 : width, colors: colors)
    }

    var exactWrapWidth: CGFloat? { envWrapWidth }

    public var body: some View {
        let rgba = (color ?? inherited).value(for: scheme)
        let scheme = scheme
        let resolve: (AxoColor) -> CGColor = { c in
            let v = c.value(for: scheme)
            return CGColor(srgbRed: v.r, green: v.g, blue: v.b, alpha: v.a)
        }
        let tappable = onTap != nil && runs.contains(where: { $0.action != nil })
        CSSTextFrame(runs: runs, style: style, wrap: wrap, exactWrapWidth: exactWrapWidth) {
            let canvas = GeometryReader { geo in
                let origin = geo.frame(in: .global).origin
                Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                    let layout = layout(width: size.width, colors: resolve, base: color ?? inherited)
                    context.withCGContext { cg in
                        layout.draw(in: cg, width: size.width, alignment: alignment,
                                    color: CGColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a), canvasOrigin: origin)
                    }
                }
            }
            if tappable, let onTap {
                GeometryReader { geo in
                    canvas.contentShape(Rectangle()).onTapGesture(coordinateSpace: .local) { point in
                        if let action = action(at: point, width: geo.size.width) { onTap(action) }
                    }
                }
            } else {
                canvas
            }
        }
        .accessibilityElement()
        .accessibilityLabel(string)
        .accessibilityAddTraits(tappable ? .isLink : [])
    }

    /// The action of the run under `point` (text coordinates, y down).
    func action(at point: CGPoint, width: CGFloat) -> String? {
        let layout = layout(width: width, colors: nil)
        guard let index = layout.lineIndex(at: point.y) else { return nil }
        let x: CGFloat
        switch alignment {
        case .start: x = 0
        case .center: x = (width - layout.widths[index]) / 2
        case .end: x = width - layout.widths[index]
        }
        let line = layout.lines[index]
        guard point.x >= x, point.x <= x + layout.widths[index] else { return nil }
        let utf16 = CTLineGetStringIndexForPosition(line, CGPoint(x: point.x - x, y: 0))
        // Hit the character whose box contains x (the index is the nearest caret position).
        var offset = 0
        for run in runs {
            let n = run.text.utf16.count
            if utf16 < offset + n || (utf16 == offset + n && run.action != nil) { return run.action }
            offset += n
        }
        return nil
    }
}
