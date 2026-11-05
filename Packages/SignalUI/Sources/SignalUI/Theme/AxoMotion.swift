// Animation policy: upstream disables animations under prefers-reduced-motion and in
// Storybook captures (SignalContext._skipAnimation); infinite animations then rest in
// their un-animated state. Snapshot tests set `axoAnimationsDisabled`.

import SwiftUI

struct AxoAnimationsDisabledKey: EnvironmentKey { static let defaultValue = false }
struct AxoStaticRenderingKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Rendering to an image (snapshot tests, previews): AppKit-backed containers such as
    /// ScrollView don't draw there, so scroll containers render their content clipped at
    /// offset 0 — what a freshly opened, unscrolled view shows.
    public var axoStaticRendering: Bool {
        get { self[AxoStaticRenderingKey.self] }
        set { self[AxoStaticRenderingKey.self] = newValue }
    }

    public var axoAnimationsDisabled: Bool {
        get { self[AxoAnimationsDisabledKey.self] }
        set { self[AxoAnimationsDisabledKey.self] = newValue }
    }
}

extension Animation {
    /// `transition-all duration-200 ease-out-cubic`
    static func axoEaseOutCubic(_ duration: Double) -> Animation {
        .timingCurve(0.33, 1, 0.68, 1, duration: duration)
    }
}
