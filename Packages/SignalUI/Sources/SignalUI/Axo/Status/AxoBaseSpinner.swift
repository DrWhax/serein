// Port of ts/axo/status/_AxoBaseSpinner.dom.tsx: circular spinner / progress ring.
// Indeterminate: rotating arc (animate-axo-spinner-rotate 2s + dash 1.5s); with
// animations disabled the arc rests in its un-animated state, a full ring.

import SwiftUI

public enum AxoBaseSpinner {
    public enum Size: Sendable { case sm, md, lg, points(CGFloat)
        var value: CGFloat {
            switch self {
            case .sm: 16
            case .md: 24
            case .lg: 36
            case .points(let p): p
            }
        }
    }
    public enum Weight: Sendable { case medium, regular, light, thin
        var stroke: CGFloat {
            switch self {
            case .medium: 2
            case .regular: 1.8
            case .light: 1.5
            case .thin: 1.2
            }
        }
    }
    public enum Variant: Sendable { case `default`, oncolor }
    public enum Value: Sendable, Equatable { case indeterminate, progress(completed: Double, total: Double) }

    public struct Root: View {
        let size: CGFloat
        let weight: Weight
        let variant: Variant
        let value: Value
        let track: Bool
        @Environment(\.axoAnimationsDisabled) var animationsDisabled

        public init(size: CGFloat, weight: Weight, variant: Variant, value: Value, track: Bool) {
            self.size = size
            self.weight = weight
            self.variant = variant
            self.value = value
            self.track = track
        }

        public init(size: Size, weight: Weight, variant: Variant, value: Value, track: Bool) {
            self.init(size: size.value, weight: weight, variant: variant, value: value, track: track)
        }

        public var body: some View {
            let stroke = weight.stroke
            let inset = stroke / 2
            let progressColor: AxoColor = variant == .default ? .labelPrimary : .labelPrimaryOncolor
            let trackColor: AxoColor = variant == .default ? .fillSecondary : .labelDisabledOncolor
            ZStack {
                if case .progress = value, track {
                    Circle().inset(by: inset).stroke(trackColor, lineWidth: stroke)
                }
                switch value {
                case .indeterminate:
                    if animationsDisabled {
                        Circle().inset(by: inset).stroke(progressColor, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    } else {
                        IndeterminateArc(inset: inset, stroke: stroke, color: progressColor)
                    }
                case .progress(let completed, let total):
                    Circle().inset(by: inset)
                        .trim(from: 0, to: total > 0 ? min(1, max(0, completed / total)) : 0)
                        .stroke(progressColor, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.5), value: completed)
                }
            }
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    struct IndeterminateArc: View {
        let inset: CGFloat, stroke: CGFloat, color: AxoColor
        var body: some View {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                // rotate: -180°…180° over 2 s; dash: 1px → 180% → 1px of the circumference over 1.5 s, +0…360° turn.
                let rotate = -180 + 360 * (t.truncatingRemainder(dividingBy: 2) / 2)
                let phase = t.truncatingRemainder(dividingBy: 1.5) / 1.5
                let eased = phase < 0.5 ? phase * 2 : (1 - phase) * 2
                let arc = 0.02 + 0.5 * (1 - cos(eased * .pi)) * 0.98
                Circle().inset(by: inset).trim(from: 0, to: arc)
                    .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(rotate + 360 * phase))
            }
        }
    }
}
