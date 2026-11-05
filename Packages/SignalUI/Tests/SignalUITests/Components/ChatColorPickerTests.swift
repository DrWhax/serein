// ts/components/ChatColorPicker.dom.stories.tsx (conversationId "", basil selected, ultramarine default).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct ChatColorPickerTests {
    static let customColors: [CustomChatColor] = [
        CustomChatColor(id: 1, color: .solid(.hsl(32, 1, 0.37))),
        CustomChatColor(id: 2, color: CustomChatColor.gradient(angle: 90, start: .hsl(180, 1, 0.30), end: .hsl(0, 1, 0.45))),
        CustomChatColor(id: 3, color: CustomChatColor.gradient(angle: 90, start: .hsl(315, 0.78, 0.4125), end: .hsl(197, 1, 0.3566))),
        CustomChatColor(id: 4, color: CustomChatColor.gradient(angle: 90, start: .hsl(161, 0.52, 0.30), end: .hsl(153, 0.89, 0.30))),
    ]

    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let d = ChatColorPicker(conversationId: "", customChatColors: [], selectedPreset: "basil").frame(width: 1168)
        try Snapshot.assertMatches(TimelineMessageTests.stage(d), story: "components-chatcolorpicker--default", theme: theme)
        let c = ChatColorPicker(conversationId: "", customChatColors: Self.customColors, selectedCustomColorId: 3).frame(width: 1168)
        try Snapshot.assertMatches(TimelineMessageTests.stage(c), story: "components-chatcolorpicker--custom-colors", theme: theme)
    }
}
