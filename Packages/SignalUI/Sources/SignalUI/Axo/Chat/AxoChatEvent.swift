// Port of ts/axo/chat/AxoChatEvent.dom.tsx (+ AxoChatEvent.css): a timeline event — a
// centred line of secondary (or destructive) text led by a symbol, with optional inline
// actions (contact names) and a timestamp, and an optional action button below.
//
//   <AxoChatEvent.Root variant>                 flex flex-col items-center gap-2.5 px-8 py-2.5
//     <AxoChatEvent.Body symbol>                max-w-100 text-center line-clamp-3 type-body-medium
//       <AxoChatEvent.InlineAction/> text <AxoChatEvent.Timestamp/>
//     </AxoChatEvent.Body>
//     <AxoChatEvent.Action/>                    AxoButton subtle-secondary sm
//   </AxoChatEvent.Root>
//
// The body's children are inline content (an `@AxoChatEvent.InlineBuilder` of strings,
// InlineActions and a Timestamp), laid out as one paragraph.

import Foundation
import SwiftUI

public enum AxoChatEvent {
    public enum Variant: String, Sendable, CaseIterable { case secondary, destructive }

    /**
     * <AxoChatEvent.Root>
     * --------------------------------------------------------------------------
     */

    public struct Root<Content: View>: View {
        let variant: Variant
        let content: Content

        public init(variant: Variant, @ViewBuilder content: () -> Content) {
            self.variant = variant
            self.content = content()
        }

        public var body: some View {
            VStack(spacing: 10) { content }
                .padding(.horizontal, 32)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .environment(\.axoChatEventVariant, variant)
                .accessibilityElement(children: .contain)
        }
    }

    /**
     * Inline content
     * --------------------------------------------------------------------------
     */

    /// One inline item of a Body.
    public struct Inline: Sendable {
        var pieces: [Piece]
        enum Piece: Sendable {
            case text(String)
            case action(String, @MainActor @Sendable () -> Void)
        }
    }

    @resultBuilder
    public enum InlineBuilder {
        public static func buildExpression(_ s: String) -> [Inline] { [Inline(pieces: [.text(s)])] }
        public static func buildExpression(_ a: InlineAction) -> [Inline] { [Inline(pieces: [.action(a.label, a.action)])] }
        public static func buildExpression(_ t: Timestamp) -> [Inline] { [Inline(pieces: [.text("\u{00A0}\u{00B7}\u{00A0}" + t.display)])] }
        public static func buildBlock(_ parts: [Inline]...) -> [Inline] { parts.flatMap { $0 } }
        public static func buildOptional(_ part: [Inline]?) -> [Inline] { part ?? [] }
        public static func buildEither(first: [Inline]) -> [Inline] { first }
        public static func buildEither(second: [Inline]) -> [Inline] { second }
        public static func buildArray(_ parts: [[Inline]]) -> [Inline] { parts.flatMap { $0 } }
    }

    /**
     * <AxoChatEvent.Body>
     * --------------------------------------------------------------------------
     */

    public struct Body: View {
        let symbol: AxoSymbol.Name
        let inline: [Inline]
        @Environment(\.axoChatEventVariant) var variant
        @Environment(\.layoutDirection) var direction

        public init(symbol: AxoSymbol.Name, @InlineBuilder content: () -> [Inline]) {
            self.symbol = symbol
            self.inline = content()
        }

        public var body: some View {
            var pieces: [AxoInlinePiece] = [.glyph(AxoSymbol.inlineGlyph(symbol, rtl: direction == .rightToLeft)), .text("\u{00A0}")]
            var actions: [@MainActor @Sendable () -> Void] = []
            for part in inline.flatMap(\.pieces) {
                switch part {
                case .text(let s): pieces.append(.text(s))
                case .action(let label, let action):
                    pieces.append(.action(label, id: actions.count))
                    actions.append(action)
                }
            }
            return AxoInlineFlowText(pieces: pieces, style: CSSTextStyle(AxoType.bodyMedium), alignment: .center, maxLines: 3, clampOverflow: 4) { id in
                if actions.indices.contains(id) { actions[id]() }
            }
            .frame(maxWidth: 400)
            .fixedSize(horizontal: false, vertical: true)
            .cssTextColor(variant == .secondary ? .labelSecondary : .labelDestructive)
        }
    }

    /**
     * <AxoChatEvent.InlineAction>
     * --------------------------------------------------------------------------
     */

    /// An inline action that looks like the surrounding text (a contact name, …).
    public struct InlineAction: Sendable {
        let label: String
        let action: @MainActor @Sendable () -> Void

        public init(_ label: String, onClick action: @escaping @MainActor @Sendable () -> Void) {
            self.label = label
            self.action = action
        }
    }

    /**
     * <AxoChatEvent.Timestamp>
     * --------------------------------------------------------------------------
     */

    /// A relative timestamp after the text: "&nbsp;·&nbsp;<time>".
    public struct Timestamp: Sendable {
        let timestamp: Date
        let display: String

        public init(timestamp: Date, _ display: String) {
            self.timestamp = timestamp
            self.display = display
        }
    }

    /**
     * <AxoChatEvent.Action>
     * --------------------------------------------------------------------------
     */

    /// The (single) optional action below the event.
    public struct Action: View {
        let label: String
        let disabled: Bool
        let discouraged: Bool
        let action: () -> Void

        public init(_ label: String, disabled: Bool = false, discouraged: Bool = false, onClick action: @escaping () -> Void = {}) {
            self.label = label
            self.disabled = disabled
            self.discouraged = discouraged
            self.action = action
        }

        public var body: some View {
            AxoButton.Root(label, variant: .subtleSecondary, size: .sm, disabled: disabled, discouraged: discouraged, action: action)
        }
    }
}

extension EnvironmentValues {
    @Entry var axoChatEventVariant: AxoChatEvent.Variant = .secondary
}
