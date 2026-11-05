// Port of ts/axo/AxoTokens.std.ts lookups over the generated tables.

import SwiftUI

public enum AxoTokens {
    public enum Avatar {
        public struct ColorValues: Sendable, Hashable { public var bg: RGBA, fg: RGBA }
        public static var allColorNames: [String] { AxoTokensTables.avatarColors.map(\.name) }
        public static func colorValues(_ name: String) -> ColorValues {
            guard let c = AxoTokensTables.avatarColors.first(where: { $0.name == name }) else { preconditionFailure("Missing avatar color: \(name)") }
            return ColorValues(bg: c.bg, fg: c.fg)
        }
        /// The 12 avatar colours by `hash % 12`.
        public static func colorName(hash: Int) -> String {
            precondition(hash >= 0, "Hash must be positive integer")
            return AxoTokensTables.avatarColors[hash % AxoTokensTables.avatarColors.count].name
        }
        public static var gradientsCount: Int { AxoTokensTables.avatarGradients.count }
        public static func gradient(hash: Int) -> (start: RGBA, end: RGBA) {
            precondition(hash >= 0, "Hash must be positive integer")
            return AxoTokensTables.avatarGradients[hash % AxoTokensTables.avatarGradients.count]
        }
        public static var contactPresetNames: [String] { AxoTokensTables.contactPresets.map(\.name) }
        public static var groupPresetNames: [String] { AxoTokensTables.groupPresets.map(\.name) }
        public static func presetColorName(_ preset: String) -> String {
            guard let p = (AxoTokensTables.contactPresets + AxoTokensTables.groupPresets).first(where: { $0.name == preset }) else {
                preconditionFailure("Missing avatar preset: \(preset)")
            }
            return p.color
        }
    }

    public enum Contact {
        public static var allColorNames: [String] { AxoTokensTables.contactColors.map(\.name) }
        public static func color(_ name: String) -> AxoColor {
            guard let c = AxoTokensTables.contactColors.first(where: { $0.name == name }) else { preconditionFailure("Missing contact color: \(name)") }
            return c.color
        }
    }

    public enum ChatBubble {
        public static var solidPresetNames: [String] { AxoTokensTables.chatBubbleSolids.map(\.name) }
        public static var gradientPresetNames: [String] { AxoTokensTables.chatBubbleGradients.map(\.name) }
        public static func solid(_ name: String) -> RGBA? { AxoTokensTables.chatBubbleSolids.first { $0.name == name }?.color }
        public static func gradient(_ name: String) -> CSSLinearGradient? {
            AxoTokensTables.chatBubbleGradients.first { $0.name == name }.map { CSSLinearGradient(deg: $0.deg, start: $0.start, end: $0.end) }
        }
    }
}

/// CSS `linear-gradient(<deg>, start, end)`: the gradient line passes through the centre at
/// the CSS angle (0deg = to top, clockwise) and is long enough that the corners reach the
/// start/end colours exactly.
public struct CSSLinearGradient: Sendable, Hashable {
    public var deg: Double
    public var start: RGBA
    public var end: RGBA
    public init(deg: Double, start: RGBA, end: RGBA) {
        self.deg = deg
        self.start = start
        self.end = end
    }

    public func points(in size: CGSize) -> (UnitPoint, UnitPoint) {
        let a = deg * .pi / 180
        let dx = sin(a), dy = -cos(a)                   // CSS: y grows downward
        let half = (abs(size.width * sin(a)) + abs(size.height * cos(a))) / 2
        let cx = size.width / 2, cy = size.height / 2
        func unit(_ x: Double, _ y: Double) -> UnitPoint {
            UnitPoint(x: size.width > 0 ? x / size.width : 0.5, y: size.height > 0 ? y / size.height : 0.5)
        }
        return (unit(cx - dx * half, cy - dy * half), unit(cx + dx * half, cy + dy * half))
    }
}

/// Fills its frame with a CSS linear gradient, interpolated as CSS does for legacy sRGB
/// colours: per component in gamma-encoded sRGB (SwiftUI's `.device` gradient space).
public struct CSSLinearGradientFill: View {
    let gradient: CSSLinearGradient
    public init(_ gradient: CSSLinearGradient) { self.gradient = gradient }
    public var body: some View {
        GeometryReader { geo in
            let (s, e) = gradient.points(in: geo.size)
            Rectangle().fill(.linearGradient(Gradient(colors: [gradient.start.color, gradient.end.color]).colorSpace(.device),
                                             startPoint: s, endPoint: e))
        }
    }
}
