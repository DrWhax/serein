// AxoBrand and AxoColorSlider stories (ts/axo/AxoBrand.dom.stories.tsx, AxoColorSlider.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

/// Story `LogoAndWordMark`: flex flex-col gap-4 of force-light / force-dark
/// `bg-surface-primary p-4` boxes.
struct AxoBrandStory: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach([AxoThemeOverrideValue.forceLight, .forceDark], id: \.self) { theme in
                AxoThemeOverride(theme: theme) {
                    AxoBrand.LogoAndWordMark(maxWidth: 200)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AxoColor.surfacePrimary)
                }
            }
        }
    }
}

/// Story `AxoColorSlider/Basic`: p-4 around three sliders (my-2, collapsing) on #f00.
struct AxoColorSliderStory: View {
    @State var color = AxoColorSlider.HSLColor(rgb: 0xFF0000)
    var body: some View {
        VStack(spacing: AxoColorSlider.margin) {
            AxoColorSlider.Root(channel: .hue, color: $color)
            AxoColorSlider.Root(channel: .saturation, color: $color)
            AxoColorSlider.Root(channel: .lightness, color: $color)
        }
        .padding(.vertical, AxoColorSlider.margin)
        .padding(16)
    }
}

@MainActor
@Suite struct AxoBrandTests {
    @Test(arguments: ["light", "dark"])
    func logoAndWordMark(theme: String) throws {
        try Snapshot.assertMatches(AxoBrandStory(), story: "axo-axobrand--logo-and-word-mark", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func colorSlider(theme: String) throws {
        try Snapshot.assertMatches(AxoColorSliderStory(), story: "axo-axocolorslider--basic", theme: theme)
    }

    @Test func svgPathGrammar() throws {
        // Numbers without separators, arc flags, relative commands, implicit lineto after M.
        let p = try #require(SVGPathData.parse("M80 0c4.15 0 8.227.316 12.207.925L91.063 8.34A73 73 0 0 0 80 7.5a73 73 0 0 0-11.062.839z"))
        #expect(!p.isEmpty)
        let box = try #require(SVGPathData.parse("M0 0 10 0 10 10H0z")).boundingRect
        #expect(box == CGRect(x: 0, y: 0, width: 10, height: 10))
        // A half circle arc from (0,0) to (20,0), radius 10, bulging down (sweep 1 = clockwise on screen).
        let arc = try #require(SVGPathData.parse("M0 0A10 10 0 0 1 20 0")).boundingRect
        #expect(abs(arc.minY - (-10)) < 0.01 || abs(arc.maxY - 10) < 0.01)
        #expect(SVGPathData.parse("L0 0") == nil)
        #expect(SVGPathData.parse("M0 0 X") == nil)
        #expect(SVGPathData.parse("M0") == nil)
    }
}
