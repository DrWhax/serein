// AxoAvatar stories (ts/axo/AxoAvatar.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

/// Story helpers: Row = flex flex-wrap items-end gap-2; Cell = flex flex-col items-center gap-2
/// with a `font-mono type-caption text-secondary` label.
@MainActor func avatarRow(@ViewBuilder _ content: () -> some View) -> some View {
    CSSFlex(.row, wrap: true, gap: 8, align: .end) { content() }.frame(maxWidth: .infinity, alignment: .leading)
}

@MainActor func avatarCell(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
    CSSFlex(.column, gap: 8, align: .center) {
        content()
        CSSText(label, style: .mono(size: 11, lineHeight: 14, letterSpacing: 0.055), wrap: .nowrap, color: .labelSecondary)
    }
}

@MainActor func sizesTemplate(@ViewBuilder _ avatar: @escaping (AxoAvatar.Size) -> some View) -> some View {
    avatarRow {
        ForEach(AxoAvatar.allSizes, id: \.self) { size in
            avatarCell("\(Int(size))") { avatar(size) }
        }
    }
}

@MainActor
@Suite struct AxoAvatarTests {
    @Test(arguments: ["light", "dark"])
    func colors(theme: String) throws {
        let view = avatarRow {
            avatarCell("Default") {
                AxoAvatar.Root(size: 64) { AxoAvatar.Content(label: nil) { AxoAvatar.Icon(symbol: "palette") } }
            }
            ForEach(AxoTokens.Avatar.allColorNames, id: \.self) { color in
                avatarCell(color) {
                    AxoAvatar.Root(size: 64) { AxoAvatar.Content(label: nil) { AxoAvatar.Initials(initials: "JK", color: color) } }
                }
            }
        }
        try Snapshot.assertMatches(view, story: "axo-axoavatar--colors", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func gradients(theme: String) throws {
        let view = avatarRow {
            ForEach(0..<AxoTokens.Avatar.gradientsCount, id: \.self) { i in
                avatarCell("") { AxoAvatar.Root(size: 64) { AxoAvatar.Content(label: nil) { AxoAvatar.Gradient(identifierHash: i) } } }
            }
        }
        try Snapshot.assertMatches(view, story: "axo-axoavatar--gradients", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func initials(theme: String) throws {
        let view = StoryStack {
            ForEach(["JK", "WW"], id: \.self) { initials in
                sizesTemplate { size in
                    AxoAvatar.Root(size: size) { AxoAvatar.Content(label: nil) { AxoAvatar.Initials(initials: initials, color: "A100") } }
                }
            }
        }
        try Snapshot.assertMatches(view, story: "axo-axoavatar--initials", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func icons(theme: String) throws {
        let names = AxoSymbolDefs.allNames
        let view = sizesTemplate { size in
            AxoAvatar.Root(size: size) { AxoAvatar.Content(label: nil) { AxoAvatar.Icon(symbol: names[Int(size) % names.count]) } }
        }
        try Snapshot.assertMatches(view, story: "axo-axoavatar--icons", theme: theme)
    }

    static var kitten: RGBAImage? { fixtureImage("kitten-3-64-64.jpg") }

    @Test(arguments: ["light", "dark"])
    func images(theme: String) throws {
        let view = sizesTemplate { size in
            AxoAvatar.Root(size: size) { AxoAvatar.Content(label: nil) { AxoAvatar.Image(Self.kitten, fallbackColor: "A100") } }
        }
        try Snapshot.assertMatches(view, story: "axo-axoavatar--images", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func brokenImage(theme: String) throws {
        let view = avatarRow {
            avatarCell("Shows fallback icon") {
                AxoAvatar.Root(size: 64) { AxoAvatar.Content(label: nil) { AxoAvatar.Image(nil, fallbackColor: "A100") } }
            }
            avatarCell("Stays blurred") {
                AxoAvatar.Root(size: 64) { AxoAvatar.Content(label: nil) { AxoAvatar.Image(nil, blur: true, fallbackColor: "A100") } }
            }
        }
        try Snapshot.assertMatches(view, story: "axo-axoavatar--broken-image", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func presets(theme: String) throws {
        let view = StoryStack {
            ForEach([AxoTokens.Avatar.contactPresetNames, AxoTokens.Avatar.groupPresetNames], id: \.self) { names in
                avatarRow {
                    ForEach(names, id: \.self) { preset in
                        avatarCell(preset) { AxoAvatar.Root(size: 64) { AxoAvatar.Content(label: nil) { AxoAvatar.Preset(preset: preset) } } }
                    }
                }
            }
        }
        try Snapshot.assertMatches(view, story: "axo-axoavatar--presets", theme: theme)
    }

    @Test(arguments: ["light", "dark"])
    func clickToView(theme: String) throws {
        let view = avatarRow {
            ForEach(AxoAvatar.allSizes.filter { $0 >= AxoAvatar.minClickToViewSize }, id: \.self) { size in
                avatarCell("\(Int(size))") {
                    AxoAvatar.Root(size: size) {
                        AxoAvatar.Content(label: "Click to view Kitten's profile photo", action: {}) {
                            AxoAvatar.Image(Self.kitten, blur: true, fallbackColor: "A140")
                            AxoAvatar.ClickToView(label: "View")
                        }
                    }
                }
            }
        }
        try Snapshot.assertMatches(view, story: "axo-axoavatar--click-to-view", theme: theme)
    }
}
