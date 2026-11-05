// Port of ts/components/UsernameEditor.dom.tsx: edit the username (nickname + discriminator in
// one field group), with reservation progress and errors, Learn more, and the change /
// recover confirmations.

import SwiftUI

/// `UsernameReservationState`
public enum UsernameReservationState: Sendable { case open, closed, reserving, confirming }

/// `UsernameReservationError`
public enum UsernameReservationError: Sendable {
    case notEnoughCharacters, tooManyCharacters, checkStartingCharacter, checkCharacters, usernameNotAvailable, general, conflictOrGone
    case notEnoughDiscriminator, allZeroDiscriminator, leadingZeroDiscriminator, tooManyAttempts
}

/// `getNickname` / `getDiscriminator` (ts/types/Username.std.ts): split at the last dot.
enum Username {
    static func nickname(_ u: String) -> String { u.range(of: ".", options: .backwards).map { String(u[..<$0.lowerBound]) } ?? u }
    static func discriminator(_ u: String) -> String? { u.range(of: ".", options: .backwards).map { String(u[$0.upperBound...]) } }
}

public struct UsernameEditor: View {
    let currentUsername: String?
    let usernameCorrupted: Bool
    /// The reserved username (`reservation.username`) and its previous username.
    let reservation: (username: String, previousUsername: String?)?
    let error: UsernameReservationError?
    let state: UsernameReservationState
    let minNickname: Int
    let maxNickname: Int
    let reserveUsername: (String, String?) -> Void
    let clearUsernameReservation: () -> Void
    let confirmUsername: () -> Void
    let setUsernameReservationError: (UsernameReservationError?) -> Void
    let onClose: () -> Void

    enum UpdateState { case original, nickname, discriminator }
    @State private var updateState = UpdateState.original
    @State private var nickname: String
    @State private var customDiscriminator: String?
    @State private var learnMore = false
    @State private var confirmingSave = false
    @State private var confirmingReset = false
    @Environment(\.i18n) var i18n

    public init(currentUsername: String?, usernameCorrupted: Bool = false, reservation: (username: String, previousUsername: String?)? = nil,
                error: UsernameReservationError? = nil, state: UsernameReservationState = .open, minNickname: Int = 3, maxNickname: Int = 20,
                reserveUsername: @escaping (String, String?) -> Void = { _, _ in }, clearUsernameReservation: @escaping () -> Void = {},
                confirmUsername: @escaping () -> Void = {}, setUsernameReservationError: @escaping (UsernameReservationError?) -> Void = { _ in },
                onClose: @escaping () -> Void = {}) {
        self.currentUsername = currentUsername
        self.usernameCorrupted = usernameCorrupted
        self.reservation = reservation
        self.error = error
        self.state = state
        self.minNickname = minNickname
        self.maxNickname = maxNickname
        self.reserveUsername = reserveUsername
        self.clearUsernameReservation = clearUsernameReservation
        self.confirmUsername = confirmUsername
        self.setUsernameReservationError = setUsernameReservationError
        self.onClose = onClose
        _nickname = State(initialValue: currentUsername.map(Username.nickname) ?? "")
    }

    var currentDiscriminator: String? { currentUsername.flatMap(Username.discriminator) }

    var discriminator: String? {
        if customDiscriminator != nil || updateState == .discriminator { return customDiscriminator }
        if let reservation { return Username.discriminator(reservation.username) }
        return currentDiscriminator
    }

    var isReserving: Bool { state == .reserving }
    var isConfirming: Bool { state == .confirming }
    var canSave: Bool { !isReserving && !isConfirming && (reservation != nil || !(customDiscriminator ?? "").isEmpty) }
    var isDiscriminatorVisible: Bool {
        (!nickname.isEmpty || !(customDiscriminator ?? "").isEmpty) && (discriminator?.isEmpty == false || updateState == .discriminator)
    }

    var errorString: String? {
        switch error {
        case nil, .general, .conflictOrGone: nil
        case .notEnoughCharacters: i18n("icu:ProfileEditor--username--check-character-min-plural", ["min": .number(Double(minNickname))])
        case .tooManyCharacters: i18n("icu:ProfileEditor--username--check-character-max-plural", ["max": .number(Double(maxNickname))])
        case .checkStartingCharacter: i18n("icu:ProfileEditor--username--check-starting-character")
        case .checkCharacters: i18n("icu:ProfileEditor--username--check-characters")
        case .usernameNotAvailable: i18n("icu:ProfileEditor--username--unavailable")
        case .notEnoughDiscriminator: i18n("icu:ProfileEditor--username--check-discriminator-min")
        case .allZeroDiscriminator: i18n("icu:ProfileEditor--username--check-discriminator-all-zero")
        case .leadingZeroDiscriminator: i18n("icu:ProfileEditor--username--check-discriminator-leading-zero")
        case .tooManyAttempts: i18n("icu:ProfileEditor--username--too-many-attempts")
        }
    }

    /// `isCaseChange`: the reservation only changes the nickname's case.
    var isCaseChange: Bool {
        guard let r = reservation, let previous = r.previousUsername else { return false }
        return previous.lowercased() == r.username.lowercased()
    }

    func save() {
        if usernameCorrupted { confirmingReset = true }
        else if currentUsername == nil || isCaseChange { confirmUsername() }
        else { confirmingSave = true }
    }

    func reserve() {
        guard updateState != .original, !nickname.isEmpty, !isConfirming else { return }
        if updateState == .discriminator && (customDiscriminator ?? "").isEmpty { return }
        reserveUsername(nickname, customDiscriminator)
    }

    public var body: some View {
        let title = !nickname.isEmpty && discriminator?.isEmpty == false ? "\(nickname).\(discriminator ?? "")" : i18n("icu:ProfileEditor--username--title")
        let nicknameBinding = Binding(get: { nickname }, set: { v in
            updateState = .nickname
            nickname = v
            if v.isEmpty { clearUsernameReservation() } else { reserve() }
        })
        let discriminatorBinding = Binding(get: { discriminator ?? "" }, set: { v in
            updateState = .discriminator
            let digits = v.filter(\.isASCII).filter(\.isNumber)
            customDiscriminator = digits.isEmpty && reservation != nil ? nil : digits
            reserve()
        })
        var learn = CSSTextRun(i18n("icu:EditUsernameModalBody__learn-more"), color: .labelAccent, action: "learn-more")
        learn.fontName = nil
        return VStack(spacing: 0) {
            // mt-6 mb-4 flex-col items-center gap-4: the @ in a 64px fill-primary circle, then the title.
            VStack(spacing: 16) {
                AxoSymbol.Icon("at", size: 36, label: nil).cssTextColor(.labelPrimary)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(AxoColor.fillPrimary))
                CSSText(title, type: AxoType.bodyLarge.weight(500), color: .labelPrimary)
            }
            .padding(.top, 24).padding(.bottom, 16)
            AxoFieldList.Root(footerRuns: [CSSTextRun(i18n("icu:EditUsernameModalBody__username-helper") + " "), learn],
                              onFooterAction: { _ in learnMore = true }) {
                AxoFieldList.Item {
                    AxoFieldGroup.Root(readOnly: isConfirming) {
                        AxoTextField.Root(value: nicknameBinding, maxGraphemes: maxNickname, maxBytes: maxNickname) {
                            AxoTextField.Input(placeholder: i18n("icu:EditUsernameModalBody__username-placeholder"))
                            AxoTextField.Count()
                            AxoTextField.LoadingIndicator(pending: isReserving)
                            if let errorString { AxoTextField.ValidationError(errorString) }
                        }
                        .accessibilityLabel(i18n("icu:EditUsernameModalBody__username-label"))
                        if isDiscriminatorVisible {
                            AxoFieldGroup.Separator()
                            AxoTextField.Root(value: discriminatorBinding, maxGraphemes: 9, maxBytes: 9) {
                                AxoTextField.Input(placeholder: "00", sizing: .fit, tabularNums: true)
                            }
                            .accessibilityLabel(i18n("icu:EditUsernameModalBody__discriminator-label"))
                        }
                    }
                }
            }
            // mt-4 flex-wrap justify-end gap-2
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                AxoButton.Root(i18n("icu:cancel"), variant: .strongSecondary, size: .lg, disabled: isConfirming, action: onClose)
                AxoButton.Root(i18n("icu:save"), variant: .strongPrimary, size: .lg, pending: isConfirming, disabled: !canSave, action: save)
            }
            .padding(.top, 16)
        }
        .onChange(of: state) { _, s in
            if s == .closed { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { onClose() } }
        }
        .viewportPortal {
            if learnMore {
                AxoBaseDialog.Host {
                    AxoDialog.Content(size: .sm) {
                        AxoDialog.Header { AxoDialog.Title(i18n("icu:EditUsernameModalBody__learn-more__title")) }
                        AxoDialog.Body { CSSText(i18n("icu:EditUsernameModalBody__learn-more__body"), type: .bodyMedium) }
                        AxoDialog.Footer {
                            AxoDialog.Actions(width: .fill) { AxoDialog.Action(i18n("icu:ok"), variant: .strongPrimary) { learnMore = false } }
                        }
                    }
                }
            } else if error == .general {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: nil, description: i18n("icu:ProfileEditor--username--general-error")) {
                        AxoConfirmDialog.Ok(i18n("icu:ok")) { setUsernameReservationError(nil) }
                    }
                }
            } else if error == .conflictOrGone {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: nil, description: i18n("icu:ProfileEditor--username--reservation-gone",
                                                                        ["username": .string(reservation?.username ?? nickname)])) {
                        AxoConfirmDialog.Ok(i18n("icu:ok")) { if !nickname.isEmpty { reserveUsername(nickname, customDiscriminator) } }
                    }
                }
            } else if confirmingSave || confirmingReset {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: nil, description: i18n(confirmingReset ? "icu:EditUsernameModalBody__recover-confirmation"
                                                                        : "icu:EditUsernameModalBody__change-confirmation")) {
                        AxoConfirmDialog.Cancel(i18n("icu:cancel")) { confirmingSave = false; confirmingReset = false }
                        AxoConfirmDialog.Action(i18n("icu:EditUsernameModalBody__change-confirmation__continue"), variant: .strongDestructive,
                                                action: confirmUsername)
                    }
                }
            }
        }
    }
}
