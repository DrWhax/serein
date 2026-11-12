// ProfileEditor's own subpages (ts/components/ProfileEditor.dom.tsx, `ProfileEditorPage.ProfileName`
// and `.Bio`): the name (given and family, 26 graphemes / 128 bytes each, given name required) and
// the about (140 graphemes / 512 bytes, an emoji, or one of the five presets), each with Cancel and
// Save. Save is offered only for a change; names are trimmed (`normalizeProfileName`).

import SignalI18n
import SwiftUI

/// `ProfileEditorPage.ProfileName`
public struct ProfileNameEditor: View {
    let firstName: String
    let familyName: String?
    let onSave: (_ firstName: String, _ familyName: String?) -> Void
    let onCancel: () -> Void
    @State private var stagedFirst: String
    @State private var stagedFamily: String
    @Environment(\.i18n) var i18n

    public init(firstName: String, familyName: String?, onSave: @escaping (String, String?) -> Void, onCancel: @escaping () -> Void) {
        self.firstName = firstName
        self.familyName = familyName
        self.onSave = onSave
        self.onCancel = onCancel
        _stagedFirst = State(initialValue: firstName)
        _stagedFamily = State(initialValue: familyName ?? "")
    }

    /// `normalizeProfileName`: trimmed, empty as none.
    static func normalize(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    var saveDisabled: Bool {
        guard let first = Self.normalize(stagedFirst) else { return true }
        return first == Self.normalize(firstName) && Self.normalize(stagedFamily) == Self.normalize(familyName)
    }

    public var body: some View {
        VStack(spacing: 0) {
            AxoList.Group {
                AxoFieldList.Root {
                    AxoFieldList.Item {
                        AxoTextField.Root(value: $stagedFirst, maxGraphemes: 26, maxBytes: 128) {
                            AxoTextField.Input(placeholder: i18n("icu:ProfileEditor--first-name"), autoFocus: true)
                            AxoTextField.Count()
                            AxoTextField.Clear()
                        }
                    }
                    AxoFieldList.Item {
                        AxoTextField.Root(value: $stagedFamily, maxGraphemes: 26, maxBytes: 128) {
                            AxoTextField.Input(placeholder: i18n("icu:ProfileEditor--last-name"))
                            AxoTextField.Count()
                            AxoTextField.Clear()
                        }
                    }
                }
            }
            ProfileEditorButtonFooter(saveDisabled: saveDisabled, onCancel: onCancel) {
                guard let first = Self.normalize(stagedFirst) else { return }
                onSave(first, Self.normalize(stagedFamily))
            }
        }
    }
}

/// `ProfileEditorPage.Bio`
public struct ProfileBioEditor: View {
    let aboutText: String?
    let aboutEmoji: String?
    let onSave: (_ text: String?, _ emoji: String?) -> Void
    let onCancel: () -> Void
    @State private var stagedText: String
    @State private var stagedEmoji: String?
    @State private var emojiPickerOpen = false
    @Environment(\.i18n) var i18n

    public init(aboutText: String?, aboutEmoji: String?, onSave: @escaping (String?, String?) -> Void, onCancel: @escaping () -> Void) {
        self.aboutText = aboutText
        self.aboutEmoji = aboutEmoji
        self.onSave = onSave
        self.onCancel = onCancel
        _stagedText = State(initialValue: aboutText ?? "")
        _stagedEmoji = State(initialValue: aboutEmoji)
    }

    /// `getDefaultBios`
    var defaultBios: [(label: String, emoji: String)] {
        [(i18n("icu:Bio--speak-freely"), "👋"), (i18n("icu:Bio--encrypted"), "🤐"), (i18n("icu:Bio--free-to-chat"), "👍"),
         (i18n("icu:Bio--coffee-lover"), "☕"), (i18n("icu:Bio--taking-break"), "📴")]
    }

    var saveDisabled: Bool { stagedText == (aboutText ?? "") && stagedEmoji == aboutEmoji }

    /// One line; clearing the text clears the emoji too.
    var text: Binding<String> {
        Binding(get: { stagedText }, set: { value in
            if value.isEmpty {
                stagedText = ""
                stagedEmoji = nil
            } else {
                stagedText = value.replacingOccurrences(of: "\r\n", with: "").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
            }
        })
    }

    public var body: some View {
        VStack(spacing: 0) {
            AxoList.Group {
                AxoFieldList.Root {
                    AxoFieldList.Item {
                        AxoTextField.Root(value: text, maxGraphemes: 140, maxBytes: 512) {
                            AxoTextField.CustomLeadingSlot {
                                FunEmojiPickerButton(isOpen: $emojiPickerOpen, selectedEmoji: stagedEmoji,
                                                     picker: AnyView(FunEmojiPicker(panel: FunPanelEmojis(recentEmojis: [], onSelectEmoji: { e in
                                                         stagedEmoji = e
                                                         emojiPickerOpen = false
                                                     }))))
                            }
                            AxoTextField.Input(placeholder: i18n("icu:ProfileEditor--about-placeholder"), autoFocus: true)
                            AxoTextField.Count()
                            AxoTextField.Clear(forceShow: stagedEmoji != nil)
                        }
                    }
                }
                AxoList.Root {
                    AxoList.Body {
                        AxoItem.Group {
                            ForEach(defaultBios, id: \.emoji) { bio in
                                SwiftUI.Button {
                                    stagedEmoji = bio.emoji
                                    stagedText = bio.label
                                } label: {
                                    HStack(spacing: 12) {
                                        FunStaticEmoji(bio.emoji, size: 24).frame(width: 24, height: 24)
                                        CSSText(bio.label, style: CSSTextStyle(AxoType.bodyLarge), wrap: .truncate, color: .labelPrimary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(bio.label)
                            }
                        }
                    }
                }
            }
            ProfileEditorButtonFooter(saveDisabled: saveDisabled, onCancel: onCancel) {
                let t = stagedText.trimmingCharacters(in: .whitespacesAndNewlines)
                onSave(t.isEmpty ? nil : t, t.isEmpty ? nil : stagedEmoji)
            }
        }
    }
}

/// `.ProfileEditor__button-footer`: Cancel and Save, large, at the end.
struct ProfileEditorButtonFooter: View {
    let saveDisabled: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    @Environment(\.i18n) var i18n

    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            AxoButton.Root(i18n("icu:cancel"), variant: .strongSecondary, size: .lg, action: onCancel)
            AxoButton.Root(i18n("icu:save"), variant: .strongPrimary, size: .lg, disabled: saveDisabled, action: onSave)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }
}
