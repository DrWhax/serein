// A design-system colour with a light and a dark value (upstream CSS `light-dark()`),
// resolved from the SwiftUI environment's colour scheme, so `AxoTheme` and the calling
// screen's force-dark mode switch every token at once.

import SwiftUI

public struct RGBA: Sendable, Hashable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
    /// 0xRRGGBB with alpha 0…1.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }
    public var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    /// Sass `color.mix(a, b, weight)`: `weight` of `a`, the rest `b` (opaque colours).
    public static func mix(_ a: RGBA, _ b: RGBA, _ weight: Double) -> RGBA {
        RGBA(a.r * weight + b.r * (1 - weight), a.g * weight + b.g * (1 - weight), a.b * weight + b.b * (1 - weight),
             a.a * weight + b.a * (1 - weight))
    }
}

public struct AxoColor: ShapeStyle, Sendable, Hashable {
    public var light: RGBA
    public var dark: RGBA

    public init(light: RGBA, dark: RGBA) {
        self.light = light
        self.dark = dark
    }
    public init(_ both: RGBA) { self.init(light: both, dark: both) }

    public func resolve(in environment: EnvironmentValues) -> Color {
        (environment.colorScheme == .dark ? dark : light).color
    }

    public func value(for scheme: ColorScheme) -> RGBA { scheme == .dark ? dark : light }
}
