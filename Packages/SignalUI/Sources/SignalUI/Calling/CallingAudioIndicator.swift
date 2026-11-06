// Port of ts/components/CallingAudioIndicator.dom.tsx (+ CallingAudioIndicator.scss): a 28px
// pill — the muted mic, three white bars that follow the audio level while speaking, or an
// empty spacer so names don't move.

import SwiftUI

public struct CallingAudioIndicator: View {
    /// `SPEAKING_LINGER_MS`
    public static let speakingLingerMs = 200

    let hasAudio: Bool
    let audioLevel: Double
    let shouldShowSpeaking: Bool

    public init(hasAudio: Bool, audioLevel: Double, shouldShowSpeaking: Bool) {
        self.hasAudio = hasAudio
        self.audioLevel = audioLevel
        self.shouldShowSpeaking = shouldShowSpeaking
    }

    public var body: some View {
        let pill = Color(rgba: RGBA(LegacyColor.gray80.r, LegacyColor.gray80.g, LegacyColor.gray80.b, 0.7))
        ZStack {
            if !hasAudio {
                SignalIcon("v3/mic/mic-slash-fill-compact-light", size: 16, color: AxoColor(light: LegacyColor.white, dark: LegacyColor.white), mask: true)
                    .frame(width: 16, height: 16)
            } else if shouldShowSpeaking {
                // The 14×14 viewBox drawn at the content's CSS size, 16px.
                AudioBars(level: audioLevel).fill(Color.white).frame(width: 16, height: 16)
                    .animation(.linear(duration: 0.2), value: audioLevel)
            }
        }
        .frame(width: 28, height: 28)
        .background { if !hasAudio || shouldShowSpeaking { Capsule().fill(pill) } }
    }
}

/// `generateCombinedPath`: three 2px bars with round ends, the sides at 75% of the centre's
/// growth, in a 14×14 viewBox.
struct AudioBars: Shape {
    var level: Double
    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    static func bar(_ x: Double, _ height: Double) -> (x: Double, top: Double, bottom: Double) {
        let h = height - 2, y = (14 - h) / 2
        return (x, y, y + h)
    }

    func path(in rect: CGRect) -> Path {
        let k = rect.width / 14
        var p = Path()
        let side = 2 + level * 9 * 0.75, centre = 2 + level * 9
        for (x, h) in [(1.0, side), (6.0, centre), (11.0, side)] {
            let b = Self.bar(x, h)
            // M left top L left bottom A 0.5… right bottom L right top A … left top: SVG enlarges
            // the too-small radius to half the 2px width, so the ends are semicircles.
            p.move(to: CGPoint(x: rect.minX + b.x * k, y: rect.minY + b.top * k))
            p.addLine(to: CGPoint(x: rect.minX + b.x * k, y: rect.minY + b.bottom * k))
            p.addArc(center: CGPoint(x: rect.minX + (b.x + 1) * k, y: rect.minY + b.bottom * k), radius: k, startAngle: .degrees(180), endAngle: .degrees(0),
                     clockwise: true)
            p.addLine(to: CGPoint(x: rect.minX + (b.x + 2) * k, y: rect.minY + b.top * k))
            p.addArc(center: CGPoint(x: rect.minX + (b.x + 1) * k, y: rect.minY + b.top * k), radius: k, startAngle: .degrees(0), endAngle: .degrees(180),
                     clockwise: true)
            p.closeSubpath()
        }
        return p
    }
}
