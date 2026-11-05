// `<I18n components={…}>`: a translated rich-text message as CSSText runs. Tags map to run
// styles (a bold face, a colour, a tap action); `{element}` placeholders are given as runs.

import SignalI18n
import SwiftUI

public struct I18nTagStyle: Sendable {
    public var fontName: String?
    public var color: AxoColor?
    public var action: String?
    public init(fontName: String? = nil, color: AxoColor? = nil, action: String? = nil) {
        self.fontName = fontName
        self.color = color
        self.action = action
    }

    /// `<strong>` / `font-weight: bold` in the Inter faces upstream ships.
    public static var bold: I18nTagStyle { I18nTagStyle(fontName: AxoFonts.interName(weight: 700)) }
}

extension CSSTextRun {
    /// Runs for `rich`: each text run styled by its enclosing tags (outermost first, inner
    /// tags win), each element by `elements[id]` plus its tags.
    public static func runs(_ rich: RichText, tags: [String: I18nTagStyle] = [:], elements: [String: CSSTextRun] = [:]) -> [CSSTextRun] {
        rich.runs.compactMap { run in
            var out: CSSTextRun
            switch run.content {
            case .text(let s): out = CSSTextRun(s)
            case .element(let id):
                guard let e = elements[id] else { return nil }
                out = e
            }
            for name in run.tags {
                guard let t = tags[name] else { continue }
                if let f = t.fontName { out.fontName = f }
                if let c = t.color { out.color = c }
                if let a = t.action { out.action = a }
            }
            return out
        }
    }
}

extension CSSTextRun {
    /// As `runs(_:tags:elements:)`, with each element given as several runs (a list of
    /// names with separators, say).
    public static func runs(_ rich: RichText, tags: [String: I18nTagStyle] = [:], elementRuns: [String: [CSSTextRun]]) -> [CSSTextRun] {
        rich.runs.flatMap { run -> [CSSTextRun] in
            var out: [CSSTextRun]
            switch run.content {
            case .text(let s): out = [CSSTextRun(s)]
            case .element(let id): out = elementRuns[id] ?? []
            }
            for name in run.tags {
                guard let t = tags[name] else { continue }
                for i in out.indices {
                    if let f = t.fontName { out[i].fontName = f }
                    if let c = t.color { out[i].color = c }
                    if let a = t.action { out[i].action = a }
                }
            }
            return out
        }
    }
}

/// `formatFileSize` (ts/util/formatFileSize.std.ts): `filesize` with decimal units, one
/// decimal from 1 MB up, none below.
public func formatFileSize(_ size: Int) -> String {
    let units = ["B", "kB", "MB", "GB", "TB", "PB"]   // filesize.js SI symbols ("10 kB")
    var value = Double(size), unit = 0
    while value >= 1000, unit < units.count - 1 {
        value /= 1000
        unit += 1
    }
    let decimals = size < 1_000_000 ? 0 : 1
    let p = decimals == 0 ? 1.0 : 10.0
    let rounded = (value * p).rounded() / p
    var text = decimals == 0 || rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    if text.hasSuffix(".0") { text.removeLast(2) }
    return "\(text) \(units[unit])"
}
