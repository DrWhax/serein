// Port of ts/components/AnimatedEmojiGalore.dom.tsx: sixteen 48px emoji, each absolutely
// positioned at a random `left` of the container, rising from 1280px below to 144px above
// their static position with a random scale and rotation, launched one after another.
// react-spring's { mass 20, tension 120, friction 80, clamp } is an interpolating spring of
// the same constants (damping ratio 0.82: the overshoot clamp removes is under 2%).

import SwiftUI

public struct AnimatedEmojiGalore: View {
    /// One emoji's random draw: `left: random(0, 100)%`, `delay: i * random(80, 120)` ms,
    /// `rotate: random(-24, 24)`, `scale: random(0.5, 1.0, true)`.
    public struct Particle: Sendable, Equatable {
        public var left: Int
        public var delay: Double
        public var rotate: Double
        public var scale: Double
        public init(left: Int, delay: Double, rotate: Double, scale: Double) {
            self.left = left
            self.delay = delay
            self.rotate = rotate
            self.scale = scale
        }
    }

    static let numEmojis = 16
    static let maxHeight: CGFloat = 1280
    static let restY: CGFloat = -144

    public static func randomParticles() -> [Particle] {
        (0..<numEmojis).map { i in
            Particle(left: Int.random(in: 0...100), delay: Double(i * Int.random(in: 80...120)) / 1000,
                     rotate: Double(Int.random(in: -24...24)), scale: Double.random(in: 0.5...1.0))
        }
    }

    let emoji: String
    let particles: [Particle]
    let onAnimationEnd: () -> Void
    /// How many particles start at rest (a still frame of the animation, for snapshots).
    let initiallyAtRest: Int
    @State private var launched: Set<Int> = []
    @Environment(\.accessibilityReduceMotion) var reducedMotion

    public init(emoji: String, particles: [Particle] = AnimatedEmojiGalore.randomParticles(), initiallyAtRest: Int = 0,
                onAnimationEnd: @escaping () -> Void = {}) {
        self.emoji = emoji
        self.particles = particles
        self.initiallyAtRest = initiallyAtRest
        self.onAnimationEnd = onAnimationEnd
    }

    func atRest(_ i: Int) -> Bool { i < initiallyAtRest || launched.contains(i) }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(particles.indices, id: \.self) { i in
                    let p = particles[i]
                    let rest = atRest(i)
                    FunStaticEmoji(emoji, size: 48)
                        .frame(width: 48, height: 48)
                        // transform: translateY(y) scale(s) rotate(r), about the box's centre.
                        .rotationEffect(.degrees(rest ? p.rotate : 0))
                        .scaleEffect(rest ? p.scale : 1)
                        .offset(x: geo.size.width * CGFloat(p.left) / 100, y: rest ? Self.restY : Self.maxHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task { await launch() }
    }

    func launch() async {
        let start = ContinuousClock.now
        for i in particles.indices where i >= initiallyAtRest {
            try? await Task.sleep(until: start + .milliseconds(Int(particles[i].delay * 1000)))
            if Task.isCancelled { return }
            if reducedMotion {
                launched.insert(i)
            } else {
                withAnimation(.interpolatingSpring(mass: 20, stiffness: 120, damping: 80)) { _ = launched.insert(i) }
            }
        }
        // onRest of the last spring: a clamped spring of these constants settles in ~2.2s.
        if !reducedMotion { try? await Task.sleep(for: .milliseconds(2200)) }
        if !Task.isCancelled { onAnimationEnd() }
    }
}
