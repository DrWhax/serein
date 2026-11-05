// Port of ts/components/ProgressBar.dom.tsx + stylesheets/components/ProgressBar.scss: a 5px
// bar (ultramarine at 20% behind a full-width ultramarine fill translated by
// (fraction − 1) × 100%, mirrored in RTL). `fractionComplete == nil` is the spinning state: a
// 36%-wide fill sliding across (2s ease-in-out, infinite), which with animations disabled
// rests un-animated (no transform): at the start of the bar.

import SwiftUI

public struct ProgressBar: View {
    let fractionComplete: Double?
    let isRTL: Bool
    @Environment(\.axoAnimationsDisabled) var animationsDisabled

    public init(fractionComplete: Double?, isRTL: Bool) {
        self.fractionComplete = fractionComplete
        self.isRTL = isRTL
    }

    static let spinningWidthFraction = 0.36
    static var track: AxoColor { AxoColor(RGBA(LegacyColor.ultramarine.r, LegacyColor.ultramarine.g, LegacyColor.ultramarine.b, 0.2)) }
    static var fill: AxoColor { AxoColor(LegacyColor.ultramarine) }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                if let fractionComplete {
                    shape.fill(Self.fill)
                        .frame(width: w)
                        .offset(x: (isRTL ? -1 : 1) * (fractionComplete - 1) * w)
                        .animation(animationsDisabled ? nil : .easeInOut(duration: 0.2), value: fractionComplete)   // transition: transform 0.2s
                } else if animationsDisabled {
                    shape.fill(Self.fill).frame(width: w * Self.spinningWidthFraction)
                } else {
                    TimelineView(.animation) { timeline in
                        let barWidth = w * Self.spinningWidthFraction
                        let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
                        let eased = Self.easeInOut(t)
                        // ltr: −100% → 100% / 0.36 of the bar's own width (rtl: reversed)
                        let from = -barWidth, to = barWidth / Self.spinningWidthFraction
                        let x = isRTL ? to + (from - to) * eased : from + (to - from) * eased
                        shape.fill(Self.fill).frame(width: barWidth).offset(x: x)
                    }
                }
            }
            .frame(width: w, height: 5, alignment: .topLeading)
        }
        .frame(height: 5)
        .background(shape.fill(Self.track))
        .clipShape(shape)
        .accessibilityElement()
        .accessibilityValue(fractionComplete.map { "\(Int(($0 * 100).rounded()))%" } ?? "")
    }

    /// CSS `ease-in-out`: cubic-bezier(0.42, 0, 0.58, 1), solved for x by bisection.
    static func easeInOut(_ x: Double) -> Double {
        func bez(_ t: Double, _ p1: Double, _ p2: Double) -> Double { 3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t }
        var lo = 0.0, hi = 1.0
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if bez(mid, 0.42, 0.58) < x { lo = mid } else { hi = mid }
        }
        return bez((lo + hi) / 2, 0, 1)
    }
}
