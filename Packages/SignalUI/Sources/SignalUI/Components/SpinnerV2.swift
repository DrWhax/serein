// Port of ts/components/SpinnerV2.dom.tsx: an SVG ring spinner (indeterminate) or progress
// ring, with a background track. Radius = min(size/2 − strokeWidth/2, size/2 × marginRatio).
// Indeterminate: the arc rotates (−180°…180° over 2s) while its dash grows and moves
// (animate-spinner-v2-dash 1.5s); with animations disabled it rests un-animated, a full ring.

import SwiftUI

public struct SpinnerV2: View {
    /// `SpinnerVariant` (stroke colours of the background track and the arc; nil = stroke-none)
    public enum Variant: Sendable, Hashable {
        case normal, noBackground, noBackgroundIncoming, noBackgroundLight, brand
        case axoButtonSpinnerSecondary, axoButtonSpinnerOncolor, axoButtonSpinnerOnbright, axoButtonSpinnerPrimary
        case axoButtonSpinnerAffirmative, axoButtonSpinnerWarning, axoButtonSpinnerDestructive
        case custom(bg: AxoColor?, fg: AxoColor)

        var colors: (bg: AxoColor?, fg: AxoColor) {
            switch self {
            case .normal: (.labelDisabledOncolor, .labelPrimaryOncolor)
            case .noBackground: (nil, .labelPrimaryOncolor)
            case .noBackgroundIncoming: (nil, .labelPrimary)
            case .noBackgroundLight: (nil, .borderPrimary)               // stroke-primary: --axo-color-border-primary
            case .brand: (.fillSecondary, .labelAccent)
            case .axoButtonSpinnerSecondary: (nil, .labelPrimary)
            case .axoButtonSpinnerOncolor: (nil, .labelPrimaryOncolor)
            case .axoButtonSpinnerOnbright: (nil, .labelPrimaryOnbright)
            case .axoButtonSpinnerPrimary: (nil, .labelPrimary)
            case .axoButtonSpinnerAffirmative: (nil, .labelAffirmative)
            case .axoButtonSpinnerWarning: (nil, .labelWarning)
            case .axoButtonSpinnerDestructive: (nil, .labelDestructive)
            case .custom(let bg, let fg): (bg, fg)
            }
        }
    }

    let value: Double?
    let min: Double
    let max: Double
    let variant: Variant
    let ariaLabel: String?
    let marginRatio: Double?
    let size: CGFloat
    let strokeWidth: CGFloat
    @Environment(\.axoAnimationsDisabled) var animationsDisabled

    /// `value == nil` is 'indeterminate'.
    public init(value: Double? = nil, min: Double = 0, max: Double = 1, variant: Variant = .normal, ariaLabel: String? = nil,
                marginRatio: Double? = nil, size: CGFloat, strokeWidth: CGFloat) {
        self.value = value
        self.min = min
        self.max = max
        self.variant = variant
        self.ariaLabel = ariaLabel
        self.marginRatio = marginRatio
        self.size = size
        self.strokeWidth = strokeWidth
    }

    var radius: CGFloat { Swift.min(size / 2 - strokeWidth / 2, size / 2 * CGFloat(marginRatio ?? 0.8)) }

    /// `roundFractionForProgressBar`
    static func roundFraction(_ f: Double) -> Double {
        if f <= 0 { return 0 }
        if f >= 1 { return 1 }
        if f <= 0.01 { return 0.01 }
        if f >= 0.99 { return 0.99 }
        return (f * 100).rounded() / 100
    }

    public var body: some View {
        let (bg, fg) = variant.colors
        let inset = size / 2 - radius
        ZStack {
            if let bg { Circle().inset(by: inset).stroke(bg, lineWidth: strokeWidth) }
            if let value {
                Circle().inset(by: inset)
                    .trim(from: 0, to: Self.roundFraction((value - min) / (max - min)))
                    .stroke(fg, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(animationsDisabled ? nil : .timingCurve(0.33, 1, 0.68, 1, duration: 0.5), value: value)
            } else if animationsDisabled {
                Circle().inset(by: inset).stroke(fg, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
            } else {
                IndeterminateArc(inset: inset, radius: radius, size: size, stroke: strokeWidth, color: fg)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(ariaLabel ?? "")
        .accessibilityValue(value.map { "\(Int((($0 - min) / (max - min) * 100).rounded()))%" } ?? "")
    }

    /// The dash keyframes, in % of the SVG's normalised diagonal (= size for a square):
    /// 0%: 2% dash at offset 0; 50%: 180% at −70%; 100%: 180% at −248% (ease-in-out per segment).
    struct IndeterminateArc: View {
        let inset: CGFloat, radius: CGFloat, size: CGFloat, stroke: CGFloat, color: AxoColor
        var body: some View {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let rotate = -180 + 360 * (t.truncatingRemainder(dividingBy: 2) / 2)
                let phase = t.truncatingRemainder(dividingBy: 1.5) / 1.5
                let (dash, offset): (Double, Double) = phase < 0.5
                    ? { let e = ProgressBar.easeInOut(phase * 2); return (2 + 178 * e, -70 * e) }()
                    : { let e = ProgressBar.easeInOut((phase - 0.5) * 2); return (180, -70 - 178 * e) }()
                let circumference = 2 * .pi * radius
                let start = (-offset / 100 * size).truncatingRemainder(dividingBy: circumference) / circumference
                let length = Swift.min(1, dash / 100 * size / circumference)
                ZStack {
                    Circle().inset(by: inset).trim(from: start, to: Swift.min(1, start + length))
                        .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    if start + length > 1 {
                        Circle().inset(by: inset).trim(from: 0, to: start + length - 1)
                            .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    }
                }
                .rotationEffect(.degrees(rotate))
            }
        }
    }
}
