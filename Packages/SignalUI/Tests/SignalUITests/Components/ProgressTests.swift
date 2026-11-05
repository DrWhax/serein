// ProgressBar, SpinnerV2 and Spinner stories (ts/components/ProgressBar.dom.stories.tsx,
// SpinnerV2.dom.stories.tsx, Spinner.dom.stories.tsx) and their SwiftUI twins.

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ProgressBarTests {
    static let stories: [String: ProgressBar] = [
        "spinning": ProgressBar(fractionComplete: nil, isRTL: false),
        "zero": ProgressBar(fractionComplete: 0, isRTL: false),
        "thirty": ProgressBar(fractionComplete: 0.3, isRTL: false),
        "done": ProgressBar(fractionComplete: 1, isRTL: false),
        // useIncreasingFractionComplete adds 0.1 every 300ms; the captures were taken at 0.2.
        "increasing": ProgressBar(fractionComplete: 0.2, isRTL: false),
        "rtl-increasing": ProgressBar(fractionComplete: 0.2, isRTL: true),
    ]

    @Test(arguments: ["spinning", "zero", "thirty", "done", "increasing", "rtl-increasing"], ["light", "dark"])
    func story(name: String, theme: String) throws {
        try Snapshot.assertMatches(Self.stories[name]!, story: "components-progressbar--\(name)", theme: theme)
    }
}

/// SpinnerV2 stories: `<div className="bg-overlay">` around a spinner (size 36, stroke 2, margin 0.8).
struct SpinnerV2Story: View {
    var strokeWidth: CGFloat = 2
    var marginRatio = 0.8
    var body: some View {
        SpinnerV2(variant: .normal, ariaLabel: "label", marginRatio: marginRatio, size: 36, strokeWidth: strokeWidth)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Rectangle().fill(AxoColor.fillOverlay))
    }
}

@MainActor
@Suite struct SpinnerV2Tests {
    static let stories: [String: SpinnerV2Story] = [
        "default": SpinnerV2Story(),
        "thin": SpinnerV2Story(strokeWidth: 1),
        "thick": SpinnerV2Story(strokeWidth: 6),
        "no-margin": SpinnerV2Story(strokeWidth: 6, marginRatio: 1),
        "big-margin": SpinnerV2Story(strokeWidth: 6, marginRatio: 0.5),
        // Toggles between indeterminate and 0.3 every 2s; captured while indeterminate.
        "spinner-to-progress": SpinnerV2Story(),
    ]

    @Test(arguments: ["default", "thin", "thick", "no-margin", "big-margin", "spinner-to-progress"], ["light", "dark"])
    func story(name: String, theme: String) throws {
        try Snapshot.assertMatches(Self.stories[name]!, story: "components-spinnerv2--\(name)", theme: theme)
    }
}

/// Spinner stories (args: size 20px, svgSize normal).
struct SpinnerStory: View {
    let spinners: [(Spinner.SvgSize, Spinner.Direction?)]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(spinners.indices, id: \.self) { i in Spinner(svgSize: spinners[i].0, direction: spinners[i].1, size: 20) }
        }
    }
}

@MainActor
@Suite struct SpinnerTests {
    static let stories: [String: SpinnerStory] = [
        "normal": SpinnerStory(spinners: [(.normal, nil)]),
        "svg-sizes": SpinnerStory(spinners: Spinner.SvgSize.allCases.map { ($0, nil) }),
        "directions": SpinnerStory(spinners: Spinner.Direction.allCases.map { (.normal, $0) }),
    ]

    @Test(arguments: ["normal", "svg-sizes", "directions"], ["light", "dark"])
    func story(name: String, theme: String) throws {
        try Snapshot.assertMatches(Self.stories[name]!, story: "components-spinner--\(name)", theme: theme)
    }
}
