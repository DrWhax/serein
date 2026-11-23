import Foundation

/// Picks each picture's quantizer so a stream's pictures, as sent (packet headers and FEC
/// included), average its share of the bandwidth estimate at the capture rate. The pacer then
/// rarely has to drop a whole picture: before this, a fixed quantizer met a busy scene with
/// several megabits a second and the pacer cut the frame rate instead of coarsening the picture.
///
/// A step controller on the logarithm of the bits: a picture over its budget raises the
/// quantizer at once, one under lowers it slowly (no oscillation, and the pacer never builds a
/// backlog). The rate-quantizer slope varies widely with content (bits fall 1.3x to 5x when the
/// quantizer step doubles), so the controller corrects rather than predicts. A keyframe is as
/// fine as the pictures around it (its quality lasts: aimed at a few pictures' budget, a pan's
/// keyframe came out coarse and the whole pan stayed so), unless that makes it more than a
/// quarter second of bandwidth: then coarser. The stream's first keyframe knows nothing of the
/// content yet: it starts finest and an oversized one is coded again at once (retryKeyframe).
struct VideoRateControl: Sendable {
    enum Codec: Sendable { case vp8, vp9 }

    /// The quantizer range: the finest used however much bandwidth there is, and the coarsest.
    let finest, coarsest: Int
    /// Quantizer index steps that about double the quantizer step (VP9: ~42, VP8: ~33), scaled
    /// down to the correction made for a picture twice its budget.
    private let perDoubling: Double
    private var inter: Double
    /// The finest a keyframe may be: raised when one exceeds its target, relaxed slowly after.
    private var keyLimit: Double
    /// Whether an inter picture has been coded (until then the inter quantizer is a guess).
    private var started = false

    /// Screen content keeps text legible: a lower coarsest quantizer, so the pacer drops frames
    /// rather than blurring them.
    init(_ codec: Codec, screen: Bool = false) {
        switch codec {
        case .vp8:
            finest = 12; coarsest = screen ? 72 : 118; perDoubling = 14
            inter = 48
        case .vp9:
            finest = 40; coarsest = screen ? 140 : 224; perDoubling = 20
            inter = 112
        }
        // Mid-range to start: easy content comes down within a dozen pictures, and busy content
        // (a noisy camera made 0.45 Mbit pictures at VP9's old 72) is not held back seconds.
        // Keyframes start finest: an oversized one is coded again (retryKeyframe).
        inter = min(inter, Double(coarsest))
        keyLimit = Double(finest)
    }

    func quantizer(key isKey: Bool) -> Int { Int(keyframe(isKey).rounded()) }

    private func keyframe(_ isKey: Bool) -> Double { isKey ? (started ? max(inter, keyLimit) : keyLimit) : inter }

    /// A picture took `bits` on the wire against its `budget`: its share of the bandwidth over
    /// one capture interval, less what is still waiting to be sent.
    mutating func record(bits: Int, budget: Int, key isKey: Bool) {
        let budget = max(1, budget)
        // Up at once, by up to two and a half doublings for a picture far over (a picture over
        // budget holds back the ones after it); down a third as fast.
        func change(_ error: Double) -> Double {
            error > 0 ? min(2.5*perDoubling, perDoubling*error) : max(-perDoubling/3, perDoubling*error/3)
        }
        if isKey {
            // Over its target: coarser than the one just coded; under: the limit relaxes.
            let error = log2(Double(max(1, bits)) / (Double(budget) * 7.5))
            keyLimit = clamp((error > 0 ? keyframe(true) : keyLimit) + change(error))
        } else {
            started = true
            inter = clamp(inter + change(log2(Double(max(1, bits)) / (Double(budget) * 0.9))))
        }
    }

    /// Whether a keyframe just coded (`bits`, before packetizing) is over eight pictures'
    /// budget and should be coded again coarser, aimed at four: then the keyframe quantizer is
    /// raised for it. A keyframe replaces the encoder's state, so coding it again is safe.
    mutating func retryKeyframe(bits: Int, budget: Int) -> Bool {
        let used = keyframe(true)
        guard bits > 8*max(1, budget), used < Double(coarsest) else { return false }
        keyLimit = clamp(used + min(2.5*perDoubling, perDoubling*log2(Double(bits) / (4*Double(max(1, budget))))))
        return true
    }

    /// After a picture a whole second of bandwidth could not hold: the coarsest from now on.
    mutating func overshoot() { inter = Double(coarsest); keyLimit = Double(coarsest) }

    private func clamp(_ value: Double) -> Double { min(Double(coarsest), max(Double(finest), value)) }
}
