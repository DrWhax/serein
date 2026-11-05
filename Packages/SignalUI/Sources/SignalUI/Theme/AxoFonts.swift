// Bundled fonts (Resources/Fonts, converted from upstream's WOFF2 by Tools/gen-fonts.sh),
// registered for this process with CoreText.

import AppKit
import CoreText
import Foundation
import SwiftUI

public enum AxoFonts {
    /// Registers every bundled font once per process. Safe to call repeatedly.
    public static func register() {
        _ = registered
    }

    static let registered: Bool = {
        guard let dir = Bundle.module.url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return false }
        let urls = files.filter { $0.pathExtension == "ttf" }.sorted { $0.path < $1.path }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        return true
    }()

    /// Inter face for a CSS font-weight, matching how upstream's @font-face rules resolve
    /// in Chromium: 500 → Medium, 600 and 700 → SemiBold (the file declared as `bold`),
    /// anything lighter → Regular. (Inter-Bold is declared with an invalid weight
    /// and is never selected.)
    public static func interName(weight: Int, italic: Bool = false) -> String {
        switch (weight, italic) {
        case (..<500, false): "Inter-Regular"
        case (..<500, true): "Inter-Italic"
        case (500..<600, false): "Inter-Medium"
        case (500..<600, true): "Inter-Italic"
        case (_, false): "Inter-SemiBold"
        case (_, true): "Inter-SemiBoldItalic"
        }
    }

    public static func inter(size: CGFloat, weight: Int = 400, italic: Bool = false) -> Font {
        register()
        return Font.custom(interName(weight: weight, italic: italic), fixedSize: size)
    }

    public static let symbolsFamily = "Signal Symbols"

    /// PostScript name of the face Chromium on macOS gives `$monospace` / `font-mono`'s system
    /// fallback: 'SF Mono' and SFMono-Regular are not installed families, Chromium does not
    /// support `ui-monospace`, so the stack lands on Menlo.
    public static let monospaceName = "Menlo-Regular"

    /// Menlo for a CSS weight and style (Menlo has Regular and Bold faces; 600+ is bold).
    public static func monospaceName(weight: Int, italic: Bool) -> String {
        switch (weight >= 600, italic) {
        case (false, false): "Menlo-Regular"
        case (false, true): "Menlo-Italic"
        case (true, false): "Menlo-Bold"
        case (true, true): "Menlo-BoldItalic"
        }
    }
}
