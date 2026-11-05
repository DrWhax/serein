// Ports of ts/components/CustomColorEditor.dom.tsx, GradientDial.dom.tsx and
// CustomColorEditorDialog.dom.tsx: the custom chat colour editor (preview card with the
// gradient dial, hue and saturation sliders) and its dialog with Solid / Gradient tabs.

import Foundation
import SignalI18n
import SwiftUI

/// `calculateLightness` (ts/util/getHSL.std.ts): the lightness Signal pairs with a hue.
public enum ChatColorLightness {
    static let table: [(hue: Double, lightness: Double)] = [(0, 45), (60, 30), (180, 30), (240, 50), (300, 40), (360, 45)]

    public static func calculate(hue: Double) -> Double {
        if hue >= 60 && hue < 180 { return 30 }
        guard let upper = table.firstIndex(where: { $0.hue > hue }), upper > 0 else { return 45 }
        let lo = table[upper - 1], hi = table[upper]
        let percentage = (hue - lo.hue) * 100 / (hi.hue - lo.hue)
        return percentage * (hi.lightness - lo.lightness) / 100 + lo.lightness
    }
}

public enum CustomColorEditorMode: String, Sendable { case solid, gradient }

/// `CustomColorEditorState`: colours as react-aria keeps them (HSL), the angle in whole degrees.
public struct CustomColorEditorState: Sendable, Hashable {
    public var start: AxoColorSlider.HSLColor
    public var end: AxoColorSlider.HSLColor
    public var angle: Int

    /// `INITIAL_CUSTOM_CHAT_COLOR`: ultramarine, at `270 − deg`.
    public static let ultramarine: (start: UInt32, end: UInt32, angle: Int) = (0x0552F0, 0x2C6BED, 90)

    /// `createCustomColorEditorState`
    public init(solid: UInt32? = nil, gradient: (start: UInt32, end: UInt32, angle: Int)? = nil) {
        start = AxoColorSlider.HSLColor(rgb: solid ?? gradient?.start ?? Self.ultramarine.start)
        end = AxoColorSlider.HSLColor(rgb: gradient?.end ?? Self.ultramarine.end)
        angle = gradient?.angle ?? Self.ultramarine.angle
    }

    /// `serializeCustomColorEditorState`, as the bubble colour it renders.
    public func bubbleColor(_ mode: CustomColorEditorMode) -> BubbleColor {
        switch mode {
        case .solid: .solid(start.rgba)
        case .gradient: CustomChatColor.gradient(angle: Double(angle), start: start.rgba, end: end.rgba)
        }
    }
}

/// `GradientDial`'s `KnobType`
public enum GradientDialKnob: Sendable { case start, end }

/// `GradientDial`: laid over the preview `inset-8`; the line through the centre at the angle,
/// and a knob for each end where it meets the edge.
public struct GradientDial: View {
    let start: AxoColorSlider.HSLColor
    let end: AxoColorSlider.HSLColor
    let angle: Int
    let onAngleChange: (Int) -> Void
    let onKnobSelect: (GradientDialKnob) -> Void
    let selectedKnob: GradientDialKnob
    @Environment(\.i18n) var i18n

    public init(start: AxoColorSlider.HSLColor, end: AxoColorSlider.HSLColor, angle: Int, onAngleChange: @escaping (Int) -> Void,
                onKnobSelect: @escaping (GradientDialKnob) -> Void, selectedKnob: GradientDialKnob) {
        self.start = start
        self.end = end
        self.angle = angle
        self.onAngleChange = onAngleChange
        self.onKnobSelect = onKnobSelect
        self.selectedKnob = selectedKnob
    }

    /// `getKnobCoordinates`: from the centre along the angle (counter-clockwise from the
    /// right, y down) to the nearest edge, and the opposite point.
    static func knobs(_ size: CGSize, degrees: Double) -> (start: CGPoint, end: CGPoint) {
        let r = degrees * .pi / 180
        let dx = cos(r), dy = -sin(r)
        let cx = size.width / 2, cy = size.height / 2
        let distance = min(abs(dx) > 1e-12 ? cx / abs(dx) : .infinity, abs(dy) > 1e-12 ? cy / abs(dy) : .infinity)
        return (CGPoint(x: cx + dx * distance, y: cy + dy * distance), CGPoint(x: cx - dx * distance, y: cy - dy * distance))
    }

    static func normalize(_ degrees: Double) -> Double { (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let points = Self.knobs(size, degrees: Double(angle))
            ZStack(alignment: .topLeading) {
                // h-screen w-1.5 bg-material-quaternary shadow-elevation-0, rotated `90 − angle`.
                Rectangle().fill(AxoColor.materialQuaternary)
                    .frame(width: 6, height: 900)
                    .axoShadow(.shadowElevation0, in: Rectangle())
                    .rotationEffect(.degrees(Double(90 - angle)))
                    .position(x: size.width / 2, y: size.height / 2)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                knob(.start, at: points.start, color: start, size: size)
                knob(.end, at: points.end, color: end, size: size)
            }
        }
        .padding(32)
    }

    func knob(_ knob: GradientDialKnob, at point: CGPoint, color: AxoColorSlider.HSLColor, size: CGSize) -> some View {
        let selected = selectedKnob == knob
        return Circle().fill(color.rgba.color)
            .padding(4.5)                          // border-3 p-[1.5px]
            .frame(width: 40, height: 40)
            .background(Circle().fill(AxoColor.materialQuaternary))
            .overlay { if selected { Circle().strokeBorder(AxoColor.borderFocusedOuter, lineWidth: 3) } }
            .axoShadow(.shadowElevation1, in: Circle())
            .contentShape(Circle())
            .position(point)
            .gesture(DragGesture(coordinateSpace: .named("GradientDial")).onChanged { value in
                onKnobSelect(knob)
                let vector = CGPoint(x: value.location.x - size.width / 2, y: value.location.y - size.height / 2)
                let degrees = atan2(-vector.y, vector.x) * 180 / .pi - (knob == .end ? 180 : 0)
                onAngleChange(Int(Self.normalize(degrees.rounded())))
            })
            .onTapGesture { onKnobSelect(knob) }
            .accessibilityElement()
            .accessibilityLabel(i18n(knob == .start ? "icu:GradientDial__knob-start" : "icu:GradientDial__knob-end"))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 1 : -1
                onAngleChange(Int(Self.normalize(Double(angle + step))))
            }
    }
}

public struct CustomColorEditor: View {
    let mode: CustomColorEditorMode
    @Binding var editorState: CustomColorEditorState
    @State private var selectedKnob = GradientDialKnob.start
    @Environment(\.i18n) var i18n

    public init(mode: CustomColorEditorMode, editorState: Binding<CustomColorEditorState>) {
        self.mode = mode
        self._editorState = editorState
    }

    /// `HUE_TRACK_BACKGROUND`: 13 stops, every 30°, at full saturation and Signal's lightness.
    static let hueTrack = AnyShapeStyle(LinearGradient(stops: (0...12).map { i in
        let hue = Double(i * 30)
        return Gradient.Stop(color: AxoColorSlider.HSLColor(hue: hue, saturation: 100, lightness: ChatColorLightness.calculate(hue: hue)).rgba.color,
                             location: Double(i) / 12)
    }, startPoint: .leading, endPoint: .trailing))

    var selectedColor: Binding<AxoColorSlider.HSLColor> {
        Binding {
            selectedKnob == .start ? editorState.start : editorState.end
        } set: { value in
            // `withCalculatedLightness`
            let color = AxoColorSlider.HSLColor(hue: value.hue, saturation: value.saturation, lightness: ChatColorLightness.calculate(hue: value.hue))
            if selectedKnob == .start { editorState.start = color } else { editorState.end = color }
        }
    }

    /// `inset-shadow-on-color`: inset 0 0.5px 1px 0 #000/12%.
    static let insetShadowOnColor: AxoShadow = {
        let layer = AxoShadowLayer(inset: true, x: 0, y: 0.5, blur: 1, spread: 0, color: RGBA(0, 0, 0, 0.12))
        return AxoShadow(light: [layer], dark: [layer])
    }()

    func label(_ key: String) -> some View {
        CSSText(i18n(key), type: .bodyLarge, color: .labelPrimary).frame(maxWidth: .infinity, alignment: .leading)
    }

    public var body: some View {
        let selected = selectedColor.wrappedValue
        let thumb = AxoColorSlider.HSLColor(hue: selected.hue, saturation: 100, lightness: ChatColorLightness.calculate(hue: selected.hue)).rgba
        VStack(spacing: 0) {
            // mb-2.5 relative rounded-xl py-4 bg-surface-primary inset-shadow-on-color
            let card = RoundedRectangle(cornerRadius: AxoRadius.xl)
            SampleMessageBubbles(bubbleColor: editorState.bubbleColor(mode))
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(card.fill(AxoColor.surfacePrimary))
                .axoShadow(Self.insetShadowOnColor, in: card)
                .overlay {
                    if mode == .gradient {
                        GradientDial(start: editorState.start, end: editorState.end, angle: editorState.angle,
                                     onAngleChange: { editorState.angle = $0 }, onKnobSelect: { selectedKnob = $0 }, selectedKnob: selectedKnob)
                            .coordinateSpace(.named("GradientDial"))
                    }
                }
                .padding(.bottom, 10)
            // The sliders' my-2 collapses with the labels' margins.
            label("icu:CustomColorEditor__hue")
            Color.clear.frame(height: AxoColorSlider.margin)
            AxoColorSlider.Root(channel: .hue, color: selectedColor, trackBackground: Self.hueTrack, thumbColor: thumb)
            Color.clear.frame(height: AxoColorSlider.margin)
            label("icu:CustomColorEditor__saturation")
            Color.clear.frame(height: AxoColorSlider.margin)
            AxoColorSlider.Root(channel: .saturation, color: selectedColor)
            Color.clear.frame(height: AxoColorSlider.margin)
        }
    }
}

public struct CustomColorEditorDialog: View {
    let onClose: () -> Void
    let onSave: (BubbleColor) -> Void
    @State private var editorState: CustomColorEditorState
    @State private var mode: String
    @Environment(\.i18n) var i18n

    /// `initialColor`: nil for a new colour.
    public init(initialSolid: UInt32? = nil, initialGradient: (start: UInt32, end: UInt32, angle: Int)? = nil, onClose: @escaping () -> Void = {},
                onSave: @escaping (BubbleColor) -> Void = { _ in }) {
        self.onClose = onClose
        self.onSave = onSave
        _editorState = State(initialValue: CustomColorEditorState(solid: initialSolid, gradient: initialGradient))
        _mode = State(initialValue: initialGradient != nil ? CustomColorEditorMode.gradient.rawValue : CustomColorEditorMode.solid.rawValue)
    }

    public var body: some View {
        AxoDialog.Content(size: .md) {
            AxoDialog.Header {
                AxoDialog.Title(i18n("icu:CustomColorEditor__title"))
                AxoDialog.Close(action: onClose)
            }
            AxoDialog.Tabs(value: $mode) {
                AxoDialog.TabList {
                    AxoDialog.Tab(value: "solid", i18n("icu:CustomColorEditor__solid"))
                    AxoDialog.Tab(value: "gradient", i18n("icu:CustomColorEditor__gradient"))
                }
                AxoDialog.TabContent(value: "solid") {
                    AxoDialog.Body(padding: .md) { CustomColorEditor(mode: .solid, editorState: $editorState) }
                }
                AxoDialog.TabContent(value: "gradient") {
                    AxoDialog.Body(padding: .md) { CustomColorEditor(mode: .gradient, editorState: $editorState) }
                }
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary, action: onClose)
                    AxoDialog.Action(i18n("icu:save"), variant: .strongPrimary) {
                        onSave(editorState.bubbleColor(CustomColorEditorMode(rawValue: mode) ?? .solid))
                        onClose()
                    }
                }
            }
        }
    }
}
