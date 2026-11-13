// Port of ts/components/preferences/notificationProfiles/NotificationProfilesOnboardingDialog
// and `ProfileAvatar` / `EmojiOrMoon` of ts/components/PreferencesNotificationProfiles.dom.tsx.

import SignalI18n
import SwiftUI

/// `IconSize` of the notification profile avatars.
public enum NotificationProfileIconSize: Sendable {
    case large, medium, mediumSmall, small
    var side: CGFloat { switch self { case .large: 80; case .medium: 36; case .mediumSmall: 28; case .small: 20 } }
    var glyph: CGFloat { switch self { case .large: 48; case .medium: 20; case .mediumSmall: 16; case .small: 12 } }
}

/// `ProfileAvatar`: the profile's emoji (or the accent moon) centred in a round chip of the
/// profile's colour (accent tint without one); `isActive` adds a 2px selected border.
public struct NotificationProfileAvatar: View {
    let emoji: String?
    /// The profile's ARGB colour.
    let color: UInt32?
    let isActive: Bool
    let size: NotificationProfileIconSize
    @Environment(\.i18n) var i18n

    public init(emoji: String? = nil, color: UInt32? = nil, isActive: Bool = false, size: NotificationProfileIconSize) {
        self.emoji = emoji
        self.color = color
        self.isActive = isActive
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle().fill(color.map { AxoColor(RGBA(hex: $0 & 0xFFFFFF)) } ?? AxoColor.fillAccentTint)
            if let emoji, !emoji.isEmpty {
                FunStaticEmoji(emoji, size: size.glyph)
            } else {
                AxoSymbol.Icon("moon-fill", size: size.glyph, label: i18n("icu:NotificationProfile--moon-icon"))
                    // A profile without an emoji keeps the light-theme accent (colorScheme: light).
                    .cssTextColor(color != nil ? AxoColor(AxoColor.labelAccent.light) : .labelAccent)
            }
            if isActive { Circle().strokeBorder(AxoColor.borderSelected, lineWidth: 2) }
        }
        .frame(width: size.side, height: size.side)
    }
}

public struct NotificationProfilesOnboardingDialog: View {
    let onDismiss: () -> Void
    @Environment(\.i18n) var i18n

    public init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

    public var body: some View {
        AxoDialog.Content(size: .sm, hasHeader: false) {
            AxoDialog.Body {
                VStack(spacing: 0) {
                    NotificationProfileAvatar(size: .large).padding(.bottom, 10)
                    // AxoDialog.Title outside a header (mb-2.5) holding a title-medium span.
                    CSSText(i18n("icu:NotificationProfiles--title"), type: .titleMedium, alignment: .center, color: .labelPrimary)
                        .padding(.bottom, 10)
                        .accessibilityAddTraits(.isHeader)
                    CSSText(i18n("icu:NotificationProfiles--setup-description"), type: .bodyMedium, wrap: .pretty, alignment: .center)
                }
                .frame(maxWidth: .infinity)
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(i18n("icu:NotificationProfiles--setup-continue"), variant: .strongPrimary,
                                     autoFocus: true, action: onDismiss)    // Radix focuses the only control
                }
            }
        }
    }
}
