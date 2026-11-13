// Port of ts/components/UsernameLinkEditor.dom.tsx + stylesheets/components/UsernameLinkEditor.scss:
// the username link card (BrandedQRCode in the chosen colour, the username with copy), Save /
// Color, the link with copy, help, Reset; the colour picker; and the reset / error / recovered
// confirmations. The exported PNG is the caller's (`onSave`).

import SignalI18n
import SwiftUI

/// `UsernameLinkState`
public enum UsernameLinkState: Sendable { case ready, updating, error }

/// `Proto.AccountRecord.UsernameLink.Color` and COLOR_MAP.
public enum UsernameLinkColor: Int, Sendable, CaseIterable {
    case unknown = 0, blue, white, grey, olive, green, orange, pink, purple
    static let picker: [UsernameLinkColor] = [.blue, .white, .grey, .olive, .green, .orange, .pink, .purple]
    /// (fg, bg, tint)
    var colors: (fg: RGBA, bg: RGBA, tint: RGBA) {
        switch self {
        case .unknown, .blue: (RGBA(hex: 0x2449c0), RGBA(hex: 0x506ecd), RGBA(hex: 0xecf0fb))
        case .white: (RGBA(hex: 0x000000), RGBA(hex: 0xffffff), RGBA(hex: 0xf5f5f5))
        case .grey: (RGBA(hex: 0x464852), RGBA(hex: 0x6a6c75), RGBA(hex: 0xf0f0f1))
        case .olive: (RGBA(hex: 0x73694f), RGBA(hex: 0xaa9c7c), RGBA(hex: 0xf6f5f2))
        case .green: (RGBA(hex: 0x55733f), RGBA(hex: 0x7c9b69), RGBA(hex: 0xf1f5f0))
        case .orange: (RGBA(hex: 0xd96b2d), RGBA(hex: 0xee691a), RGBA(hex: 0xfef1ea))
        case .pink: (RGBA(hex: 0xbb617b), RGBA(hex: 0xf77099), RGBA(hex: 0xfef1f5))
        case .purple: (RGBA(hex: 0x7651c5), RGBA(hex: 0xa183d4), RGBA(hex: 0xf5f3fb))
        }
    }
}

public struct UsernameLinkEditor: View {
    let link: String?
    let username: String
    let usernameLinkCorrupted: Bool
    let usernameLinkState: UsernameLinkState
    let initialColor: UsernameLinkColor
    let setUsernameLinkColor: (UsernameLinkColor) -> Void
    let resetUsernameLink: () -> Void
    let onSave: (UsernameLinkColor) -> Void
    let copyLink: (String) -> Void
    let copyUsername: (String) -> Void
    let onBack: () -> Void
    @State private var color: UsernameLinkColor
    @State private var showColors = false
    @State private var confirmReset = false
    @State private var showError = false
    @State private var showRecovered = false
    @Environment(\.i18n) var i18n

    public init(link: String?, username: String, usernameLinkCorrupted: Bool = false, usernameLinkState: UsernameLinkState = .ready,
                color: UsernameLinkColor = .unknown, setUsernameLinkColor: @escaping (UsernameLinkColor) -> Void = { _ in },
                resetUsernameLink: @escaping () -> Void = {}, onSave: @escaping (UsernameLinkColor) -> Void = { _ in },
                copyLink: @escaping (String) -> Void = { _ in }, copyUsername: @escaping (String) -> Void = { _ in }, onBack: @escaping () -> Void = {}) {
        self.link = link?.isEmpty == true ? nil : link
        self.username = username
        self.usernameLinkCorrupted = usernameLinkCorrupted
        self.usernameLinkState = usernameLinkState
        self.initialColor = color
        self.setUsernameLinkColor = setUsernameLinkColor
        self.resetUsernameLink = resetUsernameLink
        self.onSave = onSave
        self.copyLink = copyLink
        self.copyUsername = copyUsername
        self.onBack = onBack
        _color = State(initialValue: color)
    }

    var isReady: Bool { usernameLinkState == .ready }
    var isResettingLink: Bool { usernameLinkCorrupted || !isReady }
    func gray() -> AxoColor { AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray75) }

    /// `__link__text`: word-break break-all.
    func linkRun() -> CSSTextRun {
        var run = CSSTextRun(isResettingLink ? i18n("icu:UsernameLinkModalBody__resetting-link") : (link ?? ""))
        run.breakAll = true
        return run
    }
    static var textColor: AxoColor { AxoColor(light: LegacyColor.black, dark: LegacyColor.gray02) }

    public var body: some View {
        let c = color.colors
        let white = color == .white
        VStack(spacing: 0) {
            card(c, white: white)
            if showColors { colorsPage } else { info }
        }
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity)
        .onAppear { if usernameLinkCorrupted { resetUsernameLink() } }
        .onChange(of: usernameLinkState) { _, s in if s == .error { showError = true } }
        .onChange(of: isResettingLink) { was, now in if was && !now { showRecovered = true } }
        .viewportPortal { dialogs }
    }

    func card(_ c: (fg: RGBA, bg: RGBA, tint: RGBA), white: Bool) -> some View {
        let textColor = AxoColor(white ? RGBA(hex: 0x000000) : RGBA(hex: 0xffffff))
        return VStack(spacing: 0) {
            // __qr: 148px white, padding 10, radius 8 (white cards add a gray-05 outline)
            ZStack {
                if isReady, let link {
                    BrandedQRCode(size: 128, link: link, color: c.fg.color)
                } else if usernameLinkState == .error {
                    SignalIcon("v3/error/error-circle", size: 28, color: AxoColor(LegacyColor.gray25))
                } else {
                    Spinner(svgSize: .small).foregroundStyle(c.fg.color).cssTextColor(AxoColor(c.fg))
                }
            }
            .frame(width: 128, height: 128)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
            .overlay { if white { RoundedRectangle(cornerRadius: 8).stroke(AxoColor(LegacyColor.gray05), lineWidth: 2).padding(-1) } }
            // __username: margin 12px 2px, 16px semibold (line-height normal), letter-spacing −0.252px
            let name = CSSText(username, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 600), size: 16, lineHeight: 20, letterSpacing: -0.252),
                               alignment: .center, color: textColor)
            Group {
                if showColors {
                    name
                } else {
                    SwiftUI.Button { copyUsername(username) } label: {
                        HStack(alignment: .top, spacing: 4) {
                            SignalIcon("v3/copy/copy", size: 16, color: textColor).padding(.top, 2)
                            name
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(i18n("icu:UsernameLinkModalBody__copy"))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12).padding(.bottom, 2)
        }
        .frame(width: 148)
        .padding(.vertical, 22).padding(.horizontal, 28)
        .background(RoundedRectangle(cornerRadius: 18).fill(AxoColor(c.bg)))
        .shadow(color: white ? Color.black.opacity(0.08) : .clear, radius: 2)
        .padding(.top, 8)
    }

    func actionButton(_ icon: String, _ label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        SwiftUI.Button(action: action) {
            VStack(spacing: 4) {
                SignalIcon(icon, size: 20, color: Self.textColor).padding(.top, 2)
                CSSText(label, style: LegacyType.caption(), color: Self.textColor)
            }
            .frame(minWidth: 58)                 // min-width 68 (border-box) − padding
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 8).fill(gray()))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    @ViewBuilder var info: some View {
        HStack(spacing: 12) {
            actionButton("v3/save/save", i18n("icu:UsernameLinkModalBody__save"), disabled: link == nil || isResettingLink) { onSave(color) }
            actionButton("v3/color/color", i18n("icu:UsernameLinkModalBody__color"), disabled: false) { showColors = true }
        }
        .padding(.top, 16)
        // __link: 2px gray-05 border, radius 12, padding 12px 16px, gap 12
        HStack(spacing: 12) {
            let disabled = link == nil || isResettingLink
            SwiftUI.Button { if let link { copyLink(link) } } label: {
                SignalIcon("v3/copy/copy", size: 20, color: disabled ? AxoColor(light: LegacyColor.gray45, dark: LegacyColor.gray25) : Self.textColor)
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityLabel(i18n("icu:UsernameLinkModalBody__copy"))
            CSSText(runs: [linkRun()], style: LegacyType.body1(),
                    color: isResettingLink ? AxoColor(light: LegacyColor.gray45, dark: LegacyColor.gray25) : .labelPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12 + 2).padding(.horizontal, 16 + 2)     // padding + the 2px border
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(gray(), lineWidth: 2))
        .padding(.top, 20)
        CSSText(i18n("icu:UsernameLinkModalBody__help"), style: LegacyType.subtitle(), alignment: .center,
                color: AxoColor(light: LegacyColor.gray60, dark: LegacyColor.gray25))
            .padding(.top, 16)
        SwiftUI.Button { confirmReset = true } label: {
            CSSText(i18n("icu:UsernameLinkModalBody__reset"), style: LegacyType.body1(weight: 700),
                    color: AxoColor(light: LegacyColor.ultramarine, dark: LegacyColor.ultramarineLight))
        }
        .buttonStyle(.plain)
        .padding(.top, 12).padding(.bottom, 16)
    }

    /// `UsernameLinkColors`: a 4×2 grid of 48px swatches (gap 18px 20px), Cancel / Save.
    @ViewBuilder var colorsPage: some View {
        let current = color == .unknown ? UsernameLinkColor.blue : color
        Grid(horizontalSpacing: 20, verticalSpacing: 18) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<4, id: \.self) { col in
                        let swatch = UsernameLinkColor.picker[row * 4 + col]
                        let index = row * 4 + col
                        SwiftUI.Button { color = swatch } label: {
                            Circle().fill(AxoColor(swatch.colors.bg))
                                .overlay(Circle().strokeBorder(swatch == .white ? AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray60)
                                                               : AxoColor(swatch.colors.fg), lineWidth: 2))
                                .padding(swatch == current ? 5 : 0)
                                .overlay { if swatch == current { Circle().strokeBorder(AxoColor(light: LegacyColor.black, dark: LegacyColor.ultramarine), lineWidth: 2) } }
                                .frame(width: 48, height: 48)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(i18n("icu:UsernameLinkModalBody__color__radio", ["index": .number(Double(index + 1)), "total": .number(8)]))
                        .accessibilityAddTraits(swatch == current ? .isSelected : [])
                    }
                }
            }
        }
        .padding(.top, 24).padding(.bottom, 30)
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            LegacyButton(i18n("icu:cancel"), variant: .secondary) {
                color = initialColor
                showColors = false
            }
            LegacyButton(i18n("icu:save"), variant: .primary) {
                setUsernameLinkColor(color)
                showColors = false
            }
            .padding(.leading, 4)
        }
        .padding(.top, 14).padding(.bottom, 16)
    }

    @ViewBuilder var dialogs: some View {
        if confirmReset {
            AxoBaseDialog.Host {
                AxoConfirmDialog.Root(title: nil, description: i18n("icu:UsernameLinkModalBody__reset__confirm")) {
                    AxoConfirmDialog.Cancel(i18n("icu:cancel")) { confirmReset = false }
                    AxoConfirmDialog.Action(i18n("icu:UsernameLinkModalBody__reset"), variant: .strongDestructive) {
                        showError = false
                        confirmReset = false
                        resetUsernameLink()
                    }
                }
            }
        } else if showError {
            AxoBaseDialog.Host {
                AxoConfirmDialog.Root(title: nil, description: i18n("icu:UsernameLinkModalBody__error__text")) {
                    AxoConfirmDialog.Cancel(i18n("icu:cancel")) { showError = false; onBack() }
                    AxoConfirmDialog.Action(i18n("icu:UsernameLinkModalBody__error__fix-now"), variant: .strongPrimary) {
                        showError = false
                        resetUsernameLink()
                    }
                }
            }
        } else if showRecovered {
            AxoBaseDialog.Host {
                AxoConfirmDialog.Root(title: nil, description: i18n("icu:UsernameLinkModalBody__recovered__text")) {
                    AxoConfirmDialog.Ok(i18n("icu:ok")) { showRecovered = false }
                }
            }
        }
    }
}
