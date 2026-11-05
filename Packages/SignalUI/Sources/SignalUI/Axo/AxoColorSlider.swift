// Port of ts/axo/AxoColorSlider.dom.tsx (react-aria ColorSlider): a slider over one HSL
// channel of a colour, `my-2 h-2.5`, with a gradient track (rounded-full) and a 20px
// thumb (border-2 fill-white, shadow-elevation-0) filled with the colour.
//
// Upstream's `my-2` is a collapsing margin: lay sliders out 8pt apart (`margin`) and leave
// 8pt above / below the group.
//
// Upstream's colour value is AxoColor.std.ts (a react-aria Color); its HSL view is
// `AxoColorSlider.HSLColor` here (the name AxoColor is taken by the design tokens).

import SwiftUI

public enum AxoColorSlider {
    /// The vertical `my-2` margin around each slider (collapses between siblings).
    public static let margin: CGFloat = 8

    public enum Channel: String, Sendable, CaseIterable { case hue, saturation, lightness }

    /// An HSL colour (hue 0…360°, saturation and lightness 0…100 %), as react-aria keeps it.
    public struct HSLColor: Sendable, Hashable {
        public var hue: Double
        public var saturation: Double
        public var lightness: Double
        public var alpha: Double

        public init(hue: Double, saturation: Double, lightness: Double, alpha: Double = 1) {
            self.hue = hue
            self.saturation = saturation
            self.lightness = lightness
            self.alpha = alpha
        }

        /// From 0xRRGGBB (`AxoColor.parse('#…')` then `.toFormat('hsl')`).
        public init(rgb hex: UInt32, alpha: Double = 1) {
            let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
            let maxC = max(r, g, b), minC = min(r, g, b), d = maxC - minC
            let l = (maxC + minC) / 2
            var h = 0.0, s = 0.0
            if d > 0 {
                s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
                switch maxC {
                case r: h = (g - b) / d + (g < b ? 6 : 0)
                case g: h = (b - r) / d + 2
                default: h = (r - g) / d + 4
                }
                h *= 60
            }
            self.init(hue: h, saturation: s * 100, lightness: l * 100, alpha: alpha)
        }

        public var rgba: RGBA {
            let s = saturation / 100, l = lightness / 100
            func f(_ n: Double) -> Double {
                let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
                let a = s * min(l, 1 - l)
                return l - a * max(-1, min(k - 3, 9 - k, 1))
            }
            return RGBA(f(0), f(8), f(4), alpha)
        }

        public func value(_ channel: Channel) -> Double {
            switch channel {
            case .hue: hue
            case .saturation: saturation
            case .lightness: lightness
            }
        }

        public func with(_ channel: Channel, _ v: Double) -> HSLColor {
            var c = self
            switch channel {
            case .hue: c.hue = v
            case .saturation: c.saturation = v
            case .lightness: c.lightness = v
            }
            return c
        }
    }

    static func range(_ channel: Channel) -> ClosedRange<Double> { channel == .hue ? 0...360 : 0...100 }

    /// react-aria's track gradient for a channel (`to right`, in sRGB).
    static func trackStops(_ channel: Channel, _ color: HSLColor) -> [RGBA] {
        switch channel {
        case .hue: stride(from: 0.0, through: 360, by: 60).map { color.with(.hue, $0).rgba }
        case .saturation: [color.with(.saturation, 0).rgba, color.with(.saturation, 100).rgba]
        case .lightness: [0.0, 50, 100].map { color.with(.lightness, $0).rgba }
        }
    }

    /// `<AxoColorSlider.Root>`
    public struct Root: View {
        let channel: Channel
        @Binding var color: HSLColor
        /// A CSS background for the track, replacing react-aria's channel gradient.
        let trackBackground: AnyShapeStyle?
        let thumbColor: RGBA?
        @Environment(\.layoutDirection) var direction

        public init(channel: Channel, color: Binding<HSLColor>, trackBackground: AnyShapeStyle? = nil, thumbColor: RGBA? = nil) {
            self.channel = channel
            _color = color
            self.trackBackground = trackBackground
            self.thumbColor = thumbColor
        }

        var label: String {
            switch channel {
            case .hue: "Hue"
            case .saturation: "Saturation"
            case .lightness: "Lightness"
            }
        }

        public var body: some View {
            let range = AxoColorSlider.range(channel)
            let fraction = (color.value(channel) - range.lowerBound) / (range.upperBound - range.lowerBound)
            GeometryReader { geo in
                let w = geo.size.width
                let x = (direction == .rightToLeft ? 1 - fraction : fraction) * w
                ZStack(alignment: .topLeading) {
                    Group {
                        if let trackBackground {
                            Capsule().fill(trackBackground)
                        } else {
                            Capsule().fill(.linearGradient(Gradient(colors: AxoColorSlider.trackStops(channel, color).map(\.color)).colorSpace(.device),
                                                           startPoint: direction == .rightToLeft ? .trailing : .leading,
                                                           endPoint: direction == .rightToLeft ? .leading : .trailing))
                        }
                    }
                    .frame(width: w, height: geo.size.height)
                    Circle()
                        .fill((thumbColor ?? color.rgba).color)
                        .overlay { Circle().strokeBorder(AxoColor.fillWhite, lineWidth: 2) }
                        .axoShadow(.shadowElevation0, in: Circle())
                        .frame(width: 20, height: 20)
                        .offset(x: x - 10, y: geo.size.height / 2 - 10)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    guard w > 0 else { return }
                    var f = min(1, max(0, g.location.x / w))
                    if direction == .rightToLeft { f = 1 - f }
                    color = color.with(channel, range.lowerBound + f * (range.upperBound - range.lowerBound))
                })
            }
            .frame(height: 10)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(color.value(channel).rounded()))")
            .accessibilityAdjustableAction { dir in
                let v = color.value(channel) + (dir == .increment ? 1 : -1)
                color = color.with(channel, min(range.upperBound, max(range.lowerBound, v)))
            }
        }
    }
}
