// Chat colours (upstream ChatStyle, ducks/chatColors and conversationBubbleColor): a chat's
// bubble colour is a preset name or one of our custom colours (conversations.
// bubbleColorPreset / customChatColorId), else the account default (account table), else
// ultramarine. Custom colours are a solid ARGB or a gradient (start, end, angle), kept in
// customChatColors. Local to this device.

import Foundation
import GRDB

public struct CustomChatColor: Sendable, Equatable, Identifiable {
    public var id: Int64
    /// ARGB.
    public var solid: UInt32?
    public var gradient: (start: UInt32, end: UInt32, angle: Int)?

    public init(id: Int64, solid: UInt32? = nil, gradient: (start: UInt32, end: UInt32, angle: Int)? = nil) {
        self.id = id
        self.solid = solid
        self.gradient = gradient
    }

    public static func == (a: CustomChatColor, b: CustomChatColor) -> Bool {
        a.id == b.id && a.solid == b.solid && a.gradient?.start == b.gradient?.start && a.gradient?.end == b.gradient?.end && a.gradient?.angle == b.gradient?.angle
    }
}

/// A bubble colour: a preset, or a custom colour's id.
public enum ChatBubbleColor: Sendable, Equatable {
    case preset(String)
    case custom(Int64)
}

public struct ChatColorsState: Sendable, Equatable {
    public var customColors: [CustomChatColor]
    /// The account default (nil: ultramarine).
    public var defaultColor: ChatBubbleColor?

    public init(customColors: [CustomChatColor] = [], defaultColor: ChatBubbleColor? = nil) {
        self.customColors = customColors
        self.defaultColor = defaultColor
    }
}

public enum ChatColors {
    public static func state(_ db: Database) throws -> ChatColorsState {
        let colors = try Row.fetchAll(db, sql: "SELECT id, solid, gradientStart, gradientEnd, gradientAngle FROM customChatColors ORDER BY id").map { r in
            let solid = (r["solid"] as Int64?).map { UInt32(truncatingIfNeeded: $0) }
            var gradient: (UInt32, UInt32, Int)?
            if let s: Int64 = r["gradientStart"], let e: Int64 = r["gradientEnd"] {
                gradient = (UInt32(truncatingIfNeeded: s), UInt32(truncatingIfNeeded: e), Int(r["gradientAngle"] as Int64? ?? 0))
            }
            return CustomChatColor(id: r["id"], solid: solid, gradient: gradient.map { (start: $0.0, end: $0.1, angle: $0.2) })
        }
        let account = try Row.fetchOne(db, sql: "SELECT defaultBubbleColorPreset, defaultCustomChatColorId FROM account WHERE id = 1")
        return ChatColorsState(customColors: colors, defaultColor: color(preset: account?["defaultBubbleColorPreset"], custom: account?["defaultCustomChatColorId"]))
    }

    static func color(preset: String?, custom: Int64?) -> ChatBubbleColor? {
        if let custom { return .custom(custom) }
        if let preset, !preset.isEmpty { return .preset(preset) }
        return nil
    }

    /// A chat's own colour (nil: the default).
    public static func conversationColor(_ db: Database, conversationId: String) throws -> ChatBubbleColor? {
        guard let r = try Row.fetchOne(db, sql: "SELECT bubbleColorPreset, customChatColorId FROM conversations WHERE id = ?", arguments: [conversationId])
        else { return nil }
        return color(preset: r["bubbleColorPreset"], custom: r["customChatColorId"])
    }

    static func columns(_ c: ChatBubbleColor?) -> (String?, Int64?) {
        switch c {
        case .preset(let p): (p, nil)
        case .custom(let id): (nil, id)
        case nil: (nil, nil)
        }
    }

    /// `setConversationBubbleColor` (nil: back to the default).
    public static func setConversationColor(_ db: Database, conversationId: String, _ c: ChatBubbleColor?) throws {
        let (p, id) = columns(c)
        try db.execute(sql: "UPDATE conversations SET bubbleColorPreset = ?, customChatColorId = ? WHERE id = ?", arguments: [p, id, conversationId])
    }

    /// `setGlobalDefaultBubbleColor`
    public static func setDefaultColor(_ db: Database, _ c: ChatBubbleColor?) throws {
        let (p, id) = columns(c)
        try db.execute(sql: """
            INSERT INTO account (id, defaultBubbleColorPreset, defaultCustomChatColorId) VALUES (1, ?, ?)
            ON CONFLICT(id) DO UPDATE SET defaultBubbleColorPreset = excluded.defaultBubbleColorPreset, defaultCustomChatColorId = excluded.defaultCustomChatColorId
            """, arguments: [p, id])
    }

    /// `createCustomChatColor`: returns its id.
    @discardableResult
    public static func addCustomColor(_ db: Database, solid: UInt32?, gradient: (start: UInt32, end: UInt32, angle: Int)?) throws -> Int64 {
        try db.execute(sql: "INSERT INTO customChatColors (solid, gradientStart, gradientEnd, gradientAngle) VALUES (?, ?, ?, ?)",
                       arguments: [solid.map { Int64($0) }, gradient.map { Int64($0.start) }, gradient.map { Int64($0.end) }, gradient.map { Int64($0.angle) }])
        return db.lastInsertedRowID
    }

    /// `updateCustomChatColor`
    public static func updateCustomColor(_ db: Database, _ c: CustomChatColor) throws {
        try db.execute(sql: "UPDATE customChatColors SET solid = ?, gradientStart = ?, gradientEnd = ?, gradientAngle = ? WHERE id = ?",
                       arguments: [c.solid.map { Int64($0) }, c.gradient.map { Int64($0.start) }, c.gradient.map { Int64($0.end) },
                                   c.gradient.map { Int64($0.angle) }, c.id])
    }

    /// `removeCustomColor`: chats using it fall back to the default (ON DELETE SET NULL).
    public static func removeCustomColor(_ db: Database, id: Int64) throws {
        try db.execute(sql: "DELETE FROM customChatColors WHERE id = ?", arguments: [id])
    }
}

extension SignalDatabase {
    public func chatColorsUpdates() -> AsyncThrowingStream<ChatColorsState, Error> { observe { try ChatColors.state($0) } }
    public func conversationColorUpdates(conversationId: String) -> AsyncThrowingStream<ChatBubbleColor?, Error> {
        observe { try ChatColors.conversationColor($0, conversationId: conversationId) }
    }
}
