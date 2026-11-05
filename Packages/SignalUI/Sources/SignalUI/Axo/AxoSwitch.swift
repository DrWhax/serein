// Port of ts/axo/AxoSwitch.dom.tsx (Radix Switch): 32×18 track with a sliding thumb.

import SwiftUI

public enum AxoSwitch {
    /// `<AxoSwitch.Root>`
    public struct Root: View {
        @Binding var checked: Bool
        let disabled: Bool
        let label: String?
        @Environment(\.axoAnimationsDisabled) var animationsDisabled
        @GestureState private var pressed = false

        public init(checked: Binding<Bool>, disabled: Bool = false, label: String? = nil) {
            _checked = checked
            self.disabled = disabled
            self.label = label
        }

        // Thumb shadow: shadow-[#000]/12, shadow-[0.5px_0_0.5px_0.5px,-0.5px_0_0.5px_0.5px]
        static let thumbShadow: [AxoShadowLayer] = [
            .init(inset: false, x: 0.5, y: 0, blur: 0.5, spread: 0.5, color: RGBA(0, 0, 0, 0.12)),
            .init(inset: false, x: -0.5, y: 0, blur: 0.5, spread: 0.5, color: RGBA(0, 0, 0, 0.12)),
        ]
        // inset-shadow-on-color: inset 0 0.5px 1px 0 #000/12%
        static let trackShadow: [AxoShadowLayer] = [.init(inset: true, x: 0, y: 0.5, blur: 1, spread: 0, color: RGBA(0, 0, 0, 0.12))]

        public var body: some View {
            let track = Capsule()
            ZStack(alignment: .leading) {
                // Accent fill (absolute inset-y-0 w-5.5 rounded-s-full, slides in from -14).
                Group {
                    if disabled {
                        Capsule().fill(AxoColor.fillAccent).frame(width: 30)
                    } else {
                        UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                            .fill(pressed ? AxoColor.fillAccentPressed : AxoColor.fillAccent).frame(width: 22)
                    }
                }
                .opacity(checked ? (disabled ? 0.25 : 1) : 0)
                .offset(x: checked ? 0 : -14)
                // Thumb (size-4 rounded-full, translate-x-3.5 when checked).
                Circle()
                    .fill(disabled ? AxoColor.labelDisabledOncolor : AxoColor.labelPrimaryOncolor)
                    .frame(width: 16, height: 16)
                    .cssBoxShadow(Self.thumbShadow, in: Circle())
                    .offset(x: checked ? 14 : 0)
            }
            .frame(width: 30, height: 16, alignment: .leading)
            .clipShape(Capsule())                                       // overflow-hidden (padding box)
            .padding(1)                                                 // border
            .background {
                track.fill(disabled ? AxoColor.fillControl : pressed ? AxoColor.fillPrimaryPressed : AxoColor.fillPrimary)
                    .cssBoxShadow(Self.trackShadow, in: track)
            }
            .overlay { track.strokeBorder(AxoColor.borderSecondary, lineWidth: 1) }
            .animation(animationsDisabled ? nil : .axoEaseOutCubic(0.2), value: checked)
            .contentShape(track)
            .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, s, _ in s = !disabled }.onEnded { _ in
                if !disabled { checked.toggle() }
            })
            .accessibilityElement()
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(checked ? "on" : "off")
            .accessibilityLabel(label ?? "")
        }
    }
}
