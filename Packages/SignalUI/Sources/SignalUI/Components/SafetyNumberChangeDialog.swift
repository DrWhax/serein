// Port of ts/components/SafetyNumberChangeDialog.dom.tsx (stylesheets/components/
// SafetyNumberChangeDialog.scss): before sending, the contacts whose safety numbers changed —
// listed (up to five) or behind an explicit review — each viewable (or, in a story section,
// with verify / remove); a selected contact's safety number in place.

import SignalI18n
import SwiftUI

public struct SafetyNumberChangeContact: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var color: String
    public var avatar: RGBAImage?
    public var phoneNumber: String?
    /// `name || profileName`: the number is shown under the title.
    public var hasName: Bool
    public var isVerified: Bool
    public var isInSystemContacts: Bool
    public var serviceId: String?
    public init(id: String, title: String, color: String = "A200", avatar: RGBAImage? = nil, phoneNumber: String? = nil, hasName: Bool = false,
                isVerified: Bool = false, isInSystemContacts: Bool = false, serviceId: String? = nil) {
        self.id = id
        self.title = title
        self.color = color
        self.avatar = avatar
        self.phoneNumber = phoneNumber
        self.hasName = hasName
        self.isVerified = isVerified
        self.isInSystemContacts = isInSystemContacts
        self.serviceId = serviceId
    }
}

/// `StoryContacts`
public struct SafetyNumberChangeSection: Sendable {
    public struct Story: Sendable {
        public var name: String
        public var distributionId: String?
        public var isMyStory: Bool
        public init(name: String, distributionId: String? = nil, isMyStory: Bool = false) {
            self.name = name
            self.distributionId = distributionId
            self.isMyStory = isMyStory
        }
    }
    public var story: Story?
    public var contacts: [SafetyNumberChangeContact]
    public init(story: Story? = nil, contacts: [SafetyNumberChangeContact]) {
        self.story = story
        self.contacts = contacts
    }
}

public struct SafetyNumberChangeDialog<SafetyNumberView: View>: View {
    enum DialogState { case startingInReview, explicitReviewNeeded, explicitReviewStep, explicitReviewComplete }

    let confirmText: String?
    let sections: [SafetyNumberChangeSection]
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let removeFromStory: ((String, [String]) -> Void)?
    let renderSafetyNumber: (String, @escaping () -> Void) -> SafetyNumberView
    @State private var state: DialogState
    @State private var selectedContact: SafetyNumberChangeContact?
    @Environment(\.i18n) var i18n

    public init(confirmText: String? = nil, sections: [SafetyNumberChangeSection], onCancel: @escaping () -> Void = {}, onConfirm: @escaping () -> Void = {},
                removeFromStory: ((String, [String]) -> Void)? = nil,
                @ViewBuilder renderSafetyNumber: @escaping (_ contactId: String, _ onClose: @escaping () -> Void) -> SafetyNumberView) {
        self.confirmText = confirmText
        self.sections = sections
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        self.removeFromStory = removeFromStory
        self.renderSafetyNumber = renderSafetyNumber
        let count = sections.reduce(0) { $0 + $1.contacts.count }
        _state = State(initialValue: count == 0 ? .explicitReviewComplete : count > 5 ? .explicitReviewNeeded : .startingInReview)
    }

    var totalCount: Int { sections.reduce(0) { $0 + $1.contacts.count } }
    var allVerified: Bool { sections.allSatisfy { $0.contacts.allSatisfy(\.isVerified) } }

    public var body: some View {
        Group {
            if let selectedContact {
                AxoDialog.Content(size: .md, hasFooter: false) {
                    AxoDialog.Header {
                        AxoDialog.Back { self.selectedContact = nil }
                        AxoDialog.Title(i18n("icu:SafetyNumberModal__title"))
                    }
                    AxoDialog.Body(maxHeight: 560) { renderSafetyNumber(selectedContact.id) { self.selectedContact = nil } }
                }
            } else if state == .startingInReview || state == .explicitReviewStep {
                reviewDialog
            } else {
                summaryDialog
            }
        }
        .onChange(of: allVerified, initial: true) { _, verified in
            if state == .explicitReviewStep && (totalCount == 0 || verified) { state = .explicitReviewComplete }
        }
    }

    /// `ShieldIcon` over the title.
    func header(_ description: String, bottomMargin: Bool) -> some View {
        VStack(spacing: 0) {
            AxoSymbol.Icon("shield-check", size: 24, label: nil).cssTextColor(.labelAccent)
                .padding(12).background(Circle().fill(AxoColor.fillAccentTint))
                .padding(.bottom, 10)
            // <AxoDialog.Title><span type-title-medium> (h2 mb-2.5)
            CSSText(i18n("icu:safetyNumberChanges"), style: CSSTextStyle(AxoType.titleMedium), alignment: .center, color: .labelPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 10)
            CSSText(description, type: .bodyMedium, alignment: .center).padding(.bottom, bottomMargin ? 10 : 0)
        }
        .frame(maxWidth: .infinity)
    }

    var reviewDialog: some View {
        let text = state == .explicitReviewStep ? i18n("icu:safetyNumberChangeDialog_done")
            : allVerified || totalCount == 0 ? confirmText ?? i18n("icu:safetyNumberChangeDialog_send") : confirmText ?? i18n("icu:sendAnyway")
        return AxoDialog.Content(size: .md, hasHeader: false) {
            AxoDialog.Body {
                VStack(alignment: .leading, spacing: 0) {
                    header(i18n("icu:safetyNumberChangeDialog__message"), bottomMargin: true)
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        if !section.contacts.isEmpty { sectionView(section) }
                    }
                }
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary, autoFocus: true, action: onCancel)
                    AxoDialog.Action(text, variant: .strongPrimary) {
                        if state == .explicitReviewStep { state = .explicitReviewComplete } else { onConfirm() }
                    }
                }
            }
        }
    }

    var summaryDialog: some View {
        let needed = state == .explicitReviewNeeded
        let text = needed ? confirmText ?? i18n("icu:sendAnyway") : confirmText ?? i18n("icu:safetyNumberChangeDialog_send")
        let description = needed ? i18n("icu:safetyNumberChangeDialog__many-contacts", ["count": .number(Double(totalCount))])
            : i18n("icu:safetyNumberChangeDialog__post-review")
        return AxoDialog.Content(size: .md, hasHeader: false) {
            AxoDialog.Body { header(description, bottomMargin: false) }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    if !needed { AxoDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary, autoFocus: true, action: onCancel) }
                    if needed { AxoDialog.Action(i18n("icu:safetyNumberChangeDialog__review"), variant: .strongPrimary) { state = .explicitReviewStep } }
                    AxoDialog.Action(text, variant: .strongPrimary, action: onConfirm)
                }
            }
        }
    }

    /// `ContactSection`: a story's name row (body-1 bold), then the contacts (`__contacts`).
    @ViewBuilder func sectionView(_ section: SafetyNumberChangeSection) -> some View {
        if let story = section.story {
            let name = story.isMyStory ? i18n("icu:Stories__mine") : story.name
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    CSSText(name, style: LegacyType.body1(weight: 700), color: .labelPrimary).frame(maxWidth: .infinity, alignment: .leading)
                    if let id = story.distributionId, let removeFromStory, section.contacts.compactMap(\.serviceId).count > 1 {
                        RowMenu(label: i18n("icu:safetyNumberChangeDialog__actions-story", ["story": .string(name)])) {
                            AxoDropdownMenu.Item(i18n("icu:safetyNumberChangeDialog__remove-all"), symbol: "x-circle") {
                                removeFromStory(id, section.contacts.compactMap(\.serviceId))
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
                contactRows(section.contacts, distributionId: story.distributionId)
            }
        } else {
            contactRows(section.contacts, distributionId: nil)
        }
    }

    /// `ul`: list-style none, its rows 16px apart (the last margin stays).
    func contactRows(_ contacts: [SafetyNumberChangeContact], distributionId: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(contacts.enumerated()), id: \.offset) { _, c in row(c, distributionId: distributionId).padding(.bottom, 16) }
        }
        .cssTextColor(.labelPrimary)
    }

    func row(_ contact: SafetyNumberChangeContact, distributionId: String?) -> some View {
        let showNumber = contact.hasName
        let subtitle = [showNumber ? contact.phoneNumber : nil, contact.isVerified ? i18n("icu:verified") : nil].compactMap { $0 }
        return HStack(spacing: 0) {
            Avatar(strings: AvatarStrings(i18n: i18n), title: contact.title, size: 32, conversationType: .direct, color: contact.color,
                   image: contact.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: contact.avatar != nil)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    CSSText(runs: [Emojify.run(contact.title)], style: LegacyType.body1(), color: AxoColor(light: AxoColor.labelPrimary.light, dark: LegacyColor.white))
                    if contact.isInSystemContacts { InContactsIcon().padding(.leading, 4) }
                }
                if !subtitle.isEmpty {
                    CSSText(subtitle.joined(separator: "\u{00A0}·\u{00A0}"), style: LegacyType.subtitle(),
                            color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
                }
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let distributionId, let removeFromStory, let serviceId = contact.serviceId {
                RowMenu(label: i18n("icu:safetyNumberChangeDialog__actions-contact", ["contact": .string(contact.title)])) {
                    AxoDropdownMenu.Item(i18n("icu:safetyNumberChangeDialog__verify-number"), symbol: "shield-check") { selectedContact = contact }
                    AxoDropdownMenu.Item(i18n("icu:safetyNumberChangeDialog__remove"), symbol: "x-circle") { removeFromStory(distributionId, [serviceId]) }
                }
            } else {
                ViewButton(label: i18n("icu:view")) { selectedContact = contact }
            }
        }
    }

    /// `__row__view`: secondary blue text, shown on hover or focus.
    struct ViewButton: View {
        let label: String
        let action: () -> Void
        @State private var hovered = false
        @FocusState private var focused: Bool
        var body: some View {
            Button(action: action) {
                // button-secondary-blue-text: 13/18 regular, ultramarine.
                CSSText(label, style: LegacyType.body2(), color: AxoColor(light: LegacyColor.ultramarine, dark: LegacyColor.ultramarineLight))
                    .padding(.vertical, 8).padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .focused($focused)
            .opacity(hovered || focused ? 1 : 0)
            .onHover { hovered = $0 }
        }
    }

    /// `__row__chevron`: an implied-secondary chevron opening the row's menu, shown on hover.
    struct RowMenu<Items: View>: View {
        let label: String
        @ViewBuilder let items: Items
        @State private var hovered = false
        @State private var open = false
        var body: some View {
            AxoDropdownMenu.Root(isOpen: $open) {
                AxoIconButton.Root(label: label, variant: .impliedSecondary, size: .sm, symbol: "chevron-down")
            } items: {
                items
            }
            .opacity(hovered || open ? 1 : 0)
            .onHover { hovered = $0 }
        }
    }
}
