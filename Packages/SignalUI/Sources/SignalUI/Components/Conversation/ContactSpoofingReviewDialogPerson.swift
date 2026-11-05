// Port of ts/components/conversation/ContactSpoofingReviewDialogPerson.dom.tsx (+ stylesheets/
// components/ContactSpoofingReviewDialogPerson.scss): one of the look-alike contacts in the
// spoofing review dialog. A 48px avatar, then the name (body-1 bold), the "recently changed
// their profile name" callout, the phone number, "Signal Connection ›", the shared groups,
// and the caller's actions; each property row is a 20px icon 12px before body-2 text.

import SignalI18n
import SwiftUI

/// A contact in the spoofing review (`ConversationType` fields it shows).
public struct ContactSpoofingPerson: Sendable {
    public var title: String
    public var profileName: String?
    public var phoneNumber: String?
    public var color: String
    public var avatar: RGBAImage?
    public init(title: String, profileName: String? = nil, phoneNumber: String? = nil, color: String = "A200", avatar: RGBAImage? = nil) {
        self.title = title
        self.profileName = profileName
        self.phoneNumber = phoneNumber
        self.color = color
        self.avatar = avatar
    }
}

public struct ContactSpoofingReviewDialogPerson<Actions: View>: View {
    public typealias Person = ContactSpoofingPerson

    let conversation: Person
    let oldName: String?
    let isSignalConnection: Bool
    let sharedGroupNames: [String]
    let onClick: (() -> Void)?
    let toggleSignalConnectionsModal: () -> Void
    let actions: Actions
    @Environment(\.i18n) var i18n

    public init(conversation: Person, oldName: String? = nil, isSignalConnection: Bool = false, sharedGroupNames: [String] = [],
                onClick: (() -> Void)? = nil, toggleSignalConnectionsModal: @escaping () -> Void = {}, @ViewBuilder actions: () -> Actions) {
        self.conversation = conversation
        self.oldName = oldName
        self.isSignalConnection = isSignalConnection
        self.sharedGroupNames = sharedGroupNames
        self.onClick = onClick
        self.toggleSignalConnectionsModal = toggleSignalConnectionsModal
        self.actions = actions()
    }

    static var propertyColor: AxoColor { AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray05) }
    static var iconColor: AxoColor { AxoColor(light: LegacyColor.gray90, dark: LegacyColor.gray05) }

    public var body: some View {
        let newName = conversation.profileName ?? conversation.title
        HStack(alignment: .top, spacing: 16) {
            Avatar(strings: AvatarStrings(i18n: i18n), title: conversation.title, size: 48, conversationType: .direct, color: conversation.color,
                   image: conversation.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, onClick: onClick)
            VStack(alignment: .leading, spacing: 12) {
                let name = CSSText(runs: [Emojify.run(conversation.title)], style: LegacyType.body1(weight: 600), color: .labelPrimary)
                if let onClick {
                    SwiftUI.Button(action: onClick) { name }.buttonStyle(.plain)
                } else {
                    name
                }
                if let oldName, oldName != newName {
                    property("v3/person/person") {
                        CSSText(runs: CSSTextRun.runs(i18n.richText("icu:ContactSpoofingReviewDialog__group__name-change-info",
                                                                    ["oldName": .element("oldName"), "newName": .element("newName")]),
                                                      elements: ["oldName": Emojify.run(oldName), "newName": Emojify.run(newName)]),
                                style: LegacyType.body2(), color: Self.propertyColor)
                    }
                }
                if let phone = conversation.phoneNumber {
                    property("v3/phone/phone-compact") { CSSText(phone, style: LegacyType.body2(), color: Self.propertyColor) }
                }
                if isSignalConnection {
                    property("v3/connections/connections") {
                        SwiftUI.Button(action: toggleSignalConnectionsModal) {
                            HStack(spacing: 0) {
                                CSSText(i18n("icu:ContactSpoofingReviewDialog__signal-connection"), style: LegacyType.body2(), wrap: .nowrap,
                                        color: Self.propertyColor)
                                SignalIcon("v3/chevron/chevron-right-bold", size: 20, color: AxoColor(LegacyColor.gray45), mask: true)
                            }
                            .frame(height: 20)
                        }
                        .buttonStyle(.plain)
                    }
                }
                property("v3/group/group") {
                    if sharedGroupNames.isEmpty {
                        CSSText(i18n("icu:ContactSpoofingReviewDialog__group__members__no-shared-groups"), style: LegacyType.body2(),
                                color: Self.propertyColor)
                    } else {
                        AxoInlineFlowText(pieces: SharedGroupNames.pieces(sharedGroupNames, i18n), style: LegacyType.body2(), alignment: .start,
                                          maxLines: nil) { _ in }
                            .cssTextColor(Self.propertyColor)
                    }
                }
                actions
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func property(_ icon: String, @ViewBuilder _ text: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SignalIcon(icon, size: 20, color: Self.iconColor, mask: true)
            text()
        }
    }
}

extension ContactSpoofingReviewDialogPerson where Actions == EmptyView {
    public init(conversation: Person, oldName: String? = nil, isSignalConnection: Bool = false, sharedGroupNames: [String] = [],
                onClick: (() -> Void)? = nil, toggleSignalConnectionsModal: @escaping () -> Void = {}) {
        self.init(conversation: conversation, oldName: oldName, isSignalConnection: isSignalConnection, sharedGroupNames: sharedGroupNames,
                  onClick: onClick, toggleSignalConnectionsModal: toggleSignalConnectionsModal) { EmptyView() }
    }
}
