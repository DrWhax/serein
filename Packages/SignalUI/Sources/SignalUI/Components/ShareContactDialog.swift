// Port of ts/components/ShareContactDialog.dom.tsx (+ ts/util/shareContact.std.ts): pick a
// contact (searchable list, system names first), then choose what to share — photo, name,
// phone, nickname, note — with editors for the name and the photo, and send.

import SignalI18n
import SwiftUI

/// `EmbeddedContactName`
public struct EmbeddedContactName: Sendable, Hashable {
    public var prefix: String?, givenName: String?, middleName: String?, familyName: String?, suffix: String?
    public init(prefix: String? = nil, givenName: String? = nil, middleName: String? = nil, familyName: String? = nil, suffix: String? = nil) {
        self.prefix = prefix
        self.givenName = givenName
        self.middleName = middleName
        self.familyName = familyName
        self.suffix = suffix
    }
}

/// `ShareContactAvatarType`
public struct ShareContactAvatar: Sendable, Hashable {
    public var image: RGBAImage?
    public var isProfile: Bool
    public init(image: RGBAImage?, isProfile: Bool) {
        self.image = image
        self.isProfile = isProfile
    }
}

/// `ShareContactDraftType` / `ShareContactType` (no `avatarOptions`).
public struct ShareContactDraft: Sendable, Hashable {
    public var aci: String?
    public var avatar: ShareContactAvatar?
    public var avatarOptions: [ShareContactAvatar] = []
    public var name: EmbeddedContactName?
    public var e164: String?
    public var organization: String?
    public var nickname: (givenName: String?, familyName: String?)?
    public var note: String?
    public init(aci: String?, avatar: ShareContactAvatar? = nil, avatarOptions: [ShareContactAvatar] = [], name: EmbeddedContactName? = nil,
                e164: String? = nil, organization: String? = nil, nickname: (givenName: String?, familyName: String?)? = nil, note: String? = nil) {
        self.aci = aci
        self.avatar = avatar
        self.avatarOptions = avatarOptions
        self.name = name
        self.e164 = e164
        self.organization = organization
        self.nickname = nickname
        self.note = note
    }
    public static func == (a: Self, b: Self) -> Bool {
        a.aci == b.aci && a.avatar == b.avatar && a.avatarOptions == b.avatarOptions && a.name == b.name && a.e164 == b.e164
            && a.organization == b.organization && a.nickname?.givenName == b.nickname?.givenName && a.nickname?.familyName == b.nickname?.familyName
            && a.note == b.note
    }
    public func hash(into h: inout Hasher) { h.combine(aci); h.combine(e164); h.combine(note) }
}

/// A contact in the picker.
public struct ShareContactCandidate: Identifiable {
    public var id: String
    /// The title with the system contact name preferred (`withSystemContactTitle`).
    public var title: String
    public var color: String
    public var avatar: RGBAImage?
    public var about: String?
    public init(id: String, title: String, color: String = "A200", avatar: RGBAImage? = nil, about: String? = nil) {
        self.id = id
        self.title = title
        self.color = color
        self.avatar = avatar
        self.about = about
    }
}

/// `formatPhoneNumber` for the cases the dialog shows: national format for NANP numbers in the
/// US / Canada, the E.164 string otherwise.
public func shareContactFormatPhoneNumber(_ e164: String, ourRegionCode: String?) -> String {
    let digits = e164.filter(\.isNumber)
    if e164.hasPrefix("+1"), digits.count == 11, ["US", "CA"].contains(ourRegionCode ?? "") {
        let d = Array(digits.dropFirst())
        return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
    }
    return e164
}

public struct ShareContactDialog: View {
    enum Step { case selectContact, share, editName, selectPhoto }
    let contacts: [ShareContactCandidate]
    let recipientTitle: String
    let ourRegionCode: String?
    let getContactDraft: (String) -> ShareContactDraft
    let onClose: () -> Void
    let onShareContact: (ShareContactDraft) -> Void
    @State private var step = Step.selectContact
    @State private var selected: ShareContactCandidate?
    @State private var draft: ShareContactDraft?
    @State private var shareE164 = false
    @State private var shareNickname = false
    @State private var shareNote = false
    @State private var search = ""
    @Environment(\.i18n) var i18n

    public init(contacts: [ShareContactCandidate], recipientTitle: String, ourRegionCode: String?, getContactDraft: @escaping (String) -> ShareContactDraft,
                onClose: @escaping () -> Void = {}, onShareContact: @escaping (ShareContactDraft) -> Void = { _ in }) {
        self.contacts = contacts
        self.recipientTitle = recipientTitle
        self.ourRegionCode = ourRegionCode
        self.getContactDraft = getContactDraft
        self.onClose = onClose
        self.onShareContact = onShareContact
    }

    public var body: some View {
        AxoDialog.Content(size: step == .selectPhoto ? .sm : .md) {
            switch step {
            case .selectContact: selectContact
            case .share: shareStep
            case .editName: editName
            case .selectPhoto: selectPhoto
            }
        }
    }

    // MARK: Select contact

    var visibleContacts: [ShareContactCandidate] {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return contacts.sorted { $0.title.localizedCompare($1.title) == .orderedAscending } }
        let byId = Dictionary(contacts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let searchable = contacts.map { SearchableConversation(listItem: ContactListItemData(id: $0.id, title: $0.title)) }
        return ConversationSearch.filterAndSort(searchable, searchTerm: q, regionCode: ourRegionCode).compactMap { byId[$0.id] }
    }

    func select(_ c: ShareContactCandidate) {
        var d = getContactDraft(c.id)
        // withE164AsMissingName
        if d.name == nil, let e164 = d.e164 { d.name = EmbeddedContactName(givenName: shareContactFormatPhoneNumber(e164, ourRegionCode: ourRegionCode)) }
        selected = c
        draft = d
        // getDefaultShareContactSelection
        shareE164 = d.e164 != nil
        shareNickname = false
        shareNote = false
        step = .share
    }

    @ViewBuilder var selectContact: some View {
        let rows = visibleContacts
        AxoDialog.Header {
            AxoDialog.Title(i18n("icu:ShareContactDialog__SelectContact__Title"))
            AxoDialog.Close(action: onClose)
        }
        AxoDialog.Search {
            AxoSearchField.Root(value: $search) {
                AxoSearchField.Icon()
                AxoSearchField.Input(placeholder: i18n("icu:ShareContactDialog__SelectContact__SearchPlaceholder"), autoFocus: true)
                AxoSearchField.Clear()
            }
        }
        AxoDialog.Body(padding: .onlyScrollbarGutter) {
            if rows.isEmpty {
                let q = search.trimmingCharacters(in: .whitespaces)
                AxoContactList.Root {
                    AxoContactList.EmptyStateItem(title: q.isEmpty ? i18n("icu:ShareContactDialog__SelectContact__EmptyState")
                                                  : i18n("icu:ShareContactDialog__SelectContact__NoResults", ["searchQuery": .string(q)]))
                }
                .padding(.horizontal, 16).padding(.top, 16)
                .frame(height: 440, alignment: .top)
            } else {
                // h-110: the conversation list's own scroller (padding-inline 11).
                AxoDialog.AxoScrollContainer {
                    VStack(spacing: 0) {
                        ForEach(rows) { c in
                            ContactListItem(ContactListItemData(id: c.id, title: c.title, about: c.about,
                                                                avatar: ConversationAvatarData(title: c.title, color: c.color, image: c.avatar))) { _ in select(c) }
                                .frame(height: 52, alignment: .top)
                        }
                    }
                    .padding(.horizontal, 11)
                }
                .frame(height: 440)
                .cssTextColor(.labelPrimary)
            }
        }
    }

    // MARK: Share

    func avatarView(_ avatar: ShareContactAvatar?, size: CGFloat, label: String?) -> some View {
        let c = selected
        let color = c?.color ?? "A200"
        return AxoAvatar.Root(size: size) {
            AxoAvatar.Content(label: label) {
                if let image = avatar?.image {
                    AxoAvatar.Image(image, fallbackIcon: "person", fallbackColor: color)
                } else if let initials = getInitials(c?.title) {
                    AxoAvatar.Initials(initials: initials, color: color)
                } else {
                    AxoAvatar.Icon(symbol: "person", color: color)
                }
            }
        }
    }

    func photoLabel(_ avatar: ShareContactAvatar?) -> String {
        guard let avatar else { return i18n("icu:ShareContactDialog__SelectPhoto__DefaultAvatar") }
        return i18n(avatar.isProfile ? "icu:ShareContactDialog__SelectPhoto__ProfilePhoto" : "icu:ShareContactDialog__SelectPhoto__ContactPhoto")
    }

    var contactToShare: ShareContactDraft? {
        guard var d = draft else { return nil }
        if !shareE164 { d.e164 = nil }
        if !shareNickname { d.nickname = nil }
        if !shareNote { d.note = nil }
        d.avatarOptions = []
        return d
    }

    /// `canShareContact`
    var canShare: Bool {
        guard let c = contactToShare else { return false }
        let display = combineNames(c.name?.givenName, c.name?.familyName) ?? c.organization
        return (display?.isEmpty == false && c.aci != nil) || c.e164 != nil
    }

    /// A check bubble that is always on (EditableFieldItem) or a round checkbox (FieldItem).
    static var checkBubble: some View {
        AxoSymbol.Icon("check", size: 14, label: nil).cssTextColor(.labelPrimaryOncolor)
            .frame(width: 20, height: 20)
            .background(Circle().fill(AxoColor.fillAccent))
            .overlay(Circle().strokeBorder(AxoColor.borderSecondary, lineWidth: 1))
            .accessibilityHidden(true)
    }

    func editableItem(_ editLabel: String, onEdit: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
        AxoItem.Root {
            AxoItem.Leading(centerToFullHeight: true) { Self.checkBubble }
            AxoItem.Content {
                AxoItem.Label { content() }
                AxoItem.HiddenTrigger(label: editLabel, action: onEdit)
                AxoItem.Accessory(centerToFullHeight: true) { AxoSymbol.Icon("pencil", size: 20, label: nil) }
            }
        }
    }

    func fieldItem(_ label: String?, checked: Binding<Bool>, text: String) -> some View {
        AxoItem.Root {
            AxoItem.Leading(centerToFullHeight: true) { AxoCheckbox.Root(variant: .round, checked: checked, label: label ?? text) }
            AxoItem.Content {
                AxoItem.Label {
                    VStack(alignment: .leading, spacing: 0) {
                        if let label { CSSText(label, type: .bodySmall, color: .labelSecondary) }
                        CSSText(text, type: .bodyLarge, color: .labelPrimary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { checked.wrappedValue.toggle() }
                }
            }
        }
    }

    @ViewBuilder var shareStep: some View {
        let d = draft ?? ShareContactDraft(aci: nil)
        AxoDialog.Header {
            AxoDialog.Back { step = .selectContact }
            AxoDialog.Title(i18n("icu:ShareContactDialog__ShareContact__Title"))
            AxoDialog.Close(action: onClose)
        }
        AxoDialog.Body(padding: .md) {
            VStack(alignment: .leading, spacing: 12) {
                if d.aci != nil {
                    CSSText(i18n("icu:ShareContactDialog__ShareContact__Description", ["name": .string(selected?.title ?? "")]), type: .bodySmall,
                            color: .labelSecondary)
                        .padding(.horizontal, 12)
                }
                AxoList.Root {
                    AxoList.Body {
                        AxoItem.Group {
                            if !d.avatarOptions.isEmpty {
                                editableItem(i18n("icu:ShareContactDialog__ShareContact__EditPhoto"), onEdit: { step = .selectPhoto }) {
                                    avatarView(d.avatar, size: 48, label: photoLabel(d.avatar))
                                }
                            }
                            if let name = combineNames(d.name?.givenName, d.name?.familyName) {
                                editableItem(i18n("icu:ShareContactDialog__ShareContact__EditName"), onEdit: { step = .editName }) {
                                    CSSText(name, type: .bodyLarge, color: .labelPrimary)
                                }
                            }
                            if let e164 = d.e164 {
                                fieldItem(i18n("icu:phone-v2"), checked: $shareE164, text: shareContactFormatPhoneNumber(e164, ourRegionCode: ourRegionCode))
                            }
                            if let nickname = combineNames(d.nickname?.givenName, d.nickname?.familyName) {
                                fieldItem(i18n("icu:ContactDetail__nickname"), checked: $shareNickname, text: nickname)
                            }
                            if let note = d.note { fieldItem(i18n("icu:ContactDetail__note"), checked: $shareNote, text: note) }
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
        AxoDialog.Footer {
            AxoDialog.FooterContent(recipientTitle)
            AxoDialog.Actions {
                AxoDialog.IconAction(label: i18n("icu:ShareContactDialog__ShareContact__Send"), variant: .strongPrimary, symbol: "arrow-up",
                                     disabled: !canShare) { if let c = contactToShare { onShareContact(c) } }
            }
        }
    }

    // MARK: Select photo

    @State private var photoChoice: String = "default"

    func photoValue(_ a: ShareContactAvatar?) -> String { a == nil ? "default" : a!.isProfile ? "profile" : "system" }

    @ViewBuilder var selectPhoto: some View {
        let d = draft ?? ShareContactDraft(aci: nil)
        AxoDialog.Header {
            AxoDialog.Back { step = .share }
            AxoDialog.Title(i18n("icu:ShareContactDialog__SelectPhoto__Title"))
        }
        AxoDialog.Body(padding: .md) {
            HStack(spacing: 12) {
                ForEach(d.avatarOptions + [nil], id: \.self) { (option: ShareContactAvatar?) in
                    let value = photoValue(option)
                    SwiftUI.Button { photoChoice = value } label: {
                        avatarView(option, size: 80, label: nil)
                            .overlay(alignment: .bottomTrailing) {
                                if photoChoice == value {
                                    Self.checkBubble
                                } else {
                                    Circle().fill(AxoColor.fillControl).frame(width: 20, height: 20)
                                        .overlay(Circle().strokeBorder(AxoColor.borderSecondary, lineWidth: 1))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(photoLabel(option))
                    .accessibilityAddTraits(photoChoice == value ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8).padding(.bottom, 20)
            .onAppear { photoChoice = photoValue(d.avatar) }
        }
        AxoDialog.Footer {
            AxoDialog.Actions {
                AxoDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary) { step = .share }
                AxoDialog.Action(i18n("icu:done"), variant: .strongPrimary) {
                    draft?.avatar = d.avatarOptions.first { photoValue($0) == photoChoice }
                    step = .share
                }
            }
        }
    }

    // MARK: Edit name

    @State private var nameFields = ["", "", "", "", "", ""]   // prefix, given, middle, family, suffix, organization

    @ViewBuilder var editName: some View {
        let labels = ["Prefix", "GivenName", "MiddleName", "FamilyName", "Suffix", "Organization"]
        AxoDialog.Header {
            AxoDialog.Back { step = .share }
            AxoDialog.Title(i18n("icu:ShareContactDialog__EditName__Title"))
        }
        AxoDialog.Body(padding: .md) {
            AxoFieldList.Root {
                ForEach(labels.indices, id: \.self) { i in
                    AxoFieldList.Item {
                        AxoTextField.Root(value: $nameFields[i], maxGraphemes: 128, maxBytes: 512) {
                            AxoTextField.Input(placeholder: i18n("icu:ShareContactDialog__EditName__\(labels[i])"), autoFocus: i == 1)
                        }
                        .accessibilityLabel(i18n("icu:ShareContactDialog__EditName__\(labels[i])"))
                    }
                }
            }
            .padding(.bottom, 8)
            .onAppear {
                let n = draft?.name
                nameFields = [n?.prefix ?? "", n?.givenName ?? "", n?.middleName ?? "", n?.familyName ?? "", n?.suffix ?? "", draft?.organization ?? ""]
            }
        }
        AxoDialog.Footer {
            let t = nameFields.map { $0.trimmingCharacters(in: .whitespaces) }
            AxoDialog.Actions {
                AxoDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary) { step = .share }
                AxoDialog.Action(i18n("icu:done"), variant: .strongPrimary, disabled: t[1].isEmpty && t[3].isEmpty) {
                    func v(_ s: String) -> String? { s.isEmpty ? nil : s }
                    draft?.name = EmbeddedContactName(prefix: v(t[0]), givenName: v(t[1]), middleName: v(t[2]), familyName: v(t[3]), suffix: v(t[4]))
                    draft?.organization = v(t[5])
                    step = .share
                }
            }
        }
    }
}
