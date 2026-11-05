// Port of the data side of ts/axo/emoji.std.ts: categories of parent emoji, skin-tone
// variants and short names, from upstream's generated build/emoji-data.json
// (Tools/gen-emoji-data.sh copies it into the bundle).

import Foundation

public enum EmojiCategory: String, Sendable, CaseIterable, Hashable {
    case smileysAndPeople = "SMILIES_AND_PEOPLE"
    case animalsAndNature = "ANIMALS_AND_NATURE"
    case foodAndDrink = "FOOD_AND_DRINK"
    case travelAndPlaces = "TRAVEL_AND_PLACES"
    case activities = "ACTIVITIES"
    case objects = "OBJECTS"
    case symbols = "SYMBOLS"
    case flags = "FLAGS"
}

/// `Emoji.SkinTone`
public enum EmojiSkinTone: String, Sendable, CaseIterable, Hashable {
    case none = "", type1 = "1F3FB", type2 = "1F3FC", type3 = "1F3FD", type4 = "1F3FE", type5 = "1F3FF"
}

public final class EmojiData: Sendable {
    struct Info: Decodable, Sendable {
        var shortName: String
        var emoticon: String?
        var skinTones: [String: String]?
    }
    struct File: Decodable {
        var categories: [String: [String]]
        var emojis: [String: Info]
        var parents: [String: String]
    }

    let categories: [EmojiCategory: [String]]
    let emojis: [String: Info]
    let parents: [String: String]

    init(file: File) {
        var c: [EmojiCategory: [String]] = [:]
        for (k, v) in file.categories { if let cat = EmojiCategory(rawValue: k) { c[cat] = v } }
        categories = c
        emojis = file.emojis
        parents = file.parents
    }

    public static let shared: EmojiData = {
        guard let url = Bundle.module.url(forResource: "emoji-data", withExtension: "json"),
              let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else {
            return EmojiData(file: File(categories: [:], emojis: [:], parents: [:]))
        }
        return EmojiData(file: file)
    }()

    /// `getCategoryParents`
    public func parents(in category: EmojiCategory) -> [String] { categories[category] ?? [] }

    /// `getParent`: a skin-tone variant's parent (an emoji is its own parent otherwise).
    public func parent(of variant: String) -> String { parents[variant] ?? variant }

    /// `getVariant`
    public func variant(_ parent: String, skinTone: EmojiSkinTone) -> String {
        guard skinTone != .none, let tones = emojis[parent]?.skinTones, let v = tones[skinTone.rawValue] else { return parent }
        return v
    }

    /// `Emoji.isEmoji`: `isParent || isSkinToneVariant`.
    public func isEmoji(_ s: String) -> Bool { emojis[s] != nil || parents[s] != nil }

    public func hasSkinTones(_ parent: String) -> Bool { emojis[parent]?.skinTones != nil }

    public func shortName(_ emoji: String) -> String? { emojis[parent(of: emoji)]?.shortName }
}
