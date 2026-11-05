// ts/components/AvatarPreview.dom.stories.tsx. TEST_IMAGE is the stories' 8×8 two-colour PNG.

import ImagePNG
import SwiftUI
import Testing
@testable import SignalUI

@MainActor
@Suite struct AvatarPreviewTests {
    static var testImage: RGBAImage? {
        let hex = "89504e470d0a1a0a0000000d4948445200000008000000080103000000fec12cc800000006504c5445ff00ff00ff000c82e9800000001849444154085b633061a8638863a867f8c720c760c12000001a4302f4d81dd9870000000049454e44ae426082"
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return (try? PNGDecoder.decode(bytes)).map { RGBAImage($0.stillImage) }
    }

    static let colors = AxoTokens.Avatar.allColorNames

    static var stories: [(String, AnyView)] {
        let kitten = fixtureImage("kitten-3-64-64.jpg")
        return [
            ("no-state-contact", AnyView(AvatarPreview(avatarColor: colors[0], conversationTitle: "Just Testing", onClear: {}, onClick: {}))),
            ("no-initials-contact", AnyView(AvatarPreview(avatarColor: colors[0], conversationTitle: "", onClear: {}, onClick: {}))),
            ("no-state-group", AnyView(AvatarPreview(avatarColor: colors[1], isGroup: true, onClear: {}, onClick: {}))),
            ("no-state-group-upload-me", AnyView(AvatarPreview(avatarColor: colors[1], isGroup: true, showUploadButton: true, onClear: {}, onClick: {}))),
            ("value", AnyView(AvatarPreview(avatarValue: testImage, onClear: {}, onClick: {}))),
            ("path", AnyView(AvatarPreview(avatarImage: kitten, onClear: {}, onClick: {}))),
            ("value-and-path", AnyView(AvatarPreview(avatarValue: testImage, avatarImage: kitten, onClear: {}, onClick: {}))),
            ("style", AnyView(AvatarPreview(avatarValue: testImage, size: 100, onClear: {}, onClick: {}))),
        ]
    }

    @Test(arguments: ["light", "dark"], 0..<8)
    func story(theme: String, index: Int) throws {
        let (name, view) = Self.stories[index]
        try Snapshot.assertMatches(view.frame(width: 1168), story: "components-avatarpreview--\(name)", theme: theme)
    }
}

/// ts/components/AvatarIconEditor.dom.stories.tsx
@MainActor
@Suite struct AvatarIconEditorTests {
    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let c = AxoTokens.Avatar.allColorNames
        try Snapshot.assertMatches(AvatarIconEditor(avatarData: AvatarData(id: "1", color: c[3], icon: AvatarIcons.personal[0])).frame(width: 1168),
                                   story: "components-avatariconeditor--personal-icon", theme: theme)
        try Snapshot.assertMatches(AvatarIconEditor(avatarData: AvatarData(id: "1", color: c[8], icon: AvatarIcons.group[0])).frame(width: 1168),
                                   story: "components-avatariconeditor--group-icon", theme: theme)
    }
}

/// ts/components/AvatarTextEditor.dom.stories.tsx. Upstream fits the font to a hidden copy of
/// the text when the editor mounts, before Inter has loaded in Storybook, so the captures'
/// sizes (54px empty, 47px "SUP", 12px for the wide characters) are injected.
@MainActor
@Suite struct AvatarTextEditorTests {
    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let c = AxoTokens.Avatar.allColorNames
        let sizes: [String: CGFloat] = ["": 54, "SUP": 47, "‱௸𒈙": 12]
        let fit: (String) -> CGFloat = { sizes[$0] ?? 54 }
        try Snapshot.assertMatches(AvatarTextEditor(fittedFontSize: fit).frame(width: 1168), story: "components-avatartexteditor--empty", theme: theme)
        try Snapshot.assertMatches(AvatarTextEditor(avatarData: AvatarData(id: "123", color: c[6], text: "SUP"), fittedFontSize: fit).frame(width: 1168),
                                   story: "components-avatartexteditor--with-data", theme: theme)
        try Snapshot.assertMatches(AvatarTextEditor(avatarData: AvatarData(id: "123", color: c[6], text: "‱௸𒈙"), fittedFontSize: fit).frame(width: 1168),
                                   story: "components-avatartexteditor--with-wide-characters", theme: theme)
    }

    @Test func fitting() {
        #expect(AvatarTextEditor.fittedFontSize("") == 54)
        #expect(AvatarTextEditor.fittedFontSize("SUP") < 47)
    }
}

/// ts/components/AvatarEditor.dom.stories.tsx (avatar colour AvatarColors[9], the presets).
@MainActor
@Suite struct AvatarEditorTests {
    @Test(arguments: ["light", "dark"])
    func stories(theme: String) throws {
        let color = AxoTokens.Avatar.allColorNames[9]
        func editor(_ title: String = "Default Title", group: Bool = false, image: RGBAImage? = nil) -> some View {
            AvatarEditor(avatarColor: color, avatarImage: image, conversationTitle: title, isGroup: group,
                         userAvatarData: AvatarEditor.defaultAvatars(isGroup: group)).frame(width: 1168)
        }
        try Snapshot.assertMatches(editor(group: true), story: "components-avatareditor--no-avatar-group", theme: theme)
        try Snapshot.assertMatches(editor(" "), story: "components-avatareditor--no-avatar-contact-no-initials", theme: theme)
        try Snapshot.assertMatches(editor(), story: "components-avatareditor--no-avatar-contact", theme: theme)
        try Snapshot.assertMatches(editor(image: fixtureImage("kitten-3-64-64.jpg")), story: "components-avatareditor--has-avatar", theme: theme)
    }
}
