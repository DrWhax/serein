// Port of ts/components/SafetyNumberViewer.dom.tsx: the safety number card (QR code, the 12
// five-digit blocks, mark as verified / clear verification), the hint, and automatic key
// verification (key transparency) with its result popups.

import AppKit
import SignalI18n
import SwiftUI

/// `SafetyNumberType`
public struct SafetyNumber: Sendable {
    public var numberBlocks: [String]
    /// The QR code's modules (from `qrData`).
    public var qrModules: [[Bool]]
    public init(numberBlocks: [String], qrData: [UInt8]) {
        self.numberBlocks = numberBlocks
        qrModules = QRCodeGenerator(bytes: qrData, level: .L).map(QrCode.matrix) ?? []
    }
    public init(numberBlocks: [String], qrModules: [[Bool]]) {
        self.numberBlocks = numberBlocks
        self.qrModules = qrModules
    }
}

public enum KeyTransparencyStatus: String, Sendable { case idle, running, ok, fail, unavailable }

public struct SafetyNumberViewer: View {
    let contactTitle: String
    let isVerified: Bool
    let safetyNumber: SafetyNumber?
    let verificationDisabled: Bool
    let keyTransparencyStatus: KeyTransparencyStatus
    let isKeyTransparencyEnabled: Bool
    let toggleVerified: () -> Void
    let checkKeyTransparency: () -> Void
    let onClose: () -> Void
    @State private var popup: KeyTransparencyStatus?
    @Environment(\.i18n) var i18n
    @Environment(\.safetyNumberHintWidth) var hintWidth
    /// The type the viewer's unstyled text inherits (body-large on a page; body-medium in AxoDialog).
    @Environment(\.safetyNumberInheritedType) var inherited

    static let safetyNumberURL = URL(string: "https://support.signal.org/hc/articles/360007060632")!
    static let keyTransparencyURL = URL(string: "https://support.signal.org/hc/articles/10223569377562")!

    public init(contactTitle: String, isVerified: Bool, safetyNumber: SafetyNumber?, verificationDisabled: Bool = false,
                keyTransparencyStatus: KeyTransparencyStatus = .idle, isKeyTransparencyEnabled: Bool = true, toggleVerified: @escaping () -> Void = {},
                checkKeyTransparency: @escaping () -> Void = {}, onClose: @escaping () -> Void = {}) {
        self.contactTitle = contactTitle
        self.isVerified = isVerified
        self.safetyNumber = safetyNumber
        self.verificationDisabled = verificationDisabled
        self.keyTransparencyStatus = keyTransparencyStatus
        self.isKeyTransparencyEnabled = isKeyTransparencyEnabled
        self.toggleVerified = toggleVerified
        self.checkKeyTransparency = checkKeyTransparency
        self.onClose = onClose
    }

    public var body: some View {
        if let safetyNumber {
            VStack(spacing: 16) {
                card(safetyNumber)
                hint(CSSTextRun.runs(i18n.richText("icu:SafetyNumberViewer__hint-v2", ["name": .element("name")]), elements: ["name": Emojify.run(contactTitle)]),
                     link: "icu:SafetyNumberViewer__learn_more", url: Self.safetyNumberURL, alignment: .center, color: nil)
                if isKeyTransparencyEnabled { keyTransparency }
            }
            .frame(maxWidth: .infinity)
            .viewportPortal {
                if let popup { AxoBaseDialog.Host { KeyTransparencyPopup(type: popup, contactTitle: contactTitle) { self.popup = nil } } }
            }
        } else {
            VStack(spacing: 16) {
                // Inherits the page's 14px text.
                CSSText(i18n("icu:cannotGenerateSafetyNumber"), type: inherited, color: .labelPrimary)
                AxoButton.Root(i18n("icu:ok"), variant: .strongPrimary, size: .lg, action: onClose)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// `rounded-[18px] bg-accent px-5 pt-7.5 pb-5 max-w-62.5`, items centred 16px apart.
    func card(_ number: SafetyNumber) -> some View {
        VStack(spacing: 16) {
            QrCode(modules: number.qrModules, alt: i18n("icu:Install__scan-this-code"))
                .padding(10)
                .background(Color.white)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            CSSText(number.numberBlocks.joined(separator: " "),
                    style: .mono(size: inherited.size, lineHeight: inherited.lineHeight, letterSpacing: inherited.tracking * inherited.size), color: .labelPrimaryOncolor)
                .frame(width: 200, alignment: .leading)
            AxoButton.Root(i18n(isVerified ? "icu:SafetyNumberViewer__clearVerification" : "icu:SafetyNumberViewer__markAsVerified"),
                           variant: .elevatedSecondary, size: .lg, disabled: verificationDisabled, action: toggleVerified)
                .environment(\.colorScheme, .light)
        }
        .padding(.horizontal, 20).padding(.top, 30).padding(.bottom, 20)
        .frame(maxWidth: 250)
        .background(RoundedRectangle(cornerRadius: 18).fill(AxoColor.fillAccent))
    }

    /// A body-small paragraph, then `&ensp;` and a "Learn more" link (text-primary). In a
    /// dialog of known width (`safetyNumberHintWidth`) it wraps exactly where Blink does.
    func hint(_ runs: [CSSTextRun], link key: String, url: URL, alignment: CSSTextAlign, color: AxoColor?) -> some View {
        let action = "learn-more"
        // a[href] (global.css): underlined.
        var link = CSSTextRun(i18n(key), color: .labelPrimary, action: action)
        link.underline = true
        return CSSText(runs: runs + [CSSTextRun("\u{2002}"), link], style: CSSTextStyle(AxoType.bodySmall), alignment: alignment, color: color) {
            if $0 == action { NSWorkspace.shared.open(url) }
        }
        .environment(\.cssTextWrapWidth, hintWidth)
    }

    var keyTransparency: some View {
        let s = keyTransparencyStatus
        let (text, icon, arrow, iconColor): (String, AxoSymbol.Name, Bool, AxoColor?) = switch s {
        case .idle: (i18n("icu:SafetyNumberViewer__KeyTransparency__button--idle"), "key", false, nil)
        case .running: (i18n("icu:SafetyNumberViewer__KeyTransparency__button--running"), "info", false, nil)
        case .ok: (i18n("icu:SafetyNumberViewer__KeyTransparency__button--ok"), "check-circle-fill", true, .labelAffirmative)
        case .unavailable, .fail: (i18n("icu:SafetyNumberViewer__KeyTransparency__button--fail"), "info", true, nil)
        }
        return VStack(alignment: .leading, spacing: 0) {
            CSSText(i18n("icu:SafetyNumberViewer__KeyTransparency__title"), type: AxoType.bodyMedium.weight(500), color: .labelPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 24).padding(.bottom, 12)
            Button {
                switch s {
                case .idle: checkKeyTransparency()
                case .running: break
                case .ok, .fail, .unavailable: popup = s
                }
            } label: {
                HStack(spacing: 0) {
                    Group {
                        if s == .running {
                            SpinnerV2(variant: .axoButtonSpinnerSecondary, size: 20, strokeWidth: 2)
                        } else {
                            AxoSymbol.Icon(icon, size: 20, label: nil).cssTextColor(iconColor ?? .labelPrimary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    .padding(.trailing, 12)
                    CSSText(text, style: CSSTextStyle(inherited), color: .labelPrimary)
                    if arrow { AxoSymbol.Icon("chevron-[end]", size: 16, label: nil).cssTextColor(.labelPrimary) }
                    Spacer(minLength: 0)
                }
                .frame(height: 20)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(AxoColor.fillPrimary))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(s == .running)
            hint([CSSTextRun(i18n("icu:SafetyNumberViewer__KeyTransparency__hint"))], link: "icu:SafetyNumberViewer__KeyTransparency__learn_more",
                 url: Self.keyTransparencyURL, alignment: .start, color: .labelSecondary)
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `Popup`: the key transparency result.
struct KeyTransparencyPopup: View {
    let type: KeyTransparencyStatus
    let contactTitle: String
    let onClose: () -> Void
    @Environment(\.i18n) var i18n

    var body: some View {
        let (icon, title, body): (AxoSymbol.Name, String, String) = switch type {
        case .ok: ("check-circle", i18n("icu:SafetyNumberViewer__KeyTransparency__popup--ok__title"),
                   i18n("icu:SafetyNumberViewer__KeyTransparency__popup--ok__body-2"))
        case .unavailable: ("info", i18n("icu:SafetyNumberViewer__KeyTransparency__popup--fail__title-2"),
                            i18n("icu:SafetyNumberViewer__KeyTransparency__popup--unavailable__body"))
        default: ("info", i18n("icu:SafetyNumberViewer__KeyTransparency__popup--fail__title-2"),
                  i18n("icu:SafetyNumberViewer__KeyTransparency__popup--fail__body-2", ["name": .string(contactTitle)]))
        }
        AxoDialog.Content(size: .sm, hasHeader: false) {
            AxoDialog.Body {
                VStack(spacing: 0) {
                    AxoSymbol.Icon(icon, size: 24, label: nil).cssTextColor(.labelAccent)
                        .padding(12).background(Circle().fill(AxoColor.fillAccentTint))
                        .padding(.bottom, 10)
                    CSSText(title, style: CSSTextStyle(AxoType.titleMedium), alignment: .center, color: .labelPrimary).padding(.bottom, 10)
                    AxoDialog.Description(body)
                }
                .frame(maxWidth: .infinity)
            }
            AxoDialog.Footer {
                AxoDialog.Actions { AxoDialog.Action(i18n("icu:ok"), variant: .strongPrimary, action: onClose) }
            }
        }
    }
}

extension EnvironmentValues {
    /// The viewer's content width when it is fixed (SafetyNumberModal's md body: 352).
    @Entry public var safetyNumberHintWidth: CGFloat? = nil
    /// The font the viewer inherits from its container (`type-body-medium` in AxoDialog.Content).
    @Entry public var safetyNumberInheritedType: AxoType = .bodyLarge
}
