// Port of ts/components/conversation/ContactDetail.dom.tsx: a shared contact opened from a
// message. The 80px avatar (tap to download / cancel), the name (title-large) and organization,
// Message / Video / Audio and "Add to a group" for Signal users, then one item per phone
// number, email, postal address, the nickname and the note (each a body-small label over a
// body-large value).

import SignalI18n
import SwiftUI

/// The parts of `EmbeddedContactForUIType` the detail view shows beyond `SharedContact`.
public struct ContactDetailFields: Sendable, Hashable {
    /// `ContactFormType`
    public enum FormType: Sendable, Hashable { case home, mobile, work, custom }
    /// `AddressType`
    public enum AddressType: Sendable, Hashable { case home, work, custom }

    public struct Method: Sendable, Hashable {
        public var type: FormType
        public var label: String?
        public var value: String
        public init(_ type: FormType, _ value: String, label: String? = nil) {
            self.type = type
            self.value = value
            self.label = label
        }
    }

    public struct PostalAddress: Sendable, Hashable {
        public var type: AddressType
        public var label: String?
        public var street, pobox, neighborhood, city, region, postcode, country: String?
        public init(type: AddressType, label: String? = nil, street: String? = nil, pobox: String? = nil, neighborhood: String? = nil,
                    city: String? = nil, region: String? = nil, postcode: String? = nil, country: String? = nil) {
            self.type = type
            self.label = label
            self.street = street
            self.pobox = pobox
            self.neighborhood = neighborhood
            self.city = city
            self.region = region
            self.postcode = postcode
            self.country = country
        }
    }

    public var number: [Method] = []
    public var email: [Method] = []
    public var address: [PostalAddress] = []
    public var nicknameGiven: String?
    public var nicknameFamily: String?
    public var note: String?
    public init() {}

    /// `getDisplayNickname`
    var nickname: String? { combineNames(nicknameGiven, nicknameFamily) }
    var hasFields: Bool { !number.isEmpty || !email.isEmpty || !address.isEmpty || nickname != nil || !(note ?? "").isEmpty }
}

public struct ContactDetail: View {
    let contact: SharedContact
    let fields: ContactDetailFields
    let hasActiveCall: Bool
    let onSendMessage: () -> Void
    let onStartVideoCall: () -> Void
    let onStartAudioCall: () -> Void
    let onAddToGroup: () -> Void
    let kickOffAttachmentDownload: () -> Void
    let cancelAttachmentDownload: () -> Void
    @Environment(\.i18n) var i18n

    public init(contact: SharedContact, fields: ContactDetailFields, hasActiveCall: Bool = false, onSendMessage: @escaping () -> Void = {},
                onStartVideoCall: @escaping () -> Void = {}, onStartAudioCall: @escaping () -> Void = {}, onAddToGroup: @escaping () -> Void = {},
                kickOffAttachmentDownload: @escaping () -> Void = {}, cancelAttachmentDownload: @escaping () -> Void = {}) {
        self.contact = contact
        self.fields = fields
        self.hasActiveCall = hasActiveCall
        self.onSendMessage = onSendMessage
        self.onStartVideoCall = onStartVideoCall
        self.onStartAudioCall = onStartAudioCall
        self.onAddToGroup = onAddToGroup
        self.kickOffAttachmentDownload = kickOffAttachmentDownload
        self.cancelAttachmentDownload = cancelAttachmentDownload
    }

    func label(_ m: ContactDetailFields.Method, fallback: String) -> String {
        switch m.type {
        case .custom: m.label.flatMap { $0.isEmpty ? nil : $0 } ?? i18n(fallback)
        case .home: i18n("icu:home-v2")
        case .mobile: i18n("icu:mobile-v2")
        case .work: i18n("icu:work-v2")
        }
    }

    func label(_ a: ContactDetailFields.PostalAddress) -> String {
        switch a.type {
        case .custom: a.label.flatMap { $0.isEmpty ? nil : $0 } ?? i18n("icu:address-v2")
        case .home: i18n("icu:home-v2")
        case .work: i18n("icu:work-v2")
        }
    }

    /// Tapping the avatar downloads it (or cancels a download), unless it can't be.
    var avatarAction: (() -> Void)? {
        guard let a = contact.avatar, !a.isPermanentlyUndownloadable, a.pending || !a.isDownloaded else { return nil }
        return a.pending ? cancelAttachmentDownload : kickOffAttachmentDownload
    }

    public var body: some View {
        // mx-auto w-full max-w-160 flex-col gap-6 px-4 pt-2 pb-8
        VStack(spacing: 24) {
            VStack(spacing: 0) {
                let avatar = ContactAvatar(contact: contact, isIncoming: true, size: 80)
                if let avatarAction {
                    SwiftUI.Button(action: avatarAction) { avatar }
                        .buttonStyle(.plain)
                        .accessibilityLabel(i18n(contact.avatar?.pending == true ? "icu:cancelDownload" : "icu:downloadAttachment"))
                } else {
                    avatar
                }
                // The name's div is there (mt-3) even when empty.
                Group {
                    if let name = contact.displayName {
                        CSSText(runs: [CSSTextRun(name)], style: CSSTextStyle(AxoType.titleLarge), alignment: .center, color: .labelPrimary)
                            .textSelection(.enabled)
                    } else {
                        Color.clear.frame(height: 0)
                    }
                }
                .padding(.top, 12)
                if combineNames(contact.givenName, contact.familyName) != nil, let org = contact.organization, !org.isEmpty {
                    CSSText(org, type: .bodyLarge, alignment: .center, color: .labelSecondary).padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
            if contact.canMessage {
                AxoStackedButton.Row(spacing: .md) {
                    AxoStackedButton.Root(symbol: "message", label: i18n("icu:ContactDetail__message"), onClick: onSendMessage)
                    AxoStackedButton.Root(symbol: "videocamera", label: i18n("icu:video"), discouraged: hasActiveCall, onClick: onStartVideoCall)
                        .help(hasActiveCall ? i18n("icu:calling__in-another-call-tooltip") : "")
                    AxoStackedButton.Root(symbol: "phone", label: i18n("icu:audio"), discouraged: hasActiveCall, onClick: onStartAudioCall)
                        .help(hasActiveCall ? i18n("icu:calling__in-another-call-tooltip") : "")
                }
            }
            AxoList.Group {
                if contact.canMessage {
                    AxoList.Root {
                        AxoList.Body {
                            AxoItem.Group {
                                AxoClickableItem.Root(symbol: "plus-circle", label: i18n("icu:ContactDetail__add-to-group"), onClick: onAddToGroup)
                            }
                        }
                    }
                }
                if fields.hasFields {
                    AxoList.Root {
                        AxoList.Body {
                            AxoItem.Group { items }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 32)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder var items: some View {
        ForEach(Array(fields.number.enumerated()), id: \.offset) { _, phone in
            // formatPhoneNumber(ourRegionCode): these story values aren't valid numbers and stay as given.
            ContactDataItem(label: label(phone, fallback: "icu:phone-v2"), lines: [phone.value])
        }
        ForEach(Array(fields.email.enumerated()), id: \.offset) { _, email in
            ContactDataItem(label: label(email, fallback: "icu:email-v2"), lines: [email.value])
        }
        ForEach(Array(fields.address.enumerated()), id: \.offset) { _, a in
            let cityLine = [a.city, a.region, a.postcode].contains { $0 != nil }
                ? "\(a.city ?? "") \(a.region ?? "") \(a.postcode ?? "")" : nil
            let lines = [a.street, a.pobox.map { "\(i18n("icu:poBox")) \($0)" }, a.neighborhood, cityLine, a.country].compactMap { $0 }
            ContactDataItem(label: label(a), lines: lines)
        }
        if let nickname = fields.nickname {
            ContactDataItem(label: i18n("icu:ContactDetail__nickname"), lines: [nickname])
        }
        if let note = fields.note, !note.isEmpty {
            ContactDataItem(label: i18n("icu:ContactDetail__note"), lines: [note], preWrap: true)
        }
    }
}

/// `ContactDataItem`: an item whose label is a body-small secondary caption over the
/// body-large primary value (one block per line).
struct ContactDataItem: View {
    let label: String
    let lines: [String]
    var preWrap = false

    var body: some View {
        AxoItem.Root {
            AxoItem.Content {
                AxoItem.Label {
                    VStack(alignment: .leading, spacing: 0) {
                        CSSText(label, type: .bodySmall, color: .labelSecondary)
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            CSSText(runs: [CSSTextRun(line)], style: CSSTextStyle(AxoType.bodyLarge), wrap: .wrap, color: .labelPrimary)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }
}
