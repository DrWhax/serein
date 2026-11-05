// ts/components/BetterAvatar.dom.stories.tsx and BetterAvatarBubble.dom.stories.tsx.
// Text is captured with the capture tool's asset:/// font rewrite and CAPTURE_REMOUNT (Inter
// loaded, as the app's own text has it; a canvas only draws with faces in use).

import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct BetterAvatarTests {
    static let colors = AxoTokens.Avatar.allColorNames

    @Test(arguments: ["light", "dark"])
    func betterAvatar(theme: String) throws {
        try Snapshot.assertMatches(BetterAvatar(avatarData: AvatarData(id: "1", color: Self.colors[1], icon: AvatarIcons.personal[1]), size: 80)
            .frame(width: 1168, alignment: .leading), story: "components-betteravatar--personal-icon", theme: theme)
        try Snapshot.assertMatches(BetterAvatar(avatarData: AvatarData(id: "1", color: Self.colors[1], icon: AvatarIcons.group[1]), size: 80)
            .frame(width: 1168, alignment: .leading), story: "components-betteravatar--group-icon", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func text(theme: String) throws {
        try Snapshot.assertMatches(BetterAvatar(avatarData: AvatarData(id: "1", color: Self.colors[0], text: "AH"), size: 80)
            .frame(width: 1168, alignment: .leading), story: "components-betteravatar--text", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func bubble(theme: String) throws {
        try Snapshot.assertMatches(BetterAvatarBubble(color: Self.colors[8], onDelete: {}) { Text("HI") }.frame(width: 1168, alignment: .leading),
                                   story: "components-betteravatarbubble--children", theme: theme)
        try Snapshot.assertMatches(BetterAvatarBubble(color: Self.colors[1], isSelected: true, onDelete: {}) { EmptyView() }
            .frame(width: 1168, alignment: .leading), story: "components-betteravatarbubble--selected", theme: theme)
        try Snapshot.assertMatches(BetterAvatarBubble(color: Self.colors[2], diameter: 120, onDelete: {}) { EmptyView() }
            .frame(width: 1168, alignment: .leading), story: "components-betteravatarbubble--style", theme: theme)
    }
}

/// ts/components/AvatarColorPicker, AvatarModalButtons and AvatarUploadButton stories.
@MainActor
@Suite struct AvatarEditorPartsTests {
    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        try Snapshot.assertMatches(AvatarColorPicker().frame(width: 1168), story: "components-avatarcolorpicker--default", theme: theme)
        try Snapshot.assertMatches(AvatarColorPicker(selectedColor: AxoTokens.Avatar.allColorNames[7]).frame(width: 1168),
                                   story: "components-avatarcolorpicker--selected", theme: theme)
        try Snapshot.assertMatches(AvatarModalButtons(hasChanges: true).frame(width: 1168), story: "components-avatarmodalbuttons--has-changes", theme: theme)
        try Snapshot.assertMatches(AvatarModalButtons(hasChanges: false).frame(width: 1168), story: "components-avatarmodalbuttons--no-changes", theme: theme)
        try Snapshot.assertMatches(AvatarUploadButton(onChange: { _ in }).frame(width: 1168, alignment: .leading),
                                   story: "components-avataruploadbutton--default", theme: theme)
    }
}
