// Ports of ts/components/CallLinkEditModal.dom.tsx ("Call link details" after creating a
// link), CallLinkAddNameModal.dom.tsx (add / edit the call name) and
// CallLinkPendingParticipantModal.dom.tsx (an admin reviewing one request to join).

import SignalI18n
import SwiftUI

public struct CallLinkEditModal: View {
    let callLink: CallLinkInfo
    let hasActiveCall: Bool
    let onClose: () -> Void
    let onCopyCallLink: () -> Void
    let onOpenCallLinkAddNameModal: () -> Void
    let onUpdateCallLinkRestrictions: (Bool) -> Void
    let onShareCallLinkViaSignal: () -> Void
    let onStartCallLinkLobby: () -> Void
    @Environment(\.i18n) var i18n

    public init(callLink: CallLinkInfo, hasActiveCall: Bool, onClose: @escaping () -> Void = {}, onCopyCallLink: @escaping () -> Void = {},
                onOpenCallLinkAddNameModal: @escaping () -> Void = {}, onUpdateCallLinkRestrictions: @escaping (Bool) -> Void = { _ in },
                onShareCallLinkViaSignal: @escaping () -> Void = {}, onStartCallLinkLobby: @escaping () -> Void = {}) {
        self.callLink = callLink
        self.hasActiveCall = hasActiveCall
        self.onClose = onClose
        self.onCopyCallLink = onCopyCallLink
        self.onOpenCallLinkAddNameModal = onOpenCallLinkAddNameModal
        self.onUpdateCallLinkRestrictions = onUpdateCallLinkRestrictions
        self.onShareCallLinkViaSignal = onShareCallLinkViaSignal
        self.onStartCallLinkLobby = onStartCallLinkLobby
    }

    /// `line-clamp-2 break-all`
    var urlRun: CSSTextRun {
        var run = CSSTextRun(callLink.webURL)
        run.breakAll = true
        return run
    }

    public var body: some View {
        AxoDialog.Content(size: .sm) {
            AxoDialog.Header { AxoDialog.Title(i18n("icu:CallLinkEditModal__Title")) }
            AxoDialog.Body(padding: .md, gutter: 11) {
                AxoList.Group {
                    AxoList.Root {
                        AxoList.Body {
                            AxoItem.Group(spacing: .sm) {
                                AxoItem.Root {
                                    AxoItem.Leading(centerToFullHeight: true) {
                                        AxoItem.IconAvatar(size: 48, symbol: "videocamera", color: callLinkColor(callLink.rootKey))
                                    }
                                    AxoItem.Content {
                                        AxoItem.Label {
                                            CSSText(callLink.name.isEmpty ? i18n("icu:calling__call-link-default-title") : callLink.name,
                                                    type: AxoType.bodyMedium.weight(600))
                                        }
                                        AxoItem.Description(interactive: true) {
                                            // The dialog's first focusable control: Radix focuses it on open.
                                            CallLinkURLButton(run: urlRun, label: i18n("icu:CallLinkDetails__CopyLink"), action: onCopyCallLink)
                                        }
                                        AxoItem.Accessory(centerToFullHeight: true) {
                                            AxoButton.Root(i18n("icu:CallLinkEditModal__JoinButtonLabel"), variant: .subtleAffirmative, size: .md,
                                                           discouraged: hasActiveCall, action: onStartCallLinkLobby)
                                                .help(hasActiveCall ? i18n("icu:calling__in-another-call-tooltip") : "")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    AxoList.Root {
                        AxoList.Body {
                            AxoItem.Group {
                                AxoClickableItem.Root(symbol: "pencil",
                                                      label: i18n(callLink.name.isEmpty ? "icu:CallLinkEditModal__AddCallNameLabel"
                                                                  : "icu:CallLinkEditModal__EditCallNameLabel"),
                                                      onClick: onOpenCallLinkAddNameModal)
                                AxoSwitchItem.Root(symbol: "person-check", label: i18n("icu:CallLinkEditModal__InputLabel--ApproveAllMembers"),
                                                   checked: Binding(get: { callLink.requiresAdminApproval }, set: { onUpdateCallLinkRestrictions($0) }))
                            }
                        }
                    }
                    AxoList.Root {
                        AxoList.Body {
                            AxoItem.Group {
                                AxoClickableItem.Root(symbol: "copy", label: i18n("icu:CallLinkDetails__CopyLink"), onClick: onCopyCallLink)
                                AxoClickableItem.Root(symbol: "share", label: i18n("icu:CallLinkDetails__ShareLinkViaSignal"), onClick: onShareCallLinkViaSignal)
                            }
                        }
                    }
                }
                // Each section is min-w-min: the first one's min-content (a 48px avatar, a 128px
                // label column and the Join button) is 288px, wider than the 266px column, and
                // the stretched sections overflow it (into the scrollbar gutter) alike.
                .frame(width: 288, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(i18n("icu:done"), variant: .strongPrimary, action: onClose)
                }
            }
        }
    }
}

/// The link in the edit modal's description: copies it; `rounded-xs` focus ring.
struct CallLinkURLButton: View {
    let run: CSSTextRun
    let label: String
    let action: () -> Void
    private var focus = AxoFocusState()

    init(run: CSSTextRun, label: String, action: @escaping () -> Void) {
        self.run = run
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            CSSText(runs: [run], style: CSSTextStyle(.bodySmall), wrap: .clamp(2))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 4)     // an inline-block on the description's 16px line: its descent below
        .axoFocusRing(focus.visible(autoFocus: true), in: RoundedRectangle(cornerRadius: 2))
        .focusable(interactions: .activate)
        .focusEffectDisabled()
        .focused(focus.$focused)
        .onChange(of: focus.focused) { _, now in if !now { focus.autoFocusConsumed = true } }
        .accessibilityLabel(label)
    }
}

public struct CallLinkAddNameModal: View {
    let callLink: CallLinkInfo
    let onClose: () -> Void
    let onUpdateCallLinkName: (String) -> Void
    @State var nameInput: String
    @Environment(\.i18n) var i18n

    /// `CallLinkNameMaxLength` / `CallLinkNameMaxByteLength`
    static let maxGraphemes = 32
    static let maxBytes = 120

    public init(callLink: CallLinkInfo, onClose: @escaping () -> Void = {}, onUpdateCallLinkName: @escaping (String) -> Void = { _ in }) {
        self.callLink = callLink
        self.onClose = onClose
        self.onUpdateCallLinkName = onUpdateCallLinkName
        _nameInput = State(initialValue: callLink.name)
    }

    /// The trimmed name, or nil while it equals the current one (Save is disabled).
    var parsedName: String? {
        let name = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return name == callLink.name ? nil : name
    }

    func submit() {
        guard let name = parsedName else { return }
        onUpdateCallLinkName(name)
        onClose()
    }

    public var body: some View {
        AxoDialog.Content(size: .sm) {
            AxoDialog.Header(focusesClose: false) {     // the name field has autoFocus
                AxoDialog.Title(i18n(callLink.name.isEmpty ? "icu:CallLinkAddNameModal__Title" : "icu:CallLinkAddNameModal__Title--Edit"))
                AxoDialog.Close(action: onClose)
            }
            AxoDialog.Body(gutter: 11) {
                VStack(spacing: 0) {
                    AxoAvatar.Root(size: 64) { AxoAvatar.Icon(symbol: "videocamera", color: callLinkColor(callLink.rootKey)) }
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 12)
                    AxoList.Group {
                        AxoFieldList.Root {
                            AxoFieldList.Item {
                                AxoTextField.Root(value: $nameInput, maxGraphemes: Self.maxGraphemes, maxBytes: Self.maxBytes) {
                                    AxoTextField.Input(placeholder: i18n("icu:CallLinkAddNameModal__NameLabel"), autoFocus: true)
                                }
                                .accessibilityLabel(i18n("icu:CallLinkAddNameModal__NameLabel"))
                                .onSubmit(submit)
                            }
                        }
                    }
                }
            }
            AxoDialog.Footer {
                AxoDialog.Actions {
                    AxoDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary, action: onClose)
                    AxoDialog.Action(i18n("icu:save"), variant: .strongPrimary, disabled: parsedName == nil, action: submit)
                }
            }
        }
    }
}

public struct CallLinkPendingParticipantModal: View {
    let conversation: CallingConversation
    let isInSystemContacts: Bool
    let sharedGroupNames: [String]
    let approveUser: () -> Void
    let denyUser: () -> Void
    let onClose: () -> Void
    let toggleAboutContactModal: () -> Void
    @Environment(\.i18n) var i18n

    public init(conversation: CallingConversation, isInSystemContacts: Bool = false, sharedGroupNames: [String] = [],
                approveUser: @escaping () -> Void = {}, denyUser: @escaping () -> Void = {}, onClose: @escaping () -> Void = {},
                toggleAboutContactModal: @escaping () -> Void = {}) {
        self.conversation = conversation
        self.isInSystemContacts = isInSystemContacts
        self.sharedGroupNames = sharedGroupNames
        self.approveUser = approveUser
        self.denyUser = denyUser
        self.onClose = onClose
        self.toggleAboutContactModal = toggleAboutContactModal
    }

    public var body: some View {
        let title = CSSTextStyle(.titleLarge)
        AxoThemeOverride(theme: .forceDark) {
            AxoDialog.Content(size: .sm, hasHeader: false, hasFooter: false) {
                AxoDialog.Body {
                    VStack(spacing: 0) {
                        Avatar(strings: AvatarStrings(i18n: i18n), title: conversation.title, size: 80, conversationType: .direct, color: conversation.color,
                               image: conversation.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: conversation.avatar != nil)
                        Button(action: toggleAboutContactModal) {
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                CSSText(conversation.title, style: title, wrap: .wrap, color: .labelPrimary)
                                if isInSystemContacts {
                                    CSSText("\u{00A0}", style: title, wrap: .nowrap)
                                    AxoContactName.SystemContactEmblem(size: 24)
                                }
                                CSSText("\u{00A0}", style: title, wrap: .nowrap)
                                AxoSymbol.InlineGlyph("chevron-[end]", size: 20, weight: 400).cssTextColor(.labelSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 12)
                        Group {
                            if sharedGroupNames.isEmpty {
                                CSSText(i18n("icu:no-groups-in-common-warning"), type: .bodyMedium, alignment: .center)
                            } else {
                                CSSText(runs: SharedGroupNames.runs(sharedGroupNames, i18n), style: CSSTextStyle(.bodyMedium), alignment: .center)
                            }
                        }
                        .cssTextColor(.labelSecondary)
                        .padding(.top, 10)
                    }
                    .frame(maxWidth: .infinity)
                    Rectangle().fill(AxoColor.borderPrimary).frame(height: 1).padding(.vertical, 24)
                    VStack(spacing: 8) {
                        AxoButton.Root(i18n("icu:CallLinkPendingParticipantModal__ApproveButtonLabel"), variant: .subtleAffirmative, size: .md,
                                       width: .full, symbol: "check") {
                            approveUser()
                            onClose()
                        }
                        AxoButton.Root(i18n("icu:CallLinkPendingParticipantModal__DenyButtonLabel"), variant: .subtleDestructive, size: .md,
                                       width: .full, symbol: "x") {
                            denyUser()
                            onClose()
                        }
                    }
                }
            }
            .overlay(alignment: .top) {
                AxoDialog.Header(floating: true) {
                    AxoDialog.Title(conversation.title)
                    AxoDialog.Close(action: onClose)
                }
            }
        }
    }
}
