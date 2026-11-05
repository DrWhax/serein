// Port of ts/components/conversation/EmbeddedContact.dom.tsx and contactUtil.dom.tsx
// (ContactAvatar): a shared contact in a bubble — avatar, display name and a chevron, and a
// "Message" button when the contact is on Signal.

import SignalI18n
import SwiftUI

/// `EmbeddedContactForUIType` (the parts the bubble shows).
public struct SharedContact: Sendable, Hashable {
    public var givenName: String?
    public var familyName: String?
    public var organization: String?
    public var avatar: MessageAttachment?
    /// `resolution.type !== 'not-on-signal'` (`canMessageSharedContact`).
    public var canMessage = false
    public init(givenName: String? = nil, familyName: String? = nil, organization: String? = nil) {
        self.givenName = givenName
        self.familyName = familyName
        self.organization = organization
    }

    /// `getDisplayName`: the full name, else the organization.
    var displayName: String? { combineNames(givenName, familyName) ?? organization.flatMap { $0.isEmpty ? nil : $0 } }
}

/// `combineNames`: "given family", or family + given when both are CJK/V.
func combineNames(_ given: String?, _ family: String?) -> String? {
    let g = given.flatMap { $0.isEmpty ? nil : $0 }, f = family.flatMap { $0.isEmpty ? nil : $0 }
    guard let g else { return f }
    guard let f else { return g }
    func isCKJV(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { u in
            [0x1100...0x11FF, 0x2E80...0x2FDF, 0x3000...0x30FF, 0x3130...0x318F, 0x31C0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA960...0xA97F, 0xAC00...0xD7FF, 0xF900...0xFAFF, 0x20000...0x2FA1F].contains { $0.contains(Int(u.value)) }
        }
    }
    return isCKJV(f) && isCKJV(g) ? f + g : "\(g) \(f)"
}

/// `getInitials`: letters and separators only; two capitals kept as-is; else the first
/// characters of the first and last words.
func getInitials(_ name: String?) -> String? {
    guard let name else { return nil }
    var cleaned = ""
    var lastWasSpace = false
    for ch in name {
        let isLetter = ch.unicodeScalars.allSatisfy { $0.properties.isAlphabetic && CharacterSet.letters.contains($0) }
        let isSeparator = ch.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) || $0.properties.generalCategory == .spaceSeparator }
        if isLetter {
            cleaned.append(ch)
            lastWasSpace = false
        } else if isSeparator, !lastWasSpace {
            cleaned.append(" ")
            lastWasSpace = true
        }
    }
    let parsed = cleaned.trimmingCharacters(in: .whitespaces)
    guard !parsed.isEmpty else { return nil }
    if parsed.count == 2 && parsed == parsed.uppercased() { return parsed }
    let parts = parsed.split(separator: " ")
    let first = parts.first.map { String($0.prefix(1)) } ?? ""
    return parts.count == 1 ? first : first + String(parts[parts.count - 1].prefix(1))
}

/// `ContactAvatar`
struct ContactAvatar: View {
    let contact: SharedContact
    let isIncoming: Bool
    let size: AxoAvatar.Size
    static let color = "A100"

    var body: some View {
        AxoAvatar.Root(size: size) {
            AxoAvatar.Content(label: nil) {
                if let a = contact.avatar, a.status != .readyToShow {
                    ZStack {
                        Circle().fill(isIncoming ? AxoColor.fillOnmessageIncomingPrimary : AxoColor.fillOnmessageOutgoingPrimary)
                        if case .downloading(let size, let downloaded) = a.status {
                            AxoSymbol.Icon("x", size: 24, label: nil)
                            AxoProgressIndicator.Root(size: .lg, completed: downloaded > 0 ? .value(Double(downloaded)) : .indeterminate,
                                                      total: size > 0 ? .value(Double(size)) : .indeterminate, noTrack: true)
                        } else {
                            AxoSymbol.Icon("arrow-down", size: 24, label: nil)
                        }
                    }
                    .cssTextColor(isIncoming ? .labelPrimary : .labelPrimaryOncolor)
                } else if let a = contact.avatar, a.hasUrl {
                    AxoAvatar.Image(a.image, fallbackColor: Self.color)
                } else if let initials = getInitials(contact.displayName) {
                    AxoAvatar.Initials(initials: initials, color: Self.color)
                } else {
                    AxoAvatar.Icon(symbol: "person")
                }
            }
        }
    }
}

public struct EmbeddedContact: View {
    let contact: SharedContact
    let isIncoming: Bool
    let onClick: () -> Void
    let onSendMessage: (() -> Void)?
    @Environment(\.i18n) var i18n

    public init(contact: SharedContact, isIncoming: Bool, onClick: @escaping () -> Void = {}, onSendMessage: (() -> Void)? = nil) {
        self.contact = contact
        self.isIncoming = isIncoming
        self.onClick = onClick
        self.onSendMessage = onSendMessage
    }

    public var body: some View {
        // flex flex-col gap-3 pt-1 pb-1.5
        VStack(spacing: 12) {
            SwiftUI.Button(action: onClick) {
                HStack(spacing: 12) {
                    ContactAvatar(contact: contact, isIncoming: isIncoming, size: 52)
                    CSSText(contact.displayName ?? "", style: CSSTextStyle(AxoType.bodyLarge.weight(500)), wrap: .truncate,
                            color: isIncoming ? .labelPrimary : .labelPrimaryOncolor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AxoSymbol.Icon("chevron-[end]", size: 20, label: nil)
                        .cssTextColor(isIncoming ? .labelSecondary : .labelSecondaryOncolor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let onSendMessage {
                AxoButton.Root(i18n("icu:EmbeddedContact__message"), variant: isIncoming ? .messageIncomingPrimary : .messageOutgoingPrimary,
                               size: .lg, width: .full, action: onSendMessage)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}
