// The legacy (pre-Axo) type scale: the SCSS font mixins of Signal-Desktop/stylesheets/_mixins.scss
// (`@include mixins.font-body-1` …) as CSSTextStyles. Sizes, line heights and letter spacing
// (absolute px) are upstream's; the weight picks the Inter face as Chromium resolves it.

import SwiftUI

public enum LegacyType {
    static func inter(_ size: CGFloat, _ lineHeight: CGFloat, _ letterSpacing: CGFloat, weight: Int) -> CSSTextStyle {
        CSSTextStyle(fontName: AxoFonts.interName(weight: weight), size: size, lineHeight: lineHeight, letterSpacing: letterSpacing)
    }

    /// `font-title-1`: 600 26px/32px, −0.56px
    public static func title1(weight: Int = 600) -> CSSTextStyle { inter(26, 32, -0.56, weight: weight) }
    /// `font-title-2`: 600 20px/26px, −0.34px
    public static func title2(weight: Int = 600) -> CSSTextStyle { inter(20, 26, -0.34, weight: weight) }
    /// `font-title-medium`: 600 18px/25px, −0.25px
    public static func titleMedium(weight: Int = 600) -> CSSTextStyle { inter(18, 25, -0.25, weight: weight) }
    /// `font-body-1`: 14px/20px, −0.08px (`font-body-1-bold`: weight 600)
    public static func body1(weight: Int = 400) -> CSSTextStyle { inter(14, 20, -0.08, weight: weight) }
    /// `font-body-2`: 13px/18px, −0.03px (`-bold` 600, `-medium` 500)
    public static func body2(weight: Int = 400) -> CSSTextStyle { inter(13, 18, -0.03, weight: weight) }
    /// `font-body-small` / `font-subtitle`: 12px/16px, 0
    public static func bodySmall(weight: Int = 400) -> CSSTextStyle { inter(12, 16, 0, weight: weight) }
    /// `font-subtitle`: 12px/16px, 0
    public static func subtitle(weight: Int = 400) -> CSSTextStyle { inter(12, 16, 0, weight: weight) }
    /// `font-caption`: 11px/14px, 0.06px
    public static func caption(weight: Int = 400) -> CSSTextStyle { inter(11, 14, 0.06, weight: weight) }
}
