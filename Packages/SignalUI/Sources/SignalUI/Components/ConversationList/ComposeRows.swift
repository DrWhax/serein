// Compose rows: ComposeStepButton (New group, Find by username / phone number) and
// GroupListItem (ts/components/conversationList/*.dom.tsx).

import SignalI18n
import SwiftUI

/// ComposeStepButton: a ListTile led by a 32px tinted disc with a 20px glyph.
public struct ComposeStepButton: View {
    public enum Icon: Sendable {
        case group, username, phoneNumber, callLink
        var svg: String {
            switch self {
            case .group: "v3/group/group"
            case .username: "v3/at/at"
            case .phoneNumber: "v3/number/number-light"
            case .callLink: "v3/link/link"
            }
        }
    }

    let icon: Icon
    let title: String
    let onClick: () -> Void

    public init(icon: Icon, title: String, onClick: @escaping () -> Void = {}) {
        self.icon = icon
        self.title = title
        self.onClick = onClick
    }

    public var body: some View {
        let size: CGFloat = icon == .callLink ? 36 : 32
        ListTile(onClick: onClick) {
            SignalIcon(icon.svg, size: 20, color: AxoColor(light: LegacyColor.black, dark: LegacyColor.gray05))
                .frame(width: 20, height: 20)
                .frame(width: size, height: size)
                .background(Circle().fill(AxoColor(light: LegacyColor.blackAlpha06, dark: LegacyColor.whiteAlpha12)))
        } title: {
            CSSText(title, style: ListTile<EmptyView, EmptyView, EmptyView, EmptyView>.titleStyle, wrap: .clamp(1))
        } subtitle: {
            EmptyView()
        } trailing: {
            EmptyView()
        }
    }
}

public struct GroupListItemData {
    public enum DisabledReason: Sendable { case alreadyMember, pending }
    public var id: String
    public var title: String
    public var membersCount: Int
    public var disabledReason: DisabledReason?
    public var avatar: ConversationAvatarData
    public init(id: String, title: String, membersCount: Int, disabledReason: DisabledReason? = nil, avatar: ConversationAvatarData? = nil) {
        self.id = id
        self.title = title
        self.membersCount = membersCount
        self.disabledReason = disabledReason
        self.avatar = avatar ?? ConversationAvatarData(title: title, conversationType: .group)
    }
}

public struct GroupListItem: View {
    let group: GroupListItemData
    let onSelectGroup: (String) -> Void
    @Environment(\.i18n) var i18n

    public init(group: GroupListItemData, onSelectGroup: @escaping (String) -> Void = { _ in }) {
        self.group = group
        self.onSelectGroup = onSelectGroup
    }

    public var body: some View {
        let message = switch group.disabledReason {
        case .alreadyMember: i18n("icu:GroupListItem__message-already-member")
        case .pending: i18n("icu:GroupListItem__message-pending")
        case nil: i18n("icu:GroupListItem__message-default", ["count": .number(Double(group.membersCount))])
        }
        ListTile(onClick: { if group.disabledReason == nil { onSelectGroup(group.id) } }) {
            ListAvatar(data: group.avatar, size: 32)
        } title: {
            CSSText(runs: [Self.emojified(group.title)], style: ListTile<EmptyView, EmptyView, EmptyView, EmptyView>.titleStyle, wrap: .clamp(1))
        } subtitle: {
            ListTileSubtitle(message, emojify: true)
        } trailing: {
            EmptyView()
        }
    }

    static func emojified(_ text: String) -> CSSTextRun {
        var r = CSSTextRun(text)
        r.emojify = true
        return r
    }
}

/// ts/util/Username.dom.ts
public enum UsernameSearch {
    static func isUsernameLike(_ s: String) -> Bool {
        s.range(of: #"^@?[a-zA-Z_][a-zA-Z0-9_]{2,31}(.\d*?)?$"#, options: .regularExpression) != nil
    }
    static func isAllDigits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(\.isASCII) && s.allSatisfy(\.isNumber) }

    /// `getUsernameFromSearch`
    public static func username(from searchTerm: String) -> String? {
        var term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        if isAllDigits(term) { return nil }
        if term.hasPrefix("@") { term.removeFirst() }
        return isUsernameLike(term) ? term : nil
    }

    /// `isProbablyAUsername`
    public static func isProbablyAUsername(_ text: String) -> Bool {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if term.hasPrefix("@") { return true }
        if !isUsernameLike(term) || isAllDigits(term) { return false }
        return term.range(of: #".+\.\d\d\d?$"#, options: .regularExpression) != nil
    }
}

/// `parseAndFormatPhoneNumber` (ts/util/libphonenumberInstance + PhoneNumber): a subset until
/// libphonenumber's metadata is ported. "+<digits>" numbers take their country code as typed;
/// national numbers are supported for NANP regions (US, CA, …: 10 digits, or 11 starting with
/// 1). Validity is length-based (E.164 allows 7–15 digits after "+"); the display string is
/// the user's input, as upstream shows it.
public enum PhoneNumberParsing {
    static let nanpRegions: Set<String> = ["US", "CA", "AG", "AI", "AS", "BB", "BM", "BS", "DM", "DO", "GD", "GU", "JM", "KN", "KY", "LC",
                                           "MP", "MS", "PR", "SX", "TC", "TT", "VC", "VG", "VI"]

    public static func parse(_ input: String, regionCode: String?) -> ParsedPhoneNumber? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let allowed = Set("0123456789+-() .")
        guard trimmed.allSatisfy({ allowed.contains($0) }), trimmed.contains(where: \.isNumber) else { return nil }
        let digits = trimmed.filter(\.isNumber)
        if trimmed.hasPrefix("+") {
            return ParsedPhoneNumber(isValid: (7...15).contains(digits.count), userInput: input, e164: "+" + digits)
        }
        if let region = regionCode, nanpRegions.contains(region) {
            if digits.count == 10 { return ParsedPhoneNumber(isValid: true, userInput: input, e164: "+1" + digits) }
            if digits.count == 11, digits.hasPrefix("1") { return ParsedPhoneNumber(isValid: true, userInput: input, e164: "+" + digits) }
            return ParsedPhoneNumber(isValid: false, userInput: input, e164: "+1" + digits)
        }
        return nil
    }
}
