// ts/components/CustomColorEditor.dom.stories.tsx and CustomColorEditorDialog.dom.stories.tsx
// (INITIAL_CUSTOM_CHAT_COLOR is ultramarine; edited colours go through argbInt).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct CustomColorEditorTests {
    /// `AxoColor.parse('hsl(…)').argbInt()` (8-bit channels, rounded).
    static func argb(_ h: Double, _ s: Double, _ l: Double) -> UInt32 {
        let c = AxoColorSlider.HSLColor(hue: h, saturation: s, lightness: l).rgba
        func byte(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(c.r) << 16 | byte(c.g) << 8 | byte(c.b)
    }

    @Test(arguments: ["light", "dark"])
    func editor(theme: String) throws {
        for mode in [CustomColorEditorMode.solid, .gradient] {
            // The sliders' trailing my-2 collapses out of the story root.
            let view = CustomColorEditor(mode: mode, editorState: .constant(CustomColorEditorState())).frame(width: 1168).padding(.bottom, -8)
            try Snapshot.assertMatches(TimelineMessageTests.stage(view), story: "components-customcoloreditor--\(mode.rawValue)", theme: theme)
        }
    }

    @Test(arguments: ["light", "dark"])
    func dialog(theme: String) throws {
        let stories: [(String, CustomColorEditorDialog)] = [
            ("new-color", CustomColorEditorDialog()),
            ("edit-solid-color", CustomColorEditorDialog(initialSolid: Self.argb(340, 70, 43.33))),
            ("edit-gradient-color", CustomColorEditorDialog(initialGradient: (Self.argb(32, 90, 37), Self.argb(280, 60, 43.33), 135))),
        ]
        for (name, view) in stories {
            try Snapshot.assertMatches(TimelineMessageTests.stage(PortalStage { EmptyView() } modal: { AxoBaseDialog.Host { view } }),
                                       story: "components-customcoloreditordialog--\(name)", theme: theme)
        }
    }
}
