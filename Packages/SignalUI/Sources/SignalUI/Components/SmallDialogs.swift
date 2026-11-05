// Ports of small confirmation / alert dialogs: ErrorModal, TerminateGroupFailedModal,
// DeleteAttachmentConfirmationDialog, TapToViewNotAvailableModal, BackfillFailureModal.

import AppKit
import SignalI18n
import SwiftUI

/// `ErrorModal`
public struct ErrorModal: View {
    let title: String
    let description: String
    let onClose: () -> Void
    @Environment(\.i18n) var i18n
    public init(title: String, description: String, onClose: @escaping () -> Void = {}) {
        self.title = title
        self.description = description
        self.onClose = onClose
    }
    public var body: some View {
        AxoConfirmDialog.Root(title: title, description: description) { AxoConfirmDialog.Ok(i18n("icu:ok"), action: onClose) }
    }
}

/// `TerminateGroupFailedModal`
public struct TerminateGroupFailedModal: View {
    let onClose: () -> Void
    let onRetry: () -> Void
    @Environment(\.i18n) var i18n
    public init(onClose: @escaping () -> Void = {}, onRetry: @escaping () -> Void = {}) {
        self.onClose = onClose
        self.onRetry = onRetry
    }
    public var body: some View {
        AxoAlertDialog.Content {
            AxoAlertDialog.Body { AxoAlertDialog.Description(i18n("icu:TerminateGroupFailedModal__description")) }
            AxoAlertDialog.Footer {
                AxoAlertDialog.Cancel(i18n("icu:cancel"), action: onClose)
                AxoAlertDialog.Action(i18n("icu:TerminateGroupFailedModal__try-again"), variant: .subtleSecondary, action: onRetry)
            }
        }
    }
}

/// `DeleteAttachmentConfirmationDialog`
public struct DeleteAttachmentConfirmationDialog: View {
    let onClose: () -> Void
    let onDestroyAttachment: () -> Void
    @Environment(\.i18n) var i18n
    public init(onClose: @escaping () -> Void = {}, onDestroyAttachment: @escaping () -> Void = {}) {
        self.onClose = onClose
        self.onDestroyAttachment = onDestroyAttachment
    }
    public var body: some View {
        AxoConfirmDialog.Root(title: i18n("icu:DeleteAttachmentModal__Title"), description: i18n("icu:DeleteAttachmentModal__Body")) {
            AxoConfirmDialog.Cancel(i18n("icu:cancel"), action: onClose)
            AxoConfirmDialog.Action(i18n("icu:DeleteAttachmentModal__Delete"), variant: .strongDestructive, action: onDestroyAttachment)
        }
    }
}

/// `TapToViewNotAvailableType`
public enum TapToViewNotAvailableType: Sendable { case error, expired }

/// `TapToViewNotAvailableModal`
public struct TapToViewNotAvailableModal: View {
    let type: TapToViewNotAvailableType
    let name: String
    let onClose: () -> Void
    @Environment(\.i18n) var i18n
    public init(type: TapToViewNotAvailableType, name: String, onClose: @escaping () -> Void = {}) {
        self.type = type
        self.name = name
        self.onClose = onClose
    }
    public var body: some View {
        let key = type == .expired ? "icu:TapToViewNotAvailableModal__body--expired" : "icu:TapToViewNotAvailableModal__body--error"
        AxoConfirmDialog.Root(title: nil, description: i18n(key, ["name": .string(name)])) { AxoConfirmDialog.Ok(i18n("icu:ok"), action: onClose) }
    }
}

/// `BackfillFailureModalKind`
public enum BackfillFailureModalKind: Sendable { case timeout, notFound }

/// `BackfillFailureModal`
public struct BackfillFailureModal: View {
    let kind: BackfillFailureModalKind
    let onClose: () -> Void
    @Environment(\.i18n) var i18n
    public init(kind: BackfillFailureModalKind, onClose: @escaping () -> Void = {}) {
        self.kind = kind
        self.onClose = onClose
    }
    public var body: some View {
        let body = i18n(kind == .timeout ? "icu:BackfillFailureModal__body--timeout" : "icu:BackfillFailureModal__body--not-found")
        AxoConfirmDialog.Root(title: i18n("icu:BackfillFailureModal__title"), description: body) { AxoConfirmDialog.Ok(i18n("icu:ok"), action: onClose) }
    }
}

/// `NotePreviewModal`: the contact's note (linkified, emoji) with Edit and Done.
public struct NotePreviewModal: View {
    let note: String
    let onClose: () -> Void
    let onEdit: () -> Void
    @Environment(\.i18n) var i18n
    public init(note: String, onClose: @escaping () -> Void = {}, onEdit: @escaping () -> Void = {}) {
        self.note = note
        self.onClose = onClose
        self.onEdit = onEdit
    }
    public var body: some View {
        AxoDialog.Content(size: .sm) {
            AxoDialog.Header {
                AxoDialog.Title(i18n("icu:NotePreviewModal__Title"))
                AxoDialog.Close(action: onClose)
            }
            AxoDialog.Body {
                // <p dir="auto" class="text-primary"> in a selectable body: white-space collapses.
                let collapsed = note.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                CSSText(runs: Linkify.runs(collapsed, emojify: true), style: CSSTextStyle(AxoType.bodyMedium), color: .labelPrimary) { url in
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(i18n("icu:edit"), variant: .subtleSecondary, action: onEdit)
                    AxoDialog.Action(i18n("icu:done"), variant: .strongPrimary, action: onClose)
                }
            }
        }
    }
}

/// `CriticalIdlePrimaryDeviceModal`: a 48px destructive error icon, title, the description
/// with its "Learn more" link.
public struct CriticalIdlePrimaryDeviceModal: View {
    static let supportPage = URL(string: "https://support.signal.org/hc/articles/8997185514138-Re-connect-your-primary-device-to-continue-using-Signal-Desktop")!
    let onClose: () -> Void
    @Environment(\.i18n) var i18n
    public init(onClose: @escaping () -> Void = {}) { self.onClose = onClose }
    public var body: some View {
        AxoAlertDialog.Content {
            AxoAlertDialog.Body {
                AxoSymbol.Icon("error-circle", size: 48, label: nil).cssTextColor(.labelDestructive)
                    .frame(maxWidth: .infinity).padding(.bottom, 10)
                AxoAlertDialog.Title(i18n("icu:CriticalIdlePrimaryDeviceModal__title"))
                AxoAlertDialog.Description(runs: CSSTextRun.runs(i18n.richText("icu:CriticalIdlePrimaryDeviceModal__description"),
                                                                tags: ["learnMoreLink": I18nTagStyle(action: "learn-more")])) { _ in
                    NSWorkspace.shared.open(Self.supportPage)
                }
            }
            AxoAlertDialog.Footer { AxoAlertDialog.Ok(i18n("icu:ok"), action: onClose) }
        }
    }
}

/// `KeyTransparencyErrorDialog`: report a failed check, optionally with the debug log.
public struct KeyTransparencyErrorDialog: View {
    let isSubmitting: Bool
    let onClose: () -> Void
    let onSubmit: (Bool) -> Void
    let onViewDebugLog: () -> Void
    @State private var shareDebugLog = false
    @Environment(\.i18n) var i18n
    public init(isSubmitting: Bool = false, onClose: @escaping () -> Void = {}, onSubmit: @escaping (Bool) -> Void = { _ in },
                onViewDebugLog: @escaping () -> Void = {}) {
        self.isSubmitting = isSubmitting
        self.onClose = onClose
        self.onSubmit = onSubmit
        self.onViewDebugLog = onViewDebugLog
    }
    public var body: some View {
        AxoDialog.Content(size: .md, hasHeader: false) {
            AxoDialog.Body {
                AxoDialog.BodyTitle(i18n("icu:KeyTransparencyErrorDialog__Title-v2"))
                CSSText(i18n("icu:KeyTransparencyErrorDialog__Description-v2"), type: .bodyMedium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 10)
                // flex items-center gap-3: checkbox, label (grow, truncate), View button.
                HStack(spacing: 12) {
                    AxoCheckbox.Root(variant: .square, checked: $shareDebugLog, label: i18n("icu:KeyTransparencyErrorDialog__ShareDebugLog__Label-v2"))
                    CSSText(i18n("icu:KeyTransparencyErrorDialog__ShareDebugLog__Label-v2"), type: .bodyMedium, wrap: .truncate, color: .labelPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onTapGesture { shareDebugLog.toggle() }
                    AxoButton.Root(i18n("icu:KeyTransparencyErrorDialog__ShareDebugLog__ViewButton"), variant: .subtlePrimary, size: .sm,
                                   action: onViewDebugLog)
                }
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(i18n("icu:KeyTransparencyErrorDialog__Cancel"), variant: .subtleSecondary, action: onClose)
                    AxoDialog.Action(i18n("icu:KeyTransparencyErrorDialog__Submit"), variant: .strongPrimary, arrow: .externalLink,
                                     pending: isSubmitting) { onSubmit(shareDebugLog) }
                }
            }
        }
    }
}

/// `WhatsNewModal`: the release date and version, then the release notes as a disc list.
public struct WhatsNewModal: View {
    let date: Date
    let version: String
    let features: [String]
    let onClose: () -> Void
    @Environment(\.i18n) var i18n

    /// The current release's notes (`icu:WhatsNew__8.34--*`).
    public static let featureKeys = ["icu:WhatsNew__8.34--0", "icu:WhatsNew__8.34--1"]

    public init(date: Date, version: String, features: [String]? = nil, onClose: @escaping () -> Void = {}) {
        self.date = date
        self.version = version
        self.features = features ?? []
        self.onClose = onClose
    }

    /// moment's `LL` in English: "November 4, 2026".
    var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM d, yyyy"
        return f.string(from: date)
    }

    public var body: some View {
        let notes = features.isEmpty ? Self.featureKeys.map { i18n($0) } : features
        let style = CSSTextStyle(AxoType.bodyMedium)
        AxoDialog.Content(size: .sm, hasFooter: false) {
            AxoDialog.Header {
                AxoDialog.Title(i18n("icu:WhatsNew__modal-title"))
                AxoDialog.Close(action: onClose)
            }
            AxoDialog.Body {
                VStack(alignment: .leading, spacing: 0) {
                    CSSText("\(dateText) \u{00B7} \(version)", style: style, color: .labelPrimary)
                    if notes.count == 1 {
                        CSSText(notes[0], style: style, color: .labelPrimary).padding(.top, 8)
                    } else {
                        // ul.ms-4.mt-2.list-disc > li.mt-2: an outside "• " marker ends at the content.
                        let marker = CSSTextLayout.make("\u{2022} ", style, wrap: .nowrap, maxWidth: nil).width
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(notes, id: \.self) { note in
                                CSSText(note, style: style, color: .labelPrimary)
                                    .overlay(alignment: .topLeading) {
                                        CSSText("\u{2022} ", style: style, wrap: .nowrap, color: .labelPrimary).offset(x: -marker)
                                    }
                            }
                        }
                        .padding(.leading, 16)
                        .padding(.top, 8)               // the ul's and first li's mt-2 collapse
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// `SignalConnectionsModal`: what makes someone a Signal connection.
public struct SignalConnectionsModal: View {
    let onClose: () -> Void
    @Environment(\.i18n) var i18n
    public init(onClose: @escaping () -> Void = {}) { self.onClose = onClose }

    public var body: some View {
        let title = i18n("icu:SignalConnectionsModal__title")
        let header = i18n("icu:SignalConnectionsModal__header", ["connections": .string("\u{FFFC}")])
        let parts = header.components(separatedBy: "\u{FFFC}")
        var bold = CSSTextRun(title)
        bold.fontName = AxoFonts.interName(weight: 700)
        let runs = parts.enumerated().flatMap { i, p in i == 0 ? [CSSTextRun(p)] : [bold, CSSTextRun(p)] }
        let style = CSSTextStyle(AxoType.bodyMedium)
        return AxoDialog.Content(size: .md, hasHeader: false, hasFooter: false) {
            AxoDialog.Body {
                VStack(alignment: .leading, spacing: 0) {
                    AxoSymbol.Icon("connections", size: 36, label: nil).cssTextColor(.labelPrimary)
                        .frame(maxWidth: .infinity).padding(.bottom, 10)
                    CSSText(runs: runs, style: style, color: .labelPrimary).padding(.bottom, 10)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(["icu:SignalConnectionsModal__bullet--1", "icu:SignalConnectionsModal__bullet--2", "icu:SignalConnectionsModal__bullet--3"],
                                id: \.self) { key in
                            // RectangleBulletListItem: a 4px × 1lh rounded bar, me-4.
                            HStack(spacing: 16) {
                                RoundedRectangle(cornerRadius: 6).fill(AxoColor.fillTertiary).frame(width: 4, height: AxoType.bodyMedium.lineHeight)
                                CSSText(i18n(key), style: style, color: .labelPrimary)
                            }
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.bottom, 10)
                    CSSText(i18n("icu:SignalConnectionsModal__footer"), style: style, color: .labelPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .top) {
            AxoDialog.Header(floating: true) {
                AxoDialog.Title(title)
                AxoDialog.Close(action: onClose)
            }
        }
    }
}

/// `SafetyNumberModal`: the safety number viewer, or (no safety number yet) a not-ready note.
public struct SafetyNumberModal<Viewer: View>: View {
    let isAvailable: Bool
    let onClose: () -> Void
    let viewer: Viewer
    @Environment(\.i18n) var i18n
    static var learnMoreURL: URL { URL(string: "https://support.signal.org/hc/articles/360007060632")! }

    public init(isAvailable: Bool, onClose: @escaping () -> Void = {}, @ViewBuilder viewer: () -> Viewer) {
        self.isAvailable = isAvailable
        self.onClose = onClose
        self.viewer = viewer()
    }

    public var body: some View {
        if isAvailable {
            AxoDialog.Content(size: .md, hasFooter: false) {
                AxoDialog.Header {
                    AxoDialog.Title(i18n("icu:SafetyNumberModal__title"))
                    AxoDialog.Close(action: onClose)
                }
                // The md body is 352px wide: wrap the viewer's text exactly where Blink does.
                AxoDialog.Body(maxHeight: 560) { viewer.environment(\.safetyNumberHintWidth, 352).environment(\.safetyNumberInheritedType, .bodyMedium) }
            }
        } else {
            AxoDialog.Content(size: .md, hasHeader: false) {
                AxoDialog.Body(maxHeight: 560) {
                    CSSText(i18n("icu:SafetyNumberNotReady__body"), type: .bodyMedium).frame(maxWidth: .infinity, alignment: .leading)
                }
                AxoDialog.Footer {
                    AxoDialog.Actions {
                        AxoDialog.Action(i18n("icu:SafetyNumberNotReady__learn-more"), variant: .subtleSecondary, arrow: .externalLink) {
                            NSWorkspace.shared.open(Self.learnMoreURL)
                        }
                        AxoDialog.Action(i18n("icu:ok"), variant: .strongPrimary, autoFocus: true, action: onClose)
                    }
                }
            }
            .overlay(alignment: .top) {
                AxoDialog.Header(floating: true) { AxoDialog.Title(i18n("icu:SafetyNumberModal__title")) }
            }
        }
    }
}

/// `UsernameOnboardingModal`: what a username is, with the three 40px colour illustrations.
public struct UsernameOnboardingModal: View {
    let onNext: () -> Void
    let onSkip: () -> Void
    let onClose: () -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.colorScheme) var scheme
    public init(onNext: @escaping () -> Void = {}, onSkip: @escaping () -> Void = {}, onClose: @escaping () -> Void = {}) {
        self.onNext = onNext
        self.onSkip = onSkip
        self.onClose = onClose
    }

    func item(_ key: String, image: String) -> some View {
        // flex gap-6: the image, then (flex-1) a body-large label over a secondary description.
        HStack(alignment: .top, spacing: 24) {
            SignalIcon(scheme == .dark ? image + "_dark" : image, size: 40)
            VStack(alignment: .leading, spacing: 0) {
                CSSText(i18n("icu:UsernameOnboardingModalBody__row__\(key)__title"), type: .bodyLarge, color: .labelPrimary)
                    .accessibilityAddTraits(.isHeader)
                CSSText(i18n("icu:UsernameOnboardingModalBody__row__\(key)__body"), type: .bodyMedium, color: .labelSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    public var body: some View {
        AxoDialog.Content(size: .md) {
            AxoDialog.Header {
                AxoDialog.Title(i18n("icu:UsernameOnboardingModalBody__title"))
                AxoDialog.Close(action: onClose)
            }
            AxoDialog.Body {
                VStack(spacing: 16) {
                    item("number", image: "phone_40_color")
                    item("username", image: "usernames_40_color")
                    item("qr", image: "qr_codes_40_color")
                }
                .padding(.bottom, 8)
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(i18n("icu:UsernameOnboardingModalBody__skip"), variant: .subtleSecondary, action: onSkip)
                    AxoDialog.Action(i18n("icu:UsernameOnboardingModalBody__continue"), variant: .strongPrimary, action: onNext)
                }
            }
        }
    }
}

/// `<I18n>` (ts/components/I18n.dom.tsx): a localized message with string or element
/// components, drawn in the inherited text style.
public struct I18n: View {
    public enum Component {
        case string(String)
        /// A styled element (e.g. `<b>` → a bold run, a button → a tappable run).
        case run(CSSTextRun)
    }
    let id: String
    let components: [String: Component]
    let style: CSSTextStyle
    let onTap: ((String) -> Void)?
    @Environment(\.i18n) var i18n

    public init(_ id: String, components: [String: Component] = [:], style: CSSTextStyle = CSSTextStyle(AxoType.bodyLarge), onTap: ((String) -> Void)? = nil) {
        self.id = id
        self.components = components
        self.style = style
        self.onTap = onTap
    }

    public var body: some View {
        var args: [String: I18nArgument] = [:]
        var elements: [String: CSSTextRun] = [:]
        for (k, c) in components {
            switch c {
            case .string(let s): args[k] = .string(s)
            case .run(let r):
                args[k] = .element(k)
                elements[k] = r
            }
        }
        return CSSText(runs: CSSTextRun.runs(i18n.richText(id, args), elements: elements), style: style, color: .labelPrimary, onTap: onTap)
    }
}

/// `GroupMemberLabelInfoModal`: what member labels are, with Add / Edit label when allowed.
public struct GroupMemberLabelInfoModal: View {
    let canAddLabel: Bool
    let hasLabel: Bool
    let isEditMemberLabelEnabled: Bool
    let onClose: () -> Void
    let showEditMemberLabelScreen: () -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.colorScheme) var scheme

    public init(canAddLabel: Bool, hasLabel: Bool, isEditMemberLabelEnabled: Bool, onClose: @escaping () -> Void = {},
                showEditMemberLabelScreen: @escaping () -> Void = {}) {
        self.canAddLabel = canAddLabel
        self.hasLabel = hasLabel
        self.isEditMemberLabelEnabled = isEditMemberLabelEnabled
        self.onClose = onClose
        self.showEditMemberLabelScreen = showEditMemberLabelScreen
    }

    public var body: some View {
        AxoDialog.Content(size: .sm, hasHeader: false) {
            AxoDialog.Body {
                VStack(spacing: 0) {
                    SignalIcon(scheme == .dark ? "tag_dark" : "tag_light", size: 32).padding(.bottom, 10)
                    AxoDialog.BodyTitle(i18n("icu:GroupMemberLabelInfoModal--title"), type: .titleMedium, alignment: .center)
                    CSSText(i18n("icu:GroupMemberLabelInfoModal--description"), type: .bodyMedium, alignment: .center).frame(maxWidth: .infinity)
                }
            }
            AxoDialog.Footer {
                AxoDialog.Actions(width: .fill) {
                    // Radix focuses the first button.
                    let showsEdit = isEditMemberLabelEnabled && canAddLabel
                    if showsEdit {
                        AxoDialog.Action(i18n(hasLabel ? "icu:GroupMemberLabelInfoModal--edit-label" : "icu:GroupMemberLabelInfoModal--add-label"),
                                         variant: .subtleSecondary, autoFocus: true) {
                            showEditMemberLabelScreen()
                            onClose()
                        }
                    }
                    AxoDialog.Action(i18n("icu:ok"), variant: .strongPrimary, autoFocus: !showsEdit, action: onClose)
                }
            }
        }
    }
}
