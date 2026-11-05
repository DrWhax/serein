// Port of ts/components/Slider.dom.tsx + stylesheets/components/Slider.scss: an 8px gray-15
// track (full width) with a 16px gray-90 handle (1px white border) at `value`% (0–100),
// offset −4px (start, top). Click or drag sets the value; ←/→ step by 1, Home / End.

import SwiftUI

public struct Slider: View {
    let label: String
    @Binding var value: Double
    @FocusState private var focused: Bool

    public init(label: String, value: Binding<Double>) {
        self.label = label
        _value = value
    }

    public var body: some View {
        GeometryReader { g in
            let width = max(g.size.width, 1)
            Rectangle().fill(AxoColor(LegacyColor.gray15))
                .overlay(alignment: .topLeading) {
                    Circle().fill(AxoColor(LegacyColor.gray90))
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 1))
                        .frame(width: 16, height: 16)
                        .offset(x: width * value / 100 - 4, y: -4)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { e in
                    value = min(100, max(0, 100 * e.location.x / width))
                })
        }
        .frame(height: 8)
        .focusable()
        .focused($focused)
        .onKeyPress(.leftArrow) { value = max(0, value - 1); return .handled }
        .onKeyPress(.rightArrow) { value = min(100, value + 1); return .handled }
        .onKeyPress(.home) { value = 0; return .handled }
        .onKeyPress(.end) { value = 100; return .handled }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(Text("\(Int(value))"))
        .accessibilityAdjustableAction { d in value = d == .increment ? min(100, value + 1) : max(0, value - 1) }
    }
}
